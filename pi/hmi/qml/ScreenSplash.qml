// ScreenSplash.qml — kiosk startup screen.
// Logo appears immediately at full opacity (no fades).
// Navigates to ScreenHome after a short hold.

import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root

    Rectangle {
        anchors.fill: parent
        color: "#000000"
    }

    Image {
        anchors.fill: parent
        source: "qrc:/XylosomeHMI/HMLOGO.png"
        fillMode: Image.PreserveAspectFit
    }

    Timer {
        interval: 3000
        running: true
        onTriggered: root.StackView.view.replace("qrc:/XylosomeHMI/qml/ScreenSequences.qml")
    }
}
