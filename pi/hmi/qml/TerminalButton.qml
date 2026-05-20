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
    property bool   active:      false   // shows accent border + text when true
    property color  borderColor: active ? Theme.accent : Theme.border
    property color  textColor:   active ? Theme.accent : Theme.colorText
    property int    fontSize:    Theme.fontBody

    signal clicked()

    width:  146
    height: 45

    color:         Theme.panel
    border.color:  borderColor
    border.width:  1
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
