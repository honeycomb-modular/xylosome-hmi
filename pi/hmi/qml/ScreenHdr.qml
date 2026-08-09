// ScreenHdr.qml — capture ▸ hdr. The same sweep at several exposures.
//
// The line scanner's real problem is dynamic range: a clean B&W scan without
// clipped highlights. Bracketing captures the same subject light and dark and
// leaves the merge to a machine with more bits than the sensor has.
//
// WHY CHAINED, NOT MULTI-PASS. xylod can now run N passes in one job, but the
// exposure has to change BETWEEN them, and the daemon marches straight from
// pass_end into the next reposition. Changing a camera parameter into that
// window is a race, and losing it means a bracket shot at the wrong exposure —
// which looks like a successful HDR set and is not. So each bracket is its own
// single-pass execute, fired only once the camera has acknowledged the change.
// Same chaining chrono already proved. Slower by a reposition per bracket.
//
// WHICH LEVER. The camera exposes no exposure-time control. What is writable is
// gain, tdi.stages and line.rate (capture/PROTOCOL.md), and they are not
// equivalent:
//   gain   — continuous, ±10 dB, ~6 dB per stop. Amplifies noise with signal,
//            so it buys less REAL dynamic range than it appears to.
//   stages — 16/32/48/64/80/96. Closer to true exposure and quieter, but coarse,
//            and 48 is the recorded sharpness default so moving costs something.
// Both are offered because which one wins on this sensor is a measurement, not
// a fact anyone here knows yet. Shoot a set each way and look.
//
// The original setting is captured on execute and restored when the set ends,
// aborts, faults or the link drops — leaving the camera on the last bracket
// would silently poison every scan taken afterwards.
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
        category: "hdr"
        property alias brackets: root.brackets
        property alias stepDb:   root.stepDb
        property alias lever:    root.lever
        property alias speed:    root.speed
        property alias lines:    root.lines
        property alias hand1Angle: root.hand1Angle
        property alias hand2Angle: root.hand2Angle
    }

    // HDR owns its FOV rather than inheriting capture ▸ scan's. Brackets are
    // usually shot on a tighter field than a full sweep, and borrowing the scan
    // arc meant a 177 deg sweep per bracket without ever saying so.
    readonly property real axisMinDeg: -180
    readonly property real axisMaxDeg:  180
    property real hand1Angle: -30
    property real hand2Angle:  30

    // ── Bracket definition ──────────────────────────────────────────────────────
    readonly property int bracketMin: 3
    readonly property int bracketMax: 9
    property int brackets: 5

    readonly property real stepMin: 1.0
    readonly property real stepMax: 6.0
    property real stepDb: 3.0            // dB between brackets (gain lever)

    property string lever: "gain"        // gain | stages

    readonly property real speedMin:   1.0
    readonly property real speedMax: 300.0
    property real speed: 60.0

    readonly property int linesMin: 256
    readonly property int linesMax: 65000
    property int lines: 22200

    readonly property var stageLadder: [16, 32, 48, 64, 80, 96]
    readonly property real gainMin: -10.0
    readonly property real gainMax:  10.0

    readonly property real arcDeg: Math.abs(root.hand2Angle - root.hand1Angle)
    readonly property real sweepSec: root.arcDeg / Math.max(0.001, root.speed)
    readonly property real totalSec: root.brackets * (root.sweepSec + 1.0)

    // 6 dB is a stop. For stages, each ladder step is its own ratio, so the span
    // is stated in stops between the extremes rather than per step.
    readonly property real spanStops: {
        var v = root.bracketValues()
        if (v.length < 2) return 0
        if (root.lever === "gain") return (v[v.length - 1] - v[0]) / 6.0
        return Math.log(v[v.length - 1] / Math.max(1, v[0])) / Math.log(2)
    }

    // ── Run state ───────────────────────────────────────────────────────────────
    property string execState:   "idle"
    property bool   blinkVisible: true
    property int    shotIdx:     -1       // bracket currently being captured
    property real   passFrac:     0.0
    property bool   homed:        false
    // Captured at execute so the camera can be put back exactly as it was.
    property real   savedGain:    0.0
    property int    savedStages: 48

    readonly property real overallFrac: {
        if (root.brackets <= 0 || root.shotIdx < 0) return 0
        return Math.min(1, (root.shotIdx + root.passFrac) / root.brackets)
    }

    // ── Bracket values, centred on what the camera is set to now ────────────────
    function bracketValues() {
        var out = [], mid = Math.floor(root.brackets / 2), i
        if (root.lever === "gain") {
            var base = parseFloat(Camera.gain)
            if (isNaN(base)) base = 0
            for (i = 0; i < root.brackets; i++) {
                var g = base + (i - mid) * root.stepDb
                out.push(Math.max(root.gainMin, Math.min(root.gainMax, g)))
            }
        } else {
            var bi = root.stageLadder.indexOf(Camera.tdiStages)
            if (bi < 0) bi = 2                       // 48, the recorded default
            for (i = 0; i < root.brackets; i++) {
                var k = Math.max(0, Math.min(root.stageLadder.length - 1, bi + (i - mid)))
                out.push(root.stageLadder[k])
            }
        }
        return out
    }
    // Clamping at the ends can repeat a value — those brackets are duplicates,
    // not extra range, so say so rather than pretending the span is wider.
    readonly property bool clipped: {
        var v = root.bracketValues()
        for (var i = 1; i < v.length; i++) if (v[i] === v[i - 1]) return true
        return false
    }

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
    function fmtValue(v) {
        return root.lever === "gain" ? (v >= 0 ? "+" : "") + v.toFixed(1) + " dB"
                                     : v + " stg"
    }

    // ── Touch-free focus ────────────────────────────────────────────────────────
    property var    focusController: hdrFocus
    property string editTarget: "none"     // none | brackets | step | speed | lines | fov1 | fov2

    function focusBack() { root.StackView.view.pop() }

    FocusController {
        id: hdrFocus
        index: 0
        // Reading order — left to right, then down a line:
        //   brackets · step · speed · lines · [lever] · [settings] · [modes] · chip · [abort] · [home]
        targets: [brProxy, stepProxy, speedProxy, linesProxy,
                  fov1Proxy, fov2Proxy, leverBtn, settingsBtn, modesBtn]
                 .concat(faultChip.focusTargets)
                 .concat(root.execState !== "idle" ? [abortBtn] : [])
                 .concat([homeBtn])
        onActivated: function(item) {
            if (item === brProxy)          root.enterEditing("brackets")
            else if (item === stepProxy)   root.enterEditing("step")
            else if (item === speedProxy)  root.enterEditing("speed")
            else if (item === linesProxy)  root.enterEditing("lines")
            else if (item === fov1Proxy)   root.enterEditing("fov1")
            else if (item === fov2Proxy)   root.enterEditing("fov2")
            else if (item.clicked)         item.clicked()
        }
        onAdjust: function(delta) {
            if (root.editTarget === "brackets")
                root.brackets = Math.max(root.bracketMin,
                                Math.min(root.bracketMax, root.brackets + delta))
            else if (root.editTarget === "step")
                root.stepDb = Math.max(root.stepMin,
                              Math.min(root.stepMax,
                                       Math.round((root.stepDb + delta * 0.5) * 2) / 2))
            else if (root.editTarget === "speed")
                root.speed = Math.max(root.speedMin,
                             Math.min(root.speedMax, root.speed + delta * 2))
            else if (root.editTarget === "lines")
                root.lines = root.linesOfFrac(root.fracOfLines(root.lines) + delta * 0.015)
            else if (root.editTarget === "fov1")
                root.hand1Angle = Math.max(root.axisMinDeg,
                                  Math.min(root.axisMaxDeg, root.hand1Angle + delta))
            else if (root.editTarget === "fov2")
                root.hand2Angle = Math.max(root.axisMinDeg,
                                  Math.min(root.axisMaxDeg, root.hand2Angle + delta))
        }
        onConfirmed: root.exitEditing()
        onCanceled:  root.exitEditing()
    }

    function enterEditing(what) { hdrFocus.editing = true;  root.editTarget = what }
    function exitEditing()      { hdrFocus.editing = false; root.editTarget = "none" }

    function focusContext() { if (hdrFocus.editing) root.exitEditing() }
    function btn1Execute()  { playBtn.clicked() }

    // ── Run control ─────────────────────────────────────────────────────────────
    function flatProfile() {
        var p = []
        for (var i = 0; i < 32; i++) p.push(1.0)
        return p
    }
    function applyExposure(v) {
        if (!Camera.connected) return
        if (root.lever === "gain") Camera.setParam("gain", v)
        else                       Camera.setParam("tdi.stages", v)
    }
    function restoreExposure() {
        if (!Camera.connected) return
        if (root.lever === "gain") Camera.setParam("gain", root.savedGain)
        else                       Camera.setParam("tdi.stages", root.savedStages)
    }
    function fireBracket(i) {
        root.shotIdx  = i
        root.passFrac = 0
        root.applyExposure(root.bracketValues()[i])
        camSettle.restart()          // let the camera take the change first
    }
    function startRun() {
        var g = parseFloat(Camera.gain)
        root.savedGain   = isNaN(g) ? 0 : g
        root.savedStages = Camera.tdiStages > 0 ? Camera.tdiStages : 48
        root.execState    = "running"
        root.blinkVisible = true
        root.homed        = false
        root.fireBracket(0)
    }
    function finishRun() {
        camSettle.stop(); simTimer.stop()
        root.restoreExposure()
        root.passFrac  = 1
        root.execState = "idle"
        root.blinkVisible = true
        finishClear.start()
    }
    function abortRun() {
        // Only if a bracket was open — nextBracket() commits the completed ones.
        if (root.shotIdx >= 0) { Recorder.endPass(0); Recorder.commitSession() }
        camSettle.stop(); simTimer.stop()
        root.restoreExposure()       // never leave the camera on a bracket
        root.execState = "idle"
        root.blinkVisible = true
        root.shotIdx   = -1
        root.passFrac  = 0
    }

    // The camera change goes Pi -> agent -> serial. 400 ms is comfortably longer
    // than that round trip; firing sooner risks a bracket at the previous value.
    Timer {
        id: camSettle
        interval: 400; repeat: false
        onTriggered: {
            if (root.execState !== "running") return
            // One session per BRACKET: each is its own execute and its own TIF.
            Recorder.startSession()
            Recorder.setScanContext(root.hand1Angle, root.hand2Angle,
                                    root.speed, root.speed, root.flatProfile())
            Recorder.startPass(0)
            if (Beckhoff.connected) {
                Beckhoff.executeScan(1,                       // BW: one pass each
                                     root.hand1Angle, root.hand2Angle,
                                     root.speed, root.speed,
                                     root.lines, root.flatProfile())
            } else {
                simTimer.start()
            }
        }
    }
    Timer {
        id: finishClear
        interval: 900; repeat: false
        onTriggered: { root.shotIdx = -1; root.passFrac = 0 }
    }
    Timer {
        id: simTimer
        interval: 250; repeat: true; running: false
        onTriggered: {
            if (Beckhoff.connected) { simTimer.stop(); return }
            root.passFrac += 0.25 / Math.max(1, root.sweepSec)
            if (root.passFrac >= 1) { simTimer.stop(); root.nextBracket() }
        }
    }
    Timer {
        interval: 500; repeat: true; running: root.execState === "paused"
        onTriggered: root.blinkVisible = !root.blinkVisible
    }

    function nextBracket() {
        if (root.execState !== "running") return
        Recorder.endPass(0)
        Recorder.commitSession()   // sidecar for the bracket just captured
        if (root.shotIdx + 1 < root.brackets) root.fireBracket(root.shotIdx + 1)
        else                                  root.finishRun()
    }

    Connections {
        target: Beckhoff
        function onProgressChanged() {
            if (root.execState === "running" && Beckhoff.connected)
                root.passFrac = Beckhoff.progress
        }
        function onSequenceDone(passes) { root.nextBracket() }
        function onFaulted(text)        { root.abortRun() }
        function onConnectedChanged()   { if (!Beckhoff.connected && root.execState !== "idle") root.abortRun() }
    }

    // ── Header ────────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: Theme.titleY
        text:  "capture.hdr"
        color: Theme.colorText
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }
    Text {
        x: Theme.marginX; y: 48
        text:  "the same sweep at several exposures — merged off the Pi"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
    }

    // ── Brackets ────────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: 84
        text: "brackets"; color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: Theme.marginX; y: 100; width: 440; height: 46

        Item { id: brProxy; anchors.fill: parent }

        // Must be declared alongside its target: FocusIndicator reads target.x/y
        // raw, so it only lines up when the two share a parent.
        FocusIndicator {
            inset: true
            target: (hdrFocus.current === brProxy && !hdrFocus.editing) ? brProxy : null
        }

        Rectangle {
            anchors.fill: parent
            color: Theme.panel; radius: 2
            border.width: root.editTarget === "brackets" ? 2 : 1
            border.color: root.editTarget === "brackets" ? Theme.accent : Theme.border
            Rectangle {
                x: 1; y: 1; height: parent.height - 2
                width: (parent.width - 2) * (root.brackets - root.bracketMin)
                       / (root.bracketMax - root.bracketMin)
                color: Theme.accent; opacity: 0.16
            }
            Text {
                anchors.centerIn: parent
                text:  root.brackets + " \xD7"
                color: Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
        }
    }

    // ── Step ────────────────────────────────────────────────────────────────────
    Text {
        x: 502; y: 84
        text: root.lever === "gain" ? "step" : "step (fixed by the ladder)"
        color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: 502; y: 100; width: 440; height: 46
        opacity: root.lever === "gain" ? 1.0 : 0.45

        Item { id: stepProxy; anchors.fill: parent }

        FocusIndicator {
            inset: true
            target: (hdrFocus.current === stepProxy && !hdrFocus.editing) ? stepProxy : null
        }

        Rectangle {
            anchors.fill: parent
            color: Theme.panel; radius: 2
            border.width: root.editTarget === "step" ? 2 : 1
            border.color: root.editTarget === "step" ? Theme.accent : Theme.border
            Rectangle {
                x: 1; y: 1; height: parent.height - 2
                width: (parent.width - 2) * (root.stepDb - root.stepMin)
                       / (root.stepMax - root.stepMin)
                color: Theme.accent; opacity: 0.16
            }
            Text {
                anchors.centerIn: parent
                text:  root.lever === "gain"
                       ? root.stepDb.toFixed(1) + " dB  ("
                         + (root.stepDb / 6).toFixed(2) + " stop)"
                       : "one ladder step"
                color: Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
        }
    }

    // ── Speed / lines ───────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: 154
        text: "speed"; color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: Theme.marginX; y: 170; width: 440; height: 46

        Item { id: speedProxy; anchors.fill: parent }

        FocusIndicator {
            inset: true
            target: (hdrFocus.current === speedProxy && !hdrFocus.editing) ? speedProxy : null
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

    Text {
        x: 502; y: 154
        text: "lines"; color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: 502; y: 170; width: 440; height: 46

        Item { id: linesProxy; anchors.fill: parent }

        FocusIndicator {
            inset: true
            target: (hdrFocus.current === linesProxy && !hdrFocus.editing) ? linesProxy : null
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

    // ── FOV — HDR's own, not capture.scan's ─────────────────────────────────────
    Text {
        x: Theme.marginX; y: 224
        text: "field start"; color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: Theme.marginX; y: 240; width: 440; height: 46

        Item { id: fov1Proxy; anchors.fill: parent }

        FocusIndicator {
            inset: true
            target: (hdrFocus.current === fov1Proxy && !hdrFocus.editing) ? fov1Proxy : null
        }

        Rectangle {
            anchors.fill: parent
            color: Theme.panel; radius: 2
            border.width: root.editTarget === "fov1" ? 2 : 1
            border.color: root.editTarget === "fov1" ? Theme.accent : Theme.border
            Rectangle {
                x: 1; y: 1; height: parent.height - 2
                width: (parent.width - 2) * (root.hand1Angle - root.axisMinDeg)
                       / (root.axisMaxDeg - root.axisMinDeg)
                color: Theme.accent; opacity: 0.16
            }
            Text {
                anchors.centerIn: parent
                text:  root.hand1Angle.toFixed(0) + "°"
                color: Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
        }
    }

    Text {
        x: 502; y: 224
        text: "field end  ·  " + root.arcDeg.toFixed(0) + "° sweep"
        color: root.arcDeg < 0.5 ? Theme.danger : Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: 502; y: 240; width: 440; height: 46

        Item { id: fov2Proxy; anchors.fill: parent }

        FocusIndicator {
            inset: true
            target: (hdrFocus.current === fov2Proxy && !hdrFocus.editing) ? fov2Proxy : null
        }

        Rectangle {
            anchors.fill: parent
            color: Theme.panel; radius: 2
            border.width: root.editTarget === "fov2" ? 2 : 1
            border.color: root.editTarget === "fov2" ? Theme.accent : Theme.border
            Rectangle {
                x: 1; y: 1; height: parent.height - 2
                width: (parent.width - 2) * (root.hand2Angle - root.axisMinDeg)
                       / (root.axisMaxDeg - root.axisMinDeg)
                color: Theme.accent; opacity: 0.16
            }
            Text {
                anchors.centerIn: parent
                text:  root.hand2Angle.toFixed(0) + "°"
                color: Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
        }
    }

    // ── Lever + the ladder it produces ──────────────────────────────────────────
    Hairline { x: Theme.marginX; y: 294; width: Theme.contentW }

    TerminalButton {
        id: leverBtn
        controller: hdrFocus
        x: Theme.marginX; y: 300
        width: 232; height: 36
        label:  root.lever === "gain" ? "[bracket: gain]" : "[bracket: stages]"
        active: root.lever === "stages"
        fontSize: Theme.fontMonoS
        onClicked: root.lever = (root.lever === "gain" ? "stages" : "gain")
    }

    Text {
        x: Theme.marginX + 250; y: 302
        text:  root.lever === "gain"
               ? "gain is continuous but amplifies noise with signal"
               : "stages is closer to true exposure but coarse — 48 is the sharp default"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Text {
        x: Theme.marginX + 250; y: 318
        text:  Camera.connected
               ? ("now " + (root.lever === "gain" ? Camera.gain + " dB"
                                                  : Camera.tdiStages + " stages"))
               : "camera link down — brackets cannot be set"
        color: Camera.connected ? Theme.colorTextFaint : Theme.danger
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

    // The exposures this will actually shoot, in order.
    Row {
        x: Theme.marginX; y: 342
        spacing: 8
        Repeater {
            model: root.bracketValues()
            delegate: Rectangle {
                required property var  modelData
                required property int  index
                width: 104; height: 30; radius: 2
                color: (root.shotIdx === index) ? Theme.accentDim : Theme.panel
                border.width: 1
                border.color: (root.shotIdx === index) ? Theme.accent : Theme.border
                Text {
                    anchors.centerIn: parent
                    text:  root.fmtValue(modelData)
                    color: (root.shotIdx === index) ? Theme.colorText : Theme.colorTextDim
                    font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
                }
            }
        }
    }

    Text {
        x: Theme.marginX; y: 376
        text:  "span " + root.spanStops.toFixed(1) + " stops"
               + "  \xB7  " + root.arcDeg.toFixed(0) + "\xB0 field"
               + "  \xB7  about " + root.fmtDuration(root.totalSec)
        color: root.clipped ? Theme.danger : Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Text {
        x: Theme.marginX; y: 394
        visible: root.clipped
        text:  root.lever === "gain"
               ? "brackets repeat at the \xB110 dB rail — fewer brackets or a smaller step"
               : "brackets repeat at the end of the stage ladder — use fewer"
        color: Theme.danger
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

    // ── Progress, one segment per bracket ───────────────────────────────────────
    Rectangle {
        id: strip
        x: Theme.marginX; y: 410; width: Theme.contentW; height: 20
        color: Theme.panel; radius: 2
        border.width: 1; border.color: Theme.border

        Rectangle {
            x: 1; y: 1; height: parent.height - 2
            width: (parent.width - 2) * root.overallFrac
            color: Theme.accent; opacity: 0.22
            Behavior on width { NumberAnimation { duration: 180 } }
        }
        Repeater {
            model: root.brackets - 1
            delegate: Rectangle {
                required property int index
                x: strip.width / root.brackets * (index + 1)
                y: 1; width: 1; height: strip.height - 2
                color: Theme.border
            }
        }
    }

    Text {
        x: Theme.marginX; y: 438
        text:  root.execState === "idle"
               ? "the camera is put back to where it was when the set ends"
               : "bracket " + (root.shotIdx + 1) + " / " + root.brackets
                 + "  \xB7  " + root.fmtValue(root.bracketValues()[Math.max(0, root.shotIdx)])
                 + "  \xB7  " + Math.round(root.overallFrac * 100) + "%"
        color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

    // ── Bottom bar ──────────────────────────────────────────────────────────────

    TerminalButton {
        id: settingsBtn
        controller: hdrFocus
        x: Theme.marginX
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label: "[settings]"; active: false
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenHome.qml"))
    }

    TerminalButton {
        id: modesBtn
        controller: hdrFocus
        x: Theme.marginX + 130 + 18
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label: "[modes]"; active: false
        onClicked: {
            root.abortRun()
            root.StackView.view.replace(root.StackView.view.currentItem,
                                        Qt.resolvedUrl("ScreenModes.qml"),
                                        { fromPage: "ScreenHdr.qml" })
        }
    }
    FaultChip {
        id: faultChip
        controller: hdrFocus
        anchors { left: modesBtn.right; leftMargin: 24; bottom: parent.bottom; bottomMargin: 27 }
    }

    Rectangle {
        anchors { left: playBtn.right; right: parent.right; verticalCenter: playBtn.verticalCenter }
        height: 1; color: Theme.danger
    }

    TerminalButton {
        id: abortBtn
        controller: hdrFocus
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
        controller: hdrFocus
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
                if (root.arcDeg < 0.5) return       // field start and end are the same
                if (!Camera.connected) return       // every bracket would be identical
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
        hdrFocus.editing = false
        root.lines = Math.max(root.linesMin, Math.min(root.linesMax, root.lines))
    }
}
