// NavRow.qml — one clickable navigation row on the home screen.
// Port of make_row() in src/ui/screen_home.cpp.
//
// Usage (in ScreenHome.qml):
//   NavRow {
//       x: 30; y: 132; width: 740
//       rowNum: "01"; rowName: "live"; rowDesc: "position / velocity / torque"
//       onClicked: StackView.view.push(Qt.resolvedUrl("ScreenLive.qml"))
//   }

import QtQuick
import XylosomeHMI 1.0

Item {
    id: root

    // ── Public API ────────────────────────────────────────────────────────────
    property string rowNum:  "00"
    property string rowName: "item"
    property string rowDesc: ""

    signal clicked()

    // ── Dimensions (match LVGL: 740 × 32) ────────────────────────────────────
    height: 36

    // ── Pressed state ─────────────────────────────────────────────────────────
    property bool _pressed: false
    property bool selected: false

    // ── ">" indicator — appears on press ─────────────────────────────────────
    Text {
        id: lead
        anchors {
            left:           parent.left
            verticalCenter: parent.verticalCenter
        }
        text:  (root._pressed || root.selected) ? "> " : "  "
        color: Theme.accent
        font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
    }

    // ── Row number  (faint, fixed position) ──────────────────────────────────
    Text {
        anchors {
            left:           parent.left
            leftMargin:     32
            verticalCenter: parent.verticalCenter
        }
        text:  root.rowNum
        color: Theme.colorTextFaint
        font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
    }

    // ── Row name ──────────────────────────────────────────────────────────────
    Text {
        anchors {
            left:           parent.left
            leftMargin:     79
            verticalCenter: parent.verticalCenter
        }
        text:  root.rowName
        color: Theme.colorText
        font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
    }

    // ── Description ───────────────────────────────────────────────────────────
    Text {
        anchors {
            left:           parent.left
            leftMargin:     259
            verticalCenter: parent.verticalCenter
        }
        text:  root.rowDesc
        color: Theme.colorTextDim
        font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
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
