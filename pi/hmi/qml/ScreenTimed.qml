// ScreenTimed.qml — timed / long-duration field scan.
// One of the four sibling capture pages (see ScreenModes.qml) — not a submenu.
//
// Unlike the program scan (velocity curve, seconds long), this mode scans a
// fixed FOV arc at a CONSTANT crawl over a chosen span — a few seconds up to
// 24 hours. Two inputs:
//   FOV dial   — two hands set the arc (field) the camera sweeps (start · end)
//   Timeline   — drag (or encoder) sets the total span; a clock mirrors it
// Execute sends a flat constant-velocity profile (vel = arc ÷ span). While
// running the timeline fills with progress: % · elapsed/total · lines scanned.
//
// NOTE: single continuous pass (no 4-pass r/g/b/c). And the daemon's velocity
// model floors at ~1°/s, so a true multi-hour crawl needs xylod/servo work —
// the page still drives correctly offline and sends the right target velocity.

import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root
    width: 960; height: 540

    // ── Scan definition ─────────────────────────────────────────────────────────
    property real hand1Angle: -45     // FOV start (deg)
    property real hand2Angle:  45     // FOV end   (deg)
    readonly property real axisMinDeg: -180
    readonly property real axisMaxDeg:  180
    readonly property real arcDeg: Math.abs(root.hand2Angle - root.hand1Angle)

    // Span: 1 s … 24 h, set on a log scale so seconds and hours are both reachable.
    readonly property int  durMinSec: 1
    readonly property int  durMaxSec: 86400
    property int  durationSec: 3600   // default 1 h

    // "lines scanned" is an estimate until the capture pipeline defines a real
    // slow-scan line rate — scaled from the FOV arc by a nominal constant.
    readonly property int  linesPerDeg: 150
    readonly property int  plannedLines: Math.round(root.arcDeg * root.linesPerDeg)

    // ── Run state ───────────────────────────────────────────────────────────────
    property string execState:   "idle"   // idle | running | paused
    property bool   blinkVisible: true     // drives [resume] blink
    property real   progressFrac: 0.0      // 0..1
    property real   elapsedSec:   0.0
    property bool   homed:        false

    readonly property real velDegS: root.durationSec > 0 ? root.arcDeg / root.durationSec : 0

    // ── Log-scale span helpers ──────────────────────────────────────────────────
    readonly property real _lnMax: Math.log(root.durMaxSec)
    function fracOfDur(sec) {
        sec = Math.max(root.durMinSec, Math.min(root.durMaxSec, sec))
        return Math.log(sec) / root._lnMax
    }
    function durOfFrac(f) {
        f = Math.max(0, Math.min(1, f))
        return Math.round(Math.exp(f * root._lnMax))
    }
    function fmtDuration(sec) {
        sec = Math.max(0, Math.round(sec))
        var h = Math.floor(sec / 3600)
        var m = Math.floor((sec % 3600) / 60)
        var s = sec % 60
        function p2(n) { return (n < 10 ? "0" : "") + n }
        return p2(h) + ":" + p2(m) + ":" + p2(s)
    }
    function fmtLines(n) {
        return n.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ".")
    }

    // ── Touch-free focus ────────────────────────────────────────────────────────
    // Sections: FOV dial · timeline · home · back. Execute is BTN1-only.
    property var    focusController: timedFocus
    property string editTarget: "none"    // none | dial | span
    property int    dialSel:    0          // 1 start hand · 2 end hand
    property string dialLevel:  "none"     // none | select | move
    property bool   dialBlinkOn: true

    function focusBack() { root.StackView.view.pop() }

    FocusController {
        id: timedFocus
        targets: [fovCircle, timelineProxy]
                 .concat(faultChip.focusTargets)
                 .concat([homeBtn, settingsBtn, modesBtn])
        index: 1   // start on the timeline
        onActivated: function(item) {
            if (item === fovCircle)          root.enterDialEditing()
            else if (item === timelineProxy) root.enterSpanEditing()
            else if (item.clicked)           item.clicked()
        }
        onAdjust:    function(delta) { root.editAdjust(delta) }
        onConfirmed: root.editConfirm()
        onCanceled:  root.editCancel()
    }

    // ENC push while editing — confirm / advance the active editor (main.qml).
    function focusContext() {
        if (!timedFocus.editing) return
        root.editConfirm()
    }
    // BTN1 — dedicated execute toggle (main.qml Qt.Key_Delete).
    function btn1Execute() { playBtn.clicked() }

    function editAdjust(d) {
        if (root.editTarget === "dial")      root.dialAdjust(d)
        else if (root.editTarget === "span") root.spanAdjust(d)
    }
    function editConfirm() {
        if (root.editTarget === "dial")      root.dialConfirm()
        else if (root.editTarget === "span") root.exitSpanEditing()
    }
    function editCancel() {
        if (root.editTarget === "dial")      root.dialCancel()
        else if (root.editTarget === "span") root.exitSpanEditing()
    }

    // ── Dial editing — pick a hand, rotate to move it (ported from ScreenScan) ──
    function enterDialEditing() {
        timedFocus.editing = true
        root.editTarget = "dial"
        root.dialLevel  = "select"
        root.dialSel    = 2      // end hand first — the usual one to set
    }
    function exitDialEditing() {
        timedFocus.editing = false
        root.editTarget = "none"
        root.dialLevel  = "none"
        root.dialSel    = 0
    }
    function dialAdjust(d) {
        if (root.dialLevel === "select") {
            if (d > 0)      root.dialSel = 2
            else if (d < 0) root.dialSel = 1
            return
        }
        var step = 2   // degrees per detent
        if (root.dialSel === 1)
            root.hand1Angle = Math.max(root.axisMinDeg, Math.min(root.hand2Angle - 10, root.hand1Angle + d * step))
        else if (root.dialSel === 2)
            root.hand2Angle = Math.min(root.axisMaxDeg, Math.max(root.hand1Angle + 10, root.hand2Angle + d * step))
    }
    function dialConfirm() {
        if (root.dialLevel === "select")    root.dialLevel = "move"
        else if (root.dialLevel === "move") root.dialLevel = "select"
    }
    function dialCancel() {
        if (root.dialLevel === "move")        root.dialLevel = "select"
        else if (root.dialLevel === "select") root.exitDialEditing()
    }

    // ── Span editing — encoder scales the duration multiplicatively ─────────────
    function enterSpanEditing() {
        timedFocus.editing = true
        root.editTarget = "span"
    }
    function exitSpanEditing() {
        timedFocus.editing = false
        root.editTarget = "none"
    }
    function spanAdjust(d) {
        // Move along the log span axis a fixed step per detent — smooth across s→h.
        root.durationSec = root.durOfFrac(root.fracOfDur(root.durationSec) + d * 0.02)
    }

    // ── Run control ─────────────────────────────────────────────────────────────
    function buildFlatProfile() {
        var prof = []
        for (var i = 0; i < 64; i++) prof.push(1.0)   // constant velocity
        return prof
    }
    function startRun() {
        root.progressFrac = 0
        root.elapsedSec   = 0
        root.execState    = "running"
        root.blinkVisible = true
        root.homed        = false
        if (Beckhoff.connected) {
            // Constant crawl: pin min = max = target so the daemon floor can't
            // override, flat 1.0 profile. Single pass (bw).
            // plannedLines is now sent, not just displayed: with max=min=velDegS
            // the rate works out to plannedLines/durationSec, so the "N lines"
            // readout above is what the trigger actually delivers.
            Beckhoff.executeScan(1, root.hand1Angle, root.hand2Angle,
                                 root.velDegS, root.velDegS,
                                 root.plannedLines, root.buildFlatProfile())
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
        id: finishClear      // hold the full bar briefly, then reset to idle view
        interval: 900; repeat: false
        onTriggered: { root.progressFrac = 0; root.elapsedSec = 0 }
    }

    // Offline sim — real-time fill over the chosen span.
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

    // Blink timer — pulses [resume] while paused.
    Timer {
        interval: 500; repeat: true; running: root.execState === "paused"
        onTriggered: root.blinkVisible = !root.blinkVisible
    }
    // Dial candidate-hand blink while choosing.
    Timer {
        interval: 400; repeat: true
        running: root.editTarget === "dial" && root.dialLevel === "select"
        onTriggered: root.dialBlinkOn = !root.dialBlinkOn
        onRunningChanged: if (!running) root.dialBlinkOn = true
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
        text:  "capture.timed"
        color: Theme.colorText
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }
    Text {
        x: Theme.marginX; y: 48
        text:  "long-duration field scan — constant crawl over a set span"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
    }
    Hairline { x: 0; y: Theme.hairlineTopY; width: 960 }

    // ── FOV dial ────────────────────────────────────────────────────────────────
    FocusIndicator {
        inset: true
        target: (timedFocus.current === fovCircle && !timedFocus.editing) ? fovCircle : null
    }

    Item {
        id: fovCircle
        readonly property int cx: 100
        readonly property int cy: 100
        readonly property int r:  72
        x: 40; y: 110
        width: 200; height: 200

        // Ring + ticks
        Canvas {
            anchors.fill: parent
            Component.onCompleted: requestPaint()
            onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                var cx = fovCircle.cx, cy = fovCircle.cy, r = fovCircle.r
                ctx.strokeStyle = Theme.colorTextDim.toString()
                ctx.lineWidth = 1
                ctx.beginPath(); ctx.arc(cx, cy, r, 0, 2 * Math.PI); ctx.stroke()
                for (var deg = 0; deg < 360; deg += 10) {
                    var rad = (deg - 90) * Math.PI / 180
                    var innerR = (deg % 90 === 0) ? 60 : ((deg % 45 === 0) ? 64 : 67)
                    ctx.beginPath()
                    ctx.moveTo(cx + innerR  * Math.cos(rad), cy + innerR  * Math.sin(rad))
                    ctx.lineTo(cx + (r + 2) * Math.cos(rad), cy + (r + 2) * Math.sin(rad))
                    ctx.stroke()
                }
            }
        }

        // FOV arc between the hands
        Canvas {
            anchors.fill: parent
            property real _h1: root.hand1Angle
            property real _h2: root.hand2Angle
            on_H1Changed: requestPaint()
            on_H2Changed: requestPaint()
            onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                var cx = fovCircle.cx, cy = fovCircle.cy, r = fovCircle.r
                var a1 = (root.hand1Angle - 90) * Math.PI / 180
                var a2 = (root.hand2Angle - 90) * Math.PI / 180
                if (a2 <= a1) return
                ctx.beginPath(); ctx.arc(cx, cy, r, a1, a2, false)
                ctx.strokeStyle = Theme.accent.toString(); ctx.lineWidth = 2; ctx.stroke()
            }
        }

        // Hand 1 — start
        Rectangle {
            id: fovHand1
            readonly property real handLen: fovCircle.r + 6
            width: 2; height: handLen - 10
            color: (root.editTarget === "dial" && root.dialSel === 1)
                   ? (root.dialLevel === "select" ? (root.dialBlinkOn ? Theme.danger : Theme.accent) : Theme.danger)
                   : Theme.accent
            x: fovCircle.cx - 1; y: fovCircle.cy - handLen
            transform: Rotation { origin.x: 1; origin.y: fovHand1.handLen; angle: root.hand1Angle }
        }
        // Hand 2 — end
        Rectangle {
            id: fovHand2
            readonly property real handLen: fovCircle.r + 6
            width: 2; height: handLen - 10
            color: (root.editTarget === "dial" && root.dialSel === 2)
                   ? (root.dialLevel === "select" ? (root.dialBlinkOn ? Theme.danger : Theme.accent) : Theme.danger)
                   : Theme.accent
            x: fovCircle.cx - 1; y: fovCircle.cy - handLen
            transform: Rotation { origin.x: 1; origin.y: fovHand2.handLen; angle: root.hand2Angle }
        }
        // Red hand — progress within the arc
        Rectangle {
            id: fovHandRed
            readonly property real handLen: fovCircle.r + 6
            width: 2; height: handLen - 10
            color: Theme.danger
            visible: root.execState !== "idle"
            x: fovCircle.cx - 1; y: fovCircle.cy - handLen
            transform: Rotation {
                origin.x: 1; origin.y: fovHandRed.handLen
                angle: root.hand1Angle + root.progressFrac * (root.hand2Angle - root.hand1Angle)
            }
        }
        // Centre pivot
        Rectangle { width: 6; height: 6; radius: 3; color: Theme.accent
            x: fovCircle.cx - 3; y: fovCircle.cy - 3 }

        // Draggable tip — hand 1
        Item {
            readonly property real tipX: fovCircle.cx + (fovCircle.r + 6) * Math.sin(root.hand1Angle * Math.PI / 180)
            readonly property real tipY: fovCircle.cy - (fovCircle.r + 6) * Math.cos(root.hand1Angle * Math.PI / 180)
            x: tipX - 15; y: tipY - 15; width: 30; height: 30
            Rectangle { width: 8; height: 8; radius: 4; color: Theme.accent; anchors.centerIn: parent }
            MouseArea {
                anchors.fill: parent
                onPositionChanged: {
                    if (!pressed) return
                    var p = mapToItem(fovCircle, mouse.x, mouse.y)
                    var ang = Math.atan2(p.x - fovCircle.cx, -(p.y - fovCircle.cy)) * 180 / Math.PI
                    root.hand1Angle = Math.max(root.axisMinDeg, Math.min(root.hand2Angle - 10, ang))
                }
            }
        }
        // Draggable tip — hand 2
        Item {
            readonly property real tipX: fovCircle.cx + (fovCircle.r + 6) * Math.sin(root.hand2Angle * Math.PI / 180)
            readonly property real tipY: fovCircle.cy - (fovCircle.r + 6) * Math.cos(root.hand2Angle * Math.PI / 180)
            x: tipX - 15; y: tipY - 15; width: 30; height: 30
            Rectangle { width: 8; height: 8; radius: 4; color: Theme.accent; anchors.centerIn: parent }
            MouseArea {
                anchors.fill: parent
                onPositionChanged: {
                    if (!pressed) return
                    var p = mapToItem(fovCircle, mouse.x, mouse.y)
                    var ang = Math.atan2(p.x - fovCircle.cx, -(p.y - fovCircle.cy)) * 180 / Math.PI
                    root.hand2Angle = Math.min(root.axisMaxDeg, Math.max(root.hand1Angle + 10, ang))
                }
            }
        }
    }

    // FOV readout — right of the dial
    Column {
        spacing: 2
        anchors.left: fovCircle.right; anchors.leftMargin: 8
        anchors.verticalCenter: fovCircle.verticalCenter
        Text {
            text: "fov"; color: Theme.colorTextDim
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
        }
        Text {
            text: Math.round(root.arcDeg) + "\xB0"; color: Theme.colorText
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontH2 }
        }
    }

    // ── Duration clock — big readout, mirrors the span ──────────────────────────
    Column {
        id: clockBox
        anchors { right: parent.right; rightMargin: Theme.marginX }
        y: 104
        spacing: 2
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
            text: "crawl " + root.velDegS.toFixed(root.velDegS < 1 ? 3 : 1) + " deg/s"
            color: Theme.colorTextFaint
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
        }
    }

    // ── Timeline ────────────────────────────────────────────────────────────────
    // Idle: a handle marks the span on a log scale (drag to set). Running: fills
    // 0→progress with % · elapsed/total · lines overlaid.
    Item {
        id: timeline
        x: Theme.marginX; y: 330
        width: Theme.contentW; height: 64

        readonly property real handleX: root.fracOfDur(root.durationSec) * width

        // Focus/geometry proxy for the encoder (matches the spline-box pattern).
        Item { id: timelineProxy; anchors.fill: parent }

        FocusIndicator {
            inset: true
            target: (timedFocus.current === timelineProxy && !timedFocus.editing) ? timelineProxy : null
        }

        Rectangle {
            id: track
            anchors.fill: parent
            color: Theme.panel; radius: 2
            border.width: root.editTarget === "span" ? 2 : 1
            border.color: root.editTarget === "span" ? Theme.accent : Theme.border

            // Idle: dim fill up to the span handle
            Rectangle {
                visible: root.execState === "idle"
                x: 1; y: 1; height: parent.height - 2
                width: Math.max(0, timeline.handleX - 1)
                color: Theme.accent; opacity: 0.14; radius: 2
            }
            // Idle: span handle
            Rectangle {
                visible: root.execState === "idle"
                width: 3; height: parent.height - 8; radius: 1
                color: Theme.accent
                x: Math.max(1, Math.min(parent.width - 4, timeline.handleX - 1)); y: 4
            }
            // Running: progress fill
            Rectangle {
                visible: root.execState !== "idle"
                x: 1; y: 1; height: parent.height - 2
                width: Math.max(0, root.progressFrac * (parent.width - 2))
                color: Theme.accentDim; radius: 2
            }
            // Running: leading edge
            Rectangle {
                visible: root.execState !== "idle"
                width: 2; height: parent.height - 2; y: 1
                color: Theme.accent
                x: Math.max(1, Math.min(parent.width - 3, root.progressFrac * (parent.width - 2)))
            }

            // Overlay text — % complete (centre) + lines (right)
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
                text: root.fmtLines(Math.round(root.progressFrac * root.plannedLines)) + " / "
                      + root.fmtLines(root.plannedLines) + " lines"
                color: Theme.colorTextDim
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
            }

            // Drag anywhere on the track to set the span (log scale).
            MouseArea {
                anchors.fill: parent
                enabled: root.execState === "idle"
                function setFromX(mx) {
                    root.durationSec = root.durOfFrac(mx / track.width)
                }
                onPressed:         function(m) { setFromX(m.x) }
                onPositionChanged: function(m) { if (pressed) setFromX(m.x) }
            }
        }

        // Scale ends (idle) — clarify the log axis
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
                  ? "drag / turn to set span   ·   ≈ " + root.fmtLines(root.plannedLines) + " lines"
                  : "scanning — " + Math.round(root.arcDeg) + "\xB0 field"
            color: Theme.colorTextFaint
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
        }
    }

    // ── Bottom bar — [settings] left · modes · [home] [execute] right ───────────
    Hairline { x: 0; y: Theme.bottomBarY; width: 960 }

    TerminalButton {
        id: settingsBtn
        controller: timedFocus
        x: Theme.marginX
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: Theme.bottomBtnW; height: Theme.bottomBtnH
        label: "[settings]"; active: false
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenHome.qml"))
    }

    TerminalButton {
        id: modesBtn
        controller: timedFocus
        x: Theme.marginX + 130 + 18
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label: "[modes]"; active: false
        onClicked: {
            root.abortRun()
            root.StackView.view.replace(root.StackView.view.currentItem,
                                        Qt.resolvedUrl("ScreenModes.qml"),
                                        { fromPage: "ScreenTimed.qml" })
        }
    }
    FaultChip {
        id: faultChip
        controller: timedFocus
        anchors { left: modesBtn.right; leftMargin: 24; bottom: parent.bottom; bottomMargin: 27 }
    }

    // Red pointer line: execute → right screen edge (points at pendant BTN1).
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
                if (root.arcDeg < 1 || root.durationSec < 1) return
                root.startRun()
            } else if (root.execState === "running") {
                if (Beckhoff.connected) Beckhoff.pause()
                else simTimer.stop()
                root.execState = "paused"
                root.blinkVisible = true
            } else {
                if (Beckhoff.connected) Beckhoff.resume()
                else simTimer.start()
                root.execState = "running"
                root.blinkVisible = true
            }
        }
    }

    TerminalButton {
        id: homeBtn
        controller: timedFocus
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

    Component.onCompleted: timedFocus.editing = false
}
