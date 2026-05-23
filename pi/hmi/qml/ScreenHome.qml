// ScreenHome.qml — XYLOSOME landing page.
// Port of src/ui/screen_home.cpp.
//
// Layout (960×540 @ scale 2, all coordinates scaled ×1.125 from 854×480 original):
//   y=25   "XYLOSOME" heading
//   y=41   subtitle, version (right-aligned)
//   y=90   hairline
//   y=110  "select task" prompt
//   y=149  nav rows (5 × stride ~43)
//   y=389  hairline
//   y=405  status block line 1
//   y=432  status block line 2
//   y=484  hairline
//   y=515  footer text + clock

import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root

    // ── Header ────────────────────────────────────────────────────────────────

    BackButton { x: 18; y: 16 }

    Text {
        x: 124; y: 25
        text:  "XYLOSOME"
        color: Theme.colorText
        font { family: Theme.fontFamily; pixelSize: Theme.fontH1; weight: Font.Medium }
    }

    Text {
        x: 300; y: 41
        text:  "temporal scanning unit"
        color: Theme.colorTextDim
        font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
    }

    Text {
        anchors { right: parent.right; rightMargin: 9; top: parent.top; topMargin: 34 }
        text:  "v0.1-qt"
        color: Theme.colorTextDim
        font { family: Theme.fontFamily; pixelSize: Theme.fontLabel }
    }

    Hairline { x: 18; y: 90; width: 924 }

    // ── Nav prompt ────────────────────────────────────────────────────────────

    Text {
        x: 18; y: 110
        text:  "select task"
        color: Theme.colorTextDim
        font { family: Theme.fontFamily; pixelSize: Theme.fontLabel }
    }

    // ── Navigation rows ───────────────────────────────────────────────────────
    // Stride 43 px, starting at y=149.  Scaled from 38 px stride at 480p.

    NavRow {
        x: 18; y: 149; width: 924
        rowNum: "01"; rowName: "live";      rowDesc: "position / velocity / torque"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenLive.qml"))
    }
    NavRow {
        x: 18; y: 191; width: 924
        rowNum: "02"; rowName: "sequences"; rowDesc: "saved motion programs"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenSequences.qml"))
    }
    NavRow {
        x: 18; y: 234; width: 924
        rowNum: "03"; rowName: "presets";   rowDesc: "quick go-to positions"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenPlaceholder.qml"),
                                            { screenTitle: "presets" })
    }
    NavRow {
        x: 18; y: 277; width: 924
        rowNum: "04"; rowName: "telemetry"; rowDesc: "real-time monitoring"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenPlaceholder.qml"),
                                            { screenTitle: "telemetry" })
    }
    NavRow {
        x: 18; y: 320; width: 924
        rowNum: "05"; rowName: "settings";  rowDesc: "brightness, network, calibration"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenSettings.qml"))
    }

    // ── Status block ──────────────────────────────────────────────────────────

    Hairline { x: 18; y: 389; width: 924 }

    // Row 1
    Text { x: 18;  y: 405; text: "device";        color: Theme.colorTextDim; font.family: Theme.fontFamily; font.pixelSize: Theme.fontBody }
    Text { x: 124; y: 405; text: "single-motor";  color: Theme.colorText;    font.family: Theme.fontFamily; font.pixelSize: Theme.fontBody }
    Text { x: 360; y: 405; text: "bus";            color: Theme.colorTextDim; font.family: Theme.fontFamily; font.pixelSize: Theme.fontBody }
    Text { x: 414; y: 405; text: "uart → teensy → can"; color: Theme.colorText; font.family: Theme.fontFamily; font.pixelSize: Theme.fontBody }

    // Row 2
    Text { x: 18;  y: 432; text: "motor";         color: Theme.colorTextDim; font.family: Theme.fontFamily; font.pixelSize: Theme.fontBody }
    Text { x: 124; y: 432; text: "rmd-x8";         color: Theme.colorText;    font.family: Theme.fontFamily; font.pixelSize: Theme.fontBody }
    Text { x: 360; y: 432; text: "net";            color: Theme.colorTextDim; font.family: Theme.fontFamily; font.pixelSize: Theme.fontBody }
    Text {
        id: netLabel
        x: 414; y: 432
        text:  "server :8080"
        color: Theme.colorText
        font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
    }

    // ── Footer ────────────────────────────────────────────────────────────────

    Hairline {
        anchors { bottom: parent.bottom; bottomMargin: 56; left: parent.left; leftMargin: 9 }
        width: 942
    }

    Text {
        id: footerText
        anchors { bottom: parent.bottom; bottomMargin: 25; left: parent.left; leftMargin: 9 }
        text:  "qt6 / qml    motor: rmd-x8    uart: teensy / 1 mbps    heap ok"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamily; pixelSize: Theme.fontLabel }
    }

    // Clock — right-aligned, updates every second.
    Text {
        id: clockLabel
        anchors { bottom: parent.bottom; bottomMargin: 25; right: parent.right; rightMargin: 9 }
        text:  Qt.formatTime(new Date(), "hh:mm:ss")
        color: Theme.colorTextFaint
        font { family: Theme.fontFamily; pixelSize: Theme.fontLabel }
    }

    Timer {
        interval: 1000
        running:  true
        repeat:   true
        onTriggered: clockLabel.text = Qt.formatTime(new Date(), "hh:mm:ss")
    }
}
