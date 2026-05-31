// ScreenPresets.qml — saved capture recipes. No persistent storage yet, so the
// list is empty; [new preset] is a stub until the save/load system exists.

import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root
    width: 960; height: 540

    // ── Touch-free focus ────────────────────────────────────────────────────────
    property var focusController: pFocus
    function focusBack() { root.StackView.view.pop() }

    FocusController {
        id: pFocus
        targets: [newBtn, backBtn]
        onActivated: function(item) { item.clicked() }
    }

    FocusIndicator { target: pFocus.current }

    // ── Title ─────────────────────────────────────────────────────────────────
    Text {
        x: 18; y: 25
        text:  "presets"
        color: Theme.colorText
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }

    Hairline { x: 9; y: 63; width: 942 }

    // ── Empty state ─────────────────────────────────────────────────────────────
    Text {
        x: 30; y: 96
        text:  "// no presets saved"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }

    TerminalButton {
        id: newBtn
        x: 30; y: 140
        width: 200; height: 45
        label:  "[new preset]"
        active: false
        // Stub — capture-recipe save/load not yet implemented.
        onClicked: console.log("[presets] new preset — TODO (no storage yet)")
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
