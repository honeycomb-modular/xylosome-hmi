// ScreenSettings.qml — config-file aesthetic settings screen.
// Port of src/ui/screen_settings.cpp.
//
// Layout (960×540 @ scale 2, all coordinates scaled ×1.125 from 854×480 original):
//   brightness   = 255 / 255   ●━━━━━━━━━━━
//   wifi.mode    = access point
//   ...
//
// Note: display brightness is a no-op on Pi (no backlight PWM API in Qt).
// The slider is preserved for visual fidelity; hook it to a DBus call if needed.

import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root
    width: 960; height: 540

    // ── Touch-free focus ────────────────────────────────────────────────────────
    // Two focusable controls: brightness (enter → rotate adjusts the value) and
    // the fw.version row (enter → plays the easter-egg clip). Back returns to menu.
    property var focusController: setFocus
    function focusBack() { root.StackView.view.pop() }

    FocusController {
        id: setFocus
        targets: [brightnessFocus, fwVersionFocus]
        onActivated: function(item) {
            if (item === brightnessFocus) setFocus.editing = true
            else if (item === fwVersionFocus)
                Motor.playVideo("/home/hoyte/TheOdyssey_IMAX-Trailer-3_4K_51_prores.mp4")
        }
        onAdjust: function(delta) {
            var b = Math.max(20, Math.min(255, root.brightness + delta * 5))
            root.brightness = b
            brightnessSlider.value = b
        }
        onConfirmed: setFocus.editing = false
        onCanceled:  setFocus.editing = false
    }

    FocusIndicator { target: setFocus.current }

    // Invisible focus regions (no MouseArea → touch passes through to widgets).
    Item { id: brightnessFocus; x: 9;  y: 93;  width: 942; height: 26 }
    Item { id: fwVersionFocus;  x: 9;  y: 335; width: 788; height: 29 }

    // ── Header ────────────────────────────────────────────────────────────────

    BackButton { x: 18; y: 16 }

    Text {
        x: 124; y: 25
        text:  "settings"
        color: Theme.colorText
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }

    Text {
        anchors { right: parent.right; rightMargin: 9; top: parent.top; topMargin: 29 }
        text:  "// device.config"
        color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }

    Hairline { x: 9; y: 63; width: 942 }

    // ── Helpers ───────────────────────────────────────────────────────────────

    // Build a "  key  =  value" config line.
    // Returns the value Text so callers can update it later.
    component KvLine: Item {
        id: kvRoot
        property string key_:   "key"
        property string value_: "value"
        property color  vColor: Theme.colorText

        x: 56; height: 29

        Text {
            text:  kvRoot.key_
            color: Theme.colorTextDim
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            anchors.left:           parent.left
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            text:  "="
            color: Theme.colorTextFaint
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            anchors.left:           parent.left
            anchors.leftMargin:     191
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            id: valueText
            text:  kvRoot.value_
            color: kvRoot.vColor
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            anchors.left:           parent.left
            anchors.leftMargin:     225
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    // ── Brightness row ────────────────────────────────────────────────────────

    property int brightness: 255

    Text {
        x: 9; y: 95
        text:  "  brightness"
        color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }
    Text {
        x: 248; y: 95
        text:  "="
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }
    Text {
        id: brightnessValue
        x: 281; y: 95
        text:  root.brightness + " / 255"
        color: Theme.accent
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }

    Slider {
        id: brightnessSlider
        x: 394; y: 101
        width: 557; height: 11

        from: 20; to: 255; value: 255

        onMoved: root.brightness = Math.round(value)

        background: Rectangle {
            x: brightnessSlider.leftPadding
            y: brightnessSlider.topPadding + brightnessSlider.availableHeight / 2 - height / 2
            width:  brightnessSlider.availableWidth
            height: 11
            color:  Theme.panel
            border.color: Theme.border
            border.width: 1
            radius: 1
            Rectangle {
                width:  brightnessSlider.visualPosition * parent.width
                height: parent.height
                color:  Theme.accentDim
                radius: 1
            }
        }

        handle: Rectangle {
            x:      brightnessSlider.leftPadding + brightnessSlider.visualPosition * (brightnessSlider.availableWidth - width)
            y:      brightnessSlider.topPadding  + brightnessSlider.availableHeight / 2 - height / 2
            width:  11; height: 20
            color:  Theme.accent
            radius: 1
        }
    }

    // ── Config lines ──────────────────────────────────────────────────────────

    KvLine { x: 9; y: 146; key_: "wifi.mode   "; value_: "access point";     vColor: Theme.colorText }
    KvLine { x: 9; y: 178; key_: "wifi.ssid   "; value_: "xylosome01";       vColor: Theme.colorText }
    KvLine { x: 9; y: 209; key_: "wifi.status "; value_: "not applicable";   vColor: Theme.colorTextDim }
    KvLine { x: 9; y: 241; key_: "server.port "; value_: ":8080";            vColor: Theme.accent }
    KvLine { x: 9; y: 272; key_: "uart.peer   "; value_: "teensy / 1 mbps";  vColor: Theme.colorTextDim }
    KvLine { x: 9; y: 304; key_: "motor.bus   "; value_: "can / rmd-x8";     vColor: Theme.colorTextDim }
    // ── Easter egg: tap fw.version to play the Odyssey trailer ──────────────
    KvLine {
        x: 9; y: 335
        key_:   "fw.version  "
        value_: "v0.1-qt"
        vColor: Theme.colorText
    }

    MouseArea {
        x: 9; y: 335; width: 788; height: 29
        onClicked: Motor.playVideo("/home/hoyte/TheOdyssey_IMAX-Trailer-3_4K_51_prores.mp4")
    }

    KvLine { x: 9; y: 367; key_: "fw.platform "; value_: "qt6 / qml / pi5"; vColor: Theme.colorText }

    Hairline { x: 9; y: 412; width: 942 }

    Text {
        x: 9; y: 428
        text:  "# tap a row to edit (TODO).  brightness slider is live."
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }

    // ── Footer ────────────────────────────────────────────────────────────────

    Hairline {
        anchors { bottom: parent.bottom; bottomMargin: 29; left: parent.left; leftMargin: 9 }
        width: 942
    }

    Text {
        anchors { bottom: parent.bottom; bottomMargin: 7; left: parent.left; leftMargin: 9 }
        text:  "settings.config — single source of truth"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamily; pixelSize: Theme.fontLabel }
    }
}
