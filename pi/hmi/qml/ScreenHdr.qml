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
        property alias fastUs:   root.fastUs
        property alias slowUs:   root.slowUs
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
    // The ladder is defined by its ENDS, not by a centre plus a span.
    //
    // The old model dialled speed (the centre bracket), a bracket count and a
    // stop spacing, and grew the ladder symmetrically outwards. Asking for one
    // more step therefore pushed BOTH ends out at once, so "one step brighter"
    // could not be expressed at all — it collided with the fast rail as well as
    // the slow one, and the legal window for `speed` was a few °/s wide with
    // nothing on screen to say which way to move.
    //
    // Exposure per line is 1/rate, and the camera only syncs between
    // rateFloorHz and rateCeilHz, so EVERY legal exposure lies between
    // 1/ceil and 1/floor — about 27 to 286 us. Both ends are dialled inside
    // that fixed track and the count subdivides it. An illegal set cannot be
    // expressed, and the rails are visible rather than discovered.
    readonly property real rateFloorHz: 3500.0     // camera will not sync below
    readonly property real rateCeilHz: 37000.0     // nor above
    readonly property real usMin: 1.0e6 / root.rateCeilHz     // ~27.0 us
    readonly property real usMax: 1.0e6 / root.rateFloorHz    // ~285.7 us

    // Integration time per line, in microseconds, for the two ends.
    property real fastUs: 27.6      // darkest  — protects the highlights
    property real slowUs: 221.0     // brightest — reaches into the shadows

    readonly property int bracketMin: 2
    readonly property int bracketMax: 9
    property int brackets: 3

    readonly property real speedMin:   1.0
    readonly property real speedMax: 300.0

    // Derived, not dialled: the optics decide how many lines an arc holds.
    readonly property int lines: Calib.linesForArc(root.arcDeg)

    readonly property real arcDeg: Math.abs(root.hand2Angle - root.hand1Angle)
    readonly property real sweepSec: root.arcDeg / Math.max(0.001, root.fastestVel)

    // Exposure of bracket i: a geometric ladder from fastUs to slowUs.
    function usFor(i) {
        if (root.brackets < 2) return root.fastUs
        return root.fastUs * Math.pow(root.slowUs / root.fastUs,
                                      i / (root.brackets - 1))
    }
    // Velocity that produces that exposure: rate = linesPerDeg * v, so
    // v = (1e6/us) / linesPerDeg.
    function velForUs(us) { return (1.0e6 / us) / Calib.linesPerDeg }

    // xylod only accepts per-pass scales <= 1, so the job is handed the FASTEST
    // bracket as its maxVel and every other pass descends from it.
    function scales() {
        var out = []
        for (var i = 0; i < root.brackets; i++) out.push(root.fastUs / root.usFor(i))
        return out
    }

    readonly property real spanStops: Math.log(root.slowUs / root.fastUs) / Math.log(2)
    readonly property real stopsPer:
        root.brackets > 1 ? root.spanStops / (root.brackets - 1) : 0
    // The whole range the camera can express — the ladder can never exceed it.
    readonly property real headroomStops:
        Math.log(root.usMax / root.usMin) / Math.log(2)
    readonly property real fastestVel: root.velForUs(root.fastUs)
    readonly property real slowestVel: root.velForUs(root.slowUs)
    readonly property real baseHz:    1.0e6 / root.fastUs
    readonly property real slowestHz: 1.0e6 / root.slowUs
    // Kept so the rest of the screen keeps reading true/false, but by
    // construction these cannot now be reached from the UI.
    readonly property bool tooFastVel:  root.fastestVel > root.speedMax
    readonly property bool rateTooLow:  root.slowestHz  < root.rateFloorHz - 1
    readonly property bool rateTooHigh: root.baseHz     > root.rateCeilHz + 1
    // At a rail: adding range is no longer possible with speed alone.
    readonly property bool atShadowRail: root.slowUs >= root.usMax - 0.5
    readonly property bool atHighlightRail: root.fastUs <= root.usMin + 0.5
    // Gaps much wider than this leave the merge interpolating across noise.
    readonly property bool stepTooWide: root.stopsPer > 2.0
    // Each bracket takes longer than the last, so the set is not brackets*sweep.
    readonly property real totalSetSec: {
        var t = 0
        for (var i = 0; i < root.brackets; i++)
            t += root.arcDeg / Math.max(0.001, root.velForUs(root.usFor(i))) + 1.0
        return t
    }
    // How much longer the slowest pass runs than the fastest. The brackets walk
    // relative to each other while the sweep runs — measured at ~21 px across
    // the sweep for a 3-stop set on 2026-08-11 — and the walk grows with this.
    readonly property real slowFactor: root.slowUs / root.fastUs

    // ── Run state ───────────────────────────────────────────────────────────────
    property string execState:   "idle"
    property bool   blinkVisible: true
    property real   passFrac:     0.0
    property bool   homed:        false
    // Identifies one bracket SET. Each bracket is its own execute and therefore
    // its own Suite session, so without this the Review Suite has no way to know
    // the scans belong together — it sees N ordinary scans. Stamped once per run.
    property double setId: 0
    // Which bracket is in flight, straight from the daemon's pass index.
    property int shotIdx: -1
    // Bracket i runs slower than the first — longer integration per line, which
    // is the exposure ladder.
    function velFor(i) {
        return root.velForUs(root.usFor(i))
    }

    readonly property real overallFrac: {
        if (root.brackets <= 0 || root.shotIdx < 0) return 0
        return Math.min(1, (root.shotIdx + root.passFrac) / root.brackets)
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
    // Where an exposure sits in the camera's whole range, 0..1. Log scaled,
    // because exposure is multiplicative — on a linear scale the fast half of
    // the track would be a sliver.
    function trackPos(us) {
        return Math.log(us / root.usMin) / Math.log(root.usMax / root.usMin)
    }

    // ── Touch-free focus ────────────────────────────────────────────────────────
    property var    focusController: hdrFocus
    property string editTarget: "none"     // none | fast | slow | brackets | fov1 | fov2

    function focusBack() { root.StackView.view.pop() }

    FocusController {
        id: hdrFocus
        index: 0
        // Reading order — left to right, then down a line:
        //   darkest · brightest · brackets · lines · field · [settings] · [modes] · chip · [abort] · [home]
        targets: [fastProxy, slowProxy, brProxy,
                  fov1Proxy, fov2Proxy, settingsBtn, modesBtn]
                 .concat(faultChip.focusTargets)
                 .concat(root.execState !== "idle" ? [abortBtn] : [])
                 .concat([homeBtn])
        onActivated: function(item) {
            if (item === fastProxy)        root.enterEditing("fast")
            else if (item === slowProxy)   root.enterEditing("slow")
            else if (item === brProxy)     root.enterEditing("brackets")
            else if (item === fov1Proxy)   root.enterEditing("fov1")
            else if (item === fov2Proxy)   root.enterEditing("fov2")
            else if (item.clicked)         item.clicked()
        }
        onAdjust: function(delta) {
            // The ends step in twelfths of a stop: exposure is multiplicative,
            // so a fixed number of microseconds would crawl at one end of the
            // track and leap at the other. Each end is clamped to the camera's
            // range AND to the other end, so the ladder can never invert.
            if (root.editTarget === "fast")
                root.fastUs = Math.max(root.usMin,
                              Math.min(root.slowUs,
                                       root.fastUs * Math.pow(2, delta / 12)))
            else if (root.editTarget === "slow")
                root.slowUs = Math.max(root.fastUs,
                              Math.min(root.usMax,
                                       root.slowUs * Math.pow(2, delta / 12)))
            else if (root.editTarget === "brackets")
                root.brackets = Math.max(root.bracketMin,
                                Math.min(root.bracketMax, root.brackets + delta))
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
    // One bracket = one execute = one single-pass sequence. Multi-pass under
    // EXSYNC still starves the pass after a full frame by a fixed ~0.44 s, even
    // with the arm landing 10 ms into a 2.5 s settle and every frame-sized
    // operation moved off the status thread. Single-pass sequences are the one
    // path that has never failed, so each bracket gets its own — board opened
    // and closed fresh, exactly like the scan mode that works.
    //
    // Label carried with the job and echoed back by xylod on pass_start:
    //   hdr:<setId>:<n>/<total>:<ev>
    // Bracket 0 is the darkest, so bracket i is i*stopsPer stops brighter. The
    // Suite parses this to group the set and label each bracket by exposure;
    // xylod itself never looks inside it.
    function tagFor(i) {
        return "hdr:" + root.setId + ":" + (i + 1) + "/" + root.brackets
             + ":" + (Math.log(root.usFor(i) / root.fastUs) / Math.log(2)).toFixed(2)
    }
    // Costs a board open per bracket and lands each as its own Suite session.
    // Both are worth it over a set where the middle frame is a slice.
    function fireBracket(i) {
        root.shotIdx  = i
        root.passFrac = 0
        Recorder.startSession()
        Recorder.setScanContext(root.hand1Angle, root.hand2Angle,
                                root.velFor(i), 1.0, root.flatProfile())
        Recorder.startPass(0)
        if (Beckhoff.connected) {
            // Offset the whole arc by lead*velocity so every bracket starts at the
            // same SUBJECT angle. Without it the brackets sit hundreds of lines
            // apart — measured 447 and 675 lines on a 3-bracket set. Both ends
            // move together, so the arc length and line count are unchanged.
            var lead = Calib.leadDeg(root.velFor(i))
            Beckhoff.executeScan(1, root.hand1Angle + lead, root.hand2Angle + lead,
                                 root.velFor(i), 1.0,
                                 root.lines, root.flatProfile(), root.tagFor(i))
        } else {
            simTimer.start()
        }
    }
    function startRun() {
        root.execState    = "running"
        root.blinkVisible = true
        root.homed        = false
        root.setId        = Date.now()   // one id for the whole set
        root.fireBracket(0)
    }
    function nextBracket() {
        Recorder.endPass(0)
        Recorder.commitSession()      // sidecar for the bracket just captured
        if (root.shotIdx + 1 < root.brackets) bracketGap.restart()
        else                                  root.finishRun()
    }

    // The agent closes the board at seq_done and reopens it for the next
    // sequence. Firing the next bracket the instant seq_done arrives races that:
    // brackets fired 2.3 s apart gave two clean frames and one completely black
    // one. Chrono has the same gap for the same reason.
    //
    // 1.5 s was NOT enough: with the gap measurably live (1.53 s from sweep end
    // to the next execute) the third bracket was still completely black. The
    // agent destroys the Sapera acquisition at seq_done and creates a new one for
    // the next sequence — the same destroy/create pair that took the native
    // driver down when attempted per-pass, so it plainly needs longer. 3 s.
    Timer {
        id: bracketGap
        interval: 3000; repeat: false
        onTriggered: {
            if (root.execState !== "running") return
            root.fireBracket(root.shotIdx + 1)
        }
    }
    function finishRun() {
        simTimer.stop(); bracketGap.stop()
        root.passFrac  = 1
        root.execState = "idle"
        root.blinkVisible = true
        finishClear.start()
    }
    function abortRun() {
        simTimer.stop(); bracketGap.stop()
        // A part-finished set still deserves a sidecar: xylod closes the pass on
        // stop and the agent saves the lines it collected.
        Recorder.endPass(0)
        Recorder.commitSession()
        root.execState = "idle"
        root.blinkVisible = true
        root.shotIdx   = -1
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
        function onSequenceDone(passes) {
            if (root.execState !== "idle") root.nextBracket()
        }
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

    // ── Darkest end ─────────────────────────────────────────────────────────────
    // Both ends are drawn against the SAME fixed track (usMin..usMax, log
    // scaled), so the fill shows where in the camera's whole range this end
    // sits — and a full bar means the rail, not merely a big number.
    Text {
        x: Theme.marginX; y: 84
        text: "darkest  ·  holds highlights  ·  " + root.fastestVel.toFixed(0) + " °/s"
        color: root.atHighlightRail ? Theme.accent : Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: Theme.marginX; y: 100; width: 440; height: 46

        Item { id: fastProxy; anchors.fill: parent }

        // Must be declared alongside its target: FocusIndicator reads target.x/y
        // raw, so it only lines up when the two share a parent.
        FocusIndicator {
            inset: true
            target: (hdrFocus.current === fastProxy && !hdrFocus.editing) ? fastProxy : null
        }

        Rectangle {
            anchors.fill: parent
            color: Theme.panel; radius: 2
            border.width: root.editTarget === "fast" ? 2 : 1
            border.color: root.editTarget === "fast" ? Theme.accent : Theme.border
            Rectangle {
                x: 1; y: 1; height: parent.height - 2
                width: (parent.width - 2) * root.trackPos(root.fastUs)
                color: Theme.accent; opacity: 0.16
            }
            Text {
                anchors.centerIn: parent
                text:  root.fastUs.toFixed(1) + " \xB5s  ·  "
                       + root.fmtHz(root.baseHz) + " Hz"
                color: Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
        }
    }

    // ── Brightest end ───────────────────────────────────────────────────────────
    Text {
        x: 502; y: 84
        text: root.atShadowRail
              ? "brightest  ·  AT THE CAMERA'S SYNC FLOOR"
              : "brightest  ·  reaches shadows  ·  " + root.slowestVel.toFixed(0) + " °/s"
        color: root.atShadowRail ? Theme.accent : Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: 502; y: 100; width: 440; height: 46

        Item { id: slowProxy; anchors.fill: parent }

        FocusIndicator {
            inset: true
            target: (hdrFocus.current === slowProxy && !hdrFocus.editing) ? slowProxy : null
        }

        Rectangle {
            anchors.fill: parent
            color: Theme.panel; radius: 2
            border.width: root.editTarget === "slow" ? 2 : 1
            border.color: root.editTarget === "slow" ? Theme.accent : Theme.border
            Rectangle {
                x: 1; y: 1; height: parent.height - 2
                width: (parent.width - 2) * root.trackPos(root.slowUs)
                color: Theme.accent; opacity: 0.16
            }
            Text {
                anchors.centerIn: parent
                text:  root.slowUs.toFixed(1) + " \xB5s  ·  "
                       + root.fmtHz(root.slowestHz) + " Hz"
                color: Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
        }
    }

    // ── Brackets / lines ────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: 154
        text: "brackets  ·  " + root.stopsPer.toFixed(2) + " stops apart"
              + (root.stepTooWide ? "  — WIDE, the merge fills the gap with noise" : "")
        color: root.stepTooWide ? Theme.danger : Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: Theme.marginX; y: 170; width: 440; height: 46

        Item { id: brProxy; anchors.fill: parent }

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
    // What the ends cost. The span is bounded by the camera's sync range, so
    // say how much of it is in use rather than only refusing an illegal set.
    Text {
        x: Theme.marginX; y: 320
        text:  "span " + root.spanStops.toFixed(2) + " of "
               + root.headroomStops.toFixed(2) + " stops the camera can reach"
               + (root.atShadowRail
                  ? "  ·  brighter needs gain or more TDI stages, not less speed"
                  : "")
        color: root.atShadowRail ? Theme.accent : Theme.colorTextFaint
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

    // The trade-offs, in the order they bite: time, then how far the brackets
    // drift apart (the slow pass runs slowFactor times longer, and the walk
    // between brackets grows with it), then the field.
    Text {
        x: Theme.marginX; y: 376
        text:  "about " + root.fmtDuration(root.totalSetSec)
               + "  \xB7  slowest pass runs " + root.slowFactor.toFixed(1)
               + "\xD7 longer than the first"
               + "  \xB7  " + root.arcDeg.toFixed(0) + "\xB0 field"
               + "  \xB7  " + root.fmtLines(root.lines) + " lines"
        color: Theme.colorTextDim
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
                if (root.rateTooHigh) return        // and it would overrun the camera
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
