// ScreenHome.qml — XYLOSOME navigation menu.
// Pure routing screen: the choices (with sub-menu hints) and a [back] button.
// Uses the shared grid + focus vocabulary (NavRow / TerminalButton).

import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root
    width: 960; height: 540

    property var focusController: homeFocus
    function focusBack() { root.StackView.view.pop() }

    FocusController {
        id: homeFocus
        targets: [navCapture, navPresets, navDevices, navSettings, navMetadata, backBtn]
        onActivated: function(item) { item.clicked() }
    }

    // ── Choices ─────────────────────────────────────────────────────────────────
    NavRow {
        id: navCapture
        controller: homeFocus
        x: Theme.marginX; y: Theme.contentTop; width: Theme.contentW
        rowName: "capture modes";     rowDesc: "jog · static · program scan"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenCapture.qml"))
    }
    NavRow {
        id: navPresets
        controller: homeFocus
        x: Theme.marginX; y: Theme.contentTop + Theme.rowStride; width: Theme.contentW
        rowName: "presets";           rowDesc: "saved capture configurations"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenPresets.qml"))
    }
    NavRow {
        id: navDevices
        controller: homeFocus
        x: Theme.marginX; y: Theme.contentTop + Theme.rowStride * 2; width: Theme.contentW
        rowName: "connected devices"; rowDesc: "clearcore · teensy · camera"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenDevices.qml"))
    }
    NavRow {
        id: navSettings
        controller: homeFocus
        x: Theme.marginX; y: Theme.contentTop + Theme.rowStride * 3; width: Theme.contentW
        rowName: "settings";          rowDesc: "network, calibration, camera, axis"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenSettings.qml"))
    }
    NavRow {
        id: navMetadata
        controller: homeFocus
        x: Theme.marginX; y: Theme.contentTop + Theme.rowStride * 4; width: Theme.contentW
        rowName: "metadata";          rowDesc: "trigger recorder — svg export"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenMetadata.qml"))
    }

    // ── Bottom bar — [back] ───────────────────────────────────────────────────────
    Hairline { x: 0; y: Theme.bottomBarY; width: 960 }

    TerminalButton {
        id: backBtn
        controller: homeFocus
        x: Theme.marginX
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: Theme.bottomBtnW; height: Theme.bottomBtnH
        label:  "[back]"
        active: false
        onClicked: root.StackView.view.pop()
    }
}
