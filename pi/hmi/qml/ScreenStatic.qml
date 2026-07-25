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

import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root
    width: 960; height: 540

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
                 .concat(modeStrip.focusTargets)
                 .concat(faultChip.focusTargets)
                 .concat([homeBtn, settingsBtn])
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
    Hairline { x: 0; y: Theme.hairlineTopY; width: 960 }

    // ── The frame — drawn at its true proportions ───────────────────────────────
    FocusIndicator {
        inset: true
        target: (staticFocus.current === frameProxy && !staticFocus.editing) ? frameProxy : null
    }

    Item {
        id: frameBox
        x: Theme.marginX; y: 84
        width: 300; height: 234

        Item { id: frameProxy; anchors.fill: parent }

        // 8192 × lines, scaled to fit — so a tall image looks tall.
        Rectangle {
            id: framePreview
            readonly property real fit: Math.min((frameBox.width  - 40) / root.sensorPx,
                                                 (frameBox.height - 40) / root.lines)
            width:  Math.max(4, root.sensorPx * fit)
            height: Math.max(4, root.lines    * fit)
            anchors.centerIn: parent
            color: Theme.accent
            opacity: root.editTarget === "frame" ? 0.22 : 0.12
            border.width: root.editTarget === "frame" ? 2 : 1
            border.color: root.editTarget === "frame" ? Theme.danger : Theme.accent
        }
        // Progress fill — the frame builds up line by line as it scans.
        Rectangle {
            visible: root.execState !== "idle"
            width:  framePreview.width
            height: Math.max(1, framePreview.height * root.progressFrac)
            x: framePreview.x
            y: framePreview.y
            color: Theme.accent; opacity: 0.5
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
            text: root.sensorPx + " \xD7 " + root.fmtLines(root.lines) + " px   ·   1 : "
                  + (root.lines / root.sensorPx).toFixed(2)
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
    Hairline { x: 0; y: Theme.bottomBarY; width: 960 }

    TerminalButton {
        id: settingsBtn
        controller: staticFocus
        x: Theme.marginX
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label: "[settings]"; active: false
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenHome.qml"))
    }

    ModeStrip {
        id: modeStrip
        mode: "static"; controller: staticFocus
        x: Theme.marginX + 130 + 18
        anchors { bottom: parent.bottom; bottomMargin: 27 }
        onSwitchTo: function(page) {
            root.abortRun()
            root.StackView.view.replace(root.StackView.view.currentItem,
                                        Qt.resolvedUrl(page))
        }
    }
    FaultChip {
        id: faultChip
        controller: staticFocus
        anchors { left: modeStrip.right; leftMargin: 24; bottom: parent.bottom; bottomMargin: 27 }
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
