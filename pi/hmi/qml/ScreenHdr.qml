// ScreenHdr.qml — capture ▸ hdr. The same sweep at several exposures.
//
// The line scanner's real problem is dynamic range: clean shadows without
// clipped highlights. Bracketing captures the subject light and dark and leaves
// the merge to something with more bits than the sensor has.
//
// EXPOSURE IS TIME HERE, NOT GAIN. The camera has no exposure-time control, and
// gain is the wrong lever anyway: it sits before the ADC so it does rescue
// clipped highlights, but it amplifies signal and noise together, so it adds no
// information in the shadows — a darker picture of the same noisy data.
//
// What actually collects more photons is integration time, which IS 1/lineHz.
// And xylod derives the rate from the wanted line count:
//     baseHz = lines * maxVel / arc
// so running a pass at half speed halves its rate too — same arc, same line
// count, pixel-identical geometry, twice as long collecting each line. One
// stop, honestly earned. That is xylod's passVelScale, and it means the whole
// bracket set is ONE job: no camera parameter changes, no race against a pass
// boundary, and one session in the Review Suite instead of N unrelated scans.
//
// Bracket 0 runs at the speed you set and is the DARKEST; each one after is
// slower and brighter. Scales above 1.0 would mean going faster than the speed
// you chose, so the ladder only ever descends.
//
// The floor is the camera: it will not sync below 3500 Hz (capture/PROTOCOL.md),
// so the slowest bracket's rate is checked against that rather than discovered
// as a dead scan.
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
        property alias stopsPer: root.stopsPer
        property alias speed:    root.speed
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

    // Stops between brackets. Each stop is a halving of speed.
    readonly property real stopMin: 0.5
    readonly property real stopMax: 2.0
    property real stopsPer: 1.0

    readonly property real speedMin:   1.0
    readonly property real speedMax: 300.0
    property real speed: 60.0

    // Derived, not dialled: the optics decide how many lines an arc holds.
    readonly property int lines: Calib.linesForArc(root.arcDeg)

    // The camera will not sync below this; the slowest bracket must clear it.
    readonly property real rateFloorHz: 3500.0
    readonly property real rateCeilHz: 37000.0

    readonly property real arcDeg: Math.abs(root.hand2Angle - root.hand1Angle)
    readonly property real sweepSec: root.arcDeg / Math.max(0.001, root.fastestVel)

    // Bracket 0 is the speed you set; each next one is `stopsPer` stops slower.
    // Descending from the fastest bracket, so index mid lands exactly on the
    // speed the operator set.
    function scales() {
        var out = []
        for (var i = 0; i < root.brackets; i++)
            out.push(Math.pow(2, -i * root.stopsPer))
        return out
    }
    readonly property real spanStops: (root.brackets - 1) * root.stopsPer
    // The ladder is CENTRED on the speed you set: that bracket is the exposure
    // you judged correct, with darker ones above and brighter below. Since
    // xylod only accepts scales <= 1 (a scale above 1 would mean outrunning the
    // speed the job was given), the job is handed the FASTEST bracket as its
    // maxVel and every scale descends from there. Set speed for a good
    // exposure, not for the darkest frame.
    readonly property real midIdx: (root.brackets - 1) / 2
    readonly property real fastestVel: root.speed * Math.pow(2, root.midIdx * root.stopsPer)
    readonly property bool tooFastVel: root.fastestVel > root.speedMax
    // arc cancels out of lines*speed/arc — see Calib.qml.
    readonly property real baseHz: Calib.rateForSpeed(root.fastestVel)
    readonly property real slowestHz: root.baseHz * Math.pow(2, -root.spanStops)
    readonly property bool rateTooLow:  root.slowestHz < root.rateFloorHz
    // How many stops of bracketing this speed actually affords.
    readonly property real headroomStops:
        root.baseHz > root.rateFloorHz
            ? Math.log(Math.min(root.baseHz, root.rateCeilHz) / root.rateFloorHz) / Math.log(2)
            : 0
    readonly property bool rateTooHigh: root.baseHz    > root.rateCeilHz
    // Each bracket takes longer than the last, so the set is not brackets*sweep.
    readonly property real totalSetSec: {
        var t = 0, sc = root.scales()
        for (var i = 0; i < sc.length; i++) t += root.sweepSec / sc[i] + 1.0
        return t
    }

    // ── Run state ───────────────────────────────────────────────────────────────
    property string execState:   "idle"
    property bool   blinkVisible: true
    property real   passFrac:     0.0
    property bool   homed:        false
    // Which bracket is in flight, straight from the daemon's pass index.
    readonly property int shotIdx: root.execState === "idle" ? -1
                                 : Math.max(0, Beckhoff.passIndex)

    readonly property real overallFrac: {
        if (root.brackets <= 0 || root.execState === "idle") return 0
        return Math.min(1, (Math.max(0, Beckhoff.passIndex) + root.passFrac) / root.brackets)
    }

    // Exposure multiple of each bracket relative to the first.
    function bracketValues() {
        var out = [], sc = root.scales()
        for (var i = 0; i < sc.length; i++) out.push(1 / sc[i])
        return out
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────
    function fmtLines(n) { return n.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ".") }
    function fmtDuration(sec) {
        sec = Math.max(0, Math.round(sec))
        function p2(n) { return (n < 10 ? "0" : "") + n }
        return p2(Math.floor(sec / 3600)) + ":"
             + p2(Math.floor((sec % 3600) / 60)) + ":" + p2(sec % 60)
    }
    function fmtValue(v) {
        return (v < 10 ? v.toFixed(1) : v.toFixed(0)) + "×"
    }
    function fmtHz(hz) {
        return hz >= 1000 ? (hz / 1000).toFixed(1) + "k" : hz.toFixed(0)
    }

    // ── Touch-free focus ────────────────────────────────────────────────────────
    property var    focusController: hdrFocus
    property string editTarget: "none"     // none | brackets | step | speed | lines | fov1 | fov2

    function focusBack() { root.StackView.view.pop() }

    FocusController {
        id: hdrFocus
        index: 0
        // Reading order — left to right, then down a line:
        //   brackets · stops · speed · lines · field · [settings] · [modes] · chip · [abort] · [home]
        targets: [brProxy, stepProxy, speedProxy,
                  fov1Proxy, fov2Proxy, settingsBtn, modesBtn]
                 .concat(faultChip.focusTargets)
                 .concat(root.execState !== "idle" ? [abortBtn] : [])
                 .concat([homeBtn])
        onActivated: function(item) {
            if (item === brProxy)          root.enterEditing("brackets")
            else if (item === stepProxy)   root.enterEditing("step")
            else if (item === speedProxy)  root.enterEditing("speed")
            else if (item === fov1Proxy)   root.enterEditing("fov1")
            else if (item === fov2Proxy)   root.enterEditing("fov2")
            else if (item.clicked)         item.clicked()
        }
        onAdjust: function(delta) {
            if (root.editTarget === "brackets")
                root.brackets = Math.max(root.bracketMin,
                                Math.min(root.bracketMax, root.brackets + delta))
            else if (root.editTarget === "step")
                root.stopsPer = Math.max(root.stopMin,
                                Math.min(root.stopMax,
                                         Math.round((root.stopsPer + delta * 0.5) * 2) / 2))
            else if (root.editTarget === "speed")
                root.speed = Math.max(root.speedMin,
                             Math.min(root.speedMax, root.speed + delta * 2))
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
    function startRun() {
        // Without a session the scan lands as a bare TIF: commitSession() is
        // what writes the sidecar the Suite pairs against.
        Recorder.startSession()
        Recorder.setScanContext(root.hand1Angle, root.hand2Angle,
                                root.speed, root.speed, root.flatProfile())
        Recorder.startPass(0)
        root.passFrac     = 0
        root.execState    = "running"
        root.blinkVisible = true
        root.homed        = false
        if (Beckhoff.connected) {
            // ONE job, N passes, one scale per bracket. Filter pinned to Clear
            // and no arc offset — the brackets differ only in exposure.
            Beckhoff.executeStack(root.brackets, 3, 0.0,
                                  root.hand1Angle, root.hand2Angle,
                                  root.fastestVel, root.fastestVel,
                                  root.lines, root.flatProfile(), root.scales())
        } else {
            simTimer.start()
        }
    }
    function finishRun() {
        simTimer.stop()
        Recorder.endPass(0)
        Recorder.commitSession()   // writes the Suite's sidecar
        root.passFrac  = 1
        root.execState = "idle"
        root.blinkVisible = true
        finishClear.start()
    }
    function abortRun() {
        simTimer.stop()
        // A part-finished set still deserves a sidecar: xylod closes the pass on
        // stop and the agent saves the lines it collected.
        Recorder.endPass(0)
        Recorder.commitSession()
        root.execState = "idle"
        root.blinkVisible = true
        root.passFrac  = 0
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
            root.passFrac += 0.25 / Math.max(1, root.totalSetSec)
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
        text: "stops between"
        color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: 502; y: 100; width: 440; height: 46

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
                width: (parent.width - 2) * (root.stopsPer - root.stopMin)
                       / (root.stopMax - root.stopMin)
                color: Theme.accent; opacity: 0.16
            }
            Text {
                anchors.centerIn: parent
                text:  root.stopsPer.toFixed(1) + " stop"
                       + (root.stopsPer === 1.0 ? "" : "s")
                color: Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
        }
    }

    // ── Speed / lines ───────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: 154
        text: "speed (centre bracket)  ·  fastest "
              + root.fastestVel.toFixed(0) + " °/s"
        color: (root.tooFastVel || root.spanStops > root.headroomStops)
               ? Theme.danger : Theme.colorTextDim
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
        text: "lines (derived)"; color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: 502; y: 170; width: 440; height: 46

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

    Text {
        x: Theme.marginX; y: 302
        text:  "exposure is TIME, not gain — a slower pass integrates each line longer"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Text {
        x: Theme.marginX; y: 320
        text:  "rate " + root.fmtHz(root.baseHz) + " Hz down to "
               + root.fmtHz(root.slowestHz) + " Hz"
               + (root.rateTooLow
                  ? "  ·  below the camera's " + root.fmtHz(root.rateFloorHz)
                    + " Hz floor — raise the speed, or use fewer/smaller stops"
                  : root.rateTooHigh
                  ? "  ·  first bracket is over the " + root.fmtHz(root.rateCeilHz)
                    + " Hz ceiling — xylod will slow the sweep to keep the count"
                  : "  ·  inside the camera's sync range")
        color: root.rateTooLow ? Theme.danger
             : root.rateTooHigh ? Theme.accent : Theme.colorTextFaint
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
                width: 100; height: 30; radius: 2
                color: (root.shotIdx === index) ? Theme.accentDim : Theme.panel
                border.width: 1
                border.color: (root.shotIdx === index) ? Theme.accent : Theme.border
                Text {
                    anchors.centerIn: parent
                    text:  root.fmtValue(modelData) + "  "
                           + root.fmtHz(root.baseHz / modelData)
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
               + "  \xB7  about " + root.fmtDuration(root.totalSetSec)
        color: root.rateTooLow ? Theme.danger : Theme.colorTextDim
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
               ? "one job, " + root.brackets + " passes · "
                 + root.spanStops.toFixed(1) + " stops of real exposure"
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
                if (root.rateTooLow) return         // the camera cannot sync that slow
                if (root.tooFastVel) return         // darkest bracket outruns the axis
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
    }
}
