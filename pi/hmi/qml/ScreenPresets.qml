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

    // ── Title ─────────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: Theme.titleY
        text:  "presets"
        color: Theme.colorText
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }

    // ── Empty state ─────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: Theme.contentTop
        text:  "// no presets saved"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }

    TerminalButton {
        id: newBtn
        controller: pFocus
        x: Theme.marginX; y: Theme.contentTop + Theme.rowStride
        width: 200; height: Theme.bottomBtnH
        label:  "[new preset]"
        active: false
        // Stub — capture-recipe save/load not yet implemented.
        onClicked: console.log("[presets] new preset — TODO (no storage yet)")
    }

    // ── [back] ────────────────────────────────────────────────────────────────
    TerminalButton {
        id: backBtn
        controller: pFocus
        x: Theme.marginX
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: Theme.bottomBtnW; height: Theme.bottomBtnH
        label:  "[back]"
        active: false
        onClicked: root.StackView.view.pop()
    }
}
