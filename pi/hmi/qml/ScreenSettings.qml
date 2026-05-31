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

    // ── Title ─────────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: Theme.titleY
        text:  "settings"
        color: Theme.colorText
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }

    Hairline { x: 0; y: Theme.hairlineTopY; width: 960 }

    // ── Category rows ───────────────────────────────────────────────────────────
    NavRow {
        id: rowNetwork
        controller: setFocus
        x: Theme.marginX; y: Theme.contentTop; width: Theme.contentW
        rowName: "network";       rowDesc: "wifi · ip · server · clearcore link"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenNetwork.qml"))
    }
    NavRow {
        id: rowCamera
        controller: setFocus
        x: Theme.marginX; y: Theme.contentTop + Theme.rowStride; width: Theme.contentW
        rowName: "camera";        rowDesc: "line rate · tdi · exposure · gain"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenCamera.qml"))
    }
    NavRow {
        id: rowAxis
        controller: setFocus
        x: Theme.marginX; y: Theme.contentTop + Theme.rowStride * 2; width: Theme.contentW
        rowName: "axis / motion"; rowDesc: "gear · speed · accel · homing"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenAxis.qml"))
    }
    NavRow {
        id: rowCalibration
        controller: setFocus
        x: Theme.marginX; y: Theme.contentTop + Theme.rowStride * 3; width: Theme.contentW
        rowName: "calibration";   rowDesc: "homing offset · zero · touch"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenCalibration.qml"))
    }
    NavRow {
        id: rowDisplay
        controller: setFocus
        x: Theme.marginX; y: Theme.contentTop + Theme.rowStride * 4; width: Theme.contentW
        rowName: "display";       rowDesc: "brightness · blanking"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenDisplay.qml"))
    }
    NavRow {
        id: rowSystem
        controller: setFocus
        x: Theme.marginX; y: Theme.contentTop + Theme.rowStride * 5; width: Theme.contentW
        rowName: "system";        rowDesc: "firmware · platform"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenSystem.qml"))
    }

    // ── Bottom bar — [back] ──────────────────────────────────────────────────────
    Hairline { x: 0; y: Theme.bottomBarY; width: 960 }

    TerminalButton {
        id: backBtn
        controller: setFocus
        x: Theme.marginX
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: Theme.bottomBtnW; height: Theme.bottomBtnH
        label:  "[back]"
        active: false
        onClicked: root.StackView.view.pop()
    }
}
