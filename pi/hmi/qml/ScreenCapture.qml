// ScreenCapture.qml — capture mode selector.
// Accessed from ScreenHome → 01 capture modes.
//
// Three modes:
//   program scan — automated 4-pass r/g/b/c, velocity curve set in ScreenScan
//   jog          — manual axis movement at selectable speed, with capture trigger
//   static       — motor stationary, color (4-pass r/g/b/c) or bw (single pass)
//
// Jog and static captures are stubs until the ClearCore TCP layer is implemented.
//
// Layout (960×540):
//   y=0..63    header + hairline
//   y=63..108  mode tab bar (program | jog | static)
//   y=108..460 mode content panel
//   y=460..540 footer

import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root
    width: 960; height: 540

    // 0 = program scan, 1 = jog, 2 = static
    property int activeMode: 1

    // ── Touch-free focus ────────────────────────────────────────────────────────
    // Cursor cycles the 3 mode tabs plus the buttons of the visible panel. The
    // hold-to-jog pads are excluded (they need press-and-hold, not a click) until
    // the ClearCore jog command exists. Back returns to the menu.
    property var focusController: capFocus
    function focusBack() { root.StackView.view.pop() }

    FocusController {
        id: capFocus
        index: 1   // start on the active "jog" tab
        targets: {
            var t = [tabProgram, tabJog, tabStatic]
            if (root.activeMode === 0)      return t.concat([btnOpenScan])
            else if (root.activeMode === 1) return t.concat([btnSlow, btnMed, btnFast, btnEnable, btnZero, btnJogCapture])
            else                            return t.concat([btnColor, btnBw, btnStaticCapture])
        }
        onActivated: function(item) {
            if (item === tabProgram)     root.activeMode = 0
            else if (item === tabJog)    root.activeMode = 1
            else if (item === tabStatic) root.activeMode = 2
            else if (item.clicked)       item.clicked()
        }
    }

    FocusIndicator { target: capFocus.current }

    // ── Header ────────────────────────────────────────────────────────────────

    BackButton { x: 18; y: 16 }

    Text {
        x: 124; y: 25
        text:  "capture.modes"
        color: Theme.colorText
        font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
    }

    Text {
        anchors { right: parent.right; rightMargin: 9; top: parent.top; topMargin: 29 }
        text:  "// program · jog · static"
        color: Theme.colorTextDim
        font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
    }

    Hairline { x: 9; y: 63; width: 942 }

    // ── Mode tab bar ──────────────────────────────────────────────────────────
    // Three equal tabs across 942 px (314 each), y=63..108.

    Item {
        id: tabProgram
        x: 9; y: 63; width: 314; height: 45
        Text {
            anchors.centerIn: parent
            text:  "program scan"
            color: root.activeMode === 0 ? Theme.accent : Theme.colorTextDim
            font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
        }
        Rectangle {
            anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter }
            width: parent.width - 20; height: 1
            color: root.activeMode === 0 ? Theme.accent : Theme.border
        }
        MouseArea { anchors.fill: parent; onClicked: root.activeMode = 0 }
    }

    Item {
        id: tabJog
        x: 323; y: 63; width: 314; height: 45
        Text {
            anchors.centerIn: parent
            text:  "jog"
            color: root.activeMode === 1 ? Theme.accent : Theme.colorTextDim
            font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
        }
        Rectangle {
            anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter }
            width: parent.width - 20; height: 1
            color: root.activeMode === 1 ? Theme.accent : Theme.border
        }
        MouseArea { anchors.fill: parent; onClicked: root.activeMode = 1 }
    }

    Item {
        id: tabStatic
        x: 637; y: 63; width: 314; height: 45
        Text {
            anchors.centerIn: parent
            text:  "static"
            color: root.activeMode === 2 ? Theme.accent : Theme.colorTextDim
            font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
        }
        Rectangle {
            anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter }
            width: parent.width - 20; height: 1
            color: root.activeMode === 2 ? Theme.accent : Theme.border
        }
        MouseArea { anchors.fill: parent; onClicked: root.activeMode = 2 }
    }

    Hairline { x: 9; y: 108; width: 942 }

    // ═══════════════════════════════════════════════════════════════════════════
    // Panel 0 — program scan
    // ═══════════════════════════════════════════════════════════════════════════
    Item {
        x: 9; y: 120; width: 942; height: 340
        visible: root.activeMode === 0

        Text {
            x: 0; y: 10
            text: "velocity curve controls scan axis timing."
            color: Theme.colorTextDim
            font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
        }
        Text {
            x: 0; y: 36
            text: "4-pass r/g/b/c sequence — edit curve on the main scan screen."
            color: Theme.colorTextFaint
            font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
        }

        TerminalButton {
            id: btnOpenScan
            x: 0; y: 90; width: 220; height: 45
            label: "[open scan editor]"
            // Pop all the way back to ScreenScan (stack root).
            onClicked: root.StackView.view.pop(null)
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Panel 1 — jog
    // ═══════════════════════════════════════════════════════════════════════════
    Item {
        id: jogPanel
        x: 9; y: 120; width: 942; height: 340
        visible: root.activeMode === 1

        property int jogSpeed: 1   // 0=slow, 1=medium, 2=fast
        // TODO: map to real ClearCore velocity commands when TCP layer exists.
        // Placeholder deg/s values used to drive Motor mock.
        readonly property var speedValues: [5, 30, 120]

        // Position readout ────────────────────────────────────────────────────
        Text {
            x: 0; y: 6
            text: "position"
            color: Theme.colorTextDim
            font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
        }
        Text {
            x: 140; y: 0
            text: Motor.position.toFixed(1).padStart(8)
            color: Theme.accent
            font { family: Theme.fontFamily; pixelSize: Theme.fontH1 }
        }
        Text {
            x: 440; y: 8
            text: "deg"
            color: Theme.colorTextDim
            font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
        }

        // Speed selector ──────────────────────────────────────────────────────
        Text {
            x: 0; y: 68
            text: "speed"
            color: Theme.colorTextDim
            font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
        }

        TerminalButton {
            id: btnSlow
            x: 100; y: 58; width: 120; height: 38
            label: "[slow]"
            active: jogPanel.jogSpeed === 0
            onClicked: jogPanel.jogSpeed = 0
        }
        TerminalButton {
            id: btnMed
            x: 232; y: 58; width: 138; height: 38
            label: "[medium]"
            active: jogPanel.jogSpeed === 1
            onClicked: jogPanel.jogSpeed = 1
        }
        TerminalButton {
            id: btnFast
            x: 382; y: 58; width: 120; height: 38
            label: "[fast]"
            active: jogPanel.jogSpeed === 2
            onClicked: jogPanel.jogSpeed = 2
        }

        // Jog buttons — hold to move ──────────────────────────────────────────
        Rectangle {
            x: 0; y: 120; width: 300; height: 72
            color: Theme.panel
            border.color: jogLeftArea.containsPress ? Theme.accent : Theme.border
            border.width: 1; radius: 2
            Text {
                anchors.centerIn: parent
                text: "[←  jog left  ]"
                color: jogLeftArea.containsPress ? Theme.accent : Theme.colorText
                font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
            }
            MouseArea {
                id: jogLeftArea
                anchors.fill: parent
                // TODO: replace with ClearCore TCP jog command
                onPressed:  { Motor.mode = 1; Motor.setpoint = -jogPanel.speedValues[jogPanel.jogSpeed] }
                onReleased: Motor.setpoint = 0
            }
        }

        Rectangle {
            x: 642; y: 120; width: 300; height: 72
            color: Theme.panel
            border.color: jogRightArea.containsPress ? Theme.accent : Theme.border
            border.width: 1; radius: 2
            Text {
                anchors.centerIn: parent
                text: "[  jog right  →]"
                color: jogRightArea.containsPress ? Theme.accent : Theme.colorText
                font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
            }
            MouseArea {
                id: jogRightArea
                anchors.fill: parent
                // TODO: replace with ClearCore TCP jog command
                onPressed:  { Motor.mode = 1; Motor.setpoint = jogPanel.speedValues[jogPanel.jogSpeed] }
                onReleased: Motor.setpoint = 0
            }
        }

        // Enable / zero / capture ─────────────────────────────────────────────
        TerminalButton {
            id: btnEnable
            x: 0; y: 222; width: 146; height: 45
            label:  "[enable]"
            active: Motor.enabled
            onClicked: Motor.toggleEnabled()
        }
        TerminalButton {
            id: btnZero
            x: 158; y: 222; width: 110; height: 45
            label:  "[zero]"
            onClicked: Motor.zero()
        }
        TerminalButton {
            id: btnJogCapture
            x: 642; y: 222; width: 300; height: 45
            label:  "[capture]"
            // TODO: trigger capture via ClearCore
            onClicked: console.log("jog capture — TODO")
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Panel 2 — static
    // ═══════════════════════════════════════════════════════════════════════════
    Item {
        id: staticPanel
        x: 9; y: 120; width: 942; height: 340
        visible: root.activeMode === 2

        property int colorMode: 0   // 0=color (r/g/b/c), 1=bw (single pass)

        // Position readout ────────────────────────────────────────────────────
        Text {
            x: 0; y: 6
            text: "position"
            color: Theme.colorTextDim
            font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
        }
        Text {
            x: 140; y: 0
            text: Motor.position.toFixed(1).padStart(8)
            color: Theme.accent
            font { family: Theme.fontFamily; pixelSize: Theme.fontH1 }
        }
        Text {
            x: 440; y: 8
            text: "deg"
            color: Theme.colorTextDim
            font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
        }

        // Color mode selector ─────────────────────────────────────────────────
        Text {
            x: 0; y: 68
            text: "mode"
            color: Theme.colorTextDim
            font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
        }

        TerminalButton {
            id: btnColor
            x: 100; y: 58; width: 220; height: 38
            label:  "[color  r/g/b/c]"
            active: staticPanel.colorMode === 0
            onClicked: staticPanel.colorMode = 0
        }
        TerminalButton {
            id: btnBw
            x: 332; y: 58; width: 180; height: 38
            label:  "[bw  single]"
            active: staticPanel.colorMode === 1
            onClicked: staticPanel.colorMode = 1
        }

        Text {
            x: 0; y: 108
            text: staticPanel.colorMode === 0
                  ? "motor stationary — 4-pass r/g/b/c filter wheel sequence"
                  : "motor stationary — single pass, no filter"
            color: Theme.colorTextFaint
            font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
        }

        // Capture button ──────────────────────────────────────────────────────
        TerminalButton {
            id: btnStaticCapture
            x: 0; y: 160; width: 300; height: 72
            label:    "[  capture  ]"
            fontSize: Theme.fontH2
            // TODO: trigger static capture via ClearCore
            onClicked: console.log("static capture mode=" + staticPanel.colorMode + " — TODO")
        }
    }

    // ── Footer ────────────────────────────────────────────────────────────────

    Hairline {
        anchors { bottom: parent.bottom; bottomMargin: 29; left: parent.left; leftMargin: 9 }
        width: 942
    }

    Text {
        anchors { bottom: parent.bottom; bottomMargin: 7; left: parent.left; leftMargin: 9 }
        text: "jog + static: stubs — pending clearcore tcp layer"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamily; pixelSize: Theme.fontLabel }
    }
}
