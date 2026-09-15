// ScreenXerox.qml — hold-to-halt smear scan.
// One of the sibling capture pages (see ScreenModes.qml) — not a submenu.
//
// A constant crawl over a fixed FOV, like capture.timed — with the execute
// button re-bound while it runs: HELD = the axis brakes to a standstill,
// RELEASED = it accelerates back to the crawl. The trigger never changes rate,
// so while the axis stands still the same subject line is written over and
// over, at exactly the exposure of the rest of the image: a photocopier dragged
// to a stop. The FOV always completes; the pass simply lasts longer by the
// halted time, and the frame is sized for it (see haltBudgetS).
//
//   FOV dial   — two hands set the arc the camera sweeps (start · end)
//   Timeline   — the crawl time for the FOV (the image's exposure, in effect)
//   [brake]    — how hard each halt stops: hard · medium · soft
//
// Single continuous pass (bw). Needs xylod's `xerox` execute flag and the
// pendant's BTN1 release edge (PendantReader forwards BTN1 UP).

import QtCore
import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root
    width: 960; height: 540

    Settings {
        category: "xerox"
        property alias hand1Angle:  root.hand1Angle
        property alias hand2Angle:  root.hand2Angle
        property alias durationSec: root.durationSec
        property alias brakeIdx:    root.brakeIdx
    }

    // ── Scan definition ─────────────────────────────────────────────────────────
    property real hand1Angle: -45     // FOV start (deg)
    property real hand2Angle:  45     // FOV end   (deg)
    readonly property real axisMinDeg: -180
    readonly property real axisMaxDeg:  180
    readonly property real arcDeg: Math.abs(root.hand2Angle - root.hand1Angle)

    // Crawl time for the FOV: 1 s … 1 h on a log scale.
    readonly property int  durMinSec: 1
    readonly property int  durMaxSec: 3600
    property int  durationSec: 20

    readonly property real linesPerDeg: Calib.linesPerDegOr(150)   // tdi.sync override wins
    readonly property int  plannedLines: Math.round(root.arcDeg * root.linesPerDeg)
    readonly property real velDegS: root.durationSec > 0 ? root.arcDeg / root.durationSec : 0
    readonly property real lineHz:  root.durationSec > 0 ? root.plannedLines / root.durationSec : 0

    // How hard a halt stops. Milliseconds from crawl to standstill (and back);
    // 0 = as hard as xylod's accel limit allows. A softer ramp puts a gradient
    // tail on each stripe's edges.
    readonly property var brakes: [
        { name: "hard",   ms: 0   },
        { name: "medium", ms: 150 },
        { name: "soft",   ms: 600 }
    ]
    property int brakeIdx: 0

    // Room for halts. The grabber frame tops out at frameMaxLines (the capture
    // agent's LINE_MAX); everything above the FOV's own lines is stop time at
    // the flat rate. xylod sizes plannedLines to FOV + budget and refuses halts
    // once it is spent, so the FOV is never cut off.
    readonly property int  frameMaxLines: 65000
    readonly property real haltBudgetS: root.lineHz > 0
        ? Math.max(0, root.frameMaxLines - root.plannedLines) / root.lineHz : 0

    // ── Run state ───────────────────────────────────────────────────────────────
    property string execState:   "idle"   // idle | running | halted
    property bool   blinkVisible: true
    property real   progressFrac: 0.0
    property real   elapsedSec:   0.0     // wall clock since execute
    property real   haltedSec:    0.0     // of which halted
    property bool   homed:        false

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
        return (h > 0 ? p2(h) + ":" : "") + p2(m) + ":" + p2(s)
    }
    function fmtLines(n) {
        return n.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ".")
    }

    // ── Touch-free focus ────────────────────────────────────────────────────────
    property var    focusController: xeroxFocus
    property string editTarget: "none"    // none | dial | span
    property int    dialSel:    0
    property string dialLevel:  "none"    // none | select | move
    property bool   dialBlinkOn: true

    function focusBack() { root.StackView.view.pop() }

    FocusController {
        id: xeroxFocus
        targets: [fovCircle, timelineProxy, brakeBtn, settingsBtn, modesBtn]
                 .concat(faultChip.focusTargets)
                 .concat(root.execState !== "idle" ? [abortBtn] : [])
                 .concat([homeBtn])
        index: 1
        onActivated: function(item) {
            if (item === fovCircle)          root.enterDialEditing()
            else if (item === timelineProxy) root.enterSpanEditing()
            else if (item.clicked)           item.clicked()
        }
        onAdjust:    function(delta) { root.editAdjust(delta) }
        onConfirmed: root.editConfirm()
        onCanceled:  root.editCancel()
    }

    function focusContext() {
        if (!xeroxFocus.editing) return
        root.editConfirm()
    }

    // BTN1 down (main.qml Qt.Key_Delete). Idle: execute. Running: halt — the
    // axis brakes while the button is held. Never abort; that is [abort].
    function btn1Execute() {
        if (root.execState === "idle") {
            if (root.arcDeg < 1 || root.durationSec < 1) return
            root.startRun()
        } else if (root.execState === "running") {
            if (Beckhoff.connected) Beckhoff.pause()
            root.execState = "halted"
            root.blinkVisible = true
        }
    }
    // BTN1 up: let the axis go again.
    function btn1Release() {
        if (root.execState !== "halted") return
        if (Beckhoff.connected) Beckhoff.resume()
        root.execState = "running"
        root.blinkVisible = true
    }

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

    // ── Dial editing (as ScreenTimed) ───────────────────────────────────────────
    function enterDialEditing() {
        xeroxFocus.editing = true
        root.editTarget = "dial"
        root.dialLevel  = "select"
        root.dialSel    = 2
    }
    function exitDialEditing() {
        xeroxFocus.editing = false
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
        var step = 2
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

    // ── Span editing ────────────────────────────────────────────────────────────
    function enterSpanEditing() {
        xeroxFocus.editing = true
        root.editTarget = "span"
    }
    function exitSpanEditing() {
        xeroxFocus.editing = false
        root.editTarget = "none"
    }
    function spanAdjust(d) {
        root.durationSec = root.durOfFrac(root.fracOfDur(root.durationSec) + d * 0.02)
    }

    // ── Run control ─────────────────────────────────────────────────────────────
    function startRun() {
        root.progressFrac = 0
        root.elapsedSec   = 0
        root.haltedSec    = 0
        root.execState    = "running"
        root.blinkVisible = true
        root.homed        = false
        clock.start()
        if (Beckhoff.connected) {
            Beckhoff.executeXerox(1, root.hand1Angle, root.hand2Angle, root.velDegS,
                                  root.plannedLines, root.brakes[root.brakeIdx].ms,
                                  root.haltBudgetS)
        } else {
            simTimer.start()
        }
    }
    function finishRun() {
        simTimer.stop(); clock.stop()
        root.progressFrac = 1
        root.execState    = "idle"
        root.blinkVisible = true
        finishClear.start()
    }
    function abortRun() {
        simTimer.stop(); clock.stop()
        root.execState    = "idle"
        root.blinkVisible = true
        root.progressFrac = 0
        root.elapsedSec   = 0
        root.haltedSec    = 0
    }

    Timer {
        id: finishClear
        interval: 900; repeat: false
        onTriggered: { root.progressFrac = 0; root.elapsedSec = 0; root.haltedSec = 0 }
    }
    // Wall clock: the pass lasts the crawl PLUS the halts, so progress alone
    // cannot say how long it has been running.
    Timer {
        id: clock
        interval: 250; repeat: true; running: false
        onTriggered: {
            root.elapsedSec += 0.25
            if (root.execState === "halted") root.haltedSec += 0.25
        }
    }
    // Offline sim — fills only while not halted.
    Timer {
        id: simTimer
        interval: 250; repeat: true; running: false
        onTriggered: {
            if (Beckhoff.connected) { simTimer.stop(); return }
            if (root.execState === "running")
                root.progressFrac = Math.min(1, root.progressFrac + 0.25 / Math.max(1, root.durationSec))
            if (root.progressFrac >= 1) root.finishRun()
        }
    }
    Timer {
        interval: 500; repeat: true; running: root.execState === "halted"
        onTriggered: root.blinkVisible = !root.blinkVisible
    }
    Timer {
        interval: 400; repeat: true
        running: root.editTarget === "dial" && root.dialLevel === "select"
        onTriggered: root.dialBlinkOn = !root.dialBlinkOn
        onRunningChanged: if (!running) root.dialBlinkOn = true
    }

    Connections {
        target: Beckhoff
        function onProgressChanged() {
            if (root.execState !== "idle" && Beckhoff.connected) root.progressFrac = Beckhoff.progress
        }
        function onSequenceDone(passes) { if (root.execState !== "idle") root.finishRun() }
        function onFaulted(text)        { root.abortRun() }
        function onConnectedChanged()   { if (!Beckhoff.connected && root.execState !== "idle") root.abortRun() }
    }

    // ── Header ────────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: Theme.titleY
        text:  "capture.xerox"
        color: Theme.colorText
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }
    Text {
        x: Theme.marginX; y: 48
        text:  "constant crawl — hold execute to halt the axis, the lines keep coming"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
    }

    // ── FOV dial ────────────────────────────────────────────────────────────────
    FocusIndicator {
        inset: true
        target: (xeroxFocus.current === fovCircle && !xeroxFocus.editing) ? fovCircle : null
    }

    Item {
        id: fovCircle
        readonly property int cx: 100
        readonly property int cy: 100
        readonly property int r:  72
        x: 40; y: 110
        width: 200; height: 200

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
        // Red hand — progress within the arc (stands still while halted)
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
        Rectangle { width: 6; height: 6; radius: 3; color: Theme.accent
            x: fovCircle.cx - 3; y: fovCircle.cy - 3 }

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

    // ── Clock — crawl time idle; elapsed + halted while running ─────────────────
    Column {
        id: clockBox
        anchors { right: parent.right; rightMargin: Theme.marginX }
        y: 104
        spacing: 2
        Text {
            anchors.right: parent.right
            text: root.execState === "idle" ? "crawl" : "elapsed  ·  halted"
            color: Theme.colorTextDim
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
        }
        Text {
            anchors.right: parent.right
            text: root.execState === "idle"
                  ? root.fmtDuration(root.durationSec)
                  : root.fmtDuration(root.elapsedSec) + "  ·  " + root.fmtDuration(root.haltedSec)
            color: root.execState === "idle" ? Theme.colorText
                 : root.execState === "halted" ? Theme.danger : Theme.accent
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontH1 }
        }
        Text {
            anchors.right: parent.right
            text: root.velDegS.toFixed(root.velDegS < 1 ? 3 : 1) + " deg/s  ·  "
                  + Math.round(root.lineHz) + " Hz"
            color: Theme.colorTextFaint
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
        }
        Text {
            anchors.right: parent.right
            text: "room for " + root.fmtDuration(root.haltBudgetS) + " of halts"
            color: root.execState !== "idle" && root.haltedSec >= root.haltBudgetS
                   ? Theme.danger : Theme.colorTextFaint
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
        }
    }

    // ── Timeline ────────────────────────────────────────────────────────────────
    Item {
        id: timeline
        x: Theme.marginX; y: 330
        width: Theme.contentW; height: 64

        readonly property real handleX: root.fracOfDur(root.durationSec) * width

        Item { id: timelineProxy; anchors.fill: parent }

        FocusIndicator {
            inset: true
            target: (xeroxFocus.current === timelineProxy && !xeroxFocus.editing) ? timelineProxy : null
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
                color: root.execState === "halted" ? "#6B2020" : Theme.accentDim; radius: 2
            }
            Rectangle {
                visible: root.execState !== "idle"
                width: 2; height: parent.height - 2; y: 1
                color: root.execState === "halted" ? Theme.danger : Theme.accent
                x: Math.max(1, Math.min(parent.width - 3, root.progressFrac * (parent.width - 2)))
            }

            Text {
                anchors.centerIn: parent
                visible: root.execState !== "idle"
                text: root.execState === "halted" ? "HALTED" : Math.round(root.progressFrac * 100) + "%"
                color: root.execState === "halted" ? Theme.danger : Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontH2 }
            }
            Text {
                anchors { right: parent.right; rightMargin: 8; bottom: parent.bottom; bottomMargin: 6 }
                visible: root.execState !== "idle"
                text: root.fmtLines(Math.round(root.progressFrac * root.plannedLines)) + " / "
                      + root.fmtLines(root.plannedLines) + " fov lines  +  "
                      + root.fmtLines(Math.round(root.haltedSec * root.lineHz)) + " halted"
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
            text: "1 h"; color: Theme.colorTextFaint
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
        }
        Text {
            anchors { horizontalCenter: parent.horizontalCenter; top: parent.bottom; topMargin: 4 }
            text: root.execState === "idle"
                  ? "drag / turn to set the crawl   ·   ≈ " + root.fmtLines(root.plannedLines) + " lines"
                  : "hold [execute] to halt — " + Math.round(root.arcDeg) + "\xB0 field"
            color: Theme.colorTextFaint
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
        }
    }

    // ── Bottom bar — [settings] [modes] [brake] left · [abort] [home] [execute] right ──

    TerminalButton {
        id: settingsBtn
        controller: xeroxFocus
        x: Theme.marginX
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: Theme.bottomBtnW; height: Theme.bottomBtnH
        label: "[settings]"; active: false
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenHome.qml"))
    }

    TerminalButton {
        id: modesBtn
        controller: xeroxFocus
        x: Theme.marginX + 130 + 18
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label: "[modes]"; active: false
        onClicked: {
            root.abortRun()
            root.StackView.view.replace(root.StackView.view.currentItem,
                                        Qt.resolvedUrl("ScreenModes.qml"),
                                        { fromPage: "ScreenXerox.qml" })
        }
    }

    // Cycles hard → medium → soft. Read at execute; a change mid-run applies
    // to the next scan.
    TerminalButton {
        id: brakeBtn
        controller: xeroxFocus
        x: Theme.marginX + (130 + 18) * 2
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: 160; height: 45
        label: "[brake: " + root.brakes[root.brakeIdx].name + "]"
        active: false
        onClicked: root.brakeIdx = (root.brakeIdx + 1) % root.brakes.length
    }

    FaultChip {
        id: faultChip
        controller: xeroxFocus
        anchors { left: brakeBtn.right; leftMargin: 24; bottom: parent.bottom; bottomMargin: 27 }
    }

    Rectangle {
        anchors { left: playBtn.right; right: parent.right; verticalCenter: playBtn.verticalCenter }
        height: 1; color: Theme.danger
    }

    // BTN1-only. On screen it only starts a run; the hold/release lives on the
    // pendant button, where a touch cannot be held reliably.
    TerminalButton {
        id: playBtn
        controller: null
        anchors { right: parent.right; rightMargin: 18; bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label: root.execState === "idle"    ? "[execute]" :
               root.execState === "running" ? "[hold=halt]" : "[halted]"
        borderColor: Theme.danger
        fillColor: (root.execState === "running" ||
                    (root.execState === "halted" && root.blinkVisible)) ? "#6B2020" : Theme.panel
        onClicked: if (root.execState === "idle") root.btn1Execute()
    }

    TerminalButton {
        id: abortBtn
        controller: xeroxFocus
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
        controller: xeroxFocus
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

    Component.onCompleted: xeroxFocus.editing = false
}
