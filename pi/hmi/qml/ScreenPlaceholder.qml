// ScreenPlaceholder.qml — stub screen for screens not yet implemented.
// Port of src/ui/screen_placeholder.cpp.
// Used by: Presets (row 03), Telemetry (row 04).
//
// Pass the screen name via the StackView property injection:
//   StackView.view.push(Qt.resolvedUrl("ScreenPlaceholder.qml"),
//                       { screenTitle: "presets" })

import QtQuick
import XylosomeHMI 1.0

Item {
    id: root
    width: 960; height: 540

    // Injected by StackView when pushed with properties.
    property string screenTitle: "placeholder"

    // Nothing focusable here yet — back returns to the menu.
    function focusBack() { root.StackView.view.pop() }

    // ── Header ────────────────────────────────────────────────────────────────

    BackButton { x: 18; y: 16 }

    Text {
        x: 124; y: 25
        text:  root.screenTitle
        color: Theme.colorText
        font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
    }

    Text {
        anchors { right: parent.right; rightMargin: 9; top: parent.top; topMargin: 29 }
        text:  "// not yet implemented"
        color: Theme.colorTextDim
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

    // ── Footer ────────────────────────────────────────────────────────────────

    Hairline {
        anchors { bottom: parent.bottom; bottomMargin: 29; left: parent.left; leftMargin: 9 }
        width: 942
    }

    Text {
        anchors { bottom: parent.bottom; bottomMargin: 7; left: parent.left; leftMargin: 9 }
        text:  root.screenTitle + ".placeholder"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamily; pixelSize: Theme.fontLabel }
    }
}
