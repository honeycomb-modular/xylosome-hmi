// ScreenPresets.qml — saved capture recipes.
// Each preset stores: color mode · arc (hand1/hand2) · aspect (boxW) · velocity curve (nodes).
// Saved via [save] on ScreenScan; loaded here; deleted with BTN1 (Delete key) while focused.

import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root
    width: 960; height: 540

    // ── Touch-free focus ────────────────────────────────────────────────────────
    property var focusController: pFocus
    function focusBack() { root.StackView.view.pop() }

    // BTN1 while a preset row is focused → delete that preset
    function btn1Execute() {
        var idx = pFocus.index
        if (Motor.presets.length === 0) return
        if (idx < Motor.presets.length) Motor.deletePreset(idx)
    }

    FocusController {
        id: pFocus
        onActivated: function(item) { item.clicked() }
    }

    function rebuildTargets() {
        var t = []
        for (var i = 0; i < presetRepeater.count; i++) {
            var it = presetRepeater.itemAt(i)
            if (it) t.push(it)
        }
        t.push(backBtn)
        pFocus.targets = t
    }

    // ── Title ─────────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: Theme.titleY
        text:  "presets"
        color: Theme.colorText
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }

    // ── Hint (shown when presets exist) ────────────────────────────────────────
    Text {
        anchors { right: parent.right; rightMargin: Theme.marginX }
        y: Theme.titleY
        visible: Motor.presets.length > 0
        text:  "enter = load  ·  btn1 = delete"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

    Hairline { x: 0; y: Theme.hairlineTopY; width: 960 }

    // ── Empty state ─────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: Theme.contentTop
        visible: Motor.presets.length === 0
        text:  "// no presets saved  —  use [save] on the main scan screen"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }

    // ── Preset list ─────────────────────────────────────────────────────────────
    Repeater {
        id: presetRepeater
        model: Motor.presets
        onItemAdded:   root.rebuildTargets()
        onItemRemoved: root.rebuildTargets()

        delegate: Item {
            id: rowItem
            readonly property bool focused: pFocus.current === rowItem

            x: Theme.marginX
            y: Theme.contentTop + index * Theme.rowStride
            width: Theme.contentW; height: Theme.rowHeight

            // Focus fill + left accent bar
            Rectangle {
                anchors.fill: parent
                color: Theme.accent; opacity: Theme.focusFillOpacity
                visible: rowItem.focused
            }
            Rectangle {
                anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                width: Theme.focusBarW; color: Theme.accent
                visible: rowItem.focused
            }

            // ">" lead
            Text {
                anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                text: rowItem.focused ? ">" : " "
                color: Theme.accent
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
            }

            // Preset name
            Text {
                anchors { left: parent.left; leftMargin: 42; verticalCenter: parent.verticalCenter }
                text:  modelData.name !== undefined ? modelData.name : ""
                color: Theme.colorText
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
            }

            // Mode + arc info (right column, matches NavRow desc position)
            Text {
                anchors { left: parent.left; leftMargin: 269; verticalCenter: parent.verticalCenter }
                text: {
                    var cm  = modelData.colorMode !== undefined ? modelData.colorMode : 0
                    var h1  = modelData.hand1Angle !== undefined ? modelData.hand1Angle : 0
                    var h2  = modelData.hand2Angle !== undefined ? modelData.hand2Angle : 0
                    var bw  = modelData.boxW !== undefined ? modelData.boxW : 0
                    var arc = Math.round(h2 - h1)
                    return (cm === 0 ? "color" : "bw") + "  " + arc + "°  " + bw + "px"
                }
                color: Theme.colorTextDim
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
            }

            // Touch + click = load preset + return to scan screen
            MouseArea {
                anchors.fill: parent
                onClicked: rowItem.clicked()
            }

            signal clicked()
            onClicked: {
                Motor.loadPreset(index)
                root.StackView.view.pop()
            }
        }
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
