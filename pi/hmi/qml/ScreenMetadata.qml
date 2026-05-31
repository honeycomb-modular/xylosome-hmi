// ScreenMetadata.qml — XYLOSOME metadata infuser page
//
// Accessible from ScreenHome row 06.
// Records per-pass temporal + geometric state; exports SVG for Photoshop
// compositing over the 8K scan.
//
// Layout (960×540):
//   y=0   header  (title, hairline)
//   y=80  pass timing table  (4 rows × 46px + header)
//   y=305 hairline
//   y=318 speed curve canvas  (110px, full-width minus margins)
//   y=435 session summary line
//   y=455 hairline
//   y=463 buttons  ([test trigger]  [export svg] ............ [back])

import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root
    width: 960; height: 540

    // ── Helpers ───────────────────────────────────────────────────────────────

    // "00:00.000" formatter — mirrors MetadataRecorder::formatMsRelative
    function fmtRel(absMs, t0Ms) {
        if (absMs < 0) return "--:--.---"
        var rel  = Math.max(0, absMs - t0Ms)
        var min  = Math.floor(rel / 60000)
        var sec  = Math.floor((rel % 60000) / 1000)
        var frac = rel % 1000
        function z2(n) { return n < 10 ? "0" + n : "" + n }
        function z3(n) { return n < 10 ? "00" + n : (n < 100 ? "0" + n : "" + n) }
        return z2(min) + ":" + z2(sec) + "." + z3(frac)
    }

    function fmtDur(ms) {
        if (ms < 0) return "---s"
        return (ms / 1000).toFixed(3) + "s"
    }

    // ── Speed curve canvas ────────────────────────────────────────────────────
    // Mirrors ScreenSequences Catmull-Rom — uses live Motor.nodes / Motor.seqBoxW.

    function evalSeg(nodes, seg, t) {
        var n = nodes.length
        function cl(j) { return j < 0 ? 0 : (j >= n ? n - 1 : j) }
        var xs = [], ys = []
        for (var k = 0; k < n; k++) {
            xs.push(nodes[k].nx * curveCanvas.plotW)
            ys.push(nodes[k].ny * curveCanvas.plotH)
        }
        var x0 = xs[seg],   y0 = ys[seg]
        var x1 = xs[seg+1], y1 = ys[seg+1]
        var c1x = x0 + (xs[cl(seg+1)] - xs[cl(seg-1)]) / 6.0
        var c1y = y0 + (ys[cl(seg+1)] - ys[cl(seg-1)]) / 6.0
        var c2x = x1 - (xs[cl(seg+2)] - xs[cl(seg)])   / 6.0
        var c2y = y1 - (ys[cl(seg+2)] - ys[cl(seg)])   / 6.0
        var mt  = 1.0 - t
        return {
            x: mt*mt*mt*x0 + 3*mt*mt*t*c1x + 3*mt*t*t*c2x + t*t*t*x1,
            y: mt*mt*mt*y0 + 3*mt*mt*t*c1y + 3*mt*t*t*c2y + t*t*t*y1
        }
    }

    function drawCurve() {
        curveCanvas.requestPaint()
    }

    // ── Channel config ────────────────────────────────────────────────────────
    readonly property var chColors: ["#CC4444", "#44CC44", "#4488CC", "#AAAAAA"]
    readonly property var chNames:  ["R", "G", "B", "C"]

    // ── Touch-free focus ────────────────────────────────────────────────────────
    property var focusController: metaFocus
    function focusBack() { root.StackView.view.pop() }

    FocusController {
        id: metaFocus
        targets: [testTriggerBtn, exportBtn, backBtn]
        onActivated: function(item) { item.clicked() }
    }

    // ── Header ────────────────────────────────────────────────────────────────

    Text {
        x: 18; y: 25
        text:  "metadata"
        color: Theme.colorText
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }

    Hairline { x: 9; y: 63; width: 942 }

    // ── Section label ─────────────────────────────────────────────────────────

    Text {
        x: 9; y: 76
        text:  "  pass"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Text {
        x: 72; y: 76
        text:  "ch"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Text {
        x: 130; y: 76
        text:  "t_start"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Text {
        x: 295; y: 76
        text:  "t_end"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Text {
        x: 460; y: 76
        text:  "duration"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

    // ── Pass rows — read from Recorder.currentPasses ──────────────────────────
    // Repeater over the 4-element QVariantList.
    // Falls back to placeholder text when hasData = false.

    Repeater {
        id: passRepeater
        model: Recorder.hasData ? Recorder.currentPasses : [
            { passNum: 1, channel: "R", tStartStr: "--:--.---", tEndStr: "--:--.---", durationStr: "---s" },
            { passNum: 2, channel: "G", tStartStr: "--:--.---", tEndStr: "--:--.---", durationStr: "---s" },
            { passNum: 3, channel: "B", tStartStr: "--:--.---", tEndStr: "--:--.---", durationStr: "---s" },
            { passNum: 4, channel: "C", tStartStr: "--:--.---", tEndStr: "--:--.---", durationStr: "---s" }
        ]

        delegate: Item {
            x: 0; y: 90 + index * 50; width: 960; height: 50

            readonly property var rowData: modelData
            readonly property color chColor: {
                var ch = rowData.channel
                if (ch === "R") return "#CC4444"
                if (ch === "G") return "#44CC44"
                if (ch === "B") return "#4488CC"
                return "#AAAAAA"
            }

            // pass num
            Text {
                x: 9; anchors.verticalCenter: parent.verticalCenter
                text:  "  " + rowData.passNum
                color: Theme.colorTextDim
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
            // channel (coloured)
            Text {
                x: 72; anchors.verticalCenter: parent.verticalCenter
                text:  rowData.channel
                color: chColor
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
            // t_start
            Text {
                x: 130; anchors.verticalCenter: parent.verticalCenter
                text:  rowData.tStartStr !== undefined
                       ? rowData.tStartStr
                       : root.fmtRel(rowData.tStart_ms, rowData.tStart_ms)
                color: Recorder.hasData ? Theme.colorText : Theme.colorTextFaint
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
            // t_end
            Text {
                x: 295; anchors.verticalCenter: parent.verticalCenter
                text:  rowData.tEndStr !== undefined
                       ? rowData.tEndStr
                       : root.fmtRel(rowData.tEnd_ms, rowData.tStart_ms)
                color: Recorder.hasData ? Theme.colorText : Theme.colorTextFaint
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
            // duration
            Text {
                x: 460; anchors.verticalCenter: parent.verticalCenter
                text:  rowData.durationStr !== undefined
                       ? rowData.durationStr
                       : root.fmtDur(rowData.duration_ms)
                color: Recorder.hasData ? Theme.colorText : Theme.colorTextFaint
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }

            // row hairline
            Hairline { x: 9; y: parent.height - 1; width: 942; opacity: 0.35 }
        }
    }

    // ── Speed curve canvas ────────────────────────────────────────────────────
    // Displays the CURRENT live curve from Motor.nodes.
    // Redraws whenever Motor signals a change.

    Hairline { x: 9; y: 305; width: 942 }

    Text {
        x: 9; y: 317
        text:  "  speed curve"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

    Canvas {
        id: curveCanvas
        x: 9; y: 330
        width: 942; height: 100

        readonly property int plotW: width
        readonly property int plotH: height

        onPaint: {
            var ctx = getContext("2d")
            ctx.fillStyle = Theme.panel.toString()
            ctx.fillRect(0, 0, width, height)

            // border
            ctx.strokeStyle = Theme.border.toString()
            ctx.lineWidth   = 1
            ctx.strokeRect(0, 0, width, height)

            // zero axis
            var zy = height / 2
            ctx.save()
            ctx.strokeStyle = "#404040"; ctx.lineWidth = 0.5
            ctx.setLineDash([3, 5])
            ctx.beginPath(); ctx.moveTo(0, zy); ctx.lineTo(width, zy); ctx.stroke()
            ctx.setLineDash([])
            ctx.restore()

            var nodes = Motor.nodes
            if (!nodes || nodes.length < 2) return

            // Convert to array of plain objects (QVariantList → JS)
            var pts = []
            for (var i = 0; i < nodes.length; i++)
                pts.push({ nx: nodes[i].nx, ny: nodes[i].ny })

            // Spline
            ctx.strokeStyle = Theme.colorText.toString()
            ctx.lineWidth   = 1.5
            ctx.beginPath()
            var n     = pts.length
            var first = true
            for (var seg = 0; seg < n - 1; seg++) {
                var last_k = (seg === n - 2) ? 20 : 19
                for (var k = 0; k <= last_k; k++) {
                    var pt = root.evalSeg(pts, seg, k / 20.0)
                    var px = Math.max(0, Math.min(curveCanvas.width - 1, pt.x))
                    var py = Math.max(0, Math.min(curveCanvas.height - 1, pt.y))
                    if (first) { ctx.moveTo(px, py); first = false }
                    else        ctx.lineTo(px, py)
                }
            }
            ctx.stroke()

            // Node dots
            ctx.fillStyle = Theme.accent.toString()
            for (var ni = 0; ni < pts.length; ni++) {
                var npx = pts[ni].nx * width
                var npy = pts[ni].ny * height
                ctx.beginPath()
                ctx.arc(npx, npy, 3, 0, 2 * Math.PI)
                ctx.fill()
            }
        }
    }

    // Redraw canvas when Motor.nodes changes (e.g. artist edits the curve)
    Connections {
        target: Motor
        function onNodesChanged()  { curveCanvas.requestPaint() }
        function onSeqBoxWChanged() { curveCanvas.requestPaint() }
    }

    // ── Session summary ───────────────────────────────────────────────────────

    Text {
        x: 9; y: 438
        text:  Recorder.hasData
               ? "  " + Recorder.lastSummary
               : "  // no triggers recorded this session"
        color: Recorder.hasData ? Theme.colorText : Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

    Text {
        anchors { right: parent.right; rightMargin: 9; top: undefined }
        y: 438
        text:  Recorder.hasData ? Recorder.triggerCount + " total" : ""
        color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

    Hairline { x: 9; y: 452; width: 942 }

    // ── Buttons ───────────────────────────────────────────────────────────────

    TerminalButton {
        id: testTriggerBtn
        controller: metaFocus
        x: 9; y: 463
        width: 200; height: 39
        label:  "[test trigger]"
        active: false
        onClicked: Recorder.simulateTrigger()
    }

    TerminalButton {
        id: exportBtn
        controller: metaFocus
        x: 220; y: 463
        width: 180; height: 39
        label:  "[export svg]"
        active: Recorder.hasData
        onClicked: {
            var path = Recorder.exportSvg("/home/hoyte/xylosome_exports")
            exportFeedback.text = path.length > 0
                ? "// written: " + path.split("/").pop()
                : "// export failed"
            exportFeedback.color = path.length > 0 ? Theme.accent : Theme.danger
        }
    }

    Text {
        id: exportFeedback
        x: 415; y: 481
        text:  ""
        color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

    // ── [back] — bottom-right, aligned with the action buttons ──────────────────

    TerminalButton {
        id: backBtn
        controller: metaFocus
        anchors { right: parent.right; rightMargin: 18 }
        y: 463
        width: 130; height: 39
        label:  "[back]"
        active: false
        onClicked: root.StackView.view.pop()
    }
}
