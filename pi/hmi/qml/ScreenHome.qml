// ScreenHome.qml — XYLOSOME navigation menu.
// Secondary screen — accessed from ScreenScan via the [menu] button.
//
// Layout (960×540 @ scale 2):
//   y=25   "XYLOSOME" heading
//   y=41   subtitle, version (right-aligned)
//   y=90   hairline
//   y=110  "select task" prompt
//   y=149  nav rows
//   y=484  hairline
//   y=515  footer text + clock

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
    // 5 rows, stride 57 px, starting at y=149.

    NavRow {
        x: 18; y: 149; width: 924
        rowNum: "01"; rowName: "capture modes";      rowDesc: "jog · static · program scan"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenCapture.qml"))
    }
    NavRow {
        x: 18; y: 206; width: 924
        rowNum: "02"; rowName: "presets";            rowDesc: "saved capture configurations"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenPlaceholder.qml"),
                                            { screenTitle: "presets" })
    }
    NavRow {
        x: 18; y: 263; width: 924
        rowNum: "03"; rowName: "connected devices";  rowDesc: "clearcore · teensy · camera"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenPlaceholder.qml"),
                                            { screenTitle: "connected devices" })
    }
    NavRow {
        x: 18; y: 320; width: 924
        rowNum: "04"; rowName: "settings";           rowDesc: "network, calibration, camera, axis"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenSettings.qml"))
    }
    NavRow {
        x: 18; y: 377; width: 924
        rowNum: "05"; rowName: "metadata";           rowDesc: "trigger recorder — svg export"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenMetadata.qml"))
    }

    // ── Footer ────────────────────────────────────────────────────────────────

    Hairline { x: 18; y: 462; width: 924 }

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
