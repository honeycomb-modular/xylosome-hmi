// ScreenCapture.qml — capture mode selector.
// Accessed from ScreenHome → capture modes.
//
// Three modes (selected by the [program]/[jog]/[static] button row):
//   program scan — automated 4-pass r/g/b/c, velocity curve set in ScreenScan
//   jog          — manual axis movement at selectable speed, with capture trigger
//   static       — motor stationary, color (4-pass r/g/b/c) or bw (single pass)
//
// Each panel uses one aligned grid: dim label column at x=0, controls from x=110,
// laid out top-to-bottom in workflow order. Jog/static captures are stubs until
// the ClearCore TCP layer exists.

import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root
    width: 960; height: 540

    // 0 = program scan, 1 = jog, 2 = static
    property int activeMode: 1

    // Safety: any mode change or leaving this screen stops a live jog.
    onActiveModeChanged: if (Beckhoff.connected) Beckhoff.jog(0)
    StackView.onStatusChanged: {
        if (StackView.status !== StackView.Active && Beckhoff.connected)
            Beckhoff.jog(0)
    }

    // shared layout for the panels
    readonly property int labelX:  0
    readonly property int ctlX:    110
    readonly property int btnH:    44

    // ── Touch-free focus ────────────────────────────────────────────────────────
    property var focusController: capFocus
    function focusBack() { root.StackView.view.pop() }

    FocusController {
        id: capFocus
        index: 1   // start on the active "jog" mode button
        targets: {
            var t = [tabProgram, tabJog, tabStatic]
            if (root.activeMode === 0)      t = t.concat([btnProgColor, btnProgBw, btnOpenScan])
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
        id: programPanel
        x: Theme.marginX; y: 144; width: Theme.contentW; height: 300
        visible: root.activeMode === 0

        Text {
            x: root.labelX; y: 10
            text: "velocity curve controls scan axis timing."
            color: Theme.colorTextDim
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
        }

        // color mode — shared global Motor.colorMode (also used by static panel)
        Text {
            x: root.labelX; y: 82; text: "color mode"
            color: Theme.colorTextDim
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
        }
        TerminalButton {
            id: btnProgColor; controller: capFocus
            x: root.ctlX; y: 70; width: 220; height: root.btnH
            label: "[color  r/g/b/c]"
            active: Motor.colorMode === 0
            onClicked: Motor.colorMode = 0
        }
        TerminalButton {
            id: btnProgBw; controller: capFocus
            x: 342; y: 70; width: 180; height: root.btnH
            label: "[bw  single]"
            active: Motor.colorMode === 1
            onClicked: Motor.colorMode = 1
        }

        Text {
            x: root.labelX; y: 140
            text: Motor.colorMode === 0
                  ? "4-pass r/g/b/c filter wheel sequence — curve from scan editor"
                  : "single bw pass, no filter wheel — curve from scan editor"
            color: Theme.colorTextFaint
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
        }

        TerminalButton {
            id: btnOpenScan
            controller: capFocus
            x: root.labelX; y: 202; width: 220; height: root.btnH
            label: "[open scan editor]"
            onClicked: root.StackView.view.pop(null)   // back to ScreenScan (stack root)
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Panel 1 — jog   (workflow top→bottom: status · speed · move · enable/zero · capture)
    // ═══════════════════════════════════════════════════════════════════════════
    Item {
        id: jogPanel
        x: Theme.marginX; y: 144; width: Theme.contentW; height: 300
        visible: root.activeMode === 1

        property int jogSpeed: 1   // 0=slow, 1=medium, 2=fast
        readonly property var speedValues: [5, 30, 120]

        // status — position (real axis when the Beckhoff is connected)
        Text {
            x: root.labelX; y: 16; text: "position"
            color: Theme.colorTextDim; font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
        }
        Text {
            x: 150; y: 4
            text: (Beckhoff.connected ? Beckhoff.positionDeg : Motor.position).toFixed(1)
            color: Theme.accent; font { family: Theme.fontFamilyMono; pixelSize: Theme.fontH1 }
        }
        Text {
            x: 300; y: 16; text: "deg"
            color: Theme.colorTextDim; font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
        }
        Text {
            x: 380; y: 16
            text: Beckhoff.connected
                  ? (Beckhoff.running ? "scan running — jog locked" : "beckhoff live")
                  : "offline — simulated"
            color: Beckhoff.connected && !Beckhoff.running ? Theme.colorTextDim : Theme.colorTextFaint
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
        }

        // speed
        Text {
            x: root.labelX; y: 82; text: "speed"
            color: Theme.colorTextDim; font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
        }
        TerminalButton {
            id: btnSlow; controller: capFocus
            x: root.ctlX; y: 70; width: 120; height: root.btnH
            label: "[slow]";   active: jogPanel.jogSpeed === 0; onClicked: jogPanel.jogSpeed = 0
        }
        TerminalButton {
            id: btnMed; controller: capFocus
            x: 242; y: 70; width: 120; height: root.btnH
            label: "[medium]"; active: jogPanel.jogSpeed === 1; onClicked: jogPanel.jogSpeed = 1
        }
        TerminalButton {
            id: btnFast; controller: capFocus
            x: 374; y: 70; width: 120; height: root.btnH
            label: "[fast]";   active: jogPanel.jogSpeed === 2; onClicked: jogPanel.jogSpeed = 2
        }

        // move — hold-to-jog pads, grouped side by side (press-and-hold; not focusable)
        Text {
            x: root.labelX; y: 140; text: "jog"
            color: Theme.colorTextDim; font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
        }
        Rectangle {
            x: root.ctlX; y: 126; width: 210; height: 56
            color: Theme.panel; radius: 2; border.width: 1
            border.color: jogLeftArea.containsPress ? Theme.accent : Theme.border
            Text {
                anchors.centerIn: parent; text: "[←  jog left]"
                color: jogLeftArea.containsPress ? Theme.accent : Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
            }
            MouseArea {
                id: jogLeftArea; anchors.fill: parent
                enabled: !Beckhoff.running     // never jog into a running scan
                onPressed: {
                    if (Beckhoff.connected) Beckhoff.jog(-jogPanel.speedValues[jogPanel.jogSpeed])
                    else { Motor.mode = 1; Motor.setpoint = -jogPanel.speedValues[jogPanel.jogSpeed] }
                }
                onReleased: {
                    if (Beckhoff.connected) Beckhoff.jog(0)
                    else Motor.setpoint = 0
                }
                onCanceled: {
                    if (Beckhoff.connected) Beckhoff.jog(0)
                    else Motor.setpoint = 0
                }
            }
        }
        Rectangle {
            x: 332; y: 126; width: 210; height: 56
            color: Theme.panel; radius: 2; border.width: 1
            border.color: jogRightArea.containsPress ? Theme.accent : Theme.border
            Text {
                anchors.centerIn: parent; text: "[jog right  →]"
                color: jogRightArea.containsPress ? Theme.accent : Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
            }
            MouseArea {
                id: jogRightArea; anchors.fill: parent
                enabled: !Beckhoff.running     // never jog into a running scan
                onPressed: {
                    if (Beckhoff.connected) Beckhoff.jog(jogPanel.speedValues[jogPanel.jogSpeed])
                    else { Motor.mode = 1; Motor.setpoint = jogPanel.speedValues[jogPanel.jogSpeed] }
                }
                onReleased: {
                    if (Beckhoff.connected) Beckhoff.jog(0)
                    else Motor.setpoint = 0
                }
                onCanceled: {
                    if (Beckhoff.connected) Beckhoff.jog(0)
                    else Motor.setpoint = 0
                }
            }
        }

        // axis state (left)  ·  capture (right, primary action)
        TerminalButton {
            id: btnEnable; controller: capFocus
            x: root.ctlX; y: 202; width: 120; height: root.btnH
            label: "[enable]"
            active: Beckhoff.connected ? Beckhoff.enabled : Motor.enabled
            onClicked: {
                if (Beckhoff.connected) Beckhoff.enable(!Beckhoff.enabled)
                else Motor.toggleEnabled()
            }
        }
        TerminalButton {
            id: btnZero; controller: capFocus
            x: 242; y: 202; width: 120; height: root.btnH
            label: "[zero]"
            onClicked: {
                if (Beckhoff.connected) Beckhoff.home()   // axis → 0° (home_deg)
                else Motor.zero()
            }
        }
        TerminalButton {
            id: btnJogCapture; controller: capFocus
            x: 614; y: 202; width: 300; height: root.btnH
            label: "[capture]"; onClicked: console.log("jog capture — TODO")
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Panel 2 — static  (status · mode · note · capture)
    // ═══════════════════════════════════════════════════════════════════════════
    Item {
        id: staticPanel
        x: Theme.marginX; y: 144; width: Theme.contentW; height: 300
        visible: root.activeMode === 2

        Text {
            x: root.labelX; y: 16; text: "position"
            color: Theme.colorTextDim; font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
        }
        Text {
            x: 150; y: 4
            text: (Beckhoff.connected ? Beckhoff.positionDeg : Motor.position).toFixed(1)
            color: Theme.accent; font { family: Theme.fontFamilyMono; pixelSize: Theme.fontH1 }
        }
        Text {
            x: 300; y: 16; text: "deg"
            color: Theme.colorTextDim; font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
        }

        Text {
            x: root.labelX; y: 82; text: "mode"
            color: Theme.colorTextDim; font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
        }
        TerminalButton {
            id: btnColor; controller: capFocus
            x: root.ctlX; y: 70; width: 220; height: root.btnH
            label: "[color  r/g/b/c]"; active: Motor.colorMode === 0; onClicked: Motor.colorMode = 0
        }
        TerminalButton {
            id: btnBw; controller: capFocus
            x: 342; y: 70; width: 180; height: root.btnH
            label: "[bw  single]"; active: Motor.colorMode === 1; onClicked: Motor.colorMode = 1
        }

        Text {
            x: root.labelX; y: 140
            text: Motor.colorMode === 0
                  ? "motor stationary — 4-pass r/g/b/c filter wheel sequence"
                  : "motor stationary — single pass, no filter"
            color: Theme.colorTextFaint
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
        }

        TerminalButton {
            id: btnStaticCapture; controller: capFocus
            x: 614; y: 202; width: 300; height: root.btnH
            label: "[capture]"
            onClicked: console.log("static capture mode=" + Motor.colorMode + " — TODO")
        }
    }

    // ── [back] ────────────────────────────────────────────────────────────────
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
