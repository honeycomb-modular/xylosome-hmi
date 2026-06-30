// ChoiceList.qml — reusable titled, focus-navigable settings/status screen.
//
// A list of "key = value" rows plus a bottom [back] button, fully consistent
// with the rest of the HMI (encoder/cursor navigation, corner-bracket focus).
//
// Rows whose entry has an `options` array cycle to the next option on enter.
// Rows with a numeric `step` are RANGE rows: enter puts the row into editing
// mode, the dial scrubs the value ±step (clamped to min..max), click commits and
// back cancels (reverts). Rows without either are read-only (still focusable, so
// the cursor can scroll past them). Sub-pages declare data only:
//
//   ChoiceList {
//       title: "network"
//       entries: [
//           { key: "wifi.mode", value: "access point", options: ["access point","client","off"] },
//           { key: "line.rate", value: "8500", min: 3500, max: 68610, step: 10, unit: "Hz" },
//           { key: "ip.addr",   value: "192.168.10.2" }   // read-only
//       ]
//   }
//
// `rowActivated(index)` fires on enter for an options/read-only row, and on
// COMMIT (click) for a range row — sub-pages connect to it to push the value
// (or for special actions, e.g. the firmware easter egg).

import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root
    width: 960; height: 540

    property string title:   ""
    property var    entries: []          // [{ key, value, options? }]

    signal rowActivated(int index)

    // Current displayed value of a row (after option cycling) — lets a sub-page
    // persist the choice it made.
    function rowValue(i) { return (i >= 0 && i < rowModel.count) ? rowModel.get(i).value : "" }
    // Key of a row — lets a sub-page tell which row was activated.
    function rowKey(i)   { return (i >= 0 && i < rowModel.count) ? rowModel.get(i).key : "" }

    // Exposed to the main.qml key router.
    property var focusController: listFocus
    function focusBack() { root.StackView.view.pop() }

    // Index of the range row currently being scrubbed (−1 = not editing), and
    // the value it held on entry so back() can revert.
    property int  editIndex: -1
    property real editStart: 0

    FocusController {
        id: listFocus
        onActivated: function(item) {
            if (item === backBtn) { backBtn.clicked(); return }
            var idx = (item && item.rowIndex !== undefined) ? item.rowIndex : -1
            if (idx < 0) return
            // Range row → enter editing; the dial scrubs, click commits.
            if (rowModel.get(idx).step > 0) {
                root.editIndex = idx
                root.editStart = parseFloat(rowModel.get(idx).value)
                listFocus.editing = true
                return
            }
            // Cycle the value if this row has options.
            var optsJson = rowModel.get(idx).optsJson
            if (optsJson && optsJson.length > 0) {
                var opts = JSON.parse(optsJson)
                var cur  = opts.indexOf(rowModel.get(idx).value)
                rowModel.setProperty(idx, "value", opts[(cur + 1) % opts.length])
            }
            root.rowActivated(idx)
        }
        // Scrub the value of the row being edited, clamped to its range.
        onAdjust: function(delta) {
            if (root.editIndex < 0) return
            var r = rowModel.get(root.editIndex)
            var v = parseFloat(r.value) + delta * r.step
            v = Math.max(r.min, Math.min(r.max, Math.round(v / r.step) * r.step))
            rowModel.setProperty(root.editIndex, "value", "" + v)
        }
        // Click commits (host pushes the value); back reverts.
        onConfirmed: {
            if (root.editIndex < 0) return
            var i = root.editIndex
            root.editIndex = -1; listFocus.editing = false
            root.rowActivated(i)
        }
        onCanceled: {
            if (root.editIndex < 0) return
            rowModel.setProperty(root.editIndex, "value", "" + root.editStart)
            root.editIndex = -1; listFocus.editing = false
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
                optsJson: e.options ? JSON.stringify(e.options) : "",
                min:      e.min  !== undefined ? e.min  : 0,
                max:      e.max  !== undefined ? e.max  : 0,
                step:     e.step !== undefined ? e.step : 0,
                unit:     e.unit !== undefined ? e.unit : ""
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

    // ── Rows ──────────────────────────────────────────────────────────────────
    Repeater {
        id: rowRepeater
        model: rowModel
        onItemAdded:   root.rebuildTargets()
        onItemRemoved: root.rebuildTargets()

        delegate: Item {
            id: rowItem
            property int rowIndex: index
            readonly property bool editable: model.optsJson !== "" || model.step > 0
            readonly property bool focused:  listFocus.current === rowItem
            readonly property bool scrubbing: root.editIndex === index

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
                // While scrubbing, bracket the value so it reads as "live/dial-driven".
                text:  (rowItem.scrubbing ? "‹ " : "") + model.value
                       + (model.unit !== "" ? " " + model.unit : "")
                       + (rowItem.scrubbing ? " ›" : "")
                color: rowItem.editable ? Theme.accent : Theme.colorTextDim
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
            }
        }
    }

    // ── [back] ────────────────────────────────────────────────────────────────
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
