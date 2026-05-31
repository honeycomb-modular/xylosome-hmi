// ScreenSettings.qml — settings submenu. Routes to the per-category pages.
// Each row pushes a sub-page; styled coherently with the rest of the HMI.

import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root
    width: 960; height: 540

    // ── Touch-free focus ────────────────────────────────────────────────────────
    property var focusController: setFocus
    function focusBack() { root.StackView.view.pop() }

    FocusController {
        id: setFocus
        targets: [rowNetwork, rowCamera, rowAxis, rowCalibration, rowDisplay, rowSystem, backBtn]
        onActivated: function(item) { item.clicked() }
    }

    FocusIndicator { target: setFocus.current }

    // ── Title ─────────────────────────────────────────────────────────────────
    Text {
        x: 18; y: 25
        text:  "settings"
        color: Theme.colorText
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }

    Hairline { x: 9; y: 63; width: 942 }

    // ── Category rows ───────────────────────────────────────────────────────────
    NavRow {
        id: rowNetwork
        x: 30; y: 88; width: 900
        rowNum: ""; rowName: "network";       rowDesc: "wifi · ip · server · clearcore link"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenNetwork.qml"))
    }
    NavRow {
        id: rowCamera
        x: 30; y: 140; width: 900
        rowNum: ""; rowName: "camera";        rowDesc: "line rate · tdi · exposure · gain"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenCamera.qml"))
    }
    NavRow {
        id: rowAxis
        x: 30; y: 192; width: 900
        rowNum: ""; rowName: "axis / motion"; rowDesc: "gear · speed · accel · homing"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenAxis.qml"))
    }
    NavRow {
        id: rowCalibration
        x: 30; y: 244; width: 900
        rowNum: ""; rowName: "calibration";   rowDesc: "homing offset · zero · touch"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenCalibration.qml"))
    }
    NavRow {
        id: rowDisplay
        x: 30; y: 296; width: 900
        rowNum: ""; rowName: "display";       rowDesc: "brightness · blanking"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenDisplay.qml"))
    }
    NavRow {
        id: rowSystem
        x: 30; y: 348; width: 900
        rowNum: ""; rowName: "system";        rowDesc: "firmware · platform"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenSystem.qml"))
    }

    // ── Bottom bar — [back] ──────────────────────────────────────────────────────
    Hairline { x: 0; y: 462; width: 960 }

    TerminalButton {
        id: backBtn
        x: 18
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: 130; height: 45
        label:  "[back]"
        active: false
        onClicked: root.StackView.view.pop()
    }
}
