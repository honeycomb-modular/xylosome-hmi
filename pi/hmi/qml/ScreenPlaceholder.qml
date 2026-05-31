// ScreenPlaceholder.qml — stub screen for screens not yet implemented.
// Port of src/ui/screen_placeholder.cpp.
// Used by: Presets (row 03), Telemetry (row 04).
//
// Pass the screen name via the StackView property injection:
//   StackView.view.push(Qt.resolvedUrl("ScreenPlaceholder.qml"),
//                       { screenTitle: "presets" })

import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root
    width: 960; height: 540

    // Injected by StackView when pushed with properties.
    property string screenTitle: "placeholder"

    // Touch-free focus — only the [back] button is focusable here.
    property var focusController: phFocus
    function focusBack() { root.StackView.view.pop() }

    FocusController {
        id: phFocus
        targets: [backBtn]
        onActivated: function(item) { item.clicked() }
    }

    FocusIndicator { target: phFocus.current }

    // ── Header ────────────────────────────────────────────────────────────────

    Text {
        x: 18; y: 25
        text:  root.screenTitle
        color: Theme.colorText
        font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
    }

    Hairline { x: 9; y: 63; width: 942 }

    // ── Body ──────────────────────────────────────────────────────────────────

    Text {
        anchors.centerIn: parent
        text:  root.screenTitle + "  —  coming soon"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamily; pixelSize: Theme.fontH2 }
    }

    // ── Bottom bar — [back] ─────────────────────────────────────────────────────

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
