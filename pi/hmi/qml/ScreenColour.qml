// ScreenColour.qml — settings ▸ colour. Equalise the three filter exposures.
//
// The colour wheel's R, G and B glass pass very different amounts of light
// (measured 2026-10-16: G ~0.7, B ~2 stops under R). xylod compensates by
// running each colour pass slower by 2^-stops — same arc, same lines, every
// line integrated longer — in every mode (scan, timed, static, pendulum,
// party, freerun, xerox). The three "stops of extra exposure" live in xylod
// (colour_stops, persisted on the C6920); this page reads them from status,
// nudges them by hand, or MEASURES them:
//
//   [measure] — a short colour scan (30° from where the axis stands, 3 s per
//               red pass) of whatever the camera sees. Point it at something
//               grey or white and evenly lit. The capture agent reports each
//               pass's median (pass_stats on the camera bus); the stops that
//               would make the three medians equal are shown as "→ new".
//   [apply]   — send the measured stops to xylod.
//   [−] [+]   — nudge one filter by 0.05 stop, applied at once.
//
// The measurement runs WITH the current compensation and solves for the
// residual, so repeating it converges: a second run should read ~0.00 change.

import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root
    width: 960; height: 540

    readonly property var names: ["R", "G", "B"]
    // Live stops, mirrored from xylod status.
    readonly property var stops: Beckhoff.colourStops

    // ── Measurement ─────────────────────────────────────────────────────────────
    property string measState: "idle"      // idle | running | waiting | done | failed
    property string measNote:  ""
    property var    measStops: [0, 0, 0]   // stops in force when the scan started
    property var    medians:   [0, 0, 0]
    property var    p99s:      [0, 0, 0]
    property var    gotPass:   [false, false, false]
    property var    proposed:  [0, 0, 0]
    property bool   haveProposal: false

    readonly property real measArcDeg: 30
    readonly property real measVelDegS: 10

    function fmtStops(v) { return (v >= 0 ? "+" : "") + Number(v).toFixed(2) }

    function nudge(i, d) {
        if (!Beckhoff.connected || root.measState === "running" || root.measState === "waiting") return
        var s = [Number(root.stops[0]), Number(root.stops[1]), Number(root.stops[2])]
        s[i] = Math.max(0, Math.min(4, Math.round((s[i] + d) * 100) / 100))
        Beckhoff.setColourStops(s[0], s[1], s[2])
    }

    function startMeasure() {
        if (!Beckhoff.connected || !Camera.connected) return
        if (Beckhoff.running || root.measState === "running" || root.measState === "waiting") return
        root.measStops = [Number(root.stops[0]), Number(root.stops[1]), Number(root.stops[2])]
        root.gotPass   = [false, false, false]
        root.medians   = [0, 0, 0]
        root.p99s      = [0, 0, 0]
        root.haveProposal = false
        root.measState = "running"
        root.measNote  = "scanning R/G/B — " + root.measArcDeg + "° from here"
        // Up the arc if there is room, otherwise down; 3 s per pass at full speed.
        var start = Beckhoff.positionDeg
        var end   = (start + root.measArcDeg <= 180) ? start + root.measArcDeg
                                                     : start - root.measArcDeg
        var lines = Math.round(root.measArcDeg * Calib.linesPerDegOr(150))
        var prof  = []
        for (var i = 0; i < 16; i++) prof.push(1.0)
        Beckhoff.setLineMode("curve")
        Beckhoff.executeScan(0, start, end, root.measVelDegS, root.measVelDegS, lines, prof)
    }

    function finishMeasure() {
        statsWait.stop()
        if (!(root.gotPass[0] && root.gotPass[1] && root.gotPass[2])) {
            root.measState = "failed"
            root.measNote  = "no pass_stats from the capture agent — is it running the new build?"
            return
        }
        // Undo the compensation each pass ran with, to get the filters' own
        // brightness; then the stops that bring each up to the brightest.
        var lo = Math.min(root.measStops[0], root.measStops[1], root.measStops[2])
        var raw = [0, 0, 0], best = 0, dark = false, sat = false
        for (var i = 0; i < 3; i++) {
            var scale = Math.pow(2, -(root.measStops[i] - lo))
            raw[i] = Math.max(1, root.medians[i]) / scale
            best = Math.max(best, raw[i])
            if (root.medians[i] < 400)   dark = true
            if (root.p99s[i] > 62000)    sat  = true
        }
        var p = [0, 0, 0]
        for (var j = 0; j < 3; j++)
            p[j] = Math.max(0, Math.min(4, Math.round(Math.log2(best / raw[j]) * 100) / 100))
        root.proposed = p
        root.haveProposal = true
        root.measState = "done"
        root.measNote  = sat  ? "a pass is clipping (p99 > 62000) — dim the light and measure again"
                       : dark ? "a pass is very dark (median < 400) — more light, then measure again"
                       : "measured — [apply] to send, or measure again to check (want ≈ no change)"
    }

    function applyMeasured() {
        if (!root.haveProposal || !Beckhoff.connected) return
        Beckhoff.setColourStops(root.proposed[0], root.proposed[1], root.proposed[2])
        root.haveProposal = false
        root.measState = "idle"
        root.measNote  = "applied"
    }

    Connections {
        target: Camera
        function onPassStats(pass, filter, median, p99, lines) {
            if (root.measState !== "running" && root.measState !== "waiting") return
            if (pass < 0 || pass > 2) return
            var m = root.medians.slice(), q = root.p99s.slice(), g = root.gotPass.slice()
            m[pass] = median; q[pass] = p99; g[pass] = true
            root.medians = m; root.p99s = q; root.gotPass = g
            if (g[0] && g[1] && g[2]) root.finishMeasure()
        }
    }
    Connections {
        target: Beckhoff
        function onSequenceDone(passes) {
            if (root.measState !== "running") return
            // The agent saves (and reports) the last pass after seq_done.
            root.measState = "waiting"
            root.measNote  = "waiting for the capture agent's pass statistics"
            statsWait.start()
        }
        function onFaulted(text) {
            if (root.measState === "running" || root.measState === "waiting") {
                statsWait.stop()
                root.measState = "failed"; root.measNote = "fault: " + text
            }
        }
    }
    Timer {
        id: statsWait
        interval: 10000; repeat: false
        onTriggered: root.finishMeasure()
    }

    // ── Touch-free focus ────────────────────────────────────────────────────────
    property var focusController: colFocus
    function focusBack() {
        if (root.measState === "running" || root.measState === "waiting") return
        root.StackView.view.pop()
    }

    FocusController {
        id: colFocus
        targets: [rMinus, rPlus, gMinus, gPlus, bMinus, bPlus, measureBtn, applyBtn, backBtn]
        onActivated: function(item) { if (item.clicked) item.clicked() }
    }

    // ── Title ───────────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: Theme.titleY
        text:  "settings ▸ colour"
        color: Theme.colorText
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }
    Text {
        x: Theme.marginX; y: 48
        text: "filter exposure match — each colour pass runs 2^-stops slower than red, every mode"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
    }

    // ── Column headings ─────────────────────────────────────────────────────────
    Item {
        id: head
        x: Theme.marginX; y: 100; width: Theme.contentW; height: 20
        Text { x: 0;   text: "filter";   color: Theme.colorTextDim; font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS } }
        Text { x: 110; text: "stops";    color: Theme.colorTextDim; font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS } }
        Text { x: 250; text: "speed";    color: Theme.colorTextDim; font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS } }
        Text { x: 470; text: "median";   color: Theme.colorTextDim; font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS } }
        Text { x: 600; text: "p99";      color: Theme.colorTextDim; font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS } }
        Text { x: 730; text: "→ new";    color: Theme.colorTextDim; font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS } }
    }
    Hairline { x: Theme.marginX; y: 124; width: Theme.contentW }

    // ── R / G / B rows ──────────────────────────────────────────────────────────
    Repeater {
        model: 3
        delegate: Item {
            id: row
            readonly property real lo: Math.min(Number(root.stops[0]), Number(root.stops[1]), Number(root.stops[2]))
            readonly property real st: Number(root.stops[index])
            x: Theme.marginX; y: 136 + index * 56; width: Theme.contentW; height: 48

            Text {
                x: 0; anchors.verticalCenter: parent.verticalCenter
                text: root.names[index]
                color: index === 0 ? "#F87171" : index === 1 ? "#4ADE80" : "#60A5FA"
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontH2 }
            }
            Text {
                x: 110; anchors.verticalCenter: parent.verticalCenter
                text: Beckhoff.connected ? root.fmtStops(row.st) : "—"
                color: Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontH2 }
            }
            Text {
                x: 250; anchors.verticalCenter: parent.verticalCenter
                text: Beckhoff.connected ? "x " + Math.pow(2, -(row.st - row.lo)).toFixed(3) : ""
                color: Theme.colorTextDim
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
            Text {
                x: 470; anchors.verticalCenter: parent.verticalCenter
                text: root.gotPass[index] ? Math.round(root.medians[index]) : "·"
                color: Theme.colorTextDim
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
            Text {
                x: 600; anchors.verticalCenter: parent.verticalCenter
                text: root.gotPass[index] ? Math.round(root.p99s[index]) : "·"
                color: root.gotPass[index] && root.p99s[index] > 62000 ? Theme.danger : Theme.colorTextDim
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
            Text {
                x: 730; anchors.verticalCenter: parent.verticalCenter
                text: root.haveProposal ? root.fmtStops(root.proposed[index]) : "·"
                color: root.haveProposal ? Theme.accent : Theme.colorTextDim
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontH2 }
            }
        }
    }

    // Nudge buttons — one pair per row, explicit ids so the focus chain can
    // name them.
    TerminalButton { id: rMinus; controller: colFocus; x: Theme.marginX + 340; y: 143; width: 44; height: 34
        label: "[−]"; fontSize: Theme.fontMonoM; onClicked: root.nudge(0, -0.05) }
    TerminalButton { id: rPlus;  controller: colFocus; x: Theme.marginX + 392; y: 143; width: 44; height: 34
        label: "[+]"; fontSize: Theme.fontMonoM; onClicked: root.nudge(0, +0.05) }
    TerminalButton { id: gMinus; controller: colFocus; x: Theme.marginX + 340; y: 199; width: 44; height: 34
        label: "[−]"; fontSize: Theme.fontMonoM; onClicked: root.nudge(1, -0.05) }
    TerminalButton { id: gPlus;  controller: colFocus; x: Theme.marginX + 392; y: 199; width: 44; height: 34
        label: "[+]"; fontSize: Theme.fontMonoM; onClicked: root.nudge(1, +0.05) }
    TerminalButton { id: bMinus; controller: colFocus; x: Theme.marginX + 340; y: 255; width: 44; height: 34
        label: "[−]"; fontSize: Theme.fontMonoM; onClicked: root.nudge(2, -0.05) }
    TerminalButton { id: bPlus;  controller: colFocus; x: Theme.marginX + 392; y: 255; width: 44; height: 34
        label: "[+]"; fontSize: Theme.fontMonoM; onClicked: root.nudge(2, +0.05) }

    Hairline { x: Theme.marginX; y: 308; width: Theme.contentW }

    // ── Status lines ────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: 322
        text: !Beckhoff.connected ? "xylod offline"
            : !Camera.connected   ? "capture agent offline — measuring needs it; nudging still works"
            : root.measState === "running"
              ? "pass " + (Math.max(0, Beckhoff.passIndex) + 1) + "/3 "
                + root.names[Math.max(0, Math.min(2, Beckhoff.passIndex))] + " — " + root.measNote
            : root.measNote
        color: root.measState === "failed" ? Theme.danger
             : (root.measState === "running" || root.measState === "waiting") ? Theme.accent
             : Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
    }
    Text {
        x: Theme.marginX; y: 350
        width: Theme.contentW; wrapMode: Text.WordWrap
        text: "measure: aim at an evenly lit grey or white surface. " + root.measArcDeg
              + "° sweep from the current position, " + (root.measArcDeg / root.measVelDegS).toFixed(0)
              + " s per red pass (G/B slower by their stops). "
              + "Repeat until → new reads about the same as stops."
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

    // ── Bottom bar — [back] left · [measure] [apply] right ────────────────────
    TerminalButton {
        id: backBtn
        controller: colFocus
        x: Theme.marginX
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: Theme.bottomBtnW; height: Theme.bottomBtnH
        label: "[back]"; active: false
        onClicked: root.focusBack()
    }
    TerminalButton {
        id: applyBtn
        controller: colFocus
        anchors { right: parent.right; rightMargin: 18; bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label: "[apply]"
        active: root.haveProposal
        textColor: root.haveProposal ? Theme.colorText : Theme.colorTextFaint
        onClicked: root.applyMeasured()
    }
    TerminalButton {
        id: measureBtn
        controller: colFocus
        anchors { right: parent.right; rightMargin: 18 + 130 + 18; bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label: (root.measState === "running" || root.measState === "waiting") ? "[measuring]" : "[measure]"
        active: root.measState === "running" || root.measState === "waiting"
        textColor: (Beckhoff.connected && Camera.connected) ? Theme.colorText : Theme.colorTextFaint
        onClicked: root.startMeasure()
    }
}
