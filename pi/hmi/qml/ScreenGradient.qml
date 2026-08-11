// ScreenGradient.qml — capture ▸ gradient. Exposure varies ACROSS the field,
// and the geometry does not.
//
// This mode is the same `execute` as capture ▸ scan — a velocity profile over an
// arc — and that is the point rather than a shortcoming. Under `line.mode:
// "curve"` xylod paces the trigger off instantaneous velocity
// (Sequencer.cpp:457,465):
//
//     v(x)      = profile(x) · maxVelDegS
//     lineHz(x) = baseHz · v(x)/maxVelDegS  =  linesPerDeg · v(x)
//
// so lines-per-degree is CONSTANT however the axis is moving: the subject is not
// stretched anywhere, and the only thing that changes across the frame is how
// long each line integrated — 1/(linesPerDeg·v). Drawing a speed curve in scan
// mode has therefore always drawn an exposure gradient; nobody could see it,
// because that page speaks in °/s and says nothing about what is reachable.
//
// The same curve under `line.mode: "fixed"` means the opposite — constant
// exposure, warped geometry. That is capture ▸ ramp. One command, two readings,
// and the coupling switch decides which. This page therefore sets the coupling
// explicitly on every run: ramp writes the QSettings key too, and inheriting
// "fixed" from a previous ramp would silently turn a gradient into a stretch.
//
// WHAT THIS PAGE ADDS OVER SCAN — the rails. The camera only syncs between
// 3500 and 37000 Hz, and rate = 150.65·v, so the axis may only travel between
// 23.2 and 245.6 °/s. That window is exactly 3.40 stops — the same 27…286 µs
// track capture ▸ hdr dials. hdr walks that track in TIME, one whole frame per
// rung; gradient walks it in SPACE, across a single frame. So the preview strip
// IS the track: its bottom edge is the camera's rate ceiling and its top edge
// the sync floor, both ends are clamped into it, and an unreachable gradient
// cannot be expressed — the same principle as hdr's ladder.
//
// The arc comes from capture ▸ scan's saved FOV rather than a second dial here,
// as ramp and chrono do.
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
        category: "gradient"
        property alias darkUs:   root.darkUs
        property alias brightUs: root.brightUs
        property alias shape:    root.shape
    }

    // The field is capture ▸ scan's, not a second copy of it.
    Settings {
        id: scanCfg
        category: "scan"
        property real hand1Angle: -45
        property real hand2Angle:  45
    }

    // ── The exposure track ──────────────────────────────────────────────────────
    // Identical rails to capture ▸ hdr, and for the same reason: exposure per
    // line is 1/rate, and the camera syncs over a fixed range of rates.
    readonly property real rateFloorHz: 3500.0      // camera will not sync below
    readonly property real rateCeilHz: 37000.0      // nor above
    readonly property real usMin: 1.0e6 / root.rateCeilHz     // ~27.0 µs
    readonly property real usMax: 1.0e6 / root.rateFloorHz    // ~285.7 µs

    // The two ends of the gradient, in µs of integration per line.
    property real darkUs:    40.0     // holds the highlights
    property real brightUs: 160.0     // reaches into the shadows

    // Which way the exposure runs across the field. 0 at the dark end, 1 at the
    // bright end — the shape says where each lands.
    property string shape: "linear"
    readonly property var shapes: ["linear", "reverse", "centre", "edges", "ease"]
    readonly property var shapeDesc: ({
        "linear":  "dark at the field start, bright at the end",
        "reverse": "bright at the field start, dark at the end",
        "centre":  "bright through the middle, dark at both edges",
        "edges":   "dark through the middle, bright at both edges",
        "ease":    "linear, but holding longer at each end"
    })

    // 0 = the dark end, 1 = the bright end. t is position along the ARC, since
    // the profile xylod receives is position-indexed, not time-indexed.
    function shapeAt(t) {
        t = Math.max(0, Math.min(1, t))
        if (root.shape === "reverse") return 1 - t
        if (root.shape === "centre")  return 0.5 - 0.5 * Math.cos(2 * Math.PI * t)
        if (root.shape === "edges")   return 0.5 + 0.5 * Math.cos(2 * Math.PI * t)
        if (root.shape === "ease")    return t * t * (3 - 2 * t)
        return t
    }

    // Exposure is multiplicative, so the two ends are joined geometrically —
    // a shape value of 0.5 is half the STOPS, not half the microseconds.
    readonly property real ratio: root.brightUs / Math.max(0.001, root.darkUs)
    function usAt(t)  { return root.darkUs * Math.pow(root.ratio, root.shapeAt(t)) }
    function velForUs(us) { return (1.0e6 / us) / Calib.linesPerDeg }
    function velAt(t) { return root.velForUs(root.usAt(t)) }

    // xylod scales profile 1.0 to maxVelDegS, so the profile is normalised
    // against the FASTEST point — which is the dark end, by construction.
    readonly property real peakVel:  root.velForUs(root.darkUs)
    readonly property real slowVel:  root.velForUs(root.brightUs)
    readonly property real spanStops:     Math.log(root.ratio) / Math.log(2)
    readonly property real headroomStops: Math.log(root.usMax / root.usMin) / Math.log(2)

    readonly property real arcDeg: Math.abs(scanCfg.hand2Angle - scanCfg.hand1Angle)
    // Derived from the arc by the optical calibration — see Calib.qml. A free
    // line count is what stretched every scan and stopped frames filling inside
    // their pass.
    readonly property int lines: Calib.linesForArc(root.arcDeg)

    // Time is the integral of 1/v over POSITION, not arc ÷ mean speed: the
    // bright end lingers, and a full-track gradient spends 10.6× longer per
    // degree there than at the dark end.
    readonly property real sweepSec: {
        var n = 64, s = 0
        for (var i = 0; i < n; i++)
            s += 1.0 / Math.max(0.001, root.velAt((i + 0.5) / n))
        return root.arcDeg * s / n
    }

    // At a rail: the gradient cannot be pushed further with speed alone.
    readonly property bool atHighlightRail: root.darkUs   <= root.usMin + 0.5
    readonly property bool atShadowRail:    root.brightUs >= root.usMax - 0.5

    // ── Run state ───────────────────────────────────────────────────────────────
    property string execState:    "idle"        // idle | running | paused
    property bool   blinkVisible:  true
    property real   progressFrac:  0.0
    property bool   homed:         false

    // ── Helpers ─────────────────────────────────────────────────────────────────
    function fmtLines(n) { return n.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ".") }
    function fmtDuration(sec) {
        sec = Math.max(0, Math.round(sec))
        function p2(n) { return (n < 10 ? "0" : "") + n }
        return p2(Math.floor(sec / 3600)) + ":"
             + p2(Math.floor((sec % 3600) / 60)) + ":" + p2(sec % 60)
    }
    function fmtHz(hz) { return hz >= 1000 ? (hz / 1000).toFixed(1) + "k" : hz.toFixed(0) }
    // Where an exposure sits in the camera's whole range, 0..1. Log scaled,
    // because exposure is multiplicative — on a linear scale the fast half of
    // the track would be a sliver.
    function trackPos(us) {
        return Math.log(us / root.usMin) / Math.log(root.usMax / root.usMin)
    }

    // ── Touch-free focus ────────────────────────────────────────────────────────
    property var    focusController: gradFocus
    property string editTarget: "none"          // none | dark | bright | shape

    function focusBack() { root.StackView.view.pop() }

    FocusController {
        id: gradFocus
        index: 0
        // Reading order — left to right, then down a line:
        //   dark · bright · shape · [settings] · [modes] · chip · [abort] · [home]
        targets: [darkProxy, brightProxy, shapeProxy, settingsBtn, modesBtn]
                 .concat(faultChip.focusTargets)
                 .concat(root.execState !== "idle" ? [abortBtn] : [])
                 .concat([homeBtn])
        onActivated: function(item) {
            if (item === darkProxy)        root.enterEditing("dark")
            else if (item === brightProxy) root.enterEditing("bright")
            else if (item === shapeProxy)  root.enterEditing("shape")
            else if (item.clicked)         item.clicked()
        }
        onAdjust: function(delta) {
            // The ends step in twelfths of a stop, as hdr's do: a fixed number of
            // microseconds would crawl at one end of the track and leap at the
            // other. Each end is clamped to the camera's range AND to the other
            // end, so the gradient can never invert or leave the track.
            if (root.editTarget === "dark")
                root.darkUs = Math.max(root.usMin,
                              Math.min(root.brightUs,
                                       root.darkUs * Math.pow(2, delta / 12)))
            else if (root.editTarget === "bright")
                root.brightUs = Math.max(root.darkUs,
                                Math.min(root.usMax,
                                         root.brightUs * Math.pow(2, delta / 12)))
            else if (root.editTarget === "shape") {
                var i = Math.max(0, Math.min(root.shapes.length - 1,
                                             root.shapes.indexOf(root.shape) + delta))
                root.shape = root.shapes[i]
            }
        }
        onConfirmed: root.exitEditing()
        onCanceled:  root.exitEditing()
    }

    function enterEditing(what) { gradFocus.editing = true;  root.editTarget = what }
    function exitEditing()      { gradFocus.editing = false; root.editTarget = "none" }

    // ENC push while editing (main.qml routes here).
    function focusContext() { if (gradFocus.editing) root.exitEditing() }
    // BTN1 — dedicated execute.
    function btn1Execute() { playBtn.clicked() }

    // ── Run control ─────────────────────────────────────────────────────────────
    function buildProfile() {
        // profile(t) = v(t)/peakVel = darkUs/us(t) — 1.0 at the dark end, and
        // never below 1/ratio, which is the bright end's velocity.
        var prof = []
        for (var i = 0; i < 128; i++)
            prof.push(root.darkUs / root.usAt(i / 127))
        return prof
    }
    function startRun() {
        // Without a session the scan lands as a bare TIF: commitSession() is what
        // writes the sidecar the Review Suite pairs against.
        var prof = root.buildProfile()
        Recorder.startSession()
        Recorder.setScanContext(scanCfg.hand1Angle, scanCfg.hand2Angle,
                                root.peakVel, 1.0, prof)
        Recorder.startPass(0)
        root.progressFrac = 0
        root.execState    = "running"
        root.blinkVisible = true
        root.homed        = false
        if (Beckhoff.connected) {
            // The gradient IS the coupling: "fixed" would keep the exposure flat
            // and warp the geometry instead. ramp writes this same key, so it
            // must be set here rather than assumed, and it must precede
            // executeScan — the daemon reads it as it builds the command.
            Beckhoff.setLineMode("curve")
            // The trigger clocks off COMMANDED motion, so it starts while the
            // axis is still accelerating and the frame arrives a fixed 27.1 ms
            // late — an angle that depends on speed. It is a start-of-pass
            // effect, so the START velocity is the one that sets it. Both ends
            // move together, leaving arc length and line count unchanged.
            var lead = Calib.leadDeg(root.velAt(0))
            // minVelDegS is a FLOOR, not the slow end: xylod applies it as
            // max(min·scale, profile·maxVel), and passing the real slow velocity
            // would let it win over a maxVel that got capped to hold the line
            // count. The bright end of the track already keeps the axis above
            // 23 °/s, so nothing needs the floor to do any work.
            Beckhoff.executeScan(Motor.colorMode,
                                 scanCfg.hand1Angle + lead, scanCfg.hand2Angle + lead,
                                 root.peakVel, 1.0,
                                 root.lines, prof)
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
        Recorder.commitSession()
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
        text:  "capture.gradient"
        color: Theme.colorText
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }
    Text {
        x: Theme.marginX; y: 48
        text:  "exposure varies across the field — the geometry does not"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
    }

    // ── The two ends ────────────────────────────────────────────────────────────
    // Both are drawn against the SAME fixed track (usMin..usMax, log scaled), so
    // the fill shows where in the camera's whole range each end sits — and a full
    // bar means the rail, not merely a big number.
    Text {
        x: Theme.marginX; y: 84
        text: root.atHighlightRail
              ? "dark end  ·  AT THE CAMERA'S RATE CEILING"
              : "dark end  ·  holds highlights  ·  " + root.peakVel.toFixed(0) + " °/s"
        color: root.atHighlightRail ? Theme.accent : Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: Theme.marginX; y: 100; width: 440; height: 46

        Item { id: darkProxy; anchors.fill: parent }

        // Must be declared alongside its target: FocusIndicator reads target.x/y
        // raw, so it only lines up when the two share a parent.
        FocusIndicator {
            inset: true
            target: (gradFocus.current === darkProxy && !gradFocus.editing) ? darkProxy : null
        }

        Rectangle {
            anchors.fill: parent
            color: Theme.panel; radius: 2
            border.width: root.editTarget === "dark" ? 2 : 1
            border.color: root.editTarget === "dark" ? Theme.accent : Theme.border
            Rectangle {
                x: 1; y: 1; height: parent.height - 2
                width: (parent.width - 2) * root.trackPos(root.darkUs)
                color: Theme.accent; opacity: 0.16
            }
            Text {
                anchors.centerIn: parent
                text:  root.darkUs.toFixed(1) + " \xB5s  ·  "
                       + root.fmtHz(1.0e6 / root.darkUs) + " Hz"
                color: Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
        }
    }

    Text {
        x: 502; y: 84
        text: root.atShadowRail
              ? "bright end  ·  AT THE CAMERA'S SYNC FLOOR"
              : "bright end  ·  reaches shadows  ·  " + root.slowVel.toFixed(0) + " °/s"
        color: root.atShadowRail ? Theme.accent : Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: 502; y: 100; width: 440; height: 46

        Item { id: brightProxy; anchors.fill: parent }

        FocusIndicator {
            inset: true
            target: (gradFocus.current === brightProxy && !gradFocus.editing) ? brightProxy : null
        }

        Rectangle {
            anchors.fill: parent
            color: Theme.panel; radius: 2
            border.width: root.editTarget === "bright" ? 2 : 1
            border.color: root.editTarget === "bright" ? Theme.accent : Theme.border
            Rectangle {
                x: 1; y: 1; height: parent.height - 2
                width: (parent.width - 2) * root.trackPos(root.brightUs)
                color: Theme.accent; opacity: 0.16
            }
            Text {
                anchors.centerIn: parent
                text:  root.brightUs.toFixed(1) + " \xB5s  ·  "
                       + root.fmtHz(1.0e6 / root.brightUs) + " Hz"
                color: Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
        }
    }

    // ── Shape / lines ───────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: 154
        text: "shape  ·  " + root.shapeDesc[root.shape]
        color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: Theme.marginX; y: 170; width: 440; height: 46

        Item { id: shapeProxy; anchors.fill: parent }

        FocusIndicator {
            inset: true
            target: (gradFocus.current === shapeProxy && !gradFocus.editing) ? shapeProxy : null
        }

        Rectangle {
            anchors.fill: parent
            color: Theme.panel; radius: 2
            border.width: root.editTarget === "shape" ? 2 : 1
            border.color: root.editTarget === "shape" ? Theme.accent : Theme.border
            Rectangle {
                x: 1; y: 1; height: parent.height - 2
                width: (parent.width - 2) * (root.shapes.indexOf(root.shape) + 1)
                       / root.shapes.length
                color: Theme.accent; opacity: 0.16
            }
            Text {
                anchors.centerIn: parent
                text:  root.shape
                color: Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
        }
    }

    Text {
        x: 502; y: 154
        text: "lines (derived)"
        color: root.arcDeg < 0.5 ? Theme.danger : Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Item {
        x: 502; y: 170; width: 440; height: 46

        Rectangle {
            anchors.fill: parent
            color: Theme.panel; radius: 2
            border.width: 1; border.color: Theme.border
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

    // ── The gradient itself ─────────────────────────────────────────────────────
    // Not a graph of the exposure — the exposure. Each column is shaded by where
    // its own integration time sits on the camera's track, so the strip's full
    // height IS the 3.40 stops available: bottom edge the rate ceiling, top edge
    // the sync floor. A shallow gradient looks shallow, and neither end can be
    // dialled off the strip.
    Hairline { x: Theme.marginX; y: 232; width: Theme.contentW }

    Item {
        id: preview
        x: Theme.marginX; y: 244; width: Theme.contentW; height: 108

        Canvas {
            id: previewCanvas
            anchors.fill: parent

            property real   _dark:   root.darkUs
            property real   _bright: root.brightUs
            property string _shape:  root.shape
            on_DarkChanged:   requestPaint()
            on_BrightChanged: requestPaint()
            on_ShapeChanged:  requestPaint()
            Component.onCompleted: requestPaint()

            onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var w = width, h = height

                // One column per pixel, shaded by its position on the track.
                for (var px = 0; px < w; px++) {
                    var pos = root.trackPos(root.usAt(px / (w - 1)))
                    var g   = Math.round(8 + 214 * Math.max(0, Math.min(1, pos)))
                    ctx.fillStyle = "rgb(" + g + "," + g + "," + g + ")"
                    ctx.fillRect(px, 0, 1, h)
                }

                // The exposure curve, riding its own brightness. Up = brighter.
                ctx.strokeStyle = Theme.accent.toString()
                ctx.lineWidth   = 1.5
                ctx.beginPath()
                for (var cx = 0; cx < w; cx++) {
                    var cy = h * (1 - root.trackPos(root.usAt(cx / (w - 1))))
                    if (cx === 0) ctx.moveTo(cx, cy); else ctx.lineTo(cx, cy)
                }
                ctx.stroke()

                // The rails are the edges themselves — say so.
                ctx.strokeStyle = Theme.border.toString()
                ctx.lineWidth   = 1
                ctx.beginPath()
                ctx.moveTo(0, 0.5);     ctx.lineTo(w, 0.5)
                ctx.moveTo(0, h - 0.5); ctx.lineTo(w, h - 0.5)
                ctx.stroke()
            }
        }

        Text {
            x: 6; y: 4
            text:  root.usMax.toFixed(0) + " \xB5s  sync floor"
            color: "#101010"
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
        }
        Text {
            x: 6; y: preview.height - 20
            text:  root.usMin.toFixed(0) + " \xB5s  rate ceiling"
            color: "#D0D0D0"
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
        }

        // Where the sweep has got to, on the field it is painting.
        Rectangle {
            visible: root.execState !== "idle"
            x: Math.max(0, Math.min(preview.width - 1, preview.width * root.progressFrac))
            y: 0; width: 1; height: preview.height
            color: Theme.danger
            Behavior on x { NumberAnimation { duration: 180 } }
        }
    }

    Text {
        x: Theme.marginX; y: 360
        text:  "span " + root.spanStops.toFixed(2) + " of "
               + root.headroomStops.toFixed(2) + " stops the camera can reach"
               + "  \xB7  bright end lingers " + root.ratio.toFixed(1)
               + "\xD7 longer per degree"
        color: (root.atShadowRail || root.atHighlightRail) ? Theme.accent : Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Text {
        x: Theme.marginX; y: 382
        text:  "arc " + root.arcDeg.toFixed(0) + "\xB0 from capture.scan"
               + "  \xB7  sweep " + root.fmtDuration(root.sweepSec)
               + "  \xB7  lines follow the axis, so nothing stretches"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

    // ── Progress ────────────────────────────────────────────────────────────────
    Rectangle {
        x: Theme.marginX; y: 410; width: Theme.contentW; height: 20
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
        x: Theme.marginX; y: 438
        text:  root.execState === "idle"
               ? "one pass  \xB7  " + root.darkUs.toFixed(0) + " \xB5s → "
                 + root.brightUs.toFixed(0) + " \xB5s across the field"
               : "scanning  \xB7  " + Math.round(root.progressFrac * 100) + "%"
                 + "  \xB7  " + Beckhoff.velocityDegS.toFixed(0) + " \xB0/s"
                 + "  \xB7  " + root.fmtHz(Beckhoff.lineHz) + " Hz"
        color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

    // ── Bottom bar ──────────────────────────────────────────────────────────────

    TerminalButton {
        id: settingsBtn
        controller: gradFocus
        x: Theme.marginX
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label: "[settings]"; active: false
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenHome.qml"))
    }

    TerminalButton {
        id: modesBtn
        controller: gradFocus
        x: Theme.marginX + 130 + 18
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label: "[modes]"; active: false
        onClicked: {
            root.abortRun()
            root.StackView.view.replace(root.StackView.view.currentItem,
                                        Qt.resolvedUrl("ScreenModes.qml"),
                                        { fromPage: "ScreenGradient.qml" })
        }
    }
    FaultChip {
        id: faultChip
        controller: gradFocus
        anchors { left: modesBtn.right; leftMargin: 24; bottom: parent.bottom; bottomMargin: 27 }
    }

    Rectangle {
        anchors { left: playBtn.right; right: parent.right; verticalCenter: playBtn.verticalCenter }
        height: 1; color: Theme.danger
    }

    TerminalButton {
        id: abortBtn
        controller: gradFocus
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
        controller: gradFocus
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
                // The only illegal state left: no field set in capture.scan. Both
                // ends are clamped into the camera's track as they are dialled,
                // and the fastest reachable point (245.6 °/s at the rate ceiling)
                // is inside the axis limit, so neither rail needs a guard here.
                if (root.arcDeg < 0.5) return
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
        gradFocus.editing = false
    }
}
