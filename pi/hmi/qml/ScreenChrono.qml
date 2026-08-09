// ScreenChrono.qml — capture ▸ chrono. Interval-timed repeated captures.
//
// A time-lapse of the scanner: take the SAME capture over and over, spaced by a
// fixed interval, and let the subject change between frames. Two inputs:
//   Interval — how long between the START of one frame and the next (1 s … 24 h)
//   Count    — how many frames to take (1 … 999)
//
// Each frame is a STATIC capture — the axis holds where it already is and the
// camera scans lines for a set span. That is deliberate: a time-lapse wants
// identical framing every frame, so there is no arc and no curve to define here.
// The per-frame shape (line count + span) is whatever capture ▸ static is set
// to, read from the same saved settings and shown below — this page repeats it
// rather than defining a second copy of it.
//
// No xylod change was needed: this is executeStatic on a timer.
// See docs/superpowers/specs/2026-08-09-capture-art-modes.md §5b.

import QtCore
import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root
    width: 960; height: 540

    // Mode switches destroy the page, so the schedule has to outlive it.
    Settings {
        category: "chrono"
        property alias intervalSec: root.intervalSec
        property alias frameCount:  root.frameCount
    }

    // The per-frame capture is capture ▸ static's, not a second copy. Same
    // category and the same defaults, so reading it here cannot drift from it.
    Settings {
        id: staticCfg
        category: "static"
        property int lines:       22200
        property int durationSec: 60
    }

    // ── Schedule ────────────────────────────────────────────────────────────────
    readonly property int intMinSec: 1
    readonly property int intMaxSec: 86400
    property int intervalSec: 300         // default 5 min

    readonly property int countMin: 1
    readonly property int countMax: 999
    property int frameCount: 12

    // A frame that outlasts its own interval would collide with the next one.
    // xylod would take the second executeStatic and restart mid-frame, so refuse
    // to start rather than silently dropping frames.
    readonly property bool intervalTooShort: root.intervalSec <= staticCfg.durationSec

    // Total wall time: the last frame still has to finish after its own start.
    readonly property int totalSec: (root.frameCount - 1) * root.intervalSec
                                    + staticCfg.durationSec
    readonly property int remainingSec: Math.max(0, root.totalSec - root.elapsedSec)

    // ── Run state ───────────────────────────────────────────────────────────────
    property string execState:    "idle"   // idle | running | paused
    property bool   blinkVisible:  true
    property int    framesDone:    0
    property bool   frameRunning:  false
    property real   elapsedSec:    0.0
    property bool   homed:         false

    readonly property real progressFrac:
        root.frameCount > 0 ? root.framesDone / root.frameCount : 0

    // ── Formatting ──────────────────────────────────────────────────────────────
    readonly property real _lnInt: Math.log(root.intMaxSec)
    function fracOfInt(sec) {
        sec = Math.max(root.intMinSec, Math.min(root.intMaxSec, sec))
        return Math.log(sec) / root._lnInt
    }
    function intOfFrac(f) {
        f = Math.max(0, Math.min(1, f))
        return Math.round(Math.exp(f * root._lnInt))
    }
    function p2(n) { return (n < 10 ? "0" : "") + n }
    function fmtDuration(sec) {
        sec = Math.max(0, Math.round(sec))
        return root.p2(Math.floor(sec / 3600)) + ":"
             + root.p2(Math.floor((sec % 3600) / 60)) + ":"
             + root.p2(sec % 60)
    }
    function fmtLines(n) {
        return n.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ".")
    }
    // NOTE: this reads the Pi's own clock, which COOP.md records as badly skewed.
    // The duration readouts beside it are skew-proof; this one is a convenience.
    function fmtFinishClock() {
        var d = new Date(root.nowMs + root.remainingSec * 1000)
        return root.p2(d.getHours()) + ":" + root.p2(d.getMinutes())
    }

    property double nowMs: 0
    Timer {
        interval: 1000; repeat: true; running: true
        onTriggered: {
            root.nowMs = Date.now()
            if (root.execState === "running") root.elapsedSec += 1
        }
    }
    // ── Touch-free focus ────────────────────────────────────────────────────────
    property var    focusController: chronoFocus
    property string editTarget: "none"     // none | interval | count

    function focusBack() { root.StackView.view.pop() }

    FocusController {
        id: chronoFocus
        index: 0
        // Reading order — left to right, then down a line:
        //   interval · count · [settings] · [modes] · fault chip · [abort] · [home]
        targets: [intervalProxy, countProxy, settingsBtn, modesBtn]
                 .concat(faultChip.focusTargets)
                 .concat(root.execState !== "idle" ? [abortBtn] : [])
                 .concat([homeBtn])
        onActivated: function(item) {
            if (item === intervalProxy)   root.enterEditing("interval")
            else if (item === countProxy) root.enterEditing("count")
            else if (item.clicked)        item.clicked()
        }
        onAdjust: function(delta) {
            if (root.editTarget === "interval")
                root.intervalSec = root.intOfFrac(root.fracOfInt(root.intervalSec) + delta * 0.02)
            else if (root.editTarget === "count")
                root.frameCount = Math.max(root.countMin,
                                           Math.min(root.countMax, root.frameCount + delta))
        }
        onConfirmed: root.exitEditing()
        onCanceled:  root.exitEditing()
    }

    function enterEditing(what) { chronoFocus.editing = true;  root.editTarget = what }
    function exitEditing()      { chronoFocus.editing = false; root.editTarget = "none" }

    // ENC push while editing (main.qml routes here).
    function focusContext() { if (chronoFocus.editing) root.exitEditing() }
    // BTN1 — dedicated execute.
    function btn1Execute() { playBtn.clicked() }

    // ── Run control ─────────────────────────────────────────────────────────────
    function fireFrame() {
        if (root.frameRunning) return          // previous frame overran its slot
        root.frameRunning = true
        if (Beckhoff.connected) {
            // Hold wherever the axis already is — identical framing every frame.
            Beckhoff.executeStatic(Motor.colorMode, Beckhoff.positionDeg,
                                   staticCfg.durationSec, staticCfg.lines)
        } else {
            simFrame.restart()
        }
    }
    function frameFinished() {
        if (!root.frameRunning) return
        root.frameRunning = false
        root.framesDone  += 1
        if (root.framesDone >= root.frameCount) root.finishRun()
    }
    function startRun() {
        root.framesDone   = 0
        root.frameRunning = false
        root.elapsedSec   = 0
        root.execState    = "running"
        root.blinkVisible = true
        root.homed        = false
        root.fireFrame()                       // frame 1 goes now, not one interval late
        intervalTimer.restart()
    }
    function finishRun() {
        intervalTimer.stop(); simFrame.stop()
        root.execState    = "idle"
        root.frameRunning = false
        root.blinkVisible = true
        finishClear.start()
    }
    function abortRun() {
        intervalTimer.stop(); simFrame.stop()
        root.execState    = "idle"
        root.frameRunning = false
        root.blinkVisible = true
        root.framesDone   = 0
        root.elapsedSec   = 0
    }

    Timer {
        id: intervalTimer
        interval: root.intervalSec * 1000
        repeat: true; running: false
        onTriggered: {
            if (root.execState !== "running") return
            if (root.framesDone < root.frameCount) root.fireFrame()
        }
    }
    Timer {
        id: finishClear      // hold the full strip briefly, then reset to idle view
        interval: 900; repeat: false
        onTriggered: { root.framesDone = 0; root.elapsedSec = 0 }
    }
    // Offline sim — a frame "completes" after its own span so the page is
    // exercisable with the rig down, same as the other capture modes.
    Timer {
        id: simFrame
        interval: Math.max(250, staticCfg.durationSec * 1000)
        repeat: false; running: false
        onTriggered: if (!Beckhoff.connected) root.frameFinished()
    }
    Timer {
        interval: 500; repeat: true; running: root.execState === "paused"
        onTriggered: root.blinkVisible = !root.blinkVisible
    }

    Connections {
        target: Beckhoff
        function onSequenceDone(passes) {
            if (root.execState !== "idle") root.frameFinished()
        }
        function onFaulted(text)      { root.abortRun() }
        function onConnectedChanged() { if (!Beckhoff.connected && root.execState !== "idle") root.abortRun() }
    }

    // ── Header ────────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: Theme.titleY
        text:  "capture.chrono"
        color: Theme.colorText
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }
    Text {
        x: Theme.marginX; y: 48
        text:  "interval-timed repeated captures — the same frame, over and over"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
    }

    // ── Interval (log slider, same grammar as static's timeline) ────────────────
    Text {
        x: Theme.marginX; y: 96
        text:  "interval"
        color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: Theme.marginX; y: 116; width: 440; height: 58

        Item { id: intervalProxy; anchors.fill: parent }

        // Must be declared alongside its target: FocusIndicator reads target.x/y
        // raw, so it only lines up when the two share a parent.
        FocusIndicator {
            inset: true
            target: (chronoFocus.current === intervalProxy && !chronoFocus.editing)
                    ? intervalProxy : null
        }

        Rectangle {
            anchors.fill: parent
            color: Theme.panel; radius: 2
            border.width: root.editTarget === "interval" ? 2 : 1
            border.color: root.editTarget === "interval" ? Theme.accent : Theme.border

            Rectangle {
                x: 1; y: 1; height: parent.height - 2
                width: (parent.width - 2) * root.fracOfInt(root.intervalSec)
                color: Theme.accent; opacity: 0.16
            }
            Text {
                anchors.centerIn: parent
                text:  root.fmtDuration(root.intervalSec)
                color: Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
        }

        // Drag anywhere on the track to set the interval (log scale) — same
        // grammar as static's timeline, so touch works without the encoder.
        MouseArea {
            anchors.fill: parent
            enabled: root.execState === "idle"
            function setFromX(mx) { root.intervalSec = root.intOfFrac(mx / width) }
            onPressed:         function(m) { setFromX(m.x) }
            onPositionChanged: function(m) { if (pressed) setFromX(m.x) }
        }
    }

    // ── Count ───────────────────────────────────────────────────────────────────
    Text {
        x: 502; y: 96
        text:  "frames"
        color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: 502; y: 116; width: 440; height: 58

        Item { id: countProxy; anchors.fill: parent }

        FocusIndicator {
            inset: true
            target: (chronoFocus.current === countProxy && !chronoFocus.editing)
                    ? countProxy : null
        }

        Rectangle {
            anchors.fill: parent
            color: Theme.panel; radius: 2
            border.width: root.editTarget === "count" ? 2 : 1
            border.color: root.editTarget === "count" ? Theme.accent : Theme.border

            Rectangle {
                x: 1; y: 1; height: parent.height - 2
                width: (parent.width - 2) * (root.frameCount - root.countMin)
                       / (root.countMax - root.countMin)
                color: Theme.accent; opacity: 0.16
            }
            Text {
                anchors.centerIn: parent
                text:  root.frameCount + " \xD7"
                color: Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
        }

        // Drag for a coarse count; the encoder still steps it one at a time.
        MouseArea {
            anchors.fill: parent
            enabled: root.execState === "idle"
            function setFromX(mx) {
                var f = Math.max(0, Math.min(1, mx / width))
                root.frameCount = Math.round(root.countMin
                                             + f * (root.countMax - root.countMin))
            }
            onPressed:         function(m) { setFromX(m.x) }
            onPositionChanged: function(m) { if (pressed) setFromX(m.x) }
        }
    }

    // ── What one frame is (inherited from capture ▸ static) ─────────────────────
    Hairline { x: Theme.marginX; y: 196; width: Theme.contentW }

    Text {
        x: Theme.marginX; y: 208
        text:  "each frame  ·  " + root.fmtLines(staticCfg.lines) + " lines over "
               + root.fmtDuration(staticCfg.durationSec) + "  ·  set in capture.static"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

    Text {
        x: Theme.marginX; y: 232
        visible: root.intervalTooShort
        text:  "interval is shorter than one frame — raise it above "
               + root.fmtDuration(staticCfg.durationSec)
        color: Theme.danger
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

    // ── Timeline strip ──────────────────────────────────────────────────────────
    Rectangle {
        id: strip
        x: Theme.marginX; y: 272; width: Theme.contentW; height: 44
        color: Theme.panel; radius: 2
        border.width: 1; border.color: Theme.border

        Rectangle {
            x: 1; y: 1; height: parent.height - 2
            width: (parent.width - 2) * root.progressFrac
            color: Theme.accent; opacity: 0.22
            Behavior on width { NumberAnimation { duration: 180 } }
        }

        // One tick per frame while they are still individually readable; past
        // that the fill alone carries the progress.
        Repeater {
            model: root.frameCount <= 60 ? root.frameCount - 1 : 0
            delegate: Rectangle {
                x: strip.width / root.frameCount * (index + 1)
                y: 1; width: 1; height: strip.height - 2
                color: Theme.border
            }
        }
    }

    Text {
        x: Theme.marginX; y: 328
        text:  root.execState === "idle"
               ? "total " + root.fmtDuration(root.totalSec)
                 + "  ·  ends ~" + root.fmtFinishClock()
               : "frame " + (root.framesDone + (root.frameRunning ? 1 : 0))
                 + " / " + root.frameCount
                 + "  ·  " + root.fmtDuration(root.remainingSec) + " left"
                 + "  ·  ends ~" + root.fmtFinishClock()
        color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
    }

    Text {
        x: Theme.marginX; y: 356
        text:  root.execState === "idle"
               ? "interval sets the spacing  ·  frames sets how many"
               : (root.frameRunning ? "scanning frame — axis held at "
                                      + Beckhoff.positionDeg.toFixed(1) + "\xB0"
                                    : "waiting for the next interval")
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

    // ── Bottom bar ──────────────────────────────────────────────────────────────

    TerminalButton {
        id: settingsBtn
        controller: chronoFocus
        x: Theme.marginX
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label: "[settings]"; active: false
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenHome.qml"))
    }

    TerminalButton {
        id: modesBtn
        controller: chronoFocus
        x: Theme.marginX + 130 + 18
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label: "[modes]"; active: false
        onClicked: {
            root.abortRun()
            root.StackView.view.replace(root.StackView.view.currentItem,
                                        Qt.resolvedUrl("ScreenModes.qml"),
                                        { fromPage: "ScreenChrono.qml" })
        }
    }
    FaultChip {
        id: faultChip
        controller: chronoFocus
        anchors { left: modesBtn.right; leftMargin: 24; bottom: parent.bottom; bottomMargin: 27 }
    }

    Rectangle {
        anchors { left: playBtn.right; right: parent.right; verticalCenter: playBtn.verticalCenter }
        height: 1; color: Theme.danger
    }

    TerminalButton {
        id: abortBtn
        controller: chronoFocus
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
        controller: chronoFocus
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
                if (root.intervalTooShort || root.frameCount < root.countMin) return
                root.startRun()
            } else if (root.execState === "running") {
                // Pause the schedule, and the frame in flight with it.
                intervalTimer.stop()
                if (Beckhoff.connected) Beckhoff.pause()
                else simFrame.stop()
                root.execState = "paused"; root.blinkVisible = true
            } else {
                if (Beckhoff.connected) Beckhoff.resume()
                else if (root.frameRunning) simFrame.restart()
                intervalTimer.restart()
                root.execState = "running"; root.blinkVisible = true
            }
        }
    }

    Component.onCompleted: {
        chronoFocus.editing = false
        root.nowMs = Date.now()      // seed the clock before the 1 s tick lands
    }
}
