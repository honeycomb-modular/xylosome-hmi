// ToggleChip — one clickable control with a clear selected state.
// The shared vocabulary for making keyboard actions visible (plan → Input):
//   idle   · muted text, no fill
//   hover  · faint fill
//   active · solid fill (activeColor) + contrasting text
// activeColor lets channel controls fill with their own R/G/B/C; mode
// toggles fill ink-dark. No easing — the design eases image events only.

import QtQuick
import QtQuick.Controls

Rectangle {
    id: chip

    property alias text: label.text
    property bool active: false
    property color activeColor: "#1A1A1A"   // fill when selected (ink by default)
    property color activeText: "#FFFFFF"
    property color idleText: "#666666"      // inkMuted
    property color hoverColor: "#F2F2F2"    // faint fill on white chrome
    property int fontPx: 11
    property real letterSpacing: 0
    property int hpad: 10
    property int minWidth: 0
    signal clicked()

    implicitWidth: Math.max(minWidth, label.implicitWidth + hpad * 2)
    implicitHeight: 20
    color: active ? activeColor
         : mouse.containsMouse ? hoverColor : "transparent"

    Label {
        id: label
        anchors.centerIn: parent
        color: chip.active ? chip.activeText : chip.idleText
        font.pixelSize: chip.fontPx
        font.letterSpacing: chip.letterSpacing
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: chip.clicked()
    }
}
