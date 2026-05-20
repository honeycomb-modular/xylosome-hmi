// ScreenLive.qml — live motor control surface.
// Port of src/ui/screen_live.cpp.
//
// All mutations go through Motor (the QML singleton); this screen is a
// pure view + input layer, exactly as in the original.
//
// Refresh rate: QML bindings update on every Motor signal emission (10 Hz).
// The slider and dropdown sync with Motor state when not being dragged,
// mirroring the LVGL guard on LV_STATE_PRESSED.
//
// Layout: 960×540 @ scale 2 (scaled ×1.125 from 854×480 original).

import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root
    width: 960; height: 540

    // ── Header ────────────────────────────────────────────────────────────────

    BackButton { x: 18; y: 16 }

    Text {
        x: 124; y: 25
        text:  "live.control"
        color: Theme.colorText
        font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
    }

    Text {
        anchors { right: parent.right; rightMargin: 9; top: parent.top; topMargin: 29 }
        text:  "// motor control surface"
        color: Theme.colorTextDim
        font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
    }

    Hairline { x: 9; y: 63; width: 942 }

    // ── Mode selector ─────────────────────────────────────────────────────────

    Text {
        x: 9; y: 88
        text:  "mode"
        color: Theme.colorTextDim
        font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
    }

    ComboBox {
        id: modeCombo
        x: 77; y: 79
        width: 248; height: 41

        model: ["position", "velocity", "torque"]

        // Sync with Motor when not being interacted with.
        property bool _settling: false
        Binding on currentIndex {
            when:  !modeCombo.pressed
            value: Motor.mode
        }

        onActivated: Motor.mode = currentIndex

        contentItem: Text {
            leftPadding:  8
            text:         modeCombo.displayText
            color:        Theme.colorText
            font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
            verticalAlignment: Text.AlignVCenter
        }

        background: Rectangle {
            color:        Theme.panel
            border.color: Theme.border
            border.width: 1
            radius:       2
        }

        // Style the popup list.
        popup: Popup {
            y:      modeCombo.height
            width:  modeCombo.width
            padding: 0

            contentItem: ListView {
                implicitHeight: contentHeight
                model: modeCombo.delegateModel
                clip:  true
            }

            background: Rectangle {
                color:        Theme.panel
                border.color: Theme.border
                border.width: 1
                radius:       2
            }
        }

        delegate: ItemDelegate {
            width: modeCombo.width
            contentItem: Text {
                text:  modelData
                color: Theme.colorText
                font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
                verticalAlignment: Text.AlignVCenter
                leftPadding: 8
            }
            background: Rectangle {
                color: hovered ? Theme.border : Theme.panel
            }
        }
    }

    Text {
        x: 360; y: 88
        text: {
            switch (Motor.mode) {
                case 0: return "position [deg]"
                case 1: return "velocity [deg/s]"
                case 2: return "torque   [Nm]"
                default: return ""
            }
        }
        color: Theme.colorTextFaint
        font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
    }

    // ── Setpoint ──────────────────────────────────────────────────────────────

    Text {
        x: 9; y: 146
        text:  "setpoint"
        color: Theme.colorTextDim
        font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
    }

    Text {
        x: 9; y: 169
        text:  Motor.setpoint.toFixed(1).padStart(7)
        color: Theme.accent
        font { family: Theme.fontFamily; pixelSize: Theme.fontH1 }
    }

    // Slider — range -100 to +100 (maps to ±180° via ×1.8, matching ESP32).
    Slider {
        id: setpointSlider
        x: 9; y: 236
        width: 942; height: 14

        from:  -100
        to:     100
        stepSize: 1

        // Sync Motor → slider when not being dragged.
        Binding on value {
            when:  !setpointSlider.pressed
            value: Math.round(Motor.setpoint / 1.8)
        }

        onMoved: Motor.setpoint = value * 1.8

        background: Rectangle {
            x: setpointSlider.leftPadding
            y: setpointSlider.topPadding + setpointSlider.availableHeight / 2 - height / 2
            width:  setpointSlider.availableWidth
            height: 14
            color:  Theme.panel
            border.color: Theme.border
            border.width: 1
            radius: 1

            Rectangle {
                width:  setpointSlider.visualPosition * (setpointSlider.availableWidth - 50) + 25
                height: parent.height
                color:  Theme.accentDim
                radius: 1
            }
        }

        handle: Item {
            x:      setpointSlider.leftPadding + setpointSlider.visualPosition * (setpointSlider.availableWidth - width)
            y:      setpointSlider.topPadding  + setpointSlider.availableHeight / 2 - height / 2
            width:  50; height: 54   // touch zone

            Rectangle {
                anchors.centerIn: parent
                width:  14; height: 23   // visual handle
                color:  Theme.accent
                radius: 1
            }
        }
    }

    // Tick labels below slider.
    Text { x: 9;   y: 259; text: "-100"; color: Theme.colorTextFaint; font.family: Theme.fontFamily; font.pixelSize: Theme.fontBody }
    Text { x: 465; y: 259; text: "  0 "; color: Theme.colorTextFaint; font.family: Theme.fontFamily; font.pixelSize: Theme.fontBody }
    Text { x: 919; y: 259; text: "+100"; color: Theme.colorTextFaint; font.family: Theme.fontFamily; font.pixelSize: Theme.fontBody }

    // ── Action buttons ────────────────────────────────────────────────────────

    TerminalButton {
        x: 9; y: 297; width: 146; height: 45
        label:  "[enable]"
        active: Motor.enabled
        onClicked: Motor.toggleEnabled()
    }

    TerminalButton {
        x: 167; y: 297; width: 113; height: 45
        label:  "[zero]"
        onClicked: Motor.zero()
    }

    Text {
        x: 302; y: 308
        text:  Motor.enabled ? "[X] ENABLED " : "[ ] DISABLED"
        color: Motor.enabled ? Theme.accent : Theme.colorTextDim
        font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
    }

    // ── Telemetry ─────────────────────────────────────────────────────────────

    Hairline { x: 9; y: 367; width: 942 }

    Text {
        x: 9; y: 378
        text:  "telemetry"
        color: Theme.colorTextDim
        font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
    }

    LabelledValue { x: 9;   y: 405; label: "position"; value: Motor.position.toFixed(1).padStart(7); unit: "deg"   }
    LabelledValue { x: 248; y: 405; label: "velocity"; value: Motor.velocity.toFixed(1).padStart(7); unit: "deg/s" }
    LabelledValue { x: 486; y: 405; label: "current";  value: Motor.current.toFixed(2).padStart(7);  unit: "A"     }
    LabelledValue { x: 725; y: 405; label: "temp";     value: Motor.tempC.toFixed(1).padStart(7);    unit: "°C"    }

    // ── Footer ────────────────────────────────────────────────────────────────

    Hairline {
        anchors { bottom: parent.bottom; bottomMargin: 29; left: parent.left; leftMargin: 9 }
        width: 942
    }

    Text {
        anchors { bottom: parent.bottom; bottomMargin: 7; left: parent.left; leftMargin: 9 }
        text:  "shared state — touch ↔ web in sync"
        color: Theme.colorTextDim
        font { family: Theme.fontFamily; pixelSize: Theme.fontLabel }
    }
}
