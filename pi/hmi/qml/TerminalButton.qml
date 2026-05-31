// TerminalButton.qml — flat dark button with optional "active" accent state.
// Port of terminal_button() in src/ui/screen_live.cpp.
//
// Usage:
//   TerminalButton {
//       x: 30; y: 264; width: 130; height: 40
//       label:   "[enable]"
//       active:  Motor.enabled
//       onClicked: Motor.toggleEnabled()
//   }

import QtQuick
import XylosomeHMI 1.0

Rectangle {
    id: root

    property string label:       "button"
    // Two orthogonal signals so they never read as the same thing:
    //   active   = selected / on  → solid (dim) accent FILL
    //   focused  = cursor is here → bright accent BORDER (2 px)
    property bool   active:      false
    property var    controller:  null
    readonly property bool focused: controller ? controller.current === root : false
    property color  fillColor:   active  ? Theme.accentDim : Theme.panel
    property color  borderColor: focused ? Theme.accent    : Theme.border
    property color  textColor:   Theme.colorText
    property int    fontSize:    Theme.fontBody

    signal clicked()

    width:  146
    height: 45

    color:         fillColor
    border.color:  borderColor
    border.width:  focused ? 2 : 1
    radius:        2

    Text {
        anchors.centerIn: parent
        text:  root.label
        color: root.textColor
        font { family: Theme.fontFamily; pixelSize: root.fontSize }
    }

    MouseArea {
        anchors.fill: parent
        onClicked:    root.clicked()
    }
}
