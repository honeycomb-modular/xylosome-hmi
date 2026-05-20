// main.qml — XYLOSOME HMI root window

import QtQuick
import QtQuick.Controls
import QtQuick.Window
import XylosomeHMI 1.0

ApplicationWindow {
    id: window

    // Hardcoded to exactly match the 960×540 logical canvas at scale 2.
    // Do NOT use Screen.width/height — Qt's binding can resolve fractionally,
    // leaving a 1px gap at the right edge when the canvas fills to root.width.
    width:  960
    height: 540

    visibility: Window.FullScreen
    flags:      Qt.FramelessWindowHint | Qt.Window

    visible: true
    title:   "XYLOSOME"
    color:   Theme.bg

    Connections {
        target: Motor
        function onSequencePlayingChanged() {
            var item = nav.currentItem
            if (item && typeof item.syncSequencePlaying === "function")
                item.syncSequencePlaying(Motor.sequencePlaying)
        }
        function onNodesChanged() {
            var item = nav.currentItem
            if (item && typeof item.syncNodes === "function")
                item.syncNodes(Motor.nodes)
        }
        function onSeqBoxWChanged() {
            var item = nav.currentItem
            if (item && typeof item.syncBoxW === "function")
                item.syncBoxW(Motor.seqBoxW)
        }
    }

    StackView {
        id: nav
        // Explicit size rather than anchors.fill — same reason as window dimensions above.
        x: 0; y: 0; width: 960; height: 540

        initialItem: "qrc:/XylosomeHMI/qml/ScreenSplash.qml"

        pushEnter: Transition {
            PropertyAnimation { property: "opacity"; from: 0; to: 1; duration: 200 }
        }
        pushExit: Transition {
            PropertyAnimation { property: "opacity"; from: 1; to: 0; duration: 200 }
        }
        popEnter: Transition {
            PropertyAnimation { property: "opacity"; from: 0; to: 1; duration: 200 }
        }
        popExit: Transition {
            PropertyAnimation { property: "opacity"; from: 1; to: 0; duration: 200 }
        }
    }
}
