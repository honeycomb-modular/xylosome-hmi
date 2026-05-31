// ChoiceList.qml — reusable titled, focus-navigable settings/status screen.
//
// A list of "key = value" rows plus a bottom [back] button, fully consistent
// with the rest of the HMI (encoder/cursor navigation, corner-bracket focus).
//
// Rows whose entry has an `options` array cycle to the next option on enter.
// Rows without options are read-only (still focusable, so the cursor can scroll
// past them). Sub-pages declare data only:
//
//   ChoiceList {
//       title: "network"
//       entries: [
//           { key: "wifi.mode", value: "access point", options: ["access point","client","off"] },
//           { key: "ip.addr",   value: "192.168.10.2" }   // read-only
//       ]
//   }
//
// `rowActivated(index)` fires on enter for any row — sub-pages connect to it for
// special actions (e.g. the firmware easter egg).

import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root
    width: 960; height: 540

    property string title:   ""
    property var    entries: []          // [{ key, value, options? }]

    signal rowActivated(int index)

    // Exposed to the main.qml key router.
    property var focusController: listFocus
    function focusBack() { root.StackView.view.pop() }

    FocusController {
        id: listFocus
        onActivated: function(item) {
            if (item === backBtn) { backBtn.clicked(); return }
            var idx = (item && item.rowIndex !== undefined) ? item.rowIndex : -1
            if (idx < 0) return
            // Cycle the value if this row has options.
            var optsJson = rowModel.get(idx).optsJson
            if (optsJson && optsJson.length > 0) {
                var opts = JSON.parse(optsJson)
                var cur  = opts.indexOf(rowModel.get(idx).value)
                rowModel.setProperty(idx, "value", opts[(cur + 1) % opts.length])
            }
            root.rowActivated(idx)
        }
    }

    ListModel { id: rowModel }

    function rebuildTargets() {
        var t = []
        for (var j = 0; j < rowRepeater.count; j++) {
            var it = rowRepeater.itemAt(j)
            if (it) t.push(it)
        }
        t.push(backBtn)
        listFocus.targets = t
    }

    Component.onCompleted: {
        for (var i = 0; i < entries.length; i++) {
            var e = entries[i]
            rowModel.append({
                key:      e.key !== undefined ? e.key : "",
                value:    e.value !== undefined ? e.value : "",
                optsJson: e.options ? JSON.stringify(e.options) : ""
            })
        }
        rebuildTargets()
    }

    // ── Title ─────────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: Theme.titleY
        text:  root.title
        color: Theme.colorText
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }

    Hairline { x: 0; y: Theme.hairlineTopY; width: 960 }

    // ── Rows ──────────────────────────────────────────────────────────────────
    Repeater {
        id: rowRepeater
        model: rowModel
        onItemAdded:   root.rebuildTargets()
        onItemRemoved: root.rebuildTargets()

        delegate: Item {
            id: rowItem
            property int rowIndex: index
            readonly property bool editable: model.optsJson !== ""
            readonly property bool focused:  listFocus.current === rowItem

            x: Theme.marginX
            y: Theme.contentTop + index * Theme.rowStride
            width: Theme.contentW; height: Theme.rowHeight

            // Unified focus treatment (matches NavRow).
            Rectangle {
                anchors.fill: parent
                color:   Theme.accent
                opacity: rowItem.focused ? Theme.focusFillOpacity : 0
                visible: rowItem.focused
            }
            Rectangle {
                anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                width:   Theme.focusBarW
                color:   Theme.accent
                visible: rowItem.focused
            }

            Text {
                anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                text:  model.key
                color: Theme.colorTextDim
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
            Text {
                anchors { left: parent.left; leftMargin: 288; verticalCenter: parent.verticalCenter }
                text:  "="
                color: Theme.colorTextFaint
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
            Text {
                anchors { left: parent.left; leftMargin: 322; verticalCenter: parent.verticalCenter }
                text:  model.value
                color: rowItem.editable ? Theme.accent : Theme.colorTextDim
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
        }
    }

    // ── Bottom bar — [back] ──────────────────────────────────────────────────────
    Hairline { x: 0; y: Theme.bottomBarY; width: 960 }

    TerminalButton {
        id: backBtn
        controller: listFocus
        x: Theme.marginX
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: Theme.bottomBtnW; height: Theme.bottomBtnH
        label:  "[back]"
        active: false
        onClicked: root.StackView.view.pop()
    }
}
