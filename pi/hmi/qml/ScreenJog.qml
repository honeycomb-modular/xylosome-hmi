// ScreenJog.qml — capture ▸ jog. Position the axis; nothing is captured here.
//
// Jogging is done SOLELY with the encoder, so there are no direction pads and
// no speed row: the dial is the control. Focus it, push to take it, turn to
// move, push again to cycle the step, BTN2 to let go — the same two-level dial
// grammar ScreenScan and ScreenTimed use for their hands.
//
// The graphic is the axis itself: a ring with a live hand at the real flange
// angle, so the number and the picture always agree.
//
// Layout follows ScreenScan: graphic + readout up top, secondary 26 px tier
// right, primary bottom bar. The execute slot is deliberately EMPTY — jogging
// is not a capture — so there is no red pointer line either.

import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root
    width: 960; height: 540

    // ── Jog state ───────────────────────────────────────────────────────────────
    property bool jogging:  false          // dial taken: turning moves the axis
    property int  stepIdx:  1              // 0.1 · 1.0 · 5.0 deg per detent
    property real jogTarget: 0

    readonly property var stepValues:  [0.1, 1.0, 5.0]
    readonly property var speedValues: [30, 150, 250]    // deg/s for the step move
    readonly property real posDeg: Beckhoff.connected ? Beckhoff.positionDeg
                                                      : Motor.position

    // Safety: leaving the screen lets go of the dial.
    StackView.onStatusChanged: {
        if (StackView.status !== StackView.Active) root.releaseDial()
    }

    // ── Touch-free focus ────────────────────────────────────────────────────────
    property var focusController: jogFocus
    function focusBack() { root.StackView.view.pop() }

    FocusController {
        id: jogFocus
        index: 0
        targets: [dialProxy, btnEnable, btnSetHome]
                 .concat(modeStrip.focusTargets)
                 .concat(faultChip.focusTargets)
                 .concat([goZeroBtn, settingsBtn])
        onActivated: function(item) {
            if (item === dialProxy) root.takeDial()
            else if (item.clicked)  item.clicked()
        }
        onAdjust: function(delta) {
            if (!root.jogging) return
            if (Beckhoff.running) return                  // never jog into a scan
            root.jogTarget += delta * root.stepValues[root.stepIdx]
            if (Beckhoff.connected)
                Beckhoff.moveTo(root.jogTarget, root.speedValues[root.stepIdx])
            else { Motor.mode = 0; Motor.setpoint = root.jogTarget }
        }
        // Push while holding the dial cycles the step; BTN2 lets go.
        onConfirmed: root.stepIdx = (root.stepIdx + 1) % 3
        onCanceled:  root.releaseDial()
    }

    function takeDial() {
        if (Beckhoff.running) return
        root.jogTarget   = root.posDeg
        root.jogging     = true
        jogFocus.editing = true
    }
    function releaseDial() {
        root.jogging     = false
        jogFocus.editing = false
    }

    // ── Header ────────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: Theme.titleY
        text:  "capture.jog"
        color: Theme.colorText
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }
    Text {
        x: Theme.marginX; y: 48
        text:  "position the axis — encoder only, nothing is captured"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
    }
    Hairline { x: 0; y: Theme.hairlineTopY; width: 960 }

    // ── Axis dial ───────────────────────────────────────────────────────────────
    FocusIndicator {
        inset: true
        target: (jogFocus.current === dialProxy && !root.jogging) ? dialProxy : null
    }

    Item {
        id: axisDial
        readonly property int cx: 110
        readonly property int cy: 110
        readonly property int r:   84

        x: 60; y: 120
        width: 220; height: 220

        Item { id: dialProxy; anchors.fill: parent }

        // Ring + ticks
        Canvas {
            anchors.fill: parent
            Component.onCompleted: requestPaint()
            onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                var cx = axisDial.cx, cy = axisDial.cy, r = axisDial.r
                ctx.strokeStyle = Theme.colorTextDim.toString()
                ctx.lineWidth = 1
                ctx.beginPath(); ctx.arc(cx, cy, r, 0, 2 * Math.PI); ctx.stroke()
                for (var deg = 0; deg < 360; deg += 10) {
                    var rad = (deg - 90) * Math.PI / 180
                    var innerR = (deg % 90 === 0) ? r - 12 : ((deg % 45 === 0) ? r - 8 : r - 5)
                    ctx.beginPath()
                    ctx.moveTo(cx + innerR  * Math.cos(rad), cy + innerR  * Math.sin(rad))
                    ctx.lineTo(cx + (r + 2) * Math.cos(rad), cy + (r + 2) * Math.sin(rad))
                    ctx.stroke()
                }
            }
        }

        // Live hand — the real flange angle. Red while the dial is taken, so the
        // colour means the same thing it does everywhere else: this is moving.
        Rectangle {
            id: axisHand
            readonly property real handLen: axisDial.r + 6
            width: 2; height: handLen - 10
            color: root.jogging ? Theme.danger : Theme.accent
            x: axisDial.cx - 1; y: axisDial.cy - handLen
            transform: Rotation { origin.x: 1; origin.y: axisHand.handLen; angle: root.posDeg }
        }
        Rectangle {
            width: 6; height: 6; radius: 3; color: Theme.accent
            x: axisDial.cx - 3; y: axisDial.cy - 3
        }
    }

    // ── Position readout ────────────────────────────────────────────────────────
    Column {
        spacing: 2
        anchors.left: axisDial.right; anchors.leftMargin: 16
        anchors.verticalCenter: axisDial.verticalCenter

        Text {
            text: "position"; color: Theme.colorTextDim
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
        }
        Text {
            text: root.posDeg.toFixed(1) + "\xB0"
            color: root.jogging ? Theme.danger : Theme.colorText
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontH1 }
        }
        Text {
            text: root.jogging
                  ? "turn = move  ·  push = step \xB1"
                    + root.stepValues[root.stepIdx].toFixed(1) + "\xB0  ·  BTN2 = done"
                  : "step \xB1" + root.stepValues[root.stepIdx].toFixed(1)
                    + "\xB0 / click   —   push the dial to take it"
            color: Theme.colorTextFaint
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
        }
        Text {
            text: !Beckhoff.connected ? "offline — simulated"
                : Beckhoff.running    ? "scan running — jog locked"
                                      : "beckhoff live"
            color: Beckhoff.connected && !Beckhoff.running ? Theme.colorTextDim : Theme.danger
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
        }
    }

    // ── Secondary tier — axis state, right-aligned ──────────────────────────────
    TerminalButton {
        id: btnEnable
        controller: jogFocus
        anchors { right: parent.right; rightMargin: Theme.marginX }
        y: 120
        width: 116; height: 26; fontSize: Theme.fontMonoS
        label:  "[enable]"
        active: Beckhoff.connected ? Beckhoff.enabled : Motor.enabled
        onClicked: {
            if (Beckhoff.connected) Beckhoff.enable(!Beckhoff.enabled)
            else Motor.toggleEnabled()
        }
    }
    // The two homing verbs are kept apart on purpose: [set home] REDEFINES where
    // zero is, [go to 0°] in the bottom bar merely drives there.
    TerminalButton {
        id: btnSetHome
        controller: jogFocus
        anchors { right: parent.right; rightMargin: Theme.marginX }
        y: 152
        width: 116; height: 26; fontSize: Theme.fontMonoS
        label: "[set home]"
        onClicked: {
            if (Beckhoff.connected && !Beckhoff.running) Beckhoff.setHome()
        }
    }
    Text {
        anchors { right: parent.right; rightMargin: Theme.marginX }
        y: 186
        text:  "teaches this pose as 0\xB0"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

    // ── Bottom bar ──────────────────────────────────────────────────────────────
    Hairline { x: 0; y: Theme.bottomBarY; width: 960 }

    TerminalButton {
        id: settingsBtn
        controller: jogFocus
        x: Theme.marginX
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label: "[settings]"; active: false
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenHome.qml"))
    }

    ModeStrip {
        id: modeStrip
        mode: "jog"; controller: jogFocus
        x: Theme.marginX + 130 + 18
        anchors { bottom: parent.bottom; bottomMargin: 27 }
        onSwitchTo: function(page) {
            root.releaseDial()
            root.StackView.view.replace(root.StackView.view.currentItem,
                                        Qt.resolvedUrl(page))
        }
    }
    FaultChip {
        id: faultChip
        controller: jogFocus
        anchors { left: modeStrip.right; leftMargin: 24; bottom: parent.bottom; bottomMargin: 27 }
    }

    // No [execute] on this page — jogging is not a capture, so that slot stays
    // empty and the red BTN1 pointer line is absent too.
    TerminalButton {
        id: goZeroBtn
        controller: jogFocus
        anchors { right: parent.right; rightMargin: 18; bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label: "[go to 0\xB0]"
        onClicked: {
            root.releaseDial()
            if (Beckhoff.connected) Beckhoff.home()   // axis → 0° (home_deg)
            else Motor.zero()
        }
    }
}
