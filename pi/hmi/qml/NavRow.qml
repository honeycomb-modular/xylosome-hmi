// NavRow.qml — one navigable list row.
// Unified focus treatment: when this row is the focus controller's current
// target it shows a left accent bar + faint fill + ">" lead. Same look on every
// list in the app.
//
// Usage:
//   NavRow {
//       x: Theme.marginX; width: Theme.contentW
//       controller: myFocusController
//       rowName: "network"; rowDesc: "wifi · ip"
//       onClicked: StackView.view.push(...)
//   }

import QtQuick
import XylosomeHMI 1.0

Item {
    id: root

    // ── Public API ────────────────────────────────────────────────────────────
    property string rowNum:  ""
    property string rowName: "item"
    property string rowDesc: ""
    property var    controller: null

    // Compact variant — the modes page puts every mode on one screen, which
    // does not fit at the standard row height.
    property int rowH:     Theme.rowHeight
    property int fontSize: Theme.fontBody

    // Greying uses Item.enabled, which also stops the MouseArea below: a row
    // with no page behind it cannot be clicked, not merely styled as if.

    signal clicked()

    height: rowH

    readonly property bool focused: controller ? controller.current === root : false
    property bool _pressed: false
    readonly property bool highlight: focused || _pressed

    // ── Focus fill + left accent bar ────────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        color:   Theme.accent
        opacity: root.focused ? Theme.focusFillOpacity : 0
        visible: root.focused
    }
    Rectangle {
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width:   Theme.focusBarW
        color:   Theme.accent
        visible: root.focused
    }

    // ── ">" lead ─────────────────────────────────────────────────────────────
    Text {
        anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
        text:  (root.enabled && root.highlight) ? ">" : " "
        color: Theme.accent
        font { family: Theme.fontFamilyMono; pixelSize: root.fontSize }
    }

    // ── Row number (faint) — hidden when empty ───────────────────────────────
    Text {
        visible: root.rowNum !== ""
        anchors { left: parent.left; leftMargin: 42; verticalCenter: parent.verticalCenter }
        text:  root.rowNum
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: root.fontSize }
    }

    // ── Row name ──────────────────────────────────────────────────────────────
    Text {
        anchors {
            left:           parent.left
            leftMargin:     root.rowNum !== "" ? 89 : 42
            verticalCenter: parent.verticalCenter
        }
        text:  root.rowName
        color: root.enabled ? Theme.colorText : Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: root.fontSize }
    }

    // ── Description ───────────────────────────────────────────────────────────
    Text {
        anchors { left: parent.left; leftMargin: 269; verticalCenter: parent.verticalCenter }
        text:  root.rowDesc
        color: root.enabled ? Theme.colorTextDim : Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: root.fontSize }
    }

    // ── Touch target ──────────────────────────────────────────────────────────
    MouseArea {
        anchors.fill: parent
        onPressed:  root._pressed = true
        onReleased: root._pressed = false
        onCanceled: root._pressed = false
        onClicked:  root.clicked()
    }
}
