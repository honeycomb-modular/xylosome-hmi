// ScreenParty.qml — capture ▸ party. Irregular back-and-forth, seeded.
//
// Pendulum's machinery with the sine replaced by something unruly: a sum of
// harmonics whose amplitudes come from a seed. Same seed, same dance — so a
// result you like is reproducible, which is the whole reason there is a seed
// rather than plain randomness.
//
// The profile is built ONLY from sin(2*pi*i*t/T) with integer i and no phase
// offset. That is not a stylistic choice, it is what keeps the axis safe:
//   · every harmonic completes whole cycles over the pass, so the mean is
//     exactly zero and the axis returns to where it began — no drift
//   · sin(0) = 0, so the pass starts and ends at a standstill rather than
//     stepping the velocity, which the drive could not follow
// Add a phase offset or a non-integer frequency and both guarantees are gone.
//
// energy   — peak speed of the dance
// duration — how long it lasts
// seed     — [reroll] for a different dance at the same energy
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
        category: "party"
        property alias energyDegS:  root.energyDegS
        property alias durationSec: root.durationSec
        property alias seed:        root.seed
        property alias lines:       root.lines
        property alias fwdOnly:     root.fwdOnly
    }

    // ── Dance definition ────────────────────────────────────────────────────────
    readonly property real energyMin:   5.0
    readonly property real energyMax: 200.0
    property real energyDegS: 40.0

    readonly property real durMin:   2.0
    readonly property real durMax: 120.0
    property real durationSec: 12.0

    property int seed: 1337

    readonly property int linesMin: 256
    readonly property int linesMax: 65000
    property int lines: 22200

    readonly property real velCeiling: 300.0
    readonly property real accCeiling: 1500.0   // mirrors acc_limit_degs2

    // How many harmonics the dance is built from. More is busier; beyond about
    // eight the turnarounds get too sharp for the drive at any useful energy.
    readonly property int harmonics: 6

    // ── Seeded profile ──────────────────────────────────────────────────────────
    // Cached: the preview, the acceleration check and the execute must all use
    // the SAME samples, or the drawing lies about what will run.
    property var profile: []
    property real peakAcc: 0.0

    // mulberry32 — small, fast, and identical every time for a given seed.
    function rng(s) {
        return function () {
            s |= 0; s = (s + 0x6D2B79F5) | 0
            var t = Math.imul(s ^ (s >>> 15), 1 | s)
            t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
            return ((t ^ (t >>> 14)) >>> 0) / 4294967296
        }
    }

    function rebuildProfile() {
        var rand = root.rng(root.seed)
        // Amplitude per harmonic, falling with order so the low, wide swings
        // dominate and the high ones only add detail.
        var amps = []
        for (var k = 1; k <= root.harmonics; k++)
            amps.push((0.35 + 0.65 * rand()) / k)

        var n = root.harmonics * 48 + 1      // (n-1) divides by every harmonic
        var raw = [], peak = 0
        for (var i = 0; i < n; i++) {
            var t = i / (n - 1)
            var v = 0
            for (var h = 0; h < root.harmonics; h++)
                v += amps[h] * Math.sin(2 * Math.PI * (h + 1) * t)
            raw.push(v)
            if (Math.abs(v) > peak) peak = Math.abs(v)
        }
        // Normalise to ±1 so `energy` alone sets the speed, whatever the seed.
        var prof = []
        for (i = 0; i < n; i++) prof.push(peak > 1e-9 ? raw[i] / peak : 0)

        // Peak acceleration, measured off the samples rather than derived —
        // the harmonic sum has no tidy closed form.
        var dtS = root.durationSec / (n - 1)
        var acc = 0
        for (i = 1; i < n; i++) {
            var a = Math.abs(prof[i] - prof[i - 1]) * root.energyDegS / Math.max(1e-6, dtS)
            if (a > acc) acc = a
        }
        root.peakAcc = acc
        root.profile = prof
    }

    readonly property bool tooFast: root.energyDegS > root.velCeiling
    readonly property bool tooHard: root.peakAcc > root.accCeiling

    onSeedChanged:        root.rebuildProfile()
    onEnergyDegSChanged:  root.rebuildProfile()
    onDurationSecChanged: root.rebuildProfile()
    onProfileChanged:     dance.requestPaint()
    onPeakAccChanged:     dance.requestPaint()

    // ── Run state ───────────────────────────────────────────────────────────────
    // TDI shifts one way, so the return stroke smears. Default ON: sharp is
    // the sane default and the smear is the deliberate choice.
    property bool fwdOnly: true

    property string execState:   "idle"
    property bool   blinkVisible: true
    property real   progressFrac: 0.0
    property bool   homed:        false
    property real   centreDeg:    0.0

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
    // Furthest the dance strays from the start pose, by integrating the samples.
    function excursionDeg() {
        var p = root.profile
        if (!p || p.length < 2) return 0
        var dtS = root.durationSec / (p.length - 1), x = 0, lo = 0, hi = 0
        for (var i = 0; i < p.length; i++) {
            x += p[i] * root.energyDegS * dtS
            if (x < lo) lo = x
            if (x > hi) hi = x
        }
        return Math.max(Math.abs(lo), Math.abs(hi))
    }

    // ── Touch-free focus ────────────────────────────────────────────────────────
    property var    focusController: partyFocus
    property string editTarget: "none"     // none | energy | dur | lines

    function focusBack() { root.StackView.view.pop() }

    FocusController {
        id: partyFocus
        index: 0
        // Reading order — left to right, then down a line:
        //   energy · duration · lines · [reroll] · [settings] · [modes] · chip · [abort] · [home]
        targets: [energyProxy, durProxy, linesProxy, rerollBtn, fwdBtn, settingsBtn, modesBtn]
                 .concat(faultChip.focusTargets)
                 .concat(root.execState !== "idle" ? [abortBtn] : [])
                 .concat([homeBtn])
        onActivated: function(item) {
            if (item === energyProxy)     root.enterEditing("energy")
            else if (item === durProxy)   root.enterEditing("dur")
            else if (item === linesProxy) root.enterEditing("lines")
            else if (item.clicked)        item.clicked()
        }
        onAdjust: function(delta) {
            if (root.editTarget === "energy")
                root.energyDegS = Math.max(root.energyMin,
                                  Math.min(root.energyMax, root.energyDegS + delta * 2))
            else if (root.editTarget === "dur")
                root.durationSec = Math.max(root.durMin,
                                   Math.min(root.durMax, root.durationSec + delta))
            else if (root.editTarget === "lines")
                root.lines = root.linesOfFrac(root.fracOfLines(root.lines) + delta * 0.015)
        }
        onConfirmed: root.exitEditing()
        onCanceled:  root.exitEditing()
    }

    function enterEditing(what) { partyFocus.editing = true;  root.editTarget = what }
    function exitEditing()      { partyFocus.editing = false; root.editTarget = "none" }

    function focusContext() { if (partyFocus.editing) root.exitEditing() }
    function btn1Execute()  { playBtn.clicked() }

    // ── Run control ─────────────────────────────────────────────────────────────
    function startRun() {
        // Without a session the scan lands as a bare TIF: commitSession()
        // is what writes the sidecar the Review Suite pairs against, so a
        // mode that skips this produces files the Suite cannot see.
        Recorder.startSession()
        Recorder.setScanContext(root.centreDeg, root.centreDeg,
                                root.energyDegS, 0, root.profile)
        Recorder.startPass(0)
        root.progressFrac = 0
        root.execState    = "running"
        root.blinkVisible = true
        root.homed        = false
        root.centreDeg    = Beckhoff.positionDeg
        if (Beckhoff.connected) {
            // The dance is zero-mean, so it wanders either side of the pose and
            // comes back — no need to offset the start the way pendulum does.
            Beckhoff.executeReversing(Motor.colorMode, root.centreDeg,
                                      root.energyDegS, root.durationSec,
                                      root.lines, root.profile, root.fwdOnly)
        } else {
            simTimer.start()
        }
    }
    function finishRun() {
        Recorder.endPass(0)
        Recorder.commitSession()   // writes the Suite's sidecar
        simTimer.stop()
        root.progressFrac = 1
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
            // Zero-mean means it should already be home, but rounding over
            // thousands of cycles is worth mopping up before the next run.
            if (Beckhoff.connected) Beckhoff.moveTo(root.centreDeg, 60.0)
        }
        function onFaulted(text)      { root.abortRun() }
        function onConnectedChanged() { if (!Beckhoff.connected && root.execState !== "idle") root.abortRun() }
    }

    // ── Header ────────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: Theme.titleY
        text:  "capture.party"
        color: Theme.colorText
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }
    Text {
        x: Theme.marginX; y: 48
        text:  "an irregular dance — same seed, same dance"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
    }

    // ── Energy ──────────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: 90
        text: "energy"; color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: Theme.marginX; y: 108; width: 440; height: 52

        Item { id: energyProxy; anchors.fill: parent }

        // Must be declared alongside its target: FocusIndicator reads target.x/y
        // raw, so it only lines up when the two share a parent.
        FocusIndicator {
            inset: true
            target: (partyFocus.current === energyProxy && !partyFocus.editing) ? energyProxy : null
        }

        Rectangle {
            anchors.fill: parent
            color: Theme.panel; radius: 2
            border.width: root.editTarget === "energy" ? 2 : 1
            border.color: root.editTarget === "energy" ? Theme.accent : Theme.border
            Rectangle {
                x: 1; y: 1; height: parent.height - 2
                width: (parent.width - 2) * (root.energyDegS - root.energyMin)
                       / (root.energyMax - root.energyMin)
                color: Theme.accent; opacity: 0.16
            }
            Text {
                anchors.centerIn: parent
                text:  root.energyDegS.toFixed(0) + " \xB0/s peak"
                color: Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
        }
    }

    // ── Duration ────────────────────────────────────────────────────────────────
    Text {
        x: 502; y: 90
        text: "duration"; color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: 502; y: 108; width: 440; height: 52

        Item { id: durProxy; anchors.fill: parent }

        FocusIndicator {
            inset: true
            target: (partyFocus.current === durProxy && !partyFocus.editing) ? durProxy : null
        }

        Rectangle {
            anchors.fill: parent
            color: Theme.panel; radius: 2
            border.width: root.editTarget === "dur" ? 2 : 1
            border.color: root.editTarget === "dur" ? Theme.accent : Theme.border
            Rectangle {
                x: 1; y: 1; height: parent.height - 2
                width: (parent.width - 2) * (root.durationSec - root.durMin)
                       / (root.durMax - root.durMin)
                color: Theme.accent; opacity: 0.16
            }
            Text {
                anchors.centerIn: parent
                text:  root.fmtDuration(root.durationSec)
                color: Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
        }
    }

    // ── Lines ───────────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: 174
        text: "lines"; color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: Theme.marginX; y: 192; width: Theme.contentW; height: 52

        Item { id: linesProxy; anchors.fill: parent }

        FocusIndicator {
            inset: true
            target: (partyFocus.current === linesProxy && !partyFocus.editing) ? linesProxy : null
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

    // ── The dance, drawn ────────────────────────────────────────────────────────
    Hairline { x: Theme.marginX; y: 256; width: Theme.contentW }

    Rectangle {
        x: Theme.marginX; y: 264; width: Theme.contentW; height: 76
        color: Theme.panel; radius: 2
        border.width: 1; border.color: Theme.border

        Canvas {
            id: dance
            anchors.fill: parent
            anchors.margins: 1
            onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var w = width, h = height, mid = h / 2
                var p = root.profile
                if (!p || p.length < 2) return

                ctx.strokeStyle = Theme.border; ctx.lineWidth = 1
                ctx.beginPath(); ctx.moveTo(0, mid); ctx.lineTo(w, mid); ctx.stroke()

                // Position, integrated from the velocity samples — the path the
                // axis actually takes, not the velocity that drives it.
                var dtS = root.durationSec / (p.length - 1)
                var xs = [], x = 0, span = 1e-6
                for (var i = 0; i < p.length; i++) {
                    x += p[i] * root.energyDegS * dtS
                    xs.push(x)
                    if (Math.abs(x) > span) span = Math.abs(x)
                }
                ctx.strokeStyle = (root.tooFast || root.tooHard) ? Theme.danger : Theme.accent
                ctx.lineWidth = 2
                ctx.beginPath()
                for (i = 0; i < xs.length; i++) {
                    var px = i / (xs.length - 1) * w
                    var py = mid - (xs[i] / span) * (mid - 6)
                    if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py)
                }
                ctx.stroke()
            }
        }
    }

    // ── Reroll + readouts ───────────────────────────────────────────────────────
    TerminalButton {
        id: rerollBtn
        controller: partyFocus
        x: Theme.marginX; y: 350
        width: 200; height: 40
        label: "[reroll]"
        onClicked: root.seed = Math.floor(Math.random() * 100000)
    }

    // TDI shifts charge one way only, so the return stroke smears by about the
    // stage count. Default is to skip it: sharp everywhere, half the lines.
    TerminalButton {
        id: fwdBtn
        controller: partyFocus
        x: Theme.marginX + 218; y: 350
        width: 232; height: 36
        label:  root.fwdOnly ? "[lines: forward]" : "[lines: both]"
        active: root.fwdOnly
        fontSize: Theme.fontMonoS
        onClicked: root.fwdOnly = !root.fwdOnly
    }

    Text {
        x: 470; y: 352
        text:  "seed " + root.seed
               + "  \xB7  strays \xB1" + root.excursionDeg().toFixed(1) + "\xB0"
               + "  \xB7  peak " + root.peakAcc.toFixed(0) + " \xB0/s\xB2"
        color: (root.tooFast || root.tooHard) ? Theme.danger : Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Text {
        x: 470; y: 372
        visible: root.tooFast || root.tooHard
        text:  root.tooFast
               ? "too fast — drop the energy (ceiling "
                 + root.velCeiling.toFixed(0) + " \xB0/s)"
               : "turnarounds too sharp for the drive — drop the energy or "
                 + "lengthen the duration (limit " + root.accCeiling.toFixed(0) + " \xB0/s\xB2)"
        color: Theme.danger
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

    // ── Progress ────────────────────────────────────────────────────────────────
    Rectangle {
        x: Theme.marginX; y: 400; width: Theme.contentW; height: 26
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
        x: Theme.marginX; y: 434
        text:  root.execState === "idle"
               ? "dances about the current pose and returns to it"
               : "dancing  \xB7  " + Math.round(root.progressFrac * 100) + "%"
                 + "  \xB7  " + Beckhoff.velocityDegS.toFixed(0) + " \xB0/s"
                 + "  \xB7  " + Beckhoff.positionDeg.toFixed(1) + "\xB0"
        color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

    // ── Bottom bar ──────────────────────────────────────────────────────────────

    TerminalButton {
        id: settingsBtn
        controller: partyFocus
        x: Theme.marginX
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label: "[settings]"; active: false
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenHome.qml"))
    }

    TerminalButton {
        id: modesBtn
        controller: partyFocus
        x: Theme.marginX + 130 + 18
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label: "[modes]"; active: false
        onClicked: {
            root.abortRun()
            root.StackView.view.replace(root.StackView.view.currentItem,
                                        Qt.resolvedUrl("ScreenModes.qml"),
                                        { fromPage: "ScreenParty.qml" })
        }
    }
    FaultChip {
        id: faultChip
        controller: partyFocus
        anchors { left: modesBtn.right; leftMargin: 24; bottom: parent.bottom; bottomMargin: 27 }
    }

    Rectangle {
        anchors { left: playBtn.right; right: parent.right; verticalCenter: playBtn.verticalCenter }
        height: 1; color: Theme.danger
    }

    TerminalButton {
        id: abortBtn
        controller: partyFocus
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
        controller: partyFocus
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
                if (root.tooFast || root.tooHard) return
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
        partyFocus.editing = false
        root.lines = Math.max(root.linesMin, Math.min(root.linesMax, root.lines))
        root.rebuildProfile()
    }
}
