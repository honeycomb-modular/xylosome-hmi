// ScreenRamp.qml — capture ▸ ramp. A linear speed ramp, with the line rate
// either following the axis or deliberately not.
//
// The scan mode already draws an arbitrary velocity curve, so a ramp on its own
// would add nothing. What this mode adds is the LINE COUPLING:
//
//   curve — trigger rate tracks instantaneous velocity. Geometry is honest:
//           the subject looks the same whatever the axis is doing.
//   fixed — constant trigger rate regardless of speed. The subject STRETCHES
//           where the axis is slow and compresses where it is fast.
//
// Fixed coupling has been supported by xylod all along (`line.mode` in
// PROTOCOL.md) and BeckhoffLink has always read it from QSettings — but nothing
// ever wrote the key, so it was unreachable. This page is the first thing that
// sets it. No daemon change was needed.
//
// The arc comes from capture ▸ scan's saved FOV rather than a second dial here,
// the same way chrono inherits its frame from capture ▸ static.
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
        category: "ramp"
        property alias startSpeed: root.startSpeed
        property alias endSpeed:   root.endSpeed
        property alias lines:      root.lines
        property alias coupling:   root.coupling
    }

    // The arc is capture ▸ scan's, not a second copy of it.
    Settings {
        id: scanCfg
        category: "scan"
        property real hand1Angle: -45
        property real hand2Angle:  45
    }

    // ── Ramp definition ─────────────────────────────────────────────────────────
    // 300 °/s is scan's ceiling (safe headroom under the motor's ~360) and 1 °/s
    // its floor — a literal 0 never advances, since the daemon integrates
    // position from velocity.
    readonly property real speedMin: 1.0
    readonly property real speedMax: 300.0
    property real startSpeed:  8.0
    property real endSpeed:   120.0

    readonly property int linesMin: 256
    readonly property int linesMax: 65000
    property int lines: 22200

    property string coupling: "curve"          // curve | fixed

    readonly property real arcDeg: Math.abs(scanCfg.hand2Angle - scanCfg.hand1Angle)
    readonly property real peakVel: Math.max(root.startSpeed, root.endSpeed)
    readonly property real floorVel: Math.max(root.speedMin,
                                              Math.min(root.startSpeed, root.endSpeed))
    // Mean speed of a linear ramp is its midpoint, so the sweep takes arc ÷ mean.
    readonly property real sweepSec:
        root.arcDeg > 0 ? root.arcDeg / Math.max(0.001, (root.startSpeed + root.endSpeed) / 2) : 0

    // ── Run state ───────────────────────────────────────────────────────────────
    property string execState:   "idle"        // idle | running | paused
    property bool   blinkVisible: true
    property real   progressFrac: 0.0
    property bool   homed:        false

    // ── Log-scale helper for the line count (same grammar as static's frame) ────
    readonly property real _lnLines: Math.log(root.linesMax)
    function fracOfLines(n) {
        n = Math.max(root.linesMin, Math.min(root.linesMax, n))
        return Math.log(n) / root._lnLines
    }
    function linesOfFrac(f) {
        f = Math.max(root.fracOfLines(root.linesMin), Math.min(1, f))
        return Math.round(Math.exp(f * root._lnLines))
    }
    function fmtLines(n) {
        return n.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ".")
    }
    function fmtDuration(sec) {
        sec = Math.max(0, Math.round(sec))
        function p2(n) { return (n < 10 ? "0" : "") + n }
        return p2(Math.floor(sec / 3600)) + ":"
             + p2(Math.floor((sec % 3600) / 60)) + ":" + p2(sec % 60)
    }

    // ── Touch-free focus ────────────────────────────────────────────────────────
    property var    focusController: rampFocus
    property string editTarget: "none"         // none | start | end | lines

    function focusBack() { root.StackView.view.pop() }

    FocusController {
        id: rampFocus
        index: 0
        // Reading order — left to right, then down a line:
        //   start · end · lines · [line:] · [settings] · [modes] · chip · [abort] · [home]
        targets: [startProxy, endProxy, linesProxy, couplingBtn, settingsBtn, modesBtn]
                 .concat(faultChip.focusTargets)
                 .concat(root.execState !== "idle" ? [abortBtn] : [])
                 .concat([homeBtn])
        onActivated: function(item) {
            if (item === startProxy)      root.enterEditing("start")
            else if (item === endProxy)   root.enterEditing("end")
            else if (item === linesProxy) root.enterEditing("lines")
            else if (item.clicked)        item.clicked()
        }
        onAdjust: function(delta) {
            if (root.editTarget === "start")
                root.startSpeed = Math.max(root.speedMin,
                                  Math.min(root.speedMax, root.startSpeed + delta * 2))
            else if (root.editTarget === "end")
                root.endSpeed   = Math.max(root.speedMin,
                                  Math.min(root.speedMax, root.endSpeed + delta * 2))
            else if (root.editTarget === "lines")
                root.lines = root.linesOfFrac(root.fracOfLines(root.lines) + delta * 0.015)
        }
        onConfirmed: root.exitEditing()
        onCanceled:  root.exitEditing()
    }

    function enterEditing(what) { rampFocus.editing = true;  root.editTarget = what }
    function exitEditing()      { rampFocus.editing = false; root.editTarget = "none" }

    // ENC push while editing (main.qml routes here).
    function focusContext() { if (rampFocus.editing) root.exitEditing() }
    // BTN1 — dedicated execute.
    function btn1Execute() { playBtn.clicked() }

    // ── Run control ─────────────────────────────────────────────────────────────
    // The profile is normalised against the PEAK of the ramp, because xylod
    // scales profile 1.0 to maxVelDegS. A falling ramp therefore starts at 1.0
    // and descends — direction of travel is the arc's, not the profile's.
    function buildRampProfile() {
        var prof = []
        for (var i = 0; i < 64; i++) {
            var t = i / 63
            prof.push((root.startSpeed + (root.endSpeed - root.startSpeed) * t) / root.peakVel)
        }
        return prof
    }
    function startRun() {
        root.progressFrac = 0
        root.execState    = "running"
        root.blinkVisible = true
        root.homed        = false
        if (Beckhoff.connected) {
            // Must precede executeScan: the daemon reads the coupling out of
            // QSettings as it builds the command.
            Beckhoff.setLineMode(root.coupling)
            Beckhoff.executeScan(Motor.colorMode,
                                 scanCfg.hand1Angle, scanCfg.hand2Angle,
                                 root.peakVel, root.floorVel,
                                 root.lines, root.buildRampProfile())
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
                                            + 0.25 / Math.max(1, root.sweepSec))
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
        text:  "capture.ramp"
        color: Theme.colorText
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }
    Text {
        x: Theme.marginX; y: 48
        text:  "a linear speed ramp — and whether the lines follow it"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
    }

    // ── Start / end speed ───────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: 96
        text:  "start speed"
        color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: Theme.marginX; y: 116; width: 440; height: 58

        Item { id: startProxy; anchors.fill: parent }

        // Must be declared alongside its target: FocusIndicator reads target.x/y
        // raw, so it only lines up when the two share a parent.
        FocusIndicator {
            inset: true
            target: (rampFocus.current === startProxy && !rampFocus.editing) ? startProxy : null
        }

        Rectangle {
            anchors.fill: parent
            color: Theme.panel; radius: 2
            border.width: root.editTarget === "start" ? 2 : 1
            border.color: root.editTarget === "start" ? Theme.accent : Theme.border

            Rectangle {
                x: 1; y: 1; height: parent.height - 2
                width: (parent.width - 2) * (root.startSpeed - root.speedMin)
                       / (root.speedMax - root.speedMin)
                color: Theme.accent; opacity: 0.16
            }
            Text {
                anchors.centerIn: parent
                text:  root.startSpeed.toFixed(0) + " \xB0/s"
                color: Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
        }
    }

    Text {
        x: 502; y: 96
        text:  "end speed"
        color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: 502; y: 116; width: 440; height: 58

        Item { id: endProxy; anchors.fill: parent }

        FocusIndicator {
            inset: true
            target: (rampFocus.current === endProxy && !rampFocus.editing) ? endProxy : null
        }

        Rectangle {
            anchors.fill: parent
            color: Theme.panel; radius: 2
            border.width: root.editTarget === "end" ? 2 : 1
            border.color: root.editTarget === "end" ? Theme.accent : Theme.border

            Rectangle {
                x: 1; y: 1; height: parent.height - 2
                width: (parent.width - 2) * (root.endSpeed - root.speedMin)
                       / (root.speedMax - root.speedMin)
                color: Theme.accent; opacity: 0.16
            }
            Text {
                anchors.centerIn: parent
                text:  root.endSpeed.toFixed(0) + " \xB0/s"
                color: Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
        }
    }

    // ── Line count ──────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: 190
        text:  "lines"
        color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: Theme.marginX; y: 210; width: Theme.contentW; height: 58

        Item { id: linesProxy; anchors.fill: parent }

        FocusIndicator {
            inset: true
            target: (rampFocus.current === linesProxy && !rampFocus.editing) ? linesProxy : null
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
                text:  root.fmtLines(root.lines) + " lines"
                color: Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
        }
    }

    // ── Coupling + readouts ─────────────────────────────────────────────────────
    Hairline { x: Theme.marginX; y: 288; width: Theme.contentW }

    TerminalButton {
        id: couplingBtn
        controller: rampFocus
        x: Theme.marginX; y: 302
        width: 200; height: 40
        label:  root.coupling === "fixed" ? "[line: fixed]" : "[line: curve]"
        active: root.coupling === "fixed"
        onClicked: root.coupling = (root.coupling === "fixed" ? "curve" : "fixed")
    }

    Text {
        x: 240; y: 302
        text:  "arc " + root.arcDeg.toFixed(0) + "\xB0 from capture.scan"
               + "  ·  sweep " + root.fmtDuration(root.sweepSec)
        color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Text {
        x: 240; y: 324
        text:  root.coupling === "fixed"
               ? "fixed — lines ignore the ramp: the subject stretches where the axis is slow"
               : "curve — lines follow the ramp: geometry stays true"
        color: root.coupling === "fixed" ? Theme.accent : Theme.colorTextFaint
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
               ? (root.startSpeed <= root.endSpeed ? "accelerating " : "decelerating ")
                 + root.startSpeed.toFixed(0) + " \xB0/s → " + root.endSpeed.toFixed(0) + " \xB0/s"
               : "scanning  ·  " + Math.round(root.progressFrac * 100) + "%"
                 + "  ·  " + Beckhoff.velocityDegS.toFixed(0) + " \xB0/s"
        color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
    }

    // ── Bottom bar ──────────────────────────────────────────────────────────────

    TerminalButton {
        id: settingsBtn
        controller: rampFocus
        x: Theme.marginX
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label: "[settings]"; active: false
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenHome.qml"))
    }

    TerminalButton {
        id: modesBtn
        controller: rampFocus
        x: Theme.marginX + 130 + 18
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label: "[modes]"; active: false
        onClicked: {
            root.abortRun()
            root.StackView.view.replace(root.StackView.view.currentItem,
                                        Qt.resolvedUrl("ScreenModes.qml"),
                                        { fromPage: "ScreenRamp.qml" })
        }
    }
    FaultChip {
        id: faultChip
        controller: rampFocus
        anchors { left: modesBtn.right; leftMargin: 24; bottom: parent.bottom; bottomMargin: 27 }
    }

    Rectangle {
        anchors { left: playBtn.right; right: parent.right; verticalCenter: playBtn.verticalCenter }
        height: 1; color: Theme.danger
    }

    TerminalButton {
        id: abortBtn
        controller: rampFocus
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
        controller: rampFocus
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
                if (root.arcDeg <= 0) return          // no arc set in capture.scan yet
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
        rampFocus.editing = false
        root.lines = Math.max(root.linesMin, Math.min(root.linesMax, root.lines))
    }
}
