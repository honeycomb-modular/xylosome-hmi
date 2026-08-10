// ScreenFreerun.qml — capture ▸ freerun. Motor speed and line rate, uncoupled.
//
// Same grammar as capture ▸ scan — curve editor on top, dial underneath — but
// two things are different, and they are the mode:
//
//   1. The curve is indexed by TIME, not by position along the arc, and its
//      floor is a literal standstill. Scan floors velocity at minVelDegS
//      because a position-indexed sweep at v=0 never advances and would hang;
//      here the pass ends on the clock, so the axis is free to stop dead and
//      the image keeps building. Bottom of the box = stop, top = peak.
//   2. The trigger runs at a FIXED rate that the artist sets. It does not
//      follow the axis. Lines keep arriving while the axis crawls, and while it
//      is parked — so the subject stretches where it is slow and piles onto one
//      column where it stops. That is the picture this mode makes.
//
// What each control means:
//   dial        FOV — the arc the sweep covers, exactly as in scan
//   green bar   the DURATION of the pass (the curve's time axis). Since lines =
//               rate × duration, the bar still sets the image aspect, same as
//               scan's bar does.
//   curve       SHAPE only. The peak is fitted so the curve's integral equals
//               the FOV, so the sweep always lands where the dial says.
//   rate        the fixed trigger rate, in Hz.
//
// xylod needed no change: this is `timeProfile` + `line.mode:"fixed"`, both of
// which have been in the protocol since pendulum (beckhoff/PROTOCOL.md).
//
// The spline machinery below is scan's, copied rather than shared — extracting
// a curve-editor component would mean rewriting ScreenScan, which works.

import QtCore
import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root
    width: 960; height: 540

    Settings {
        category: "freerun"
        property alias durationSec: root.durationSec
        property alias lineHz:      root.lineHz
        property alias hand1Angle:  root.hand1Angle
        property alias hand2Angle:  root.hand2Angle
        property alias curveJson:   root.curveJson
    }

    // ── Layout constants (scan's, so the two pages read the same) ──────────────
    readonly property int canvasW:  960
    readonly property int canvasH:  270
    readonly property int plotPadT:  29
    readonly property int plotPadB:  22
    readonly property int boxMinW:  200
    readonly property int boxMaxW:  915          // canvasW - 45, the bar's own width
    readonly property int nodeSzEnd:  8
    readonly property int nodeSzMid: 10

    // ── The four settings ─────────────────────────────────────────────────────
    readonly property real durMin: 1.0
    readonly property real durMax: 120.0
    property real durationSec: 6.0

    // 3500 Hz is where the camera stops syncing (see Calib.qml); 37000 is
    // xylod's line_max_hz. 8500 is the rate the cart runs sharp at.
    readonly property real rateMin: 3500
    readonly property real rateMax: 37000
    property real lineHz: 8500

    property real hand1Angle: -45
    property real hand2Angle:  45
    readonly property real axisMinDeg: -180      // mirrors xylod soft_min/max_deg
    readonly property real axisMaxDeg:  180

    property string curveJson: ""

    // ── Derived ───────────────────────────────────────────────────────────────
    // The bar is logarithmic: a second and two minutes both want fine control.
    readonly property real _lnDurSpan: Math.log(root.durMax / root.durMin)
    function fracOfDur(d) {
        d = Math.max(root.durMin, Math.min(root.durMax, d))
        return Math.log(d / root.durMin) / root._lnDurSpan
    }
    function durOfFrac(f) {
        f = Math.max(0, Math.min(1, f))
        return root.durMin * Math.exp(f * root._lnDurSpan)
    }
    readonly property int boxW: Math.round(root.boxMinW
                                + root.fracOfDur(root.durationSec) * (root.boxMaxW - root.boxMinW))

    readonly property real arcDeg:   Math.max(1, root.hand2Angle - root.hand1Angle)
    readonly property int  lines:    Math.round(root.lineHz * root.durationSec)
    // The grabber frame tops out here (capture_agent LINE_MAX); asking for more
    // does not fail, it just stops filling.
    readonly property int  linesMax: 65000
    readonly property real ar:       root.lines / 8192.0

    // Auto-fit: the profile's integral must equal the arc, so
    //   arc = peak × mean|profile| × duration.
    // Shape is preserved, including every stop — only the scale moves.
    property var  profileSamples: []
    property real meanProfile: 1.0
    readonly property real fitVel: root.meanProfile > 0.02
        ? root.arcDeg / (root.meanProfile * root.durationSec) : 0
    readonly property real maxSpeed: 300.0       // scan's ceiling — motor max is ~360
    // xylod clamps position and acceleration but NOT velocity, so the ceiling
    // has to hold here. A fit that needs more than the axis has is clamped, not
    // refused — and the readout says how far short of the FOV that lands.
    readonly property real peakVel:  Math.min(root.maxSpeed, root.fitVel)
    readonly property bool tooFast:  root.fitVel > root.maxSpeed
    readonly property real reachDeg: root.peakVel * root.meanProfile * root.durationSec
    readonly property real meanVel:  root.reachDeg / Math.max(0.001, root.durationSec)
    readonly property bool curveFlat: root.meanProfile <= 0.02

    // The rate that would keep geometry honest ON AVERAGE. Any other rate is the
    // point of the mode, so it is shown as a reference, not a target.
    readonly property real geoHz:   Calib.linesPerDeg * root.meanVel
    readonly property real stretch: root.geoHz > 1 ? root.lineHz / root.geoHz : 0

    // ── Run state ─────────────────────────────────────────────────────────────
    property string execState:   "idle"          // idle | running | paused
    property bool   blinkVisible: true
    property bool   homed:        false
    property real   progressFrac: 0.0
    property real   playheadX:   -1

    // Where the axis has got to, as a fraction of the arc — the integral of the
    // curve up to now, so the hand visibly parks while the curve is on the floor.
    function travelFracAt(t) {
        var n = root.profileSamples.length
        if (n < 2 || root.durationSec <= 0) return 0
        var upto = Math.max(0, Math.min(1, t / root.durationSec)) * (n - 1)
        var sum = 0, tot = 0
        for (var i = 0; i < n; i++) {
            tot += root.profileSamples[i]
            if (i <= upto) sum += root.profileSamples[i]
        }
        return tot > 0 ? sum / tot : 0
    }
    readonly property real redHandAngle:
        (root.execState !== "idle" && Beckhoff.connected)
        ? Math.max(root.hand1Angle, Math.min(root.hand2Angle, Beckhoff.positionDeg))
        : root.hand1Angle + root.travelFracAt(root.progressFrac * root.durationSec) * root.arcDeg

    function fmtLines(n) { return n.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ".") }

    // ── Node model — the curve's shape ────────────────────────────────────────
    ListModel {
        id: nodeModel
        ListElement { nx: 0.00; ny: 0.40; locked: true  }
        ListElement { nx: 0.50; ny: 0.40; locked: false }
        ListElement { nx: 1.00; ny: 0.40; locked: true  }
    }

    // ── Curve semantics ───────────────────────────────────────────────────────
    // Top of the box = peak, bottom = stop. Nodes clamp to ny 0.01..0.99, so
    // without a band nothing could ever reach a true zero — anything inside the
    // bottom 3% is a standstill, and the box draws that line.
    readonly property real stopBand: 0.03
    function speedOfNy(ny) {
        var v = 1.0 - Math.max(0, Math.min(1, ny))
        return v < root.stopBand ? 0.0 : v
    }

    // ── Coordinate helpers ────────────────────────────────────────────────────
    function pxOfNx(nx) { return nx * root.boxW }
    function pyOfNy(ny) { return root.plotPadT + ny * (root.canvasH - root.plotPadT - root.plotPadB) }

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

    function nyAtX(px) {
        if (nodeModel.count < 2) return 1.0
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
        return (pt.y - root.plotPadT) / (root.canvasH - root.plotPadT - root.plotPadB)
    }
    function speedAtX(px) { return root.speedOfNy(root.nyAtX(px)) }

    // What the artist drew is what executes: the same evaluator paints the
    // curve, previews the playhead and builds the profile xylod runs.
    function buildProfile() {
        var n = 128, prof = []
        for (var i = 0; i < n; i++) prof.push(root.speedAtX(i / (n - 1) * root.boxW))
        return prof
    }
    function refreshProfile() {
        var p = root.buildProfile()
        var s = 0
        for (var i = 0; i < p.length; i++) s += p[i]
        root.profileSamples = p
        root.meanProfile    = p.length > 0 ? s / p.length : 0
    }

    function findOnCurve(cxLocal) {
        var n = nodeModel.count
        var nx_t = Math.max(0.01, Math.min(0.99, cxLocal / root.boxW))
        var seg = n - 2
        for (var i = 0; i < n - 1; i++) {
            if (nodeModel.get(i).nx <= nx_t && nx_t <= nodeModel.get(i+1).nx) { seg = i; break }
        }
        return { seg: seg, nx: nx_t, ny: Math.max(0.01, Math.min(0.99, root.nyAtX(cxLocal))) }
    }
    function nearestNodeIdx(nx, thresh) {
        var best = -1, bd = thresh
        for (var i = 0; i < nodeModel.count; i++) {
            var d = Math.abs(nodeModel.get(i).nx - nx)
            if (d < bd) { bd = d; best = i }
        }
        return best
    }

    // ── Node mutation ─────────────────────────────────────────────────────────
    function moveNode(idx, dx, dy) {
        var n    = nodeModel.count
        var node = nodeModel.get(idx)
        var ph   = root.canvasH - root.plotPadT - root.plotPadB
        if (!node.locked) {
            var lo = idx > 0   ? nodeModel.get(idx-1).nx + 0.04 : 0.0
            var hi = idx < n-1 ? nodeModel.get(idx+1).nx - 0.04 : 1.0
            nodeModel.setProperty(idx, "nx", Math.max(lo, Math.min(hi, node.nx + dx / root.boxW)))
        }
        nodeModel.setProperty(idx, "ny", Math.max(0.01, Math.min(0.99, node.ny + dy / ph)))
        root.curveChanged()
    }
    function deleteNode(idx) {
        if (nodeModel.get(idx).locked) return
        if (nodeModel.count < 3) return
        nodeModel.remove(idx)
        root.curveChanged()
    }
    function insertNode(seg, nx, ny) {
        if (nodeModel.count >= 10) return
        nodeModel.insert(seg + 1, { nx: nx, ny: ny, locked: false })
        root.curveChanged()
    }
    function resetCurve() {
        nodeModel.clear()
        nodeModel.append({ nx: 0.0, ny: 0.40, locked: true  })
        nodeModel.append({ nx: 0.5, ny: 0.40, locked: false })
        nodeModel.append({ nx: 1.0, ny: 0.40, locked: true  })
        root.activeNodeIdx = -1
        root.hoverNodeIdx  = -1
        root.curveChanged()
    }

    function curveChanged() {
        root.refreshProfile()
        root.saveCurve()
        root.scheduleRepaint()
    }
    function saveCurve() {
        var arr = []
        for (var i = 0; i < nodeModel.count; i++)
            arr.push({ nx: nodeModel.get(i).nx, ny: nodeModel.get(i).ny })
        root.curveJson = JSON.stringify(arr)
    }
    function loadCurve() {
        if (root.curveJson === "") return
        var arr
        try { arr = JSON.parse(root.curveJson) } catch (e) { return }
        if (!arr || arr.length < 2) return
        nodeModel.clear()
        for (var i = 0; i < arr.length; i++)
            nodeModel.append({ nx: arr[i].nx, ny: arr[i].ny,
                               locked: (i === 0 || i === arr.length - 1) })
    }

    // ── Touch-free focus ──────────────────────────────────────────────────────
    property var    focusController: freeFocus
    property string editTarget:  "none"    // none | spline | aspect | rate | dial
    property string splineLevel: "none"    // none | scrub | node
    property real   scrubNx:      0.5
    property int    activeNodeIdx: -1
    property int    hoverNodeIdx:  -1
    property int    dialSel:        0      // 0 none · 1 start hand · 2 end hand
    property string dialLevel:  "none"     // none | select | move
    property bool   dialBlinkOn: true
    readonly property bool aspectActive: (freeFocus.current === handle && !freeFocus.editing)
                                         || root.editTarget === "aspect"

    function focusBack() { root.StackView.view.pop() }

    Item {
        id: splineBox
        x: 0; y: 0
        width: root.boxW; height: root.canvasH
    }

    FocusController {
        id: freeFocus
        // Reading order — left to right, then down a line:
        //   curve window: spline box · duration bar · [reset curve]
        //   lower half:   dial · rate
        //   bottom bar:   [settings] · [modes] · chip · [abort] · [home]
        targets: [splineBox, handle, resetCurveBtn, motorCircle, rateProxy,
                  settingsBtn, modesBtn]
                 .concat(faultChip.focusTargets)
                 .concat(root.execState !== "idle" ? [abortBtn] : [])
                 .concat([homeBtn])
        Component.onCompleted: index = targets.indexOf(homeBtn)
        onActivated: function(item) {
            if (item === splineBox)        root.enterSplineEditing()
            else if (item === handle)      { freeFocus.editing = true; root.editTarget = "aspect" }
            else if (item === rateProxy)   { freeFocus.editing = true; root.editTarget = "rate" }
            else if (item === motorCircle) root.enterDialEditing()
            else if (item && item.clicked) item.clicked()
        }
        onAdjust:    function(delta) { root.editAdjust(delta) }
        onConfirmed: root.editConfirm()
        onCanceled:  root.editCancel()
    }

    function focusContext() { if (freeFocus.editing) root.editConfirm() }
    function btn1Execute()  { playBtn.clicked() }

    function exitEditing() {
        freeFocus.editing = false
        root.editTarget   = "none"
        root.scheduleRepaint()
    }

    function editAdjust(d) {
        if (root.editTarget === "spline")      root.splineAdjust(d)
        // The profile is sampled in normalised time, so stretching the pass does
        // not change it — only the readouts and the box need redrawing.
        else if (root.editTarget === "aspect")
            root.durationSec = root.durOfFrac(root.fracOfDur(root.durationSec) + d * 0.02)
        else if (root.editTarget === "rate")
            root.lineHz = Math.max(root.rateMin, Math.min(root.rateMax, root.lineHz + d * 100))
        else if (root.editTarget === "dial")   root.dialAdjust(d)
    }
    function editConfirm() {
        if (root.editTarget === "spline")    root.splineConfirm()
        else if (root.editTarget === "dial") root.dialConfirm()
        else                                 root.exitEditing()
    }
    function editCancel() {
        if (root.editTarget === "spline")    root.splineCancel()
        else if (root.editTarget === "dial") root.dialCancel()
        else                                 root.exitEditing()
    }

    // ── Spline editing — scrub to a spot, enter to grab / add / erase ──────────
    function enterSplineEditing() {
        freeFocus.editing = true
        root.editTarget   = "spline"
        root.splineLevel  = "scrub"
        root.hoverNodeIdx = root.nearestNodeIdx(root.scrubNx, 0.02)
        root.scheduleRepaint()
    }
    function exitSplineEditing() {
        freeFocus.editing  = false
        root.editTarget    = "none"
        root.splineLevel   = "none"
        root.activeNodeIdx = -1
        root.hoverNodeIdx  = -1
        root.scheduleRepaint()
    }
    function splineAdjust(d) {
        if (root.splineLevel === "scrub") {
            root.scrubNx = Math.max(0, Math.min(1, root.scrubNx + d * (1 / 60)))
            root.hoverNodeIdx = root.nearestNodeIdx(root.scrubNx, 0.02)
            root.scheduleRepaint()
        } else if (root.splineLevel === "node" && root.activeNodeIdx >= 0) {
            var nd = nodeModel.get(root.activeNodeIdx)
            var ny = Math.max(0.01, Math.min(0.99, nd.ny - d * 0.02))
            nodeModel.setProperty(root.activeNodeIdx, "ny", ny)
            root.curveChanged()
        }
    }
    function splineConfirm() {
        if (root.splineLevel === "scrub") {
            var hit = root.nearestNodeIdx(root.scrubNx, 0.02)
            if (hit >= 0) {
                root.deleteNode(hit)
                root.hoverNodeIdx = root.nearestNodeIdx(root.scrubNx, 0.02)
            } else {
                var f = root.findOnCurve(root.scrubNx * root.boxW)
                root.insertNode(f.seg, f.nx, f.ny)
                root.activeNodeIdx = f.seg + 1
                root.splineLevel   = "node"
            }
            root.scheduleRepaint()
        } else if (root.splineLevel === "node") {
            root.activeNodeIdx = -1
            root.splineLevel   = "scrub"
            root.hoverNodeIdx  = root.nearestNodeIdx(root.scrubNx, 0.02)
            root.scheduleRepaint()
        }
    }
    function splineCancel() {
        if (root.splineLevel === "node") {
            root.activeNodeIdx = -1
            root.splineLevel   = "scrub"
            root.scheduleRepaint()
        } else root.exitSplineEditing()
    }

    // ── Dial editing — pick a hand, rotate to move it ──────────────────────────
    function enterDialEditing() {
        freeFocus.editing = true
        root.editTarget   = "dial"
        root.dialLevel    = "select"
        root.dialSel      = 1
    }
    function exitDialEditing() {
        freeFocus.editing = false
        root.editTarget   = "none"
        root.dialLevel    = "none"
        root.dialSel      = 0
    }
    function dialAdjust(d) {
        if (root.dialLevel === "select") {
            if (d > 0)      root.dialSel = 2
            else if (d < 0) root.dialSel = 1
            return
        }
        var step = 2
        if (root.dialSel === 1)
            root.hand1Angle = Math.max(root.axisMinDeg,
                              Math.min(root.hand2Angle - 10, root.hand1Angle + d * step))
        else if (root.dialSel === 2)
            root.hand2Angle = Math.min(root.axisMaxDeg,
                              Math.max(root.hand1Angle + 10, root.hand2Angle + d * step))
        root.scheduleRepaint()
    }
    function dialConfirm() {
        if (root.dialLevel === "select")    root.dialLevel = "move"
        else if (root.dialLevel === "move") root.dialLevel = "select"
    }
    function dialCancel() {
        if (root.dialLevel === "move")        root.dialLevel = "select"
        else if (root.dialLevel === "select") root.exitDialEditing()
    }

    // ── Run control ───────────────────────────────────────────────────────────
    function startRun() {
        // Without a session the pass lands as a bare TIF — commitSession() is
        // what writes the sidecar the Review Suite pairs against.
        Recorder.startSession()
        // Floor is a true 0 here: nothing stops the axis stalling because the
        // pass ends on the clock, not on reaching the arc end.
        Recorder.setScanContext(root.hand1Angle, root.hand2Angle,
                                root.peakVel, 0.0, root.profileSamples)
        Recorder.startPass(0)
        root.progressFrac = 0
        root.playheadX    = 0
        root.execState    = "running"
        root.blinkVisible = true
        root.homed        = false
        if (Beckhoff.connected)
            Beckhoff.executeFreerun(Motor.colorMode, root.hand1Angle,
                                    root.peakVel, root.durationSec,
                                    root.lineHz, root.profileSamples)
        else
            simTimer.start()
    }
    function finishRun() {
        Recorder.endPass(0)
        Recorder.commitSession()
        simTimer.stop()
        root.progressFrac = 1
        root.playheadX    = -1
        root.execState    = "idle"
        root.blinkVisible = true
        finishClear.start()
    }
    function abortRun() {
        // Guarded, unlike ramp's: [modes] and [home] call this unconditionally,
        // and commitSession() appends a record and writes an SVG + JSON sidecar
        // every time it is called (MetadataRecorder.cpp:96) — so an unguarded
        // abort leaves a sidecar for a scan that never ran.
        if (root.execState === "idle") { simTimer.stop(); return }
        Recorder.endPass(0)
        Recorder.commitSession()
        simTimer.stop()
        root.execState    = "idle"
        root.blinkVisible = true
        root.progressFrac = 0
        root.playheadX    = -1
    }

    Timer {
        id: finishClear
        interval: 900; repeat: false
        onTriggered: root.progressFrac = 0
    }
    // Offline preview only — never runs against the daemon (a second writer
    // fighting xylod's progress makes the playhead jitter).
    Timer {
        id: simTimer
        interval: 100; repeat: true; running: false
        onTriggered: {
            if (Beckhoff.connected) { simTimer.stop(); return }
            root.progressFrac = Math.min(1, root.progressFrac + 0.1 / Math.max(0.1, root.durationSec))
            root.playheadX    = root.progressFrac * root.boxW
            if (root.progressFrac >= 1) root.finishRun()
        }
    }
    Timer {
        interval: 500; repeat: true; running: root.execState === "paused"
        onTriggered: root.blinkVisible = !root.blinkVisible
    }
    Timer {
        id: dialBlinkTimer
        interval: 400; repeat: true
        running: root.editTarget === "dial" && root.dialLevel === "select"
        onTriggered: root.dialBlinkOn = !root.dialBlinkOn
        onRunningChanged: if (!running) root.dialBlinkOn = true
    }

    Connections {
        target: Beckhoff
        // A time-indexed pass reports progress as elapsed ÷ duration, which is
        // exactly the curve's x axis — so the playhead is the progress, no
        // position mapping needed (and none would work through a standstill).
        function onProgressChanged() {
            if (root.execState === "running" && Beckhoff.connected) {
                root.progressFrac = Beckhoff.progress
                root.playheadX    = Beckhoff.progress * root.boxW
            }
        }
        function onSequenceDone(passes) { if (root.execState !== "idle") root.finishRun() }
        function onFaulted(text)        { root.abortRun() }
        function onConnectedChanged()   { if (!Beckhoff.connected && root.execState !== "idle") root.abortRun() }
    }

    // ── Canvas (top half) ─────────────────────────────────────────────────────
    Canvas {
        id: canvas
        x: 0; y: 0
        width: 960; height: root.canvasH
        onPaint: drawCanvas()

        function drawCanvas() {
            var ctx = getContext("2d")
            var bw  = root.boxW
            var ch  = root.canvasH

            ctx.fillStyle = Theme.bg.toString()
            ctx.fillRect(0, 0, root.canvasW, ch)

            ctx.fillStyle = "#0A0A0A"
            ctx.fillRect(0, 0, bw, ch)

            // Grid
            ctx.save()
            ctx.strokeStyle = "#1C1C1C"; ctx.lineWidth = 0.5
            ctx.beginPath()
            for (var gx = 0; gx <= bw; gx += 10) { ctx.moveTo(gx, 0); ctx.lineTo(gx, ch) }
            for (var gy = 0; gy <= ch; gy += 10) { ctx.moveTo(0, gy); ctx.lineTo(bw, gy) }
            ctx.stroke()
            ctx.strokeStyle = "#272727"; ctx.lineWidth = 1
            ctx.beginPath()
            for (var gx2 = 0; gx2 <= bw; gx2 += 50) { ctx.moveTo(gx2, 0); ctx.lineTo(gx2, ch) }
            for (var gy2 = 0; gy2 <= ch; gy2 += 50) { ctx.moveTo(0, gy2); ctx.lineTo(bw, gy2) }
            ctx.stroke()
            ctx.restore()

            // Stop line — the bottom of the box is a standstill, and anything
            // inside the band counts as one. Drawn so the artist can park on it.
            var stopY = root.pyOfNy(1.0 - root.stopBand)
            ctx.save()
            ctx.strokeStyle = Theme.danger.toString(); ctx.lineWidth = 1; ctx.globalAlpha = 0.55
            ctx.setLineDash([2, 4])
            ctx.beginPath(); ctx.moveTo(0, stopY); ctx.lineTo(bw, stopY); ctx.stroke()
            ctx.setLineDash([])
            ctx.fillStyle = Theme.danger.toString(); ctx.globalAlpha = 0.8
            ctx.font = "12px " + Theme.fontFamilyMono; ctx.textAlign = "left"
            ctx.fillText("stop", 6, stopY - 5)
            ctx.restore()

            // Axes: time across, speed up
            ctx.save()
            ctx.strokeStyle = "#FFFFFF"; ctx.lineWidth = 0.5; ctx.globalAlpha = 0.9
            ctx.setLineDash([2, 4])
            ctx.beginPath(); ctx.moveTo(bw / 2, 0); ctx.lineTo(bw / 2, ch); ctx.stroke()
            ctx.setLineDash([])
            ctx.fillStyle = Theme.colorTextDim.toString()
            ctx.font = "12px " + Theme.fontFamilyMono; ctx.textAlign = "center"
            ctx.translate(bw / 2 - 9, 16); ctx.rotate(-Math.PI / 2)
            ctx.fillText("speed", 0, 0)
            ctx.restore()

            ctx.save()
            ctx.fillStyle = Theme.colorTextDim.toString()
            ctx.font = "12px " + Theme.fontFamilyMono; ctx.textAlign = "right"
            ctx.fillText("time  " + root.durationSec.toFixed(1) + " s", bw - 8, ch - 8 - 3 * 16)
            ctx.restore()

            // Playhead
            if (root.playheadX >= 0) {
                ctx.save()
                ctx.strokeStyle = Theme.danger.toString(); ctx.lineWidth = 1.5; ctx.globalAlpha = 0.9
                ctx.beginPath(); ctx.moveTo(root.playheadX, 0); ctx.lineTo(root.playheadX, ch); ctx.stroke()
                ctx.restore()
            }

            // Scrub cursor
            if (root.splineLevel === "scrub" || root.splineLevel === "node") {
                var scrubPx = root.pxOfNx(root.scrubNx)
                ctx.save()
                ctx.strokeStyle = Theme.danger.toString(); ctx.lineWidth = 1; ctx.globalAlpha = 0.9
                ctx.beginPath(); ctx.moveTo(scrubPx, 0); ctx.lineTo(scrubPx, ch); ctx.stroke()
                ctx.restore()
            }

            // Readouts — what the four settings add up to
            ctx.save()
            ctx.font = "12px " + Theme.fontFamilyMono; ctx.textAlign = "right"
            ctx.fillStyle = (root.lines > root.linesMax ? Theme.danger : Theme.colorTextDim).toString()
            ctx.fillText("lines: " + root.fmtLines(root.lines)
                         + (root.lines > root.linesMax
                            ? "  — grabber caps at " + root.fmtLines(root.linesMax)
                            : ""),
                         bw - 8, ch - 8)
            ctx.fillStyle = Theme.colorTextDim.toString()
            ctx.fillText("arc: " + root.arcDeg.toFixed(0) + "\xB0   AR: " + root.ar.toFixed(2) + " : 1",
                         bw - 8, ch - 24)
            ctx.fillStyle = (root.tooFast || root.curveFlat ? Theme.danger : Theme.colorTextDim).toString()
            ctx.fillText(root.curveFlat
                         ? "curve sits on the stop line — nothing would move"
                         : root.tooFast
                         ? "peak " + root.fitVel.toFixed(0) + " → " + root.maxSpeed.toFixed(0)
                           + " deg/s — sweep stops " + (root.arcDeg - root.reachDeg).toFixed(0)
                           + "\xB0 short of the fov"
                         : "peak: " + root.peakVel.toFixed(0) + " deg/s"
                           + "   mean: " + root.meanVel.toFixed(1) + " deg/s",
                         bw - 8, ch - 40)
            ctx.restore()

            // Spline
            if (nodeModel.count < 2) return
            ctx.strokeStyle = Theme.colorText.toString()
            ctx.lineWidth   = 1
            ctx.beginPath()
            var n = nodeModel.count, first = true
            for (var i = 0; i < n - 1; i++) {
                var lastK = (i === n - 2) ? 20 : 19
                for (var k = 0; k <= lastK; k++) {
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
                if (mouse.x >= 1 && mouse.x < root.boxW - 1) {
                    var f = root.findOnCurve(mouse.x)
                    root.insertNode(f.seg, f.nx, f.ny)
                }
            }
        }
    }

    FocusIndicator {
        inset: true
        target: freeFocus.editing
                ? null
                : ((freeFocus.current === splineBox || freeFocus.current === motorCircle)
                   ? freeFocus.current : null)
    }

    // ── Node handles ──────────────────────────────────────────────────────────
    Repeater {
        model: nodeModel
        delegate: Item {
            id: nodeItem
            property int  nodeIndex: index
            property bool isLocked:  model.locked
            property int  nodeSz:    isLocked ? root.nodeSzEnd : root.nodeSzMid
            readonly property int touchR: 25

            width: touchR * 2; height: touchR * 2
            x: root.pxOfNx(model.nx) - touchR
            y: root.pyOfNy(model.ny) - touchR

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

    // ── Duration bar — scan's aspect bar, measuring time instead of arc ────────
    Item {
        id: handle
        x: root.boxW; y: 0
        width: 39; height: root.canvasH

        Rectangle {
            anchors.fill: parent
            color: root.editTarget === "aspect" ? Qt.lighter(Theme.colorTextFaint, 1.5)
                                                : Theme.colorTextFaint
        }
        Canvas {
            anchors.fill: parent
            property bool armed: root.aspectActive
            onArmedChanged: requestPaint()
            Component.onCompleted: requestPaint()
            onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                ctx.fillStyle = (armed ? Theme.accent : Theme.bg).toString()
                ctx.beginPath()
                ctx.moveTo(2, 0)
                ctx.lineTo(width, height / 2)
                ctx.lineTo(2, height)
                ctx.closePath()
                ctx.fill()
            }
        }
        MouseArea {
            anchors.fill: parent
            property real lastGX: 0
            onPressed: function(mouse) { lastGX = mapToItem(null, mouse.x, mouse.y).x }
            onPositionChanged: function(mouse) {
                if (!pressed) return
                var gx = mapToItem(null, mouse.x, mouse.y).x
                var w  = Math.max(root.boxMinW, Math.min(root.boxMaxW, root.boxW + gx - lastGX))
                lastGX = gx
                root.durationSec = root.durOfFrac((w - root.boxMinW) / (root.boxMaxW - root.boxMinW))
            }
        }
    }

    TerminalButton {
        id: resetCurveBtn
        controller: freeFocus
        x: 8; y: root.canvasH - 34
        width: 150; height: 26
        z: 50
        fontSize: Theme.fontMonoS
        label: "[reset curve]"
        onClicked: root.resetCurve()
    }

    Hairline { x: 0; y: 270; width: 960 }

    // ── Bottom panel ──────────────────────────────────────────────────────────
    Text {
        x: 18; y: 288
        text:  "capture.freerun"
        color: Theme.colorText
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontH2 }
    }
    Text {
        x: 18; y: 322
        text:  "the lines never follow the axis"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
    }
    Text {
        x: 18; y: 350
        text:  "curve is shape only \xB7 peak fitted to the fov"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

    // ── FOV dial ──────────────────────────────────────────────────────────────
    Item {
        id: motorCircle
        readonly property int cx: 100
        readonly property int cy: 100
        readonly property int r:   72

        x: 340; y: 300
        width: 200; height: 200

        Canvas {
            anchors.fill: parent
            Component.onCompleted: requestPaint()
            onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                var cx = motorCircle.cx, cy = motorCircle.cy, r = motorCircle.r
                ctx.strokeStyle = Theme.colorTextDim.toString()
                ctx.lineWidth   = 1
                ctx.beginPath(); ctx.arc(cx, cy, r, 0, 2 * Math.PI); ctx.stroke()
                for (var deg = 0; deg < 360; deg += 10) {
                    var rad    = (deg - 90) * Math.PI / 180
                    var innerR = (deg % 90 === 0) ? 60 : ((deg % 45 === 0) ? 64 : 67)
                    ctx.beginPath()
                    ctx.moveTo(cx + innerR  * Math.cos(rad), cy + innerR  * Math.sin(rad))
                    ctx.lineTo(cx + (r + 2) * Math.cos(rad), cy + (r + 2) * Math.sin(rad))
                    ctx.stroke()
                }
            }
        }

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
                var a1 = (root.hand1Angle - 90) * Math.PI / 180
                var a2 = (root.hand2Angle - 90) * Math.PI / 180
                if (a2 <= a1) return
                ctx.beginPath()
                ctx.arc(motorCircle.cx, motorCircle.cy, motorCircle.r, a1, a2, false)
                ctx.strokeStyle = Theme.accent.toString()
                ctx.lineWidth   = 2
                ctx.stroke()
            }
        }

        Rectangle {
            id: hand1
            readonly property real handLen: motorCircle.r + 6
            width: 2; height: handLen - 10
            color: (root.editTarget === "dial" && root.dialSel === 1)
                   ? (root.dialLevel === "select"
                      ? (root.dialBlinkOn ? Theme.danger : Theme.accent) : Theme.danger)
                   : Theme.accent
            x: motorCircle.cx - 1
            y: motorCircle.cy - handLen
            transform: Rotation { origin.x: 1; origin.y: hand1.handLen; angle: root.hand1Angle }
        }
        Rectangle {
            id: hand2
            readonly property real handLen: motorCircle.r + 6
            width: 2; height: handLen - 10
            color: (root.editTarget === "dial" && root.dialSel === 2)
                   ? (root.dialLevel === "select"
                      ? (root.dialBlinkOn ? Theme.danger : Theme.accent) : Theme.danger)
                   : Theme.accent
            x: motorCircle.cx - 1
            y: motorCircle.cy - handLen
            transform: Rotation { origin.x: 1; origin.y: hand2.handLen; angle: root.hand2Angle }
        }
        // Red hand — where the axis is. It parks whenever the curve does.
        Rectangle {
            id: handRed
            readonly property real handLen: motorCircle.r + 6
            width: 2; height: handLen - 10
            color: Theme.danger
            visible: root.execState !== "idle"
            x: motorCircle.cx - 1
            y: motorCircle.cy - handLen
            transform: Rotation { origin.x: 1; origin.y: handRed.handLen; angle: root.redHandAngle }
        }
        Rectangle {
            width: 6; height: 6; radius: 3
            color: Theme.accent
            x: motorCircle.cx - 3
            y: motorCircle.cy - 3
        }

        // Draggable hand tips — same gesture as scan's dial
        Item {
            readonly property real tipX: motorCircle.cx + (motorCircle.r + 6) * Math.sin(root.hand1Angle * Math.PI / 180)
            readonly property real tipY: motorCircle.cy - (motorCircle.r + 6) * Math.cos(root.hand1Angle * Math.PI / 180)
            x: tipX - 15; y: tipY - 15
            width: 30; height: 30
            Rectangle { width: 8; height: 8; radius: 4; color: Theme.accent; anchors.centerIn: parent }
            MouseArea {
                anchors.fill: parent
                onPositionChanged: function(mouse) {
                    if (!pressed) return
                    var p = mapToItem(motorCircle, mouse.x, mouse.y)
                    var ang = Math.atan2(p.x - motorCircle.cx, -(p.y - motorCircle.cy)) * 180 / Math.PI
                    root.hand1Angle = Math.max(root.axisMinDeg, Math.min(root.hand2Angle - 10, ang))
                }
            }
        }
        Item {
            readonly property real tipX: motorCircle.cx + (motorCircle.r + 6) * Math.sin(root.hand2Angle * Math.PI / 180)
            readonly property real tipY: motorCircle.cy - (motorCircle.r + 6) * Math.cos(root.hand2Angle * Math.PI / 180)
            x: tipX - 15; y: tipY - 15
            width: 30; height: 30
            Rectangle { width: 8; height: 8; radius: 4; color: Theme.accent; anchors.centerIn: parent }
            MouseArea {
                anchors.fill: parent
                onPositionChanged: function(mouse) {
                    if (!pressed) return
                    var p = mapToItem(motorCircle, mouse.x, mouse.y)
                    var ang = Math.atan2(p.x - motorCircle.cx, -(p.y - motorCircle.cy)) * 180 / Math.PI
                    root.hand2Angle = Math.min(root.axisMaxDeg, Math.max(root.hand1Angle + 10, ang))
                }
            }
        }
    }

    Column {
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
            text:  Math.round(root.arcDeg) + "\xB0"
            color: Theme.colorText
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontH2 }
        }
    }

    // ── Line rate — the independent one ───────────────────────────────────────
    Text {
        x: 640; y: 292
        text:  "line rate"
        color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: 640; y: 312; width: 302; height: 52

        Item { id: rateProxy; anchors.fill: parent }

        // FocusIndicator reads target.x/y raw, so it must share a parent.
        FocusIndicator {
            inset: true
            target: (freeFocus.current === rateProxy && !freeFocus.editing) ? rateProxy : null
        }

        Rectangle {
            anchors.fill: parent
            color: Theme.panel; radius: 2
            border.width: root.editTarget === "rate" ? 2 : 1
            border.color: root.editTarget === "rate" ? Theme.accent : Theme.border

            Rectangle {
                x: 1; y: 1; height: parent.height - 2
                width: (parent.width - 2) * (root.lineHz - root.rateMin) / (root.rateMax - root.rateMin)
                color: Theme.accent; opacity: 0.16
            }
            // Where the rate would have to sit for the image to come out
            // geometrically true — the reference this mode exists to leave.
            Rectangle {
                visible: root.geoHz >= root.rateMin && root.geoHz <= root.rateMax
                x: 1 + (parent.width - 2) * (root.geoHz - root.rateMin) / (root.rateMax - root.rateMin)
                y: 1; width: 1; height: parent.height - 2
                color: Theme.colorTextDim
            }
            Text {
                anchors.centerIn: parent
                text:  Math.round(root.lineHz) + " Hz  fixed"
                color: Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
        }
    }
    Text {
        x: 640; y: 370
        width: 302
        elide: Text.ElideRight
        text:  root.geoHz >= root.rateMin && root.geoHz <= root.rateMax
               ? "true geometry at " + Math.round(root.geoHz) + " Hz \xB7 \xD7"
                 + root.stretch.toFixed(2) + " stretch"
               : "true geometry at " + Math.round(root.geoHz) + " Hz \xB7 out of range"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

    // ── Progress ──────────────────────────────────────────────────────────────
    Rectangle {
        x: 640; y: 398; width: 302; height: 20
        color: Theme.panel; radius: 2
        border.width: 1; border.color: Theme.border
        Rectangle {
            x: 1; y: 1; height: parent.height - 2
            width: (parent.width - 2) * root.progressFrac
            color: Theme.accent; opacity: 0.22
            Behavior on width { NumberAnimation { duration: 120 } }
        }
    }

    // ── Bottom bar ────────────────────────────────────────────────────────────
    TerminalButton {
        id: settingsBtn
        controller: freeFocus
        x: Theme.marginX
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label: "[settings]"; active: false
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenHome.qml"))
    }
    TerminalButton {
        id: modesBtn
        controller: freeFocus
        x: Theme.marginX + 130 + 18
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label: "[modes]"; active: false
        onClicked: {
            root.abortRun()
            root.StackView.view.replace(root.StackView.view.currentItem,
                                        Qt.resolvedUrl("ScreenModes.qml"),
                                        { fromPage: "ScreenFreerun.qml" })
        }
    }
    FaultChip {
        id: faultChip
        controller: freeFocus
        anchors { left: modesBtn.right; leftMargin: 24; bottom: parent.bottom; bottomMargin: 27 }
    }

    // Red pointer line: execute → the physical BTN1 on the pendant.
    Rectangle {
        anchors { left: playBtn.right; right: parent.right; verticalCenter: playBtn.verticalCenter }
        height: 1; color: Theme.danger
    }

    TerminalButton {
        id: abortBtn
        controller: freeFocus
        visible: root.execState !== "idle"
        anchors { right: parent.right; rightMargin: 18 + (130 + 18) * 2; bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label: "[abort]"
        textColor: Theme.danger
        onClicked: {
            if (Beckhoff.connected) Beckhoff.stop()
            root.abortRun()
        }
    }
    TerminalButton {
        id: homeBtn
        controller: freeFocus
        anchors { right: parent.right; rightMargin: 18 + 130 + 18; bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label:  root.homed ? "[ready]" : "[home]"
        active: root.homed
        onClicked: {
            if (freeFocus.editing) { root.exitSplineEditing(); return }
            if (Beckhoff.connected) { Beckhoff.stop(); Beckhoff.home() }
            root.abortRun()
            root.homed = true
        }
    }
    TerminalButton {
        id: playBtn
        controller: null    // BTN1-only
        anchors { right: parent.right; rightMargin: 18; bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label:  root.execState === "idle"    ? "[execute]" :
                root.execState === "running" ? "[pause]"   : "[resume]"
        borderColor: Theme.danger
        fillColor: (root.execState === "running" ||
                    (root.execState === "paused" && root.blinkVisible)) ? "#6B2020" : Theme.panel
        onClicked: {
            if (root.execState === "idle") {
                // A curve flat on the stop line has no travel to scale, so the
                // fit has no solution — refuse rather than send a nonsense peak.
                if (root.curveFlat) return
                root.startRun()
            } else if (root.execState === "running") {
                if (Beckhoff.connected) Beckhoff.pause()
                else simTimer.stop()
                root.execState = "paused"; root.blinkVisible = true
            } else {
                if (Beckhoff.connected) Beckhoff.resume()
                else simTimer.start()
                root.execState = "running"; root.blinkVisible = true
            }
        }
    }

    // ── Repaint plumbing ──────────────────────────────────────────────────────
    Timer {
        id: repaintTimer
        interval: 16; repeat: false
        onTriggered: canvas.requestPaint()
    }
    function scheduleRepaint() { if (!repaintTimer.running) repaintTimer.start() }

    onPlayheadXChanged:  root.scheduleRepaint()
    onDurationSecChanged: root.scheduleRepaint()
    onLineHzChanged:     root.scheduleRepaint()
    onHand1AngleChanged: root.scheduleRepaint()
    onHand2AngleChanged: root.scheduleRepaint()

    Component.onCompleted: {
        root.loadCurve()
        root.refreshProfile()
        root.scheduleRepaint()
    }
}
