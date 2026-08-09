// ScreenStack.qml — capture ▸ stack. The same sweep, N times, for signal.
//
// Noise is random and the subject is not, so averaging N passes lifts the
// signal-to-noise ratio by sqrt(N) — one stop per quadrupling. This is the
// answer to the line scanner's real problem: clean shadows without lifting gain
// and lifting the noise with it.
//
// Needs xylod's `passes` field. Before that the pass count was hardcoded 1 (BW)
// or 4 (colour), so "eight passes of the same thing" was not expressible. The
// filter is pinned to Clear for every pass, so the wheel does not walk R/G/B/C
// between them.
//
// The arc comes from capture ▸ scan's saved FOV, as ramp and pendulum do.
//
// IMPORTANT: this captures the passes. It does not combine them — that is a
// capture-PC job, and the passes land separately for the Suite to pair up. The
// SNR figure below is what averaging them WILL buy, not what has happened.
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
        category: "stack"
        property alias passes: root.passes
        property alias speed:  root.speed
        property alias dither: root.dither
    }

    // The arc is capture ▸ scan's, not a second copy of it.
    Settings {
        id: scanCfg
        category: "scan"
        property real hand1Angle: -45
        property real hand2Angle:  45
    }

    // ── Stack definition ────────────────────────────────────────────────────────
    readonly property int passMin:  2
    readonly property int passMax: 32
    property int passes: 4

    readonly property real speedMin:   1.0
    readonly property real speedMax: 300.0
    property real speed: 60.0

    // Derived from the arc by the optical calibration — see Calib.qml. Asking
    // for a free line count is what stretched every scan and stopped frames
    // filling inside their pass.
    readonly property int lines: Calib.linesForArc(root.arcDeg)

    readonly property real arcDeg: Math.abs(scanCfg.hand2Angle - scanCfg.hand1Angle)
    readonly property real sweepSec: root.arcDeg / Math.max(0.001, root.speed)
    // Rough: each pass also repositions to the arc start and settles. 0.5 s a
    // pass is about right at the default return velocity — labelled approximate
    // rather than pretending to precision.
    readonly property real totalSec: root.passes * (root.sweepSec + 0.5)

    // Averaging N frames lifts SNR by sqrt(N); in stops that is log2(sqrt(N)).
    readonly property real snrStops: 0.5 * Math.log(root.passes) / Math.log(2)

    // ── Dither (super-res) ──────────────────────────────────────────────────────
    // Same machinery, one field different. With dither off every pass traces the
    // identical arc and averaging buys signal. With it on, each pass is nudged a
    // FRACTION OF ONE LINE further along, so the passes sample between each
    // other's lines and can be interleaved into more resolution than one sweep
    // holds. The nudge is a line pitch divided by the pass count — anything
    // coarser just samples the same lines again.
    property bool dither: false
    readonly property real linePitchDeg: root.lines > 0 ? root.arcDeg / root.lines : 0
    readonly property real offsetDeg: root.dither
                                    ? root.linePitchDeg / Math.max(1, root.passes) : 0.0

    // ── Run state ───────────────────────────────────────────────────────────────
    property string execState:   "idle"
    property bool   blinkVisible: true
    property real   passFrac:     0.0     // progress within the current pass
    property bool   homed:        false

    readonly property real overallFrac: {
        if (root.passes <= 0) return 0
        var done = Math.max(0, Beckhoff.passIndex)
        return Math.min(1, (done + root.passFrac) / root.passes)
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────
    function fmtLines(n) { return n.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ".") }
    function fmtDuration(sec) {
        sec = Math.max(0, Math.round(sec))
        function p2(n) { return (n < 10 ? "0" : "") + n }
        return p2(Math.floor(sec / 3600)) + ":"
             + p2(Math.floor((sec % 3600) / 60)) + ":" + p2(sec % 60)
    }

    // ── Touch-free focus ────────────────────────────────────────────────────────
    property var    focusController: stackFocus
    property string editTarget: "none"     // none | passes | speed | lines

    function focusBack() { root.StackView.view.pop() }

    FocusController {
        id: stackFocus
        index: 0
        // Reading order — left to right, then down a line:
        //   passes · speed · lines · [settings] · [modes] · chip · [abort] · [home]
        targets: [passProxy, speedProxy, ditherBtn, settingsBtn, modesBtn]
                 .concat(faultChip.focusTargets)
                 .concat(root.execState !== "idle" ? [abortBtn] : [])
                 .concat([homeBtn])
        onActivated: function(item) {
            if (item === passProxy)        root.enterEditing("passes")
            else if (item === speedProxy)  root.enterEditing("speed")
            else if (item.clicked)         item.clicked()
        }
        onAdjust: function(delta) {
            if (root.editTarget === "passes")
                root.passes = Math.max(root.passMin, Math.min(root.passMax, root.passes + delta))
            else if (root.editTarget === "speed")
                root.speed = Math.max(root.speedMin, Math.min(root.speedMax, root.speed + delta * 2))
        }
        onConfirmed: root.exitEditing()
        onCanceled:  root.exitEditing()
    }

    function enterEditing(what) { stackFocus.editing = true;  root.editTarget = what }
    function exitEditing()      { stackFocus.editing = false; root.editTarget = "none" }

    function focusContext() { if (stackFocus.editing) root.exitEditing() }
    function btn1Execute()  { playBtn.clicked() }

    // ── Run control ─────────────────────────────────────────────────────────────
    function flatProfile() {
        var p = []
        for (var i = 0; i < 32; i++) p.push(1.0)
        return p
    }
    function startRun() {
        // Without a session the scan lands as a bare TIF: commitSession()
        // is what writes the sidecar the Review Suite pairs against, so a
        // mode that skips this produces files the Suite cannot see.
        Recorder.startSession()
        Recorder.setScanContext(scanCfg.hand1Angle, scanCfg.hand2Angle,
                                root.speed, root.speed, root.flatProfile())
        Recorder.startPass(0)
        root.passFrac     = 0
        root.execState    = "running"
        root.blinkVisible = true
        root.homed        = false
        if (Beckhoff.connected) {
            // Constant speed: pin min = max so the daemon's velocity floor cannot
            // reshape a pass that is meant to be identical to its siblings.
            // offsetDeg is 0 unless dither is on, in which case each pass steps
            // a fraction of a line further along.
            // Filter 3 (Clear) pinned so the wheel stays put across passes.
            Beckhoff.executeStack(root.passes, 3, root.offsetDeg,
                                  scanCfg.hand1Angle, scanCfg.hand2Angle,
                                  root.speed, root.speed,
                                  root.lines, root.flatProfile())
        } else {
            simTimer.start()
        }
    }
    function finishRun() {
        Recorder.endPass(0)
        Recorder.commitSession()   // writes the Suite's sidecar
        simTimer.stop()
        root.passFrac     = 1
        root.execState    = "idle"
        root.blinkVisible = true
        finishClear.start()
    }
    function abortRun() {
        Recorder.endPass(0)
        Recorder.commitSession()   // writes the Suite's sidecar
        simTimer.stop()
        root.execState    = "idle"
        root.blinkVisible = true
        root.passFrac     = 0
    }

    Timer {
        id: finishClear
        interval: 900; repeat: false
        onTriggered: root.passFrac = 0
    }
    Timer {
        id: simTimer
        interval: 250; repeat: true; running: false
        onTriggered: {
            if (Beckhoff.connected) { simTimer.stop(); return }
            root.passFrac = Math.min(1, root.passFrac + 0.25 / Math.max(1, root.totalSec))
            if (root.passFrac >= 1) root.finishRun()
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
                root.passFrac = Beckhoff.progress
        }
        function onSequenceDone(passes) { if (root.execState !== "idle") root.finishRun() }
        function onFaulted(text)        { root.abortRun() }
        function onConnectedChanged()   { if (!Beckhoff.connected && root.execState !== "idle") root.abortRun() }
    }

    // ── Header ────────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: Theme.titleY
        text:  "capture.stack"
        color: Theme.colorText
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }
    Text {
        x: Theme.marginX; y: 48
        text:  "the same sweep N times — average for signal, or dither for detail"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
    }

    // ── Passes ──────────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: 96
        text: "passes"; color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: Theme.marginX; y: 116; width: 440; height: 58

        Item { id: passProxy; anchors.fill: parent }

        // Must be declared alongside its target: FocusIndicator reads target.x/y
        // raw, so it only lines up when the two share a parent.
        FocusIndicator {
            inset: true
            target: (stackFocus.current === passProxy && !stackFocus.editing) ? passProxy : null
        }

        Rectangle {
            anchors.fill: parent
            color: Theme.panel; radius: 2
            border.width: root.editTarget === "passes" ? 2 : 1
            border.color: root.editTarget === "passes" ? Theme.accent : Theme.border

            Rectangle {
                x: 1; y: 1; height: parent.height - 2
                width: (parent.width - 2) * (root.passes - root.passMin)
                       / (root.passMax - root.passMin)
                color: Theme.accent; opacity: 0.16
            }
            Text {
                anchors.centerIn: parent
                text:  root.passes + " \xD7"
                color: Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
        }
    }

    // ── Speed ───────────────────────────────────────────────────────────────────
    Text {
        x: 502; y: 96
        text: "speed"; color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: 502; y: 116; width: 440; height: 58

        Item { id: speedProxy; anchors.fill: parent }

        FocusIndicator {
            inset: true
            target: (stackFocus.current === speedProxy && !stackFocus.editing) ? speedProxy : null
        }

        Rectangle {
            anchors.fill: parent
            color: Theme.panel; radius: 2
            border.width: root.editTarget === "speed" ? 2 : 1
            border.color: root.editTarget === "speed" ? Theme.accent : Theme.border

            Rectangle {
                x: 1; y: 1; height: parent.height - 2
                width: (parent.width - 2) * (root.speed - root.speedMin)
                       / (root.speedMax - root.speedMin)
                color: Theme.accent; opacity: 0.16
            }
            Text {
                anchors.centerIn: parent
                text:  root.speed.toFixed(0) + " \xB0/s"
                color: Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
        }
    }

    // ── Lines ───────────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: 190
        text: "lines (derived)"; color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: Theme.marginX; y: 210; width: Theme.contentW; height: 58

        Rectangle {
            anchors.fill: parent
            color: Theme.panel; radius: 2
            border.width: 1
            border.color: Theme.border

            Rectangle {
                x: 1; y: 1; height: parent.height - 2
                width: parent.width - 2
                color: Theme.accent; opacity: 0.16
            }
            Text {
                anchors.centerIn: parent
                text:  root.fmtLines(root.lines) + " lines  ·  from the arc"
                color: Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
        }
    }

    // ── Readouts ────────────────────────────────────────────────────────────────
    Hairline { x: Theme.marginX; y: 288; width: Theme.contentW }

    Text {
        x: Theme.marginX; y: 302
        text:  "arc " + root.arcDeg.toFixed(0) + "\xB0 from capture.scan"
               + "  ·  one sweep " + root.fmtDuration(root.sweepSec)
               + "  ·  all " + root.passes + " about " + root.fmtDuration(root.totalSec)
        color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Text {
        x: Theme.marginX; y: 324
        text:  "averaging " + root.passes + " passes buys \xD7"
               + Math.sqrt(root.passes).toFixed(2) + " SNR ("
               + root.snrStops.toFixed(1) + " stops) \xB7 combined off the Pi, not here"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

    // ── Progress, one segment per pass ──────────────────────────────────────────
    Rectangle {
        id: strip
        x: Theme.marginX; y: 366; width: Theme.contentW; height: 36
        color: Theme.panel; radius: 2
        border.width: 1; border.color: Theme.border

        Rectangle {
            x: 1; y: 1; height: parent.height - 2
            width: (parent.width - 2) * root.overallFrac
            color: Theme.accent; opacity: 0.22
            Behavior on width { NumberAnimation { duration: 180 } }
        }
        Repeater {
            model: root.passes - 1
            delegate: Rectangle {
                required property int index
                x: strip.width / root.passes * (index + 1)
                y: 1; width: 1; height: strip.height - 2
                color: Theme.border
            }
        }
    }

    Text {
        x: Theme.marginX; y: 410
        text:  root.execState === "idle"
               ? (root.dither
                  ? "each pass steps " + (root.offsetDeg * 1000).toFixed(1)
                    + " m° — a line pitch split " + root.passes + " ways"
                  : "every pass traces the same arc — nothing is offset")
               : "pass " + (Math.max(0, Beckhoff.passIndex) + 1) + " / " + root.passes
                 + "  ·  " + Math.round(root.overallFrac * 100) + "%"
                 + "  ·  " + Beckhoff.velocityDegS.toFixed(0) + " \xB0/s"
        color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
    }

    // ── Bottom bar ──────────────────────────────────────────────────────────────

    TerminalButton {
        id: settingsBtn
        controller: stackFocus
        x: Theme.marginX
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label: "[settings]"; active: false
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenHome.qml"))
    }

    TerminalButton {
        id: modesBtn
        controller: stackFocus
        x: Theme.marginX + 130 + 18
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label: "[modes]"; active: false
        onClicked: {
            root.abortRun()
            root.StackView.view.replace(root.StackView.view.currentItem,
                                        Qt.resolvedUrl("ScreenModes.qml"),
                                        { fromPage: "ScreenStack.qml" })
        }
    }
    FaultChip {
        id: faultChip
        controller: stackFocus
        anchors { left: modesBtn.right; leftMargin: 24; bottom: parent.bottom; bottomMargin: 27 }
    }

    Rectangle {
        anchors { left: playBtn.right; right: parent.right; verticalCenter: playBtn.verticalCenter }
        height: 1; color: Theme.danger
    }

    TerminalButton {
        id: abortBtn
        controller: stackFocus
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
        controller: stackFocus
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
                if (root.arcDeg <= 0) return      // no arc set in capture.scan yet
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
        stackFocus.editing = false
    }
}
