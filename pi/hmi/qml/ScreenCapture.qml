// ScreenCapture.qml — capture mode selector.
// Accessed from ScreenHome → capture modes.
//
// Three modes (selected by the [program]/[jog]/[static] button row):
//   program scan — automated 4-pass r/g/b/c, velocity curve set in ScreenScan
//   jog          — manual axis movement at selectable speed, with capture trigger
//   static       — motor stationary, color (4-pass r/g/b/c) or bw (single pass)
//
// Jog and static captures are stubs until the ClearCore TCP layer is implemented.

import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root
    width: 960; height: 540

    // 0 = program scan, 1 = jog, 2 = static
    property int activeMode: 1

    // ── Touch-free focus ────────────────────────────────────────────────────────
    // Cursor cycles the 3 mode buttons plus the buttons of the visible panel, then
    // [back]. The hold-to-jog pads are excluded (they need press-and-hold).
    property var focusController: capFocus
    function focusBack() { root.StackView.view.pop() }

    FocusController {
        id: capFocus
        index: 1   // start on the active "jog" mode button
        targets: {
            var t = [tabProgram, tabJog, tabStatic]
            if (root.activeMode === 0)      t = t.concat([btnOpenScan])
            else if (root.activeMode === 1) t = t.concat([btnSlow, btnMed, btnFast, btnEnable, btnZero, btnJogCapture])
            else                            t = t.concat([btnColor, btnBw, btnStaticCapture])
            return t.concat([backBtn])
        }
        onActivated: function(item) { if (item.clicked) item.clicked() }
    }

    // ── Header ────────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: Theme.titleY
        text:  "capture.modes"
        color: Theme.colorText
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }

    Hairline { x: 0; y: Theme.hairlineTopY; width: 960 }

    // ── Mode button row ─────────────────────────────────────────────────────────
    TerminalButton {
        id: tabProgram
        controller: capFocus
        x: Theme.marginX; y: 74; width: 170; height: 40
        label:  "[program]"
        active: root.activeMode === 0
        onClicked: root.activeMode = 0
    }
    TerminalButton {
        id: tabJog
        controller: capFocus
        x: 200; y: 74; width: 110; height: 40
        label:  "[jog]"
        active: root.activeMode === 1
        onClicked: root.activeMode = 1
    }
    TerminalButton {
        id: tabStatic
        controller: capFocus
        x: 322; y: 74; width: 120; height: 40
        label:  "[static]"
        active: root.activeMode === 2
        onClicked: root.activeMode = 2
    }

    Hairline { x: 0; y: 128; width: 960 }

    // ═══════════════════════════════════════════════════════════════════════════
    // Panel 0 — program scan
    // ═══════════════════════════════════════════════════════════════════════════
    Item {
        x: Theme.marginX; y: 144; width: Theme.contentW; height: 300
        visible: root.activeMode === 0

        Text {
            x: 0; y: 10
            text: "velocity curve controls scan axis timing."
            color: Theme.colorTextDim
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
        }
        Text {
            x: 0; y: 36
            text: "4-pass r/g/b/c sequence — edit curve on the main scan screen."
            color: Theme.colorTextFaint
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
        }

        TerminalButton {
            id: btnOpenScan
            controller: capFocus
            x: 0; y: 90; width: 220; height: Theme.bottomBtnH
            label: "[open scan editor]"
            onClicked: root.StackView.view.pop(null)   // back to ScreenScan (stack root)
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Panel 1 — jog
    // ═══════════════════════════════════════════════════════════════════════════
    Item {
        id: jogPanel
        x: Theme.marginX; y: 144; width: Theme.contentW; height: 300
        visible: root.activeMode === 1

        property int jogSpeed: 1   // 0=slow, 1=medium, 2=fast
        readonly property var speedValues: [5, 30, 120]

        Text {
            x: 0; y: 6
            text: "position"
            color: Theme.colorTextDim
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
        }
        Text {
            x: 140; y: 0
            text: Motor.position.toFixed(1).padStart(8)
            color: Theme.accent
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontH1 }
        }
        Text {
            x: 440; y: 8
            text: "deg"
            color: Theme.colorTextDim
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
        }

        Text {
            x: 0; y: 68
            text: "speed"
            color: Theme.colorTextDim
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
        }

        TerminalButton {
            id: btnSlow
            controller: capFocus
            x: 100; y: 58; width: 120; height: 40
            label: "[slow]"
            active: jogPanel.jogSpeed === 0
            onClicked: jogPanel.jogSpeed = 0
        }
        TerminalButton {
            id: btnMed
            controller: capFocus
            x: 232; y: 58; width: 138; height: 40
            label: "[medium]"
            active: jogPanel.jogSpeed === 1
            onClicked: jogPanel.jogSpeed = 1
        }
        TerminalButton {
            id: btnFast
            controller: capFocus
            x: 382; y: 58; width: 120; height: 40
            label: "[fast]"
            active: jogPanel.jogSpeed === 2
            onClicked: jogPanel.jogSpeed = 2
        }

        // Hold-to-jog pads — same panel/border/accent vocabulary as buttons,
        // but press-and-hold (excluded from cursor focus until ClearCore exists).
        Rectangle {
            x: 0; y: 120; width: 300; height: 72
            color: Theme.panel
            border.color: jogLeftArea.containsPress ? Theme.accent : Theme.border
            border.width: 1; radius: 2
            Text {
                anchors.centerIn: parent
                text: "[←  jog left  ]"
                color: jogLeftArea.containsPress ? Theme.accent : Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
            }
            MouseArea {
                id: jogLeftArea
                anchors.fill: parent
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
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
            }
            MouseArea {
                id: jogRightArea
                anchors.fill: parent
                onPressed:  { Motor.mode = 1; Motor.setpoint = jogPanel.speedValues[jogPanel.jogSpeed] }
                onReleased: Motor.setpoint = 0
            }
        }

        TerminalButton {
            id: btnEnable
            controller: capFocus
            x: 0; y: 222; width: 146; height: Theme.bottomBtnH
            label:  "[enable]"
            active: Motor.enabled
            onClicked: Motor.toggleEnabled()
        }
        TerminalButton {
            id: btnZero
            controller: capFocus
            x: 158; y: 222; width: 110; height: Theme.bottomBtnH
            label:  "[zero]"
            onClicked: Motor.zero()
        }
        TerminalButton {
            id: btnJogCapture
            controller: capFocus
            x: 642; y: 222; width: 300; height: Theme.bottomBtnH
            label:  "[capture]"
            onClicked: console.log("jog capture — TODO")
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Panel 2 — static
    // ═══════════════════════════════════════════════════════════════════════════
    Item {
        id: staticPanel
        x: Theme.marginX; y: 144; width: Theme.contentW; height: 300
        visible: root.activeMode === 2

        property int colorMode: 0   // 0=color (r/g/b/c), 1=bw (single pass)

        Text {
            x: 0; y: 6
            text: "position"
            color: Theme.colorTextDim
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
        }
        Text {
            x: 140; y: 0
            text: Motor.position.toFixed(1).padStart(8)
            color: Theme.accent
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontH1 }
        }
        Text {
            x: 440; y: 8
            text: "deg"
            color: Theme.colorTextDim
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
        }

        Text {
            x: 0; y: 68
            text: "mode"
            color: Theme.colorTextDim
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
        }

        TerminalButton {
            id: btnColor
            controller: capFocus
            x: 100; y: 58; width: 220; height: 40
            label:  "[color  r/g/b/c]"
            active: staticPanel.colorMode === 0
            onClicked: staticPanel.colorMode = 0
        }
        TerminalButton {
            id: btnBw
            controller: capFocus
            x: 332; y: 58; width: 180; height: 40
            label:  "[bw  single]"
            active: staticPanel.colorMode === 1
            onClicked: staticPanel.colorMode = 1
        }

        Text {
            x: 0; y: 112
            text: staticPanel.colorMode === 0
                  ? "motor stationary — 4-pass r/g/b/c filter wheel sequence"
                  : "motor stationary — single pass, no filter"
            color: Theme.colorTextFaint
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
        }

        TerminalButton {
            id: btnStaticCapture
            controller: capFocus
            x: 0; y: 160; width: 300; height: Theme.bottomBtnH
            label:    "[capture]"
            onClicked: console.log("static capture mode=" + staticPanel.colorMode + " — TODO")
        }
    }

    // ── Bottom bar — [back] ─────────────────────────────────────────────────────
    Hairline { x: 0; y: Theme.bottomBarY; width: 960 }

    TerminalButton {
        id: backBtn
        controller: capFocus
        x: Theme.marginX
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: Theme.bottomBtnW; height: Theme.bottomBtnH
        label:  "[back]"
        active: false
        onClicked: root.StackView.view.pop()
    }
}
