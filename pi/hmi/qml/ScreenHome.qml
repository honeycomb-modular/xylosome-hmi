// ScreenHome.qml — XYLOSOME navigation menu.
// Pure routing screen: just the choices of next pages (with their sub-menu
// hints) and a [back] button. No title, no numbering, no status footer —
// styled to feel coherent with ScreenScan.
//
// Accessed from ScreenScan via the [settings] button.

import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root
    width: 960; height: 540

    // ── Touch-free focus ────────────────────────────────────────────────────────
    // Encoder/keyboard moves the cursor through the choices and the [back] button;
    // enter activates; back also returns to the previous screen.
    property var focusController: homeFocus
    function focusBack() { root.StackView.view.pop() }

    FocusController {
        id: homeFocus
        targets: [navCapture, navPresets, navDevices, navSettings, navMetadata, backBtn]
        onActivated: function(item) { item.clicked() }
    }

    FocusIndicator { target: homeFocus.current }

    // ── Choices ─────────────────────────────────────────────────────────────────
    // 5 rows, stride 64 px, vertically balanced above the bottom bar.

    NavRow {
        id: navCapture
        x: 30; y: 96; width: 900
        rowNum: ""; rowName: "capture modes";      rowDesc: "jog · static · program scan"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenCapture.qml"))
    }
    NavRow {
        id: navPresets
        x: 30; y: 160; width: 900
        rowNum: ""; rowName: "presets";            rowDesc: "saved capture configurations"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenPresets.qml"))
    }
    NavRow {
        id: navDevices
        x: 30; y: 224; width: 900
        rowNum: ""; rowName: "connected devices";  rowDesc: "clearcore · teensy · camera"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenDevices.qml"))
    }
    NavRow {
        id: navSettings
        x: 30; y: 288; width: 900
        rowNum: ""; rowName: "settings";           rowDesc: "network, calibration, camera, axis"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenSettings.qml"))
    }
    NavRow {
        id: navMetadata
        x: 30; y: 352; width: 900
        rowNum: ""; rowName: "metadata";           rowDesc: "trigger recorder — svg export"
        onClicked: root.StackView.view.push(Qt.resolvedUrl("ScreenMetadata.qml"))
    }

    // ── Bottom bar — [back], ScreenScan style ────────────────────────────────────

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
