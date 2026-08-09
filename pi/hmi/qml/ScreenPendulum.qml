// ScreenPendulum.qml — capture ▸ pendulum. The axis swings back and forth
// while the camera scans, so the subject is written, unwritten and rewritten.
//
// This is the first mode that could not exist before: every other sweep is
// monotonic because the profile is indexed by POSITION along the arc, so the
// axis can only ever move one way. This one sends a SIGNED profile indexed by
// TIME (xylod's `timeProfile`), which is what lets it turn around mid-pass.
//
// Parameterised the way a pendulum actually behaves, not the way the daemon
// takes it:
//   amplitude — how far it swings either side of the start pose (deg)
//   period    — how long one full there-and-back takes (s)
//   swings    — how many full periods the pass lasts
//
// Velocity follows a sine. For a sine of peak V and period T the swing is
// A = V·T/2π, so the peak velocity the daemon needs is V = 2π·A/T — computed
// here rather than asked for, because amplitude and period are what you can
// actually picture.
//
// The pass is a whole number of periods by construction, so the sweep cannot
// drift. It begins (and parks) at pose − amplitude, the bottom of the swing, so
// that the swing is CENTRED on the pose you framed — see startRun().
//
// See docs/superpowers/specs/2026-08-09-capture-art-modes.md §5.

import QtCore
import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root
    width: 960; height: 540

    Settings {
        category: "pendulum"
        property alias amplitudeDeg: root.amplitudeDeg
        property alias periodSec:    root.periodSec
        property alias swings:       root.swings
        property alias lines:        root.lines
    }

    // ── Swing definition ────────────────────────────────────────────────────────
    readonly property real ampMin:  1.0
    readonly property real ampMax: 90.0
    property real amplitudeDeg: 20.0

    readonly property real periodMin:  0.5
    readonly property real periodMax: 60.0
    property real periodSec: 4.0

    readonly property int swingsMin:   1
    readonly property int swingsMax: 200
    property int swings: 6

    readonly property int linesMin: 256
    readonly property int linesMax: 65000
    property int lines: 22200

    // scan's ceiling — safe headroom under the motor's ~360 °/s
    readonly property real velCeiling: 300.0
    readonly property real peakVel: 2 * Math.PI * root.amplitudeDeg
                                    / Math.max(0.001, root.periodSec)
    readonly property bool tooFast: root.peakVel > root.velCeiling
    readonly property real durationSec: root.swings * root.periodSec

    // Mirrors acc_limit_degs2 in /etc/xylod.conf. A sine's peak acceleration is
    // 4*pi^2*A/T^2, and it rises with the SQUARE of the period — halving the
    // period quadruples it. Exceed the drive's limit and it cannot track the
    // commanded curve: it lags, and the swing comes out lopsided rather than
    // faulting. Nothing downstream catches this, so it is caught here.
    readonly property real accCeiling: 1500.0
    readonly property real peakAcc: 4 * Math.PI * Math.PI * root.amplitudeDeg
                                    / Math.max(0.001, root.periodSec * root.periodSec)
    readonly property bool tooHard: root.peakAcc > root.accCeiling

    // The pose the swing is centred on, captured at execute. The pass starts and
    // parks at centreDeg - amplitude, so without restoring this every run would
    // re-centre on the new lower pose and walk the axis down the arc.
    property real centreDeg: 0.0
    // Fixed preview window — see the drawing below for why it must not scale.
    readonly property real previewWindowSec: 20.0

    // ── Run state ───────────────────────────────────────────────────────────────
    property string execState:   "idle"
    property bool   blinkVisible: true
    property real   progressFrac: 0.0
    property bool   homed:        false

    // ── Helpers ─────────────────────────────────────────────────────────────────
    readonly property real _lnLines: Math.log(root.linesMax)
    function fracOfLines(n) {
        n = Math.max(root.linesMin, Math.min(root.linesMax, n))
        return Math.log(n) / root._lnLines
    }
    function linesOfFrac(f) {
        f = Math.max(root.fracOfLines(root.linesMin), Math.min(1, f))
        return Math.round(Math.exp(f * root._lnLines))
    }
    function fmtLines(n) { return n.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ".") }
    function fmtDuration(sec) {
        sec = Math.max(0, Math.round(sec))
        function p2(n) { return (n < 10 ? "0" : "") + n }
        return p2(Math.floor(sec / 3600)) + ":"
             + p2(Math.floor((sec % 3600) / 60)) + ":" + p2(sec % 60)
    }

    // ── Touch-free focus ────────────────────────────────────────────────────────
    property var    focusController: pendFocus
    property string editTarget: "none"     // none | amp | period | swings | lines

    function focusBack() { root.StackView.view.pop() }

    FocusController {
        id: pendFocus
        index: 0
        // Reading order — left to right, then down a line:
        //   amplitude · period · swings · lines · [settings] · [modes] · chip · [abort] · [home]
        targets: [ampProxy, periodProxy, swingsProxy, linesProxy, settingsBtn, modesBtn]
                 .concat(faultChip.focusTargets)
                 .concat(root.execState !== "idle" ? [abortBtn] : [])
                 .concat([homeBtn])
        onActivated: function(item) {
            if (item === ampProxy)         root.enterEditing("amp")
            else if (item === periodProxy) root.enterEditing("period")
            else if (item === swingsProxy) root.enterEditing("swings")
            else if (item === linesProxy)  root.enterEditing("lines")
            else if (item.clicked)         item.clicked()
        }
        onAdjust: function(delta) {
            if (root.editTarget === "amp")
                root.amplitudeDeg = Math.max(root.ampMin,
                                    Math.min(root.ampMax, root.amplitudeDeg + delta))
            else if (root.editTarget === "period")
                root.periodSec = Math.max(root.periodMin,
                                 Math.min(root.periodMax,
                                          Math.round((root.periodSec + delta * 0.5) * 2) / 2))
            else if (root.editTarget === "swings")
                root.swings = Math.max(root.swingsMin,
                              Math.min(root.swingsMax, root.swings + delta))
            else if (root.editTarget === "lines")
                root.lines = root.linesOfFrac(root.fracOfLines(root.lines) + delta * 0.015)
        }
        onConfirmed: root.exitEditing()
        onCanceled:  root.exitEditing()
    }

    function enterEditing(what) { pendFocus.editing = true;  root.editTarget = what }
    function exitEditing()      { pendFocus.editing = false; root.editTarget = "none" }

    function focusContext() { if (pendFocus.editing) root.exitEditing() }
    function btn1Execute()  { playBtn.clicked() }

    // ── Run control ─────────────────────────────────────────────────────────────
    // A signed sine over the whole pass. Sample density is tied to the number of
    // swings so a long run does not alias the waveform into something jagged —
    // ~32 samples per period, capped so the JSON stays sane.
    function buildSineProfile() {
        // (n-1) MUST divide exactly by the cycle count. Otherwise the last
        // sample lands mid-cycle, the profile's mean is not zero, and xylod
        // integrates that straight into positional drift — the axis would not
        // come back to where it began. The old `min(512, swings*32+1)` broke
        // exactly this whenever the cap bit, i.e. from 16 swings up.
        var spc = Math.max(8, Math.min(32, Math.floor(3200 / Math.max(1, root.swings))))
        var n = root.swings * spc + 1
        var prof = []
        for (var i = 0; i < n; i++) {
            var t = i / (n - 1)                       // 0..1 across the pass
            prof.push(Math.sin(2 * Math.PI * root.swings * t))
        }
        return prof
    }
    function startRun() {
        root.progressFrac = 0
        root.execState    = "running"
        root.blinkVisible = true
        root.homed        = false
        root.centreDeg    = Beckhoff.positionDeg
        if (Beckhoff.connected) {
            // Start HALF A SWING BELOW the framed pose, so the swing is centred
            // on it. Integrating v = V·sin(ωt) from rest gives x = A(1 − cos ωt),
            // which runs 0 → +2A — all to one side. Beginning at pose − A turns
            // that into pose − A → pose + A, which is what "±amplitude about the
            // pose you framed" actually means. xylod repositions to arcStartDeg
            // before the pass, and parks back there at the end, so the axis
            // finishes at the bottom of the swing rather than at the centre.
            Beckhoff.executeReversing(Motor.colorMode,
                                      root.centreDeg - root.amplitudeDeg,
                                      root.peakVel, root.durationSec,
                                      root.lines, root.buildSineProfile())
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
    }

    Timer {
        id: finishClear
        interval: 900; repeat: false
        onTriggered: root.progressFrac = 0
    }
    Timer {
        id: simTimer
        interval: 250; repeat: true; running: false
        onTriggered: {
            if (Beckhoff.connected) { simTimer.stop(); return }
            root.progressFrac = Math.min(1, root.progressFrac
                                            + 0.25 / Math.max(1, root.durationSec))
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
            if (root.execState === "running" && Beckhoff.connected)
                root.progressFrac = Beckhoff.progress
        }
        function onSequenceDone(passes) {
            if (root.execState === "idle") return
            root.finishRun()
            // xylod parks at arcStartDeg, which is the BOTTOM of the swing. Left
            // there, the next run would centre on that lower pose and the axis
            // would walk down the arc a full amplitude every time. Put it back
            // on the pose the swing was centred on.
            if (Beckhoff.connected) Beckhoff.moveTo(root.centreDeg, 60.0)
        }
        function onFaulted(text)        { root.abortRun() }
        function onConnectedChanged()   { if (!Beckhoff.connected && root.execState !== "idle") root.abortRun() }
    }

    // ── Header ────────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: Theme.titleY
        text:  "capture.pendulum"
        color: Theme.colorText
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }
    Text {
        x: Theme.marginX; y: 48
        text:  "the axis swings while the camera scans — written, then rewritten"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
    }

    // ── Amplitude ───────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: 96
        text: "amplitude"; color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: Theme.marginX; y: 116; width: 440; height: 58

        Item { id: ampProxy; anchors.fill: parent }

        // Must be declared alongside its target: FocusIndicator reads target.x/y
        // raw, so it only lines up when the two share a parent.
        FocusIndicator {
            inset: true
            target: (pendFocus.current === ampProxy && !pendFocus.editing) ? ampProxy : null
        }

        Rectangle {
            anchors.fill: parent
            color: Theme.panel; radius: 2
            border.width: root.editTarget === "amp" ? 2 : 1
            border.color: root.editTarget === "amp" ? Theme.accent : Theme.border

            Rectangle {
                x: 1; y: 1; height: parent.height - 2
                width: (parent.width - 2) * (root.amplitudeDeg - root.ampMin)
                       / (root.ampMax - root.ampMin)
                color: Theme.accent; opacity: 0.16
            }
            Text {
                anchors.centerIn: parent
                text:  "\xB1" + root.amplitudeDeg.toFixed(0) + "\xB0"
                color: Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
        }
    }

    // ── Period ──────────────────────────────────────────────────────────────────
    Text {
        x: 502; y: 96
        text: "period"; color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: 502; y: 116; width: 440; height: 58

        Item { id: periodProxy; anchors.fill: parent }

        FocusIndicator {
            inset: true
            target: (pendFocus.current === periodProxy && !pendFocus.editing) ? periodProxy : null
        }

        Rectangle {
            anchors.fill: parent
            color: Theme.panel; radius: 2
            border.width: root.editTarget === "period" ? 2 : 1
            border.color: root.editTarget === "period" ? Theme.accent : Theme.border

            Rectangle {
                x: 1; y: 1; height: parent.height - 2
                width: (parent.width - 2) * (root.periodSec - root.periodMin)
                       / (root.periodMax - root.periodMin)
                color: Theme.accent; opacity: 0.16
            }
            Text {
                anchors.centerIn: parent
                text:  root.periodSec.toFixed(1) + " s"
                color: Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
        }
    }

    // ── Swings ──────────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: 190
        text: "swings"; color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: Theme.marginX; y: 210; width: 440; height: 58

        Item { id: swingsProxy; anchors.fill: parent }

        FocusIndicator {
            inset: true
            target: (pendFocus.current === swingsProxy && !pendFocus.editing) ? swingsProxy : null
        }

        Rectangle {
            anchors.fill: parent
            color: Theme.panel; radius: 2
            border.width: root.editTarget === "swings" ? 2 : 1
            border.color: root.editTarget === "swings" ? Theme.accent : Theme.border

            Rectangle {
                x: 1; y: 1; height: parent.height - 2
                width: (parent.width - 2) * (root.swings - root.swingsMin)
                       / (root.swingsMax - root.swingsMin)
                color: Theme.accent; opacity: 0.16
            }
            Text {
                anchors.centerIn: parent
                text:  root.swings + " \xD7"
                color: Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
        }
    }

    // ── Lines ───────────────────────────────────────────────────────────────────
    Text {
        x: 502; y: 190
        text: "lines"; color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: 502; y: 210; width: 440; height: 58

        Item { id: linesProxy; anchors.fill: parent }

        FocusIndicator {
            inset: true
            target: (pendFocus.current === linesProxy && !pendFocus.editing) ? linesProxy : null
        }

        Rectangle {
            anchors.fill: parent
            color: Theme.panel; radius: 2
            border.width: root.editTarget === "lines" ? 2 : 1
            border.color: root.editTarget === "lines" ? Theme.accent : Theme.border

            Rectangle {
                x: 1; y: 1; height: parent.height - 2
                width: (parent.width - 2) * root.fracOfLines(root.lines)
                color: Theme.accent; opacity: 0.16
            }
            Text {
                anchors.centerIn: parent
                text:  root.fmtLines(root.lines)
                color: Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
        }
    }

    // ── The swing, drawn ────────────────────────────────────────────────────────
    // Position over time, not velocity: this is the shape the axis traces.
    // Height IS the amplitude and wavelength IS the period, both against a FIXED
    // 20 s window — which is the point. Scaling the window to the run would make
    // every setting look identical; against a fixed window a shorter period
    // visibly steepens, and steeper is faster.
    Hairline { x: Theme.marginX; y: 288; width: Theme.contentW }

    Rectangle {
        x: Theme.marginX; y: 296; width: Theme.contentW; height: 64
        color: Theme.panel; radius: 2
        border.width: 1; border.color: Theme.border

        Canvas {
            id: wave
            anchors.fill: parent
            anchors.margins: 1

            // Canvas does not track bindings — repaint when the shape changes.
            property real amp:    root.amplitudeDeg
            property real period: root.periodSec
            property real dur:    root.durationSec
            property bool hot:    root.tooFast || root.tooHard
            onAmpChanged:    requestPaint()
            onPeriodChanged: requestPaint()
            onDurChanged:    requestPaint()
            onHotChanged:    requestPaint()

            onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var w = width, h = height, mid = h / 2
                var winS = root.previewWindowSec
                var pad  = 6
                var ampPx = (mid - pad) * Math.min(1, root.amplitudeDeg / root.ampMax)

                // centre line — the pose you framed
                ctx.strokeStyle = Theme.border
                ctx.lineWidth = 1
                ctx.beginPath(); ctx.moveTo(0, mid); ctx.lineTo(w, mid); ctx.stroke()

                // x(t) = pose − A·cos(ωt): starts at the bottom, swings through
                // the centre to the top, and back.
                var endX = w * Math.min(1, root.durationSec / winS)
                ctx.strokeStyle = (root.tooFast || root.tooHard) ? Theme.danger : Theme.accent
                ctx.lineWidth = 2
                ctx.beginPath()
                for (var px = 0; px <= endX; px++) {
                    var t = px / w * winS
                    var y = mid - ampPx * (-Math.cos(2 * Math.PI * t / Math.max(0.001, root.periodSec)))
                    if (px === 0) ctx.moveTo(px, y); else ctx.lineTo(px, y)
                }
                ctx.stroke()

                // where the pass ends, when it ends inside the window
                if (endX < w - 1) {
                    ctx.strokeStyle = Theme.colorTextFaint
                    ctx.lineWidth = 1
                    ctx.beginPath(); ctx.moveTo(endX, 0); ctx.lineTo(endX, h); ctx.stroke()
                }
            }
        }

        Text {
            anchors { right: parent.right; rightMargin: 8; top: parent.top; topMargin: 4 }
            text:  root.durationSec > root.previewWindowSec ? "first 20 s" : "20 s window"
            color: Theme.colorTextFaint
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
        }
    }

    // ── Progress ────────────────────────────────────────────────────────────────
    Rectangle {
        x: Theme.marginX; y: 368; width: Theme.contentW; height: 28
        color: Theme.panel; radius: 2
        border.width: 1; border.color: Theme.border

        Rectangle {
            x: 1; y: 1; height: parent.height - 2
            width: (parent.width - 2) * root.progressFrac
            color: Theme.accent; opacity: 0.22
            Behavior on width { NumberAnimation { duration: 180 } }
        }
    }

    Text {
        x: Theme.marginX; y: 404
        text:  root.execState === "idle"
               ? "peak " + root.peakVel.toFixed(0) + " \xB0/s"
                 + "  ·  \xB1" + root.amplitudeDeg.toFixed(0) + "\xB0 about the pose"
                 + "  ·  takes " + root.fmtDuration(root.durationSec)
               : "swinging  ·  " + Math.round(root.progressFrac * 100) + "%"
                 + "  ·  " + Beckhoff.velocityDegS.toFixed(0) + " \xB0/s"
                 + "  ·  " + Beckhoff.positionDeg.toFixed(1) + "\xB0"
        color: root.tooFast ? Theme.danger : Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
    }

    Text {
        x: Theme.marginX; y: 430
        visible: root.tooFast
        text:  "too fast for the axis — widen the period or narrow the amplitude "
               + "(ceiling " + root.velCeiling.toFixed(0) + " \xB0/s)"
        color: Theme.danger
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

    // ── Bottom bar ──────────────────────────────────────────────────────────────

    TerminalButton {
        id: settingsBtn
        controller: pendFocus
        x: Theme.marginX
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label: "[settings]"; active: false
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenHome.qml"))
    }

    TerminalButton {
        id: modesBtn
        controller: pendFocus
        x: Theme.marginX + 130 + 18
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label: "[modes]"; active: false
        onClicked: {
            root.abortRun()
            root.StackView.view.replace(root.StackView.view.currentItem,
                                        Qt.resolvedUrl("ScreenModes.qml"),
                                        { fromPage: "ScreenPendulum.qml" })
        }
    }
    FaultChip {
        id: faultChip
        controller: pendFocus
        anchors { left: modesBtn.right; leftMargin: 24; bottom: parent.bottom; bottomMargin: 27 }
    }

    Rectangle {
        anchors { left: playBtn.right; right: parent.right; verticalCenter: playBtn.verticalCenter }
        height: 1; color: Theme.danger
    }

    TerminalButton {
        id: abortBtn
        controller: pendFocus
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
        controller: pendFocus
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
                if (root.tooFast || root.tooHard) return   // the axis cannot follow this swing
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

    Component.onCompleted: {
        pendFocus.editing = false
        root.lines = Math.max(root.linesMin, Math.min(root.linesMax, root.lines))
    }
}
