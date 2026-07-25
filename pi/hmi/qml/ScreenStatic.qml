// ScreenStatic.qml — capture ▸ static. Lines without moving the camera.
//
// The motor never turns. The sensor fixes one axis at 8192 px and the camera
// keeps scanning lines anyway, so the image is built from TIME alone: pick how
// many lines (which IS the aspect) and how long to take, and the trigger rate
// falls out as lines ÷ duration.
//
// Two inputs, matching the other modes' grammar:
//   Frame   — the graphic IS the image: a rectangle drawn at its true 8192 × N
//             proportions, growing as the line count changes
//   Timeline — the same log span control ScreenTimed uses (1 s … 24 h)
//
// The daemon holds the pose it is already at (executeStatic sends a zero-length
// arc), so nothing repositions. It clamps the rate at line_max_hz and reports
// the real total back as plannedLines — mirrored here as the "clamped" warning.

import QtCore
import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root
    width: 960; height: 540

    // Switching mode destroys this page (the pages replace each other), so
    // without this the frame and span reset every time you looked at another
    // mode — let alone across a reboot.
    Settings {
        category: "static"
        property alias lines:       root.lines
        property alias durationSec: root.durationSec
    }

    // ── Frame definition ────────────────────────────────────────────────────────
    readonly property int sensorPx: 8192          // the fixed sensor axis
    readonly property int linesMin: 256
    readonly property int linesMax: 65536
    property int lines: 22200

    // Span: 1 s … 24 h on a log scale, same as ScreenTimed.
    readonly property int durMinSec: 1
    readonly property int durMaxSec: 86400
    property int durationSec: 60

    // The camera cannot be driven past its readout ceiling; xylod clamps and
    // delivers fewer lines, so say so rather than promising the drawn aspect.
    readonly property real maxHz: 37000
    readonly property real rateHz: root.durationSec > 0 ? root.lines / root.durationSec : 0
    readonly property bool clamped: root.rateHz > root.maxHz
    readonly property int  deliveredLines: root.clamped
                                         ? Math.round(root.maxHz * root.durationSec)
                                         : root.lines

    // ── Run state ───────────────────────────────────────────────────────────────
    property string execState:   "idle"    // idle | running | paused
    property bool   blinkVisible: true
    property real   progressFrac: 0.0
    property real   elapsedSec:   0.0
    property bool   homed:        false

    // ── Log-scale helpers ───────────────────────────────────────────────────────
    readonly property real _lnDur: Math.log(root.durMaxSec)
    function fracOfDur(sec) {
        sec = Math.max(root.durMinSec, Math.min(root.durMaxSec, sec))
        return Math.log(sec) / root._lnDur
    }
    function durOfFrac(f) {
        f = Math.max(0, Math.min(1, f))
        return Math.round(Math.exp(f * root._lnDur))
    }
    readonly property real _lnLoLines: Math.log(root.linesMin)
    readonly property real _lnSpanLines: Math.log(root.linesMax) - Math.log(root.linesMin)
    function fracOfLines(n) {
        n = Math.max(root.linesMin, Math.min(root.linesMax, n))
        return (Math.log(n) - root._lnLoLines) / root._lnSpanLines
    }
    function linesOfFrac(f) {
        f = Math.max(0, Math.min(1, f))
        return Math.round(Math.exp(root._lnLoLines + f * root._lnSpanLines))
    }
    function fmtDuration(sec) {
        sec = Math.max(0, Math.round(sec))
        var h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60
        function p2(n) { return (n < 10 ? "0" : "") + n }
        return p2(h) + ":" + p2(m) + ":" + p2(s)
    }
    function fmtLines(n) {
        return n.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ".")
    }

    // ── Touch-free focus ────────────────────────────────────────────────────────
    property var    focusController: staticFocus
    property string editTarget: "none"     // none | frame | span

    function focusBack() { root.StackView.view.pop() }

    FocusController {
        id: staticFocus
        index: 0
        targets: [frameProxy, timelineProxy]
                 .concat(faultChip.focusTargets)
                 .concat([homeBtn, settingsBtn, modesBtn])
        onActivated: function(item) {
            if (item === frameProxy)          root.enterEditing("frame")
            else if (item === timelineProxy)  root.enterEditing("span")
            else if (item.clicked)            item.clicked()
        }
        onAdjust: function(delta) {
            if (root.editTarget === "frame")
                root.lines = root.linesOfFrac(root.fracOfLines(root.lines) + delta * 0.015)
            else if (root.editTarget === "span")
                root.durationSec = root.durOfFrac(root.fracOfDur(root.durationSec) + delta * 0.02)
        }
        onConfirmed: root.exitEditing()
        onCanceled:  root.exitEditing()
    }

    function enterEditing(what) { staticFocus.editing = true;  root.editTarget = what }
    function exitEditing()      { staticFocus.editing = false; root.editTarget = "none" }

    // ENC push while editing (main.qml routes here).
    function focusContext() { if (staticFocus.editing) root.exitEditing() }
    // BTN1 — dedicated execute.
    function btn1Execute() { playBtn.clicked() }

    // ── Run control ─────────────────────────────────────────────────────────────
    function startRun() {
        root.progressFrac = 0
        root.elapsedSec   = 0
        root.execState    = "running"
        root.blinkVisible = true
        root.homed        = false
        if (Beckhoff.connected) {
            // Hold wherever the axis already is — the point of this mode.
            Beckhoff.executeStatic(Motor.colorMode, Beckhoff.positionDeg,
                                   root.durationSec, root.lines)
        } else {
            simTimer.start()
        }
    }
    function finishRun() {
        simTimer.stop()
        root.progressFrac = 1
        root.execState    = "idle"
        root.blinkVisible = true
        finishClear.start()
    }
    function abortRun() {
        simTimer.stop()
        root.execState    = "idle"
        root.blinkVisible = true
        root.progressFrac = 0
        root.elapsedSec   = 0
    }

    Timer {
        id: finishClear
        interval: 900; repeat: false
        onTriggered: { root.progressFrac = 0; root.elapsedSec = 0 }
    }
    Timer {
        id: simTimer
        interval: 250; repeat: true; running: false
        onTriggered: {
            if (Beckhoff.connected) { simTimer.stop(); return }
            root.elapsedSec += 0.25
            root.progressFrac = Math.min(1, root.elapsedSec / Math.max(1, root.durationSec))
            if (root.progressFrac >= 1) root.finishRun()
        }
    }
    Timer {
        interval: 500; repeat: true; running: root.execState === "paused"
        onTriggered: root.blinkVisible = !root.blinkVisible
    }

    Connections {
        target: Beckhoff
        function onProgressChanged() {
            if (root.execState === "running" && Beckhoff.connected) {
                root.progressFrac = Beckhoff.progress
                root.elapsedSec   = Beckhoff.progress * root.durationSec
            }
        }
        function onSequenceDone(passes) { if (root.execState !== "idle") root.finishRun() }
        function onFaulted(text)        { root.abortRun() }
        function onConnectedChanged()   { if (!Beckhoff.connected && root.execState !== "idle") root.abortRun() }
    }

    // ── Header ────────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: Theme.titleY
        text:  "capture.static"
        color: Theme.colorText
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }
    Text {
        x: Theme.marginX; y: 48
        text:  "camera holds still — the image is built from lines alone"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
    }

    // ── The frame — drawn at its true proportions ───────────────────────────────
    Item {
        id: frameBox
        x: Theme.marginX; y: 84
        width: 300; height: 234

        Item { id: frameProxy; anchors.fill: parent }

        // Must be declared alongside its target: FocusIndicator reads target.x/y
        // raw, so it only lines up when the two share a parent.
        FocusIndicator {
            inset: true
            target: (staticFocus.current === frameProxy && !staticFocus.editing) ? frameProxy : null
        }

        // The frame at its true proportions: the scan direction runs HORIZONTALLY
        // (one scanned line per column) and the sensor's fixed 8192 px vertically,
        // matching how the image actually comes off the rig.
        Item {
            id: framePreview
            readonly property real fit: Math.min((frameBox.width  - 40) / root.lines,
                                                 (frameBox.height - 40) / root.sensorPx)
            width:  Math.max(4, root.lines    * fit)
            height: Math.max(4, root.sensorPx * fit)
            anchors.centerIn: parent

            // Same line palette as the scan page's rainbow void (ScreenScan's
            // drawCanvas) — kept local rather than shared, so nothing here can
            // change how the reference page draws. Rotated to match the frame:
            // vertical stripes, because each stripe IS one scanned line.
            Canvas {
                anchors.fill: parent
                property real prog:  root.execState === "idle" ? 1.0 : root.progressFrac
                property int  nline: root.lines
                property int  cmode: Motor.colorMode
                onProgChanged:   requestPaint()
                onNlineChanged:  requestPaint()
                onCmodeChanged:  requestPaint()
                onWidthChanged:  requestPaint()
                onHeightChanged: requestPaint()
                Component.onCompleted: requestPaint()
                onPaint: {
                    var ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)
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
                    var stride = 4          // 3 px line + 1 px gap
                    var lim = width * prog  // builds up left→right while scanning
                    ctx.save()
                    ctx.globalAlpha = 0.9
                    var bwMode = (cmode === 1)
                    for (var rx = 0; rx < lim; rx += stride) {
                        var li = Math.floor(rx / stride)
                        var ci = ((li * 1664525 + 1013904223) ^ (li * 22695477)) % palette.length
                        if (ci < 0) ci += palette.length
                        if (bwMode) {
                            var gray = 18 + (ci * 3) % 55
                            ctx.fillStyle = "rgb(" + gray + "," + gray + "," + gray + ")"
                        } else {
                            ctx.fillStyle = palette[ci]
                        }
                        ctx.fillRect(rx, 0, 3, height)
                    }
                    ctx.restore()
                }
            }

            Rectangle {
                anchors.fill: parent
                color: "transparent"
                border.width: 1
                border.color: root.editTarget === "frame" ? Theme.accent : Theme.border
            }
        }
    }

    // ── Readouts — right of the frame ───────────────────────────────────────────
    Column {
        id: linesReadout
        spacing: 2
        x: 356; y: 96
        Text {
            text: "lines"; color: Theme.colorTextDim
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
        }
        Text {
            text: root.fmtLines(root.lines)
            color: root.editTarget === "frame" ? Theme.danger : Theme.colorText
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontH1 }
        }
        Text {
            text: root.fmtLines(root.lines) + " \xD7 " + root.sensorPx + " px   ·   "
                  + (root.lines / root.sensorPx).toFixed(2) + " : 1"
            color: Theme.colorTextFaint
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
        }
    }

    Column {
        spacing: 2
        anchors { right: parent.right; rightMargin: Theme.marginX }
        y: 96
        Text {
            anchors.right: parent.right
            text: root.execState === "idle" ? "span" : "elapsed / span"
            color: Theme.colorTextDim
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
        }
        Text {
            anchors.right: parent.right
            text: root.execState === "idle"
                  ? root.fmtDuration(root.durationSec)
                  : root.fmtDuration(root.elapsedSec) + " / " + root.fmtDuration(root.durationSec)
            color: root.execState === "idle" ? Theme.colorText : Theme.accent
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontH1 }
        }
        Text {
            anchors.right: parent.right
            text: root.clamped
                  ? "rate " + Math.round(root.maxHz) + " Hz max — delivers "
                    + root.fmtLines(root.deliveredLines) + " lines"
                  : "rate " + Math.round(root.rateHz) + " Hz"
            color: root.clamped ? Theme.danger : Theme.colorTextFaint
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
        }
        Text {
            anchors.right: parent.right
            // Colour runs the span FOUR times (one pass per filter), so say what
            // the capture will actually cost rather than showing one span.
            text: Motor.colorMode === 0
                  ? "4-pass r/g/b/c — total " + root.fmtDuration(root.durationSec * 4)
                  : "single bw pass — motor stationary"
            color: Theme.colorTextFaint
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
        }
    }

    // ── Timeline — the span ─────────────────────────────────────────────────────
    Item {
        id: timeline
        x: Theme.marginX; y: 340
        width: Theme.contentW; height: 64

        readonly property real handleX: root.fracOfDur(root.durationSec) * width

        Item { id: timelineProxy; anchors.fill: parent }

        FocusIndicator {
            inset: true
            target: (staticFocus.current === timelineProxy && !staticFocus.editing) ? timelineProxy : null
        }

        Rectangle {
            id: track
            anchors.fill: parent
            color: Theme.panel; radius: 2
            border.width: root.editTarget === "span" ? 2 : 1
            border.color: root.editTarget === "span" ? Theme.accent : Theme.border

            Rectangle {
                visible: root.execState === "idle"
                x: 1; y: 1; height: parent.height - 2
                width: Math.max(0, timeline.handleX - 1)
                color: Theme.accent; opacity: 0.14; radius: 2
            }
            Rectangle {
                visible: root.execState === "idle"
                width: 3; height: parent.height - 8; radius: 1
                color: Theme.accent
                x: Math.max(1, Math.min(parent.width - 4, timeline.handleX - 1)); y: 4
            }
            Rectangle {
                visible: root.execState !== "idle"
                x: 1; y: 1; height: parent.height - 2
                width: Math.max(0, root.progressFrac * (parent.width - 2))
                color: Theme.accentDim; radius: 2
            }
            Rectangle {
                visible: root.execState !== "idle"
                width: 2; height: parent.height - 2; y: 1
                color: Theme.accent
                x: Math.max(1, Math.min(parent.width - 3, root.progressFrac * (parent.width - 2)))
            }

            Text {
                anchors.centerIn: parent
                visible: root.execState !== "idle"
                text: Math.round(root.progressFrac * 100) + "%"
                color: Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontH2 }
            }
            Text {
                anchors { right: parent.right; rightMargin: 8; bottom: parent.bottom; bottomMargin: 6 }
                visible: root.execState !== "idle"
                text: root.fmtLines(Math.round(root.progressFrac * root.deliveredLines))
                      + " / " + root.fmtLines(root.deliveredLines) + " lines"
                color: Theme.colorTextDim
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
            }

            MouseArea {
                anchors.fill: parent
                enabled: root.execState === "idle"
                function setFromX(mx) { root.durationSec = root.durOfFrac(mx / track.width) }
                onPressed:         function(m) { setFromX(m.x) }
                onPositionChanged: function(m) { if (pressed) setFromX(m.x) }
            }
        }

        Text {
            visible: root.execState === "idle"
            anchors { left: parent.left; top: parent.bottom; topMargin: 4 }
            text: "1 s"; color: Theme.colorTextFaint
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
        }
        Text {
            visible: root.execState === "idle"
            anchors { right: parent.right; top: parent.bottom; topMargin: 4 }
            text: "24 h"; color: Theme.colorTextFaint
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
        }
        Text {
            anchors { horizontalCenter: parent.horizontalCenter; top: parent.bottom; topMargin: 4 }
            text: root.execState === "idle"
                  ? "frame sets the aspect  ·  span sets how long"
                  : "scanning — axis held at " + Beckhoff.positionDeg.toFixed(1) + "\xB0"
            color: Theme.colorTextFaint
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
        }
    }

    // ── Bottom bar ──────────────────────────────────────────────────────────────

    TerminalButton {
        id: settingsBtn
        controller: staticFocus
        x: Theme.marginX
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label: "[settings]"; active: false
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenHome.qml"))
    }

    TerminalButton {
        id: modesBtn
        controller: staticFocus
        x: Theme.marginX + 130 + 18
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label: "[modes]"; active: false
        onClicked: {
            root.abortRun()
            root.StackView.view.replace(root.StackView.view.currentItem,
                                        Qt.resolvedUrl("ScreenModes.qml"),
                                        { fromPage: "ScreenStatic.qml" })
        }
    }
    FaultChip {
        id: faultChip
        controller: staticFocus
        anchors { left: modesBtn.right; leftMargin: 24; bottom: parent.bottom; bottomMargin: 27 }
    }

    Rectangle {
        anchors { left: playBtn.right; right: parent.right; verticalCenter: playBtn.verticalCenter }
        height: 1; color: Theme.danger
    }

    TerminalButton {
        id: playBtn
        controller: null    // BTN1-only
        anchors { right: parent.right; rightMargin: 18; bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label: root.execState === "idle"    ? "[execute]" :
               root.execState === "running" ? "[pause]"   : "[resume]"
        borderColor: Theme.danger
        fillColor: (root.execState === "running" ||
                    (root.execState === "paused" && root.blinkVisible)) ? "#6B2020" : Theme.panel
        onClicked: {
            if (root.execState === "idle") {
                if (root.durationSec < 1 || root.lines < root.linesMin) return
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

    TerminalButton {
        id: homeBtn
        controller: staticFocus
        anchors { right: parent.right; rightMargin: 18 + 130 + 18; bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label: root.homed ? "[ready]" : "[home]"
        active: root.homed
        onClicked: {
            if (Beckhoff.connected) { Beckhoff.stop(); Beckhoff.home() }
            root.abortRun()
            root.homed = true
        }
    }

    Component.onCompleted: staticFocus.editing = false
}
