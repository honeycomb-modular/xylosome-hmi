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
// The pass is a whole number of periods by construction, so the axis ends where
// it started and the sweep cannot drift.
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
        var n = Math.max(64, Math.min(512, Math.round(root.swings * 32) + 1))
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
        if (Beckhoff.connected) {
            // Swings around wherever the axis already is, so the pose you framed
            // stays the centre of the swing.
            Beckhoff.executeReversing(Motor.colorMode, Beckhoff.positionDeg,
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
        function onSequenceDone(passes) { if (root.execState !== "idle") root.finishRun() }
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

    // ── Derived readouts ────────────────────────────────────────────────────────
    Hairline { x: Theme.marginX; y: 288; width: Theme.contentW }

    Text {
        x: Theme.marginX; y: 302
        text:  "peak " + root.peakVel.toFixed(0) + " \xB0/s"
               + "  ·  swing takes " + root.fmtDuration(root.durationSec)
               + "  ·  ends where it started"
        color: root.tooFast ? Theme.danger : Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Text {
        x: Theme.marginX; y: 324
        visible: root.tooFast
        text:  "too fast for the axis — widen the period or narrow the amplitude "
               + "(ceiling " + root.velCeiling.toFixed(0) + " \xB0/s)"
        color: Theme.danger
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

    // ── Progress ────────────────────────────────────────────────────────────────
    Rectangle {
        x: Theme.marginX; y: 366; width: Theme.contentW; height: 36
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
        x: Theme.marginX; y: 410
        text:  root.execState === "idle"
               ? "swings \xB1" + root.amplitudeDeg.toFixed(0) + "\xB0 about the current pose"
               : "swinging  ·  " + Math.round(root.progressFrac * 100) + "%"
                 + "  ·  " + Beckhoff.velocityDegS.toFixed(0) + " \xB0/s"
                 + "  ·  " + Beckhoff.positionDeg.toFixed(1) + "\xB0"
        color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
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
                if (root.tooFast) return          // the axis cannot follow this swing
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
