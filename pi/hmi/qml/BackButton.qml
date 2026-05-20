// BackButton.qml — terminal-style "../" back affordance in the top-left.
// Port of add_back_button() / on_back_clicked() in src/ui/ui.cpp.
//
// Usage (inside any non-home screen):
//   BackButton {
//       x: 16; y: 14
//       // pops the StackView automatically via StackView.view.pop()
//   }

import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Rectangle {
    id: root

    width:  90
    height: 36

    color:        Theme.panel
    border.color: Theme.border
    border.width: 1
    radius:       2

    Text {
        anchors.centerIn: parent
        text:  "../"
        color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }

    MouseArea {
        anchors.fill: parent
        // StackView.view is the enclosing StackView — available transitively.
        onClicked: root.parent.StackView.view.pop()
    }
}
