// ScreenScan.qml — XYLOSOME primary screen + velocity-time program editor.
// Root screen — splash advances here directly on boot.
//
// Layout (960×540 @ scale 2):
//   Top half    y=0..270   Canvas — full-width spline editor + rainbow void
//   Hairline    y=270
//   Bottom half y=270..540
//       Left:   "XYLOSOME" title + "temporal scanning unit" subtitle
//               gear icon at bottom-left → pushes ScreenHome (nav menu)
//       Right:  ▶ play  and  ⏹ stop/reset  buttons in a column
//
// Spline interactions:
//   Drag node           → reshape curve  (endpoints: Y only; free nodes: X+Y)
//   Drag handle         → resize time axis (box_w)
//   Double-tap canvas   → insert node on curve at that x
//   Double-tap node     → delete it  (endpoints immune, minimum 2 nodes)

import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root
    width: 960; height: 540

    // ── Layout constants ──────────────────────────────────────────────────────
    readonly property int canvasX:    0
    readonly property int canvasY:    0
    readonly property int canvasW:    960   // hardcoded — do not bind to root.width
    readonly property int canvasH:    270          // top half of screen
    readonly property int plotPadT:    29
    readonly property int plotPadB:    22
    readonly property int boxMinW:    200
    readonly property int nodeSzEnd:    8
    readonly property int nodeSzMid:   10

    // ── Mutable state ─────────────────────────────────────────────────────────
    property int    boxW:            580
    property int    insertMarkerIdx: -1
    property real   playheadX:       -1
    property bool   isPlaying:       false

    // Execute button state machine: "idle" | "running" | "paused"
    property string execState:    "idle"
    property bool   blinkVisible: true        // drives [resume] blink
    property bool   dialBlinkOn:  true        // drives the dial "select" hand blink
    property bool   homed:        false       // bind to Motor.homed when C++ side adds it
    property bool   _dialDriving: false       // breaks boxW ↔ angle feedback loop
    readonly property real arcDegrees: Math.max(10, hand2Angle - hand1Angle)
    readonly property real maxSpeed:   100.0  // deg/s — Panasonic servo reference speed

    // ── Multi-pass state ──────────────────────────────────────────────────────
    // One execute = 4 sequential passes (R / G / B / C), same curve each time.
    property bool inMultiPass:  false
    property int  currentPass:  0             // 0=R  1=G  2=B  3=C

    readonly property var passChannelNames: ["R", "G", "B", "C"]
    readonly property var passChannelColors: ["#CC4444", "#44CC44", "#4488CC", "#AAAAAA"]

    // Dial hands — independent angles.
    // Green bar (boxW) drives hand2 only (via onBoxWChanged).
    // Dragging each node tip moves that hand independently.
    // AR 1 → hand2 ≈ 90°   AR 3 → hand2 ≈ 180°   formula: 45*AR + 45
    property real hand1Angle:  0
    property real hand2Angle:  0
    readonly property real redHandAngle: playheadX < 0
        ? hand1Angle
        : hand1Angle + (Math.min(playheadX, boxW) / boxW) * (hand2Angle - hand1Angle)

    onIsPlayingChanged: Motor.sequencePlaying = isPlaying

    // ── Touch-free focus ────────────────────────────────────────────────────────
    // Sections: spline editor · dial · settings · execute · home. The encoder
    // cycles between them; enter acts on buttons. Entering the spline editor
    // descends through edit levels:
    //   "box"   — rotate drags the green bar (aspect/duration)
    //   "scrub" — a red cursor rides the curve; enter grabs a node (or inserts
    //             one on empty curve) and descends to "node"
    //   "node"  — rotate moves the grabbed node up/down; enter drops it → "scrub"
    // Back climbs one level (node→scrub→box→section). The [home] button jumps
    // fully out while editing.
    property var    focusController: scanFocus
    property string editTarget:   "none"    // none | spline | dial
    property string splineLevel:  "none"    // none | box | scrub | node
    property real   scrubNx:       0.5       // red scrub cursor position (0..1)
    property int    activeNodeIdx: -1        // node being adjusted at "node" level
    property int    hoverNodeIdx:  -1        // node under the scrub cursor at "scrub"
    property int    dialSel:        0        // dial edit: 0 none · 1 start hand · 2 end hand
    property string dialLevel:    "none"    // dial edit: none | select | move

    // Invisible geometry proxy for the spline EDIT BOX (x:0..boxW). The focus
    // brackets frame this — just the editable box, not the full canvas + rainbow
    // void — and because its width tracks boxW the brackets follow the box as the
    // aspect changes.
    Item {
        id: splineBox
        x: root.canvasX; y: root.canvasY
        width: root.boxW; height: root.canvasH
    }

    FocusController {
        id: scanFocus
        targets: [splineBox, resetCurveBtn, motorCircle, settingsBtn, playBtn, resetBtn]
        index: 4   // default focus on [execute]
        onActivated: function(item) {
            if (item === splineBox) root.enterSplineEditing()
            else if (item === motorCircle) root.enterDialEditing()
            else if (item === resetCurveBtn || item === settingsBtn
                     || item === playBtn || item === resetBtn)
                item.clicked()
        }
        onAdjust:    function(delta) { root.editAdjust(delta) }
        onConfirmed: root.editConfirm()
        onCanceled:  root.editCancel()
    }

    // Context action (pendant BTN1 / Delete key): erase the node under the red
    // cursor while editing the curve. Endpoints and the 3-node minimum are
    // protected by deleteNode().
    function focusContext() {
        if (!scanFocus.editing) return
        if (root.splineLevel !== "scrub" && root.splineLevel !== "node") return
        var idx = (root.splineLevel === "node") ? root.activeNodeIdx
                                                 : root.nearestNodeIdx(root.scrubNx, 0.02)
        if (idx < 0) return
        root.deleteNode(idx)
        root.activeNodeIdx = -1
        root.splineLevel   = "scrub"
        root.hoverNodeIdx  = root.nearestNodeIdx(root.scrubNx, 0.02)
        root.scheduleRepaint()
    }

    // Flatten the curve to three evenly-spaced nodes on the zero (centre) axis.
    function resetCurve() {
        nodeModel.clear()
        nodeModel.append({ nx: 0.0, ny: 0.5, locked: true  })
        nodeModel.append({ nx: 0.5, ny: 0.5, locked: false })
        nodeModel.append({ nx: 1.0, ny: 0.5, locked: true  })
        root.activeNodeIdx = -1
        root.hoverNodeIdx  = -1
        root.scheduleRepaint()
        root.pushNodesToMotor()
    }

    // Brackets frame the focused section when navigating; during spline editing
    // they frame the green bar at "box" level and hand off to the red cursor /
    // node highlight at deeper levels.
    // Corner brackets are reserved for the graphic objects (spline canvas, dial)
    // and the box handle while editing. Buttons show focus via their own accent
    // border (TerminalButton.controller), so they're excluded here.
    FocusIndicator {
        inset: true   // brackets sit just inside the box edges (clear of the resize bar)
        target: scanFocus.editing
                ? (root.splineLevel === "box" ? splineBox : null)
                : ((scanFocus.current === splineBox || scanFocus.current === motorCircle)
                   ? scanFocus.current : null)
    }

    // ── Spline edit-level helpers ───────────────────────────────────────────────
    function nearestNodeIdx(nx, thresh) {
        var best = -1, bd = thresh
        for (var i = 0; i < nodeModel.count; i++) {
            var d = Math.abs(nodeModel.get(i).nx - nx)
            if (d < bd) { bd = d; best = i }
        }
        return best
    }

    function enterSplineEditing() {
        scanFocus.editing = true
        root.editTarget   = "spline"
        root.splineLevel  = "box"
        root.scheduleRepaint()
    }

    function exitSplineEditing() {
        scanFocus.editing  = false
        root.editTarget    = "none"
        root.splineLevel   = "none"
        root.activeNodeIdx = -1
        root.hoverNodeIdx  = -1
        root.scheduleRepaint()
    }

    // ── Edit dispatch — routes encoder turn/enter/back to the active editor ─────
    function editAdjust(d) {
        if (root.editTarget === "spline")    root.splineAdjust(d)
        else if (root.editTarget === "dial") root.dialAdjust(d)
    }
    function editConfirm() {
        if (root.editTarget === "spline")    root.splineConfirm()
        else if (root.editTarget === "dial") root.dialConfirm()
    }
    function editCancel() {
        if (root.editTarget === "spline")    root.splineCancel()
        else if (root.editTarget === "dial") root.dialCancel()
    }

    // ── Dial editing — select a hand, rotate to move it ─────────────────────────
    // enter on the dial selects the start hand; rotate moves it; enter advances to
    // the end hand; enter again (or back from start) exits. Back steps one level.
    function enterDialEditing() {
        scanFocus.editing = true
        root.editTarget   = "dial"
        root.dialLevel    = "select"   // first choose which hand
        root.dialSel      = 1
        root.scheduleRepaint()
    }
    function exitDialEditing() {
        scanFocus.editing = false
        root.editTarget   = "none"
        root.dialLevel    = "none"
        root.dialSel      = 0
        root.scheduleRepaint()
    }
    function dialAdjust(d) {
        if (root.dialLevel === "select") {
            // rotate to choose which hand (start / end)
            if (d > 0)      root.dialSel = 2
            else if (d < 0) root.dialSel = 1
            root.scheduleRepaint()
            return
        }
        // "move": rotate moves the selected hand
        var step = 2   // degrees per detent
        if (root.dialSel === 1)
            root.hand1Angle = Math.max(0, Math.min(root.hand2Angle - 10, root.hand1Angle + d * step))
        else if (root.dialSel === 2)
            root.hand2Angle = Math.min(360, Math.max(root.hand1Angle + 10, root.hand2Angle + d * step))
        // Keep boxW in sync with the arc, same as the hand-tip drag handlers.
        var arc = root.hand2Angle - root.hand1Angle
        root._dialDriving = true
        root.boxW = Math.max(root.boxMinW, Math.min(root.canvasW - 45,
                              Math.round(arc * (root.canvasW - 45) / 180)))
        root._dialDriving = false
        root.scheduleRepaint()
        Motor.seqBoxW = root.boxW
    }
    function dialConfirm() {
        if (root.dialLevel === "select")    root.dialLevel = "move"   // pick hand → move it
        else if (root.dialLevel === "move") root.dialLevel = "select" // done → reselect
    }
    function dialCancel() {
        if (root.dialLevel === "move")        root.dialLevel = "select"
        else if (root.dialLevel === "select") root.exitDialEditing()
    }

    function splineAdjust(d) {
        if (root.splineLevel === "box") {
            root.boxW = Math.max(root.boxMinW, Math.min(root.canvasW - 45, root.boxW + d * 12))
            Motor.seqBoxW = root.boxW
            root.scheduleRepaint()
        } else if (root.splineLevel === "scrub") {
            root.scrubNx = Math.max(0, Math.min(1, root.scrubNx + d * (1 / 60)))
            root.hoverNodeIdx = root.nearestNodeIdx(root.scrubNx, 0.02)
            root.scheduleRepaint()
        } else if (root.splineLevel === "node" && root.activeNodeIdx >= 0) {
            var nd = nodeModel.get(root.activeNodeIdx)
            // Rotate up (negative delta) raises the node (ny decreases toward 0).
            var ny = Math.max(0.01, Math.min(0.99, nd.ny - d * 0.02))
            nodeModel.setProperty(root.activeNodeIdx, "ny", ny)
            root.pushNodesToMotor()
            root.scheduleRepaint()
        }
    }

    function splineConfirm() {
        if (root.splineLevel === "box") {
            root.splineLevel  = "scrub"
            root.hoverNodeIdx = root.nearestNodeIdx(root.scrubNx, 0.02)
            root.scheduleRepaint()
        } else if (root.splineLevel === "scrub") {
            var hit = root.nearestNodeIdx(root.scrubNx, 0.02)
            if (hit >= 0) {
                root.deleteNode(hit)                           // enter on a node → erase it
                root.hoverNodeIdx = root.nearestNodeIdx(root.scrubNx, 0.02)
                // stay at scrub level
            } else {
                var f = root.findOnCurve(root.scrubNx * root.boxW)
                root.insertNode(f.seg, f.nx, f.ny)             // empty curve → add + grab
                root.activeNodeIdx = f.seg + 1
                root.splineLevel = "node"
            }
            root.scheduleRepaint()
        } else if (root.splineLevel === "node") {
            root.activeNodeIdx = -1                            // drop, back to scrub
            root.splineLevel   = "scrub"
            root.hoverNodeIdx   = root.nearestNodeIdx(root.scrubNx, 0.02)
            root.scheduleRepaint()
        }
    }

    function splineCancel() {
        if (root.splineLevel === "node") {
            root.activeNodeIdx = -1
            root.splineLevel   = "scrub"
            root.scheduleRepaint()
        } else if (root.splineLevel === "scrub") {
            root.splineLevel = "box"
            root.scheduleRepaint()
        } else if (root.splineLevel === "box") {
            root.exitSplineEditing()
        }
    }

    // ── Sync functions (called from main.qml Connections) ─────────────────────

    function syncNodes(nodesArr) {
        if (!nodesArr || nodesArr.length < 2) return
        if (nodesArr.length !== nodeModel.count) {
            nodeModel.clear()
            for (var j = 0; j < nodesArr.length; j++) {
                var isEnd = (j === 0 || j === nodesArr.length - 1)
                var nx_j = nodesArr[j].nx !== undefined ? nodesArr[j].nx : nodesArr[j]["nx"]
                var ny_j = nodesArr[j].ny !== undefined ? nodesArr[j].ny : nodesArr[j]["ny"]
                nodeModel.append({ nx: nx_j, ny: ny_j, locked: isEnd })
            }
            scheduleRepaint()
            return
        }
        var changed = false
        for (var i = 0; i < nodeModel.count; i++) {
            var nx = nodesArr[i].nx !== undefined ? nodesArr[i].nx : nodesArr[i]["nx"]
            var ny = nodesArr[i].ny !== undefined ? nodesArr[i].ny : nodesArr[i]["ny"]
            if (Math.abs(nodeModel.get(i).nx - nx) > 0.001) { nodeModel.setProperty(i, "nx", nx); changed = true }
            if (Math.abs(nodeModel.get(i).ny - ny) > 0.001) { nodeModel.setProperty(i, "ny", ny); changed = true }
        }
        if (changed) scheduleRepaint()
    }

    function syncBoxW(w) {
        if (w > 0 && w !== root.boxW) root.boxW = w
    }

    function syncSequencePlaying(playing) {
        if (playing && root.execState === "idle") {
            if (root.playheadX < 0) root.playheadX = 0
            root.isPlaying  = true
            root.execState  = "running"
            playheadTimer.start()
        } else if (!playing && root.execState === "running") {
            playheadTimer.stop()
            root.isPlaying = false
            root.execState = "idle"
        }
    }

    // ── Derived properties ────────────────────────────────────────────────────
    readonly property int plotH: canvasH - plotPadT - plotPadB   // 219 px

    readonly property int linesCount: Math.max(1, Math.round(boxW / canvasH * 8000))

    function formatLines(n) {
        return n.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ".")
    }

    // ── Node model ────────────────────────────────────────────────────────────
    ListModel {
        id: nodeModel
        ListElement { nx: 0.00; ny: 0.52; locked: true  }
        ListElement { nx: 0.27; ny: 0.27; locked: false }
        ListElement { nx: 0.50; ny: 0.63; locked: false }
        ListElement { nx: 0.70; ny: 0.17; locked: false }
        ListElement { nx: 1.00; ny: 0.41; locked: true  }
    }

    // ── Coordinate helpers ────────────────────────────────────────────────────
    function pxOfNx(nx) { return nx * root.boxW }
    function pyOfNy(ny) {
        var ph = root.canvasH - root.plotPadT - root.plotPadB
        return root.plotPadT + ny * ph
    }

    // ── Catmull-Rom spline ────────────────────────────────────────────────────
    function evalSeg(seg, t) {
        var n = nodeModel.count
        function cl(j) { return j < 0 ? 0 : (j >= n ? n - 1 : j) }
        var xs = [], ys = []
        for (var k = 0; k < n; k++) {
            xs.push(pxOfNx(nodeModel.get(k).nx))
            ys.push(pyOfNy(nodeModel.get(k).ny))
        }
        var x0 = xs[seg],   y0 = ys[seg]
        var x1 = xs[seg+1], y1 = ys[seg+1]
        var c1x = x0 + (xs[cl(seg+1)] - xs[cl(seg-1)]) / 6.0
        var c1y = y0 + (ys[cl(seg+1)] - ys[cl(seg-1)]) / 6.0
        var c2x = x1 - (xs[cl(seg+2)] - xs[cl(seg)])   / 6.0
        var c2y = y1 - (ys[cl(seg+2)] - ys[cl(seg)])   / 6.0
        var mt = 1.0 - t
        return {
            x: mt*mt*mt*x0 + 3*mt*mt*t*c1x + 3*mt*t*t*c2x + t*t*t*x1,
            y: mt*mt*mt*y0 + 3*mt*mt*t*c1y + 3*mt*t*t*c2y + t*t*t*y1
        }
    }

    function speedAtX(px) {
        if (nodeModel.count < 2) return 0
        var nx_t = Math.max(0, Math.min(1, px / root.boxW))
        var n = nodeModel.count
        var seg = n - 2
        for (var i = 0; i < n - 1; i++) {
            if (nodeModel.get(i).nx <= nx_t && nx_t <= nodeModel.get(i+1).nx) { seg = i; break }
        }
        var lo = 0.0, hi = 1.0
        for (var k = 0; k < 16; k++) {
            var m = (lo + hi) * 0.5
            if (evalSeg(seg, m).x < px) lo = m; else hi = m
        }
        var pt = evalSeg(seg, (lo + hi) * 0.5)
        var ph = root.canvasH - root.plotPadT - root.plotPadB
        var ny = (pt.y - root.plotPadT) / ph
        return Math.min(1.0, Math.abs(0.5 - ny) * 2.0)
    }

    function avgVelocity() {
        var n = nodeModel.count
        var ph = root.canvasH - root.plotPadT - root.plotPadB
        var sv = 0.0, sd = 0.0
        for (var i = 0; i < n - 1; i++) {
            for (var k = 0; k < 40; k++) {
                var p0 = evalSeg(i,  k      / 40.0)
                var p1 = evalSeg(i, (k + 1) / 40.0)
                var dnx = (p1.x - p0.x) / root.boxW
                var mny = ((p0.y - root.plotPadT) / ph + (p1.y - root.plotPadT) / ph) / 2.0
                sv += (0.5 - mny) * Math.abs(dnx)
                sd += Math.abs(dnx)
            }
        }
        return sd > 0.0 ? sv / sd : 0.0
    }

    function findOnCurve(cxLocal) {
        var n = nodeModel.count
        var nx_t = Math.max(0.01, Math.min(0.99, cxLocal / root.boxW))
        var seg = n - 2
        for (var i = 0; i < n - 1; i++) {
            if (nodeModel.get(i).nx <= nx_t && nx_t <= nodeModel.get(i+1).nx) { seg = i; break }
        }
        var lo = 0.0, hi = 1.0
        for (var k = 0; k < 24; k++) {
            var m = (lo + hi) * 0.5
            if (evalSeg(seg, m).x < cxLocal) lo = m; else hi = m
        }
        var pt = evalSeg(seg, (lo + hi) * 0.5)
        var ph = root.canvasH - root.plotPadT - root.plotPadB
        var ny = (pt.y - root.plotPadT) / ph
        return { seg: seg, nx: nx_t, ny: Math.max(0.01, Math.min(0.99, ny)) }
    }

    // ── Node mutation helpers ─────────────────────────────────────────────────
    function moveNode(idx, dx, dy) {
        var n    = nodeModel.count
        var node = nodeModel.get(idx)
        var ph   = root.canvasH - root.plotPadT - root.plotPadB
        if (!node.locked) {
            var lo = idx > 0     ? nodeModel.get(idx-1).nx + 0.04 : 0.0
            var hi = idx < n-1   ? nodeModel.get(idx+1).nx - 0.04 : 1.0
            nodeModel.setProperty(idx, "nx", Math.max(lo, Math.min(hi, node.nx + dx / root.boxW)))
        }
        nodeModel.setProperty(idx, "ny", Math.max(0.01, Math.min(0.99, node.ny + dy / ph)))
        root.scheduleRepaint()
        root.pushNodesToMotor()
    }

    function deleteNode(idx) {
        if (nodeModel.get(idx).locked) return
        if (nodeModel.count < 3) return
        nodeModel.remove(idx)
        root.scheduleRepaint()
        root.pushNodesToMotor()
    }

    function insertNode(seg, nx, ny) {
        if (nodeModel.count >= 10) return
        nodeModel.insert(seg + 1, { nx: nx, ny: ny, locked: false })
        root.scheduleRepaint()
        root.pushNodesToMotor()
    }

    function pushNodesToMotor() {
        var arr = []
        for (var i = 0; i < nodeModel.count; i++)
            arr.push({"nx": nodeModel.get(i).nx, "ny": nodeModel.get(i).ny})
        Motor.setNodesFromJson(JSON.stringify(arr))
        Motor.seqBoxW = root.boxW
    }

    // ── Canvas (top half) ─────────────────────────────────────────────────────

    Canvas {
        id: canvas
        x: root.canvasX; y: root.canvasY
        width:  960          // hardcoded — binding to root.width can be fractional
        height: root.canvasH

        onPaint: drawCanvas()

        function drawCanvas() {
            var ctx   = getContext("2d")
            var bw    = root.boxW
            var ch    = root.canvasH
            var zeroY = root.pyOfNy(0.5)

            // Background
            ctx.fillStyle = Theme.bg.toString()
            ctx.fillRect(0, 0, root.canvasW, ch)

            // Rainbow void (right of handle)
            var voidX = bw + 39
            var voidW = root.canvasW - voidX
            if (voidW > 0) {
                var palette = [
                    "#C0392B","#E67E22","#D4AC0D","#7D6608","#1E8449",
                    "#117A65","#1A5276","#6C3483","#922B21","#784212",
                    "#F1948A","#FAD7A0","#A9DFBF","#85C1E9","#D2B4DE",
                    "#E74C3C","#E59866","#82E0AA","#5DADE2","#AF7AC5",
                    "#CB4335","#CA6F1E","#1D8348","#1A5276","#7D3C98",
                    "#F0B27A","#A3E4D7","#AED6F1","#F9E79F","#D5D8DC",
                    "#884EA0","#2E86C1","#138D75","#B7950B","#A04000",
                    "#C0392B","#566573","#1B4F72","#0E6655","#6E2F1A"
                ]
                var stride = 4   // 3 px line + 1 px gap
                ctx.save()
                ctx.globalAlpha = 0.9
                for (var ry = 0; ry < ch; ry += stride) {
                    var li = Math.floor(ry / stride)
                    var ci = ((li * 1664525 + 1013904223) ^ (li * 22695477)) % palette.length
                    if (ci < 0) ci += palette.length
                    ctx.fillStyle = palette[ci]
                    ctx.fillRect(voidX, ry, voidW, 3)
                }
                ctx.restore()
            }

            // Box fill
            ctx.fillStyle = "#0A0A0A"
            ctx.fillRect(0, 0, bw, ch)

            // Grid
            ctx.save()
            ctx.strokeStyle = "#1C1C1C"
            ctx.lineWidth   = 0.5
            ctx.beginPath()
            for (var gx = 0; gx <= bw; gx += 10) { ctx.moveTo(gx, 0); ctx.lineTo(gx, ch) }
            for (var gy = 0; gy <= ch; gy += 10) { ctx.moveTo(0, gy); ctx.lineTo(bw, gy) }
            ctx.stroke()
            ctx.strokeStyle = "#272727"
            ctx.lineWidth   = 1
            ctx.beginPath()
            for (var gx2 = 0; gx2 <= bw; gx2 += 50) { ctx.moveTo(gx2, 0); ctx.lineTo(gx2, ch) }
            for (var gy2 = 0; gy2 <= ch; gy2 += 50) { ctx.moveTo(0, gy2); ctx.lineTo(bw, gy2) }
            ctx.stroke()
            ctx.restore()

            // Zero axis (time)
            ctx.save()
            ctx.strokeStyle = "#FFFFFF"; ctx.lineWidth = 0.5; ctx.globalAlpha = 0.9
            ctx.setLineDash([2, 4])
            ctx.beginPath(); ctx.moveTo(0, zeroY); ctx.lineTo(bw, zeroY); ctx.stroke()
            ctx.setLineDash([])
            ctx.fillStyle = Theme.colorTextDim.toString(); ctx.font = "12px " + Theme.fontFamilyMono; ctx.textAlign = "right"
            ctx.fillText("time", bw - 6, zeroY - 5)
            ctx.restore()

            // Speed axis
            ctx.save()
            ctx.strokeStyle = "#FFFFFF"; ctx.lineWidth = 0.5; ctx.globalAlpha = 0.9
            ctx.setLineDash([2, 4])
            ctx.beginPath(); ctx.moveTo(bw/2, 0); ctx.lineTo(bw/2, ch); ctx.stroke()
            ctx.setLineDash([])
            ctx.fillStyle = Theme.colorTextDim.toString(); ctx.font = "12px " + Theme.fontFamilyMono; ctx.textAlign = "center"
            ctx.translate(bw/2 - 9, 16); ctx.rotate(-Math.PI / 2)
            ctx.fillText("speed", 0, 0)
            ctx.restore()

            // Insert marker
            if (root.insertMarkerIdx >= 0 && root.insertMarkerIdx < nodeModel.count) {
                var mx = root.pxOfNx(nodeModel.get(root.insertMarkerIdx).nx)
                ctx.save()
                ctx.strokeStyle = Theme.danger.toString(); ctx.lineWidth = 1; ctx.globalAlpha = 0.7
                ctx.beginPath(); ctx.moveTo(mx, 0); ctx.lineTo(mx, ch); ctx.stroke()
                ctx.restore()
            }

            // Playhead
            if (root.playheadX >= 0) {
                ctx.save()
                ctx.strokeStyle = Theme.danger.toString(); ctx.lineWidth = 1.5; ctx.globalAlpha = 0.9
                ctx.beginPath(); ctx.moveTo(root.playheadX, 0); ctx.lineTo(root.playheadX, ch); ctx.stroke()
                ctx.restore()
            }

            // Scrub cursor — red vertical line during spline edit (scrub/node levels)
            if (root.splineLevel === "scrub" || root.splineLevel === "node") {
                var scrubPx = root.pxOfNx(root.scrubNx)
                ctx.save()
                ctx.strokeStyle = Theme.danger.toString(); ctx.lineWidth = 1; ctx.globalAlpha = 0.9
                ctx.beginPath(); ctx.moveTo(scrubPx, 0); ctx.lineTo(scrubPx, ch); ctx.stroke()
                ctx.restore()
            }

            // Info overlay (bottom-right of box)
            ctx.save()
            ctx.fillStyle = Theme.colorTextDim.toString(); ctx.font = "12px " + Theme.fontFamilyMono
            ctx.textAlign = "right"; ctx.globalAlpha = 1.0
            var arcDeg     = root.arcDegrees
            var realAvgSpd = Math.abs(root.avgVelocity()) * root.maxSpeed
            var scanSec    = arcDeg / Math.max(1.0, realAvgSpd)
            ctx.fillText("lines: "  + root.formatLines(root.linesCount),                                           bw - 8, ch - 8)
            ctx.fillText("arc: "    + arcDeg.toFixed(0) + "\xB0  AR: " + (root.boxW / root.canvasH).toFixed(2),  bw - 8, ch - 24)
            ctx.fillText("avg: "    + realAvgSpd.toFixed(0) + " deg/s  ~" + scanSec.toFixed(1) + " s",            bw - 8, ch - 40)

            // Pass indicator — shown during multi-pass execution
            if (root.inMultiPass) {
                var chNames  = ["R", "G", "B", "C"]
                var chColors = ["#CC4444", "#44CC44", "#4488CC", "#AAAAAA"]
                ctx.fillStyle = chColors[root.currentPass]
                ctx.font      = "13px " + Theme.fontFamilyMono
                ctx.fillText("PASS " + (root.currentPass + 1) + " / 4  " + chNames[root.currentPass],
                             bw - 8, ch - 56)
            }
            ctx.restore()

            // Spline
            if (nodeModel.count < 2) return
            ctx.strokeStyle = Theme.colorText.toString()
            ctx.lineWidth   = 1
            ctx.beginPath()
            var n = nodeModel.count
            var first = true
            for (var i = 0; i < n - 1; i++) {
                var last_k = (i === n-2) ? 20 : 19
                for (var k = 0; k <= last_k; k++) {
                    var pt = root.evalSeg(i, k / 20.0)
                    var px = Math.max(0, Math.min(root.canvasW - 1, pt.x))
                    var py = Math.max(0, Math.min(ch - 1, pt.y))
                    if (first) { ctx.moveTo(px, py); first = false }
                    else        ctx.lineTo(px, py)
                }
            }
            ctx.stroke()
        }

        MouseArea {
            anchors.fill: parent
            onDoubleClicked: function(mouse) {
                var cx = mouse.x
                if (cx >= 1 && cx < root.boxW - 1) {
                    var f = root.findOnCurve(cx)
                    root.insertNode(f.seg, f.nx, f.ny)
                    root.insertMarkerIdx = f.seg + 1
                }
            }
        }
    }

    // ── Node handles ─────────────────────────────────────────────────────────
    Repeater {
        id: nodeRepeater
        model: nodeModel

        delegate: Item {
            id: nodeItem
            property int  nodeIndex: index
            property bool isLocked:  model.locked
            property int  nodeSz:    isLocked ? root.nodeSzEnd : root.nodeSzMid
            readonly property int touchR: 25

            width:  touchR * 2; height: touchR * 2
            x: root.canvasX + root.pxOfNx(model.nx) - touchR
            y: root.canvasY + root.pyOfNy(model.ny) - touchR

            Rectangle {
                anchors.centerIn: parent
                readonly property bool isActive: nodeItem.nodeIndex === root.activeNodeIdx
                readonly property bool isHover:  root.splineLevel === "scrub"
                                                 && nodeItem.nodeIndex === root.hoverNodeIdx
                width:  isActive ? nodeItem.nodeSz + 4 : nodeItem.nodeSz
                height: isActive ? nodeItem.nodeSz + 4 : nodeItem.nodeSz
                radius: 1
                color:  (isActive || isHover) ? Theme.danger : Theme.accent
            }

            MouseArea {
                anchors.fill: parent
                property real lastGX: 0
                property real lastGY: 0

                onPressed: function(mouse) {
                    var g = mapToItem(null, mouse.x, mouse.y)
                    lastGX = g.x; lastGY = g.y
                }
                onPositionChanged: function(mouse) {
                    if (!pressed) return
                    var g = mapToItem(null, mouse.x, mouse.y)
                    root.moveNode(nodeItem.nodeIndex, g.x - lastGX, g.y - lastGY)
                    lastGX = g.x; lastGY = g.y
                }
                onDoubleClicked: function(mouse) {
                    var idx = nodeItem.nodeIndex
                    Qt.callLater(function() { root.deleteNode(idx) })
                }
            }
        }
    }

    // ── Resize handle ─────────────────────────────────────────────────────────
    Item {
        id: handle
        x: root.canvasX + root.boxW
        y: root.canvasY
        width: 39; height: root.canvasH

        // Grab-bar brightens while the aspect level is active, so it reads as the
        // live control (vs. the dimmer resting state at section focus).
        Rectangle {
            anchors.fill: parent
            radius: 0
            color: root.splineLevel === "box" ? Qt.lighter(Theme.accent, 1.4) : Theme.accent
        }

        MouseArea {
            anchors.fill: parent
            property real lastGX: 0
            onPressed: function(mouse) { lastGX = mapToItem(null, mouse.x, mouse.y).x }
            onPositionChanged: function(mouse) {
                if (!pressed) return
                var gx = mapToItem(null, mouse.x, mouse.y).x
                root.boxW = Math.max(root.boxMinW, Math.min(root.canvasW - 45, root.boxW + gx - lastGX))
                lastGX = gx
                root.scheduleRepaint()
                Motor.seqBoxW = root.boxW
            }
        }
    }

    // ── Reset curve button — inside the curve window, bottom-left ───────────────
    TerminalButton {
        id: resetCurveBtn
        controller: scanFocus
        x: root.canvasX + 8
        y: root.canvasH - 34
        width: 150; height: 26
        z: 50
        fontSize: Theme.fontMonoS
        label: "[reset curve]"
        onClicked: root.resetCurve()
    }

    // ── Divider ───────────────────────────────────────────────────────────────
    Hairline { x: 0; y: 270; width: 960 }

    // ── Bottom panel — left: title + subtitle ────────────────────────────────

    Text {
        x: 18; y: 292
        text:  "XYLOSOME_01"
        color: "#C8C8C8"                        // slightly greyer than primary text
        font { family: Theme.fontFamily; pixelSize: Theme.fontH1; weight: Font.Medium }
    }

    Text {
        x: 18; y: 338
        text:  "temporal scanning unit"
        color: "#5E5E5E"                        // a bit darker than colorTextDim
        font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
    }

    // ── Motor position dial ───────────────────────────────────────────────────
    // Two hands driven by the ny value of the first and last spline nodes.
    // ny=0 (top of box) → 0° (12-o'clock); ny=1 (bottom) → 360° (full turn), CW.
    // Hand 1 = start position (bright, full-length).
    // Hand 2 = end position   (dim,    shorter).
    // Angles update via scheduleRepaint() → root.startNy / root.endNy.

    Item {
        id: motorCircle
        readonly property int cx:     100   // centre within this Item
        readonly property int cy:     100
        readonly property int r:       72   // circle radius (diameter 144 px)
        readonly property int overEx:  12   // crosshair overshoot beyond ring

        x: 340; y: 300   // root centre ≈ (440, 400)
        width: 200; height: 200

        // ── Static layer: ring, dotted crosshairs, ticks ─────────────────────
        Canvas {
            id: circleCanvas
            anchors.fill: parent
            Component.onCompleted: requestPaint()
            onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                var cx = motorCircle.cx, cy = motorCircle.cy
                var r  = motorCircle.r,  oe = motorCircle.overEx
                ctx.strokeStyle = Theme.colorTextDim.toString()
                ctx.lineWidth   = 1

                // Ring
                ctx.beginPath()
                ctx.arc(cx, cy, r, 0, 2 * Math.PI)
                ctx.stroke()

                // Ticks every 10° — major at 90° multiples, medium at 45°
                for (var deg = 0; deg < 360; deg += 10) {
                    var rad     = (deg - 90) * Math.PI / 180
                    var isMajor = (deg % 90 === 0)
                    var isMed   = (deg % 45 === 0)
                    var innerR  = isMajor ? 60 : (isMed ? 64 : 67)
                    ctx.beginPath()
                    ctx.moveTo(cx + innerR     * Math.cos(rad), cy + innerR     * Math.sin(rad))
                    ctx.lineTo(cx + (r + 2)    * Math.cos(rad), cy + (r + 2)    * Math.sin(rad))
                    ctx.stroke()
                }
            }
        }

        // ── Pie fill — arc sector between hand1 and hand2 ────────────────────
        Canvas {
            id: pieFillCanvas
            anchors.fill: parent
            property real _h1: root.hand1Angle
            property real _h2: root.hand2Angle
            on_H1Changed: requestPaint()
            on_H2Changed: requestPaint()
            onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                var cx = motorCircle.cx, cy = motorCircle.cy, r = motorCircle.r
                var a1 = (root.hand1Angle - 90) * Math.PI / 180
                var a2 = (root.hand2Angle - 90) * Math.PI / 180
                if (a2 <= a1) return
                // Arc outline — full accent, no alpha
                ctx.beginPath()
                ctx.arc(cx, cy, r, a1, a2, false)
                ctx.strokeStyle = Theme.accent.toString()
                ctx.lineWidth   = 2
                ctx.globalAlpha = 1.0
                ctx.stroke()
            }
        }

        // ── Hand 1 — start position ───────────────────────────────────────────
        Rectangle {
            id: hand1
            readonly property real handLen: motorCircle.r + 6
            readonly property real gapPx:   10    // ~3 mm gap from centre
            width: 2;  height: handLen - gapPx
            // Selected hand: blinks while in "select", solid red while in "move".
            color: (root.editTarget === "dial" && root.dialSel === 1)
                   ? (root.dialLevel === "select"
                      ? (root.dialBlinkOn ? Theme.danger : Theme.accent)
                      : Theme.danger)
                   : Theme.accent
            x: motorCircle.cx - 1
            y: motorCircle.cy - handLen
            transform: Rotation {
                origin.x: 1;  origin.y: hand1.handLen
                angle: root.hand1Angle
            }
        }

        // ── Hand 2 — end position ─────────────────────────────────────────────
        Rectangle {
            id: hand2
            readonly property real handLen: motorCircle.r + 6
            readonly property real gapPx:   10
            width: 2;  height: handLen - gapPx
            // Selected hand: blinks while in "select", solid red while in "move".
            color: (root.editTarget === "dial" && root.dialSel === 2)
                   ? (root.dialLevel === "select"
                      ? (root.dialBlinkOn ? Theme.danger : Theme.accent)
                      : Theme.danger)
                   : Theme.accent
            x: motorCircle.cx - 1
            y: motorCircle.cy - handLen
            transform: Rotation {
                origin.x: 1;  origin.y: hand2.handLen
                angle: root.hand2Angle
            }
        }

        // ── Red hand — tracks playhead between hand1 and hand2 ────────────────
        Rectangle {
            id: handRed
            readonly property real handLen: motorCircle.r + 6
            readonly property real gapPx:   10
            width: 2;  height: handLen - gapPx
            color: Theme.danger
            visible: root.playheadX >= 0
            x: motorCircle.cx - 1
            y: motorCircle.cy - handLen
            transform: Rotation {
                origin.x: 1;  origin.y: handRed.handLen
                angle: root.redHandAngle
            }
        }

        // ── Centre pivot ──────────────────────────────────────────────────────
        Rectangle {
            width: 6;  height: 6;  radius: 3
            color: Theme.accent
            x: motorCircle.cx - 3
            y: motorCircle.cy - 3
        }

        // ── Draggable green node — hand 1 tip ─────────────────────────────────
        Item {
            readonly property real tipX: motorCircle.cx + (motorCircle.r + 6) * Math.sin(root.hand1Angle * Math.PI / 180)
            readonly property real tipY: motorCircle.cy - (motorCircle.r + 6) * Math.cos(root.hand1Angle * Math.PI / 180)
            x: tipX - 15;  y: tipY - 15
            width: 30;  height: 30

            Rectangle {
                width: 8;  height: 8;  radius: 4
                color: Theme.accent
                anchors.centerIn: parent
            }
            MouseArea {
                anchors.fill: parent
                onPositionChanged: {
                    if (!pressed) return
                    var p   = mapToItem(motorCircle, mouse.x, mouse.y)
                    var ang = Math.atan2(p.x - motorCircle.cx, -(p.y - motorCircle.cy)) * 180 / Math.PI
                    root._dialDriving = true
                    root.hand1Angle   = Math.min(root.hand2Angle - 10, ang)
                    var arc = root.hand2Angle - root.hand1Angle
                    root.boxW = Math.max(root.boxMinW,
                                Math.min(root.canvasW - 45, Math.round(arc * (root.canvasW - 45) / 180)))
                    root._dialDriving = false
                    root.scheduleRepaint()
                    Motor.seqBoxW = root.boxW
                }
            }
        }

        // ── Draggable green node — hand 2 tip ─────────────────────────────────
        Item {
            readonly property real tipX: motorCircle.cx + (motorCircle.r + 6) * Math.sin(root.hand2Angle * Math.PI / 180)
            readonly property real tipY: motorCircle.cy - (motorCircle.r + 6) * Math.cos(root.hand2Angle * Math.PI / 180)
            x: tipX - 15;  y: tipY - 15
            width: 30;  height: 30

            Rectangle {
                width: 8;  height: 8;  radius: 4
                color: Theme.accent
                anchors.centerIn: parent
            }
            MouseArea {
                anchors.fill: parent
                onPositionChanged: {
                    if (!pressed) return
                    var p   = mapToItem(motorCircle, mouse.x, mouse.y)
                    var ang = Math.atan2(p.x - motorCircle.cx, -(p.y - motorCircle.cy)) * 180 / Math.PI
                    root._dialDriving = true
                    root.hand2Angle   = Math.max(root.hand1Angle + 10, ang)
                    var arc = root.hand2Angle - root.hand1Angle
                    root.boxW = Math.max(root.boxMinW,
                                Math.min(root.canvasW - 45, Math.round(arc * (root.canvasW - 45) / 180)))
                    root._dialDriving = false
                    root.scheduleRepaint()
                    Motor.seqBoxW = root.boxW
                }
            }
        }
    }

    // ── FOV readout — degrees the camera travels (end − start position) ────────
    // Full camera rotation = 360°. FOV = hand2Angle (end) − hand1Angle (start).
    Column {
        id: fovReadout
        spacing: 2
        anchors.left: motorCircle.right
        anchors.leftMargin: 8
        anchors.verticalCenter: motorCircle.verticalCenter

        Text {
            text:  "fov"
            color: Theme.colorTextDim
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
        }
        Text {
            text:  Math.round(root.hand2Angle - root.hand1Angle) + "°"
            color: Theme.colorText
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontH2 }
        }
    }

    // ── Bottom panel — text buttons ───────────────────────────────────────────
    // [settings] left  |  [execute]/[pause]/[resume] and [home]/[ready] right.
    // [execute] → green solid while running; blinks green/grey when paused.
    // [home]/[ready] reflects root.homed — bind to Motor.homed when available.

    TerminalButton {
        id: settingsBtn
        controller: scanFocus
        x: 18
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label:  "[settings]"
        active: false
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenHome.qml"))
    }

    TerminalButton {
        id: playBtn
        controller: scanFocus
        anchors { right: parent.right; rightMargin: 18 + 130 + 18; bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        // Label cycles: [execute] → [pause] → [resume] (blinking)
        label:  root.execState === "idle"    ? "[execute]" :
                root.execState === "running" ? "[pause]"   : "[resume]"
        // Active (green) when running, or when paused + blink phase is ON
        active: root.execState === "running" ||
                (root.execState === "paused" && root.blinkVisible)
        onClicked: {
            if (root.execState === "idle") {
                root.playheadX    = 0
                root.isPlaying    = true
                root.execState    = "running"
                root.blinkVisible = true
                root.homed        = false
                root.inMultiPass  = true
                root.currentPass  = 0
                Recorder.startSession()    // snapshot curve + boxW
                Recorder.startPass(0)      // t_start for R pass
                playheadTimer.start()
            } else if (root.execState === "running") {
                playheadTimer.stop()
                root.isPlaying = false
                root.execState = "paused"
                root.blinkVisible = true
            } else {
                // resume from paused
                root.isPlaying  = true
                root.execState  = "running"
                root.blinkVisible = true
                playheadTimer.start()
            }
        }
    }

    TerminalButton {
        id: resetBtn
        controller: scanFocus
        anchors { right: parent.right; rightMargin: 18; bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label:  root.homed ? "[ready]" : "[home]"
        active: root.homed
        onClicked: {
            // While editing the spline, [home] is the "jump all the way out" shortcut.
            if (scanFocus.editing) { root.exitSplineEditing(); return }
            playheadTimer.stop()
            root.isPlaying    = false
            root.execState    = "idle"
            root.blinkVisible = true
            root.playheadX    = -1
            root.homed        = true
            root.inMultiPass  = false
            root.currentPass  = 0
        }
    }

    // ── Timers ────────────────────────────────────────────────────────────────

    Timer {
        id:       playheadTimer
        interval: 16
        repeat:   true
        running:  false
        onTriggered: {
            // Physics: real velocity (deg/s) × pixels/deg × 16 ms/frame
            // → at avg ~0.3 speed factor, 90° arc ≈ 3 s per pass
            var arcDeg = root.arcDegrees
            var spd    = root.speedAtX(root.playheadX)
            root.playheadX += Math.max(0.3, spd * root.maxSpeed * root.boxW / arcDeg * 0.016)
            if (root.playheadX >= root.boxW) {
                if (root.inMultiPass) {
                    // ── End of this pass ─────────────────────────────────────
                    Recorder.endPass(root.currentPass)
                    root.currentPass++

                    if (root.currentPass < 4) {
                        // ── Start next pass ───────────────────────────────────
                        Recorder.startPass(root.currentPass)
                        root.playheadX = 0      // reset — same curve, next colour
                        root.scheduleRepaint()
                        // timer keeps running
                    } else {
                        // ── All 4 passes complete ─────────────────────────────
                        Recorder.commitSession()   // finalise + auto-export SVG
                        root.inMultiPass  = false
                        root.currentPass  = 0
                        root.playheadX    = -1
                        root.isPlaying    = false
                        root.execState    = "idle"
                        root.blinkVisible = true
                        playheadTimer.stop()
                    }
                } else {
                    // Single-pass fallback (shouldn't happen in normal use)
                    root.playheadX    = -1
                    root.isPlaying    = false
                    root.execState    = "idle"
                    root.blinkVisible = true
                    playheadTimer.stop()
                }
            }
        }
    }

    // Blink timer — fires every 500 ms while paused to toggle [resume] colour
    Timer {
        id:       blinkTimer
        interval: 500
        repeat:   true
        running:  root.execState === "paused"
        onTriggered: root.blinkVisible = !root.blinkVisible
    }

    // Dial blink — pulses the candidate hand while choosing (select level only).
    Timer {
        id:       dialBlinkTimer
        interval: 400
        repeat:   true
        running:  root.editTarget === "dial" && root.dialLevel === "select"
        onTriggered: root.dialBlinkOn = !root.dialBlinkOn
        onRunningChanged: if (!running) root.dialBlinkOn = true
    }

    onPlayheadXChanged:  root.scheduleRepaint()
    onCurrentPassChanged: root.scheduleRepaint()

    Timer {
        id: repaintTimer
        interval: 16; repeat: false
        onTriggered: canvas.requestPaint()
    }
    function scheduleRepaint() { if (!repaintTimer.running) repaintTimer.start() }

    Component.onCompleted: {
        root.hand2Angle = root.hand1Angle + root.boxW * 180.0 / (root.canvasW - 45)
        root.scheduleRepaint()
    }
    onBoxWChanged: {
        // Only update hand2 when the handle bar is driving (not when dial is driving)
        if (!root._dialDriving)
            root.hand2Angle = root.hand1Angle + root.boxW * 180.0 / (root.canvasW - 45)
        root.scheduleRepaint()
    }
}
