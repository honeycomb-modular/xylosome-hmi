// ModeStrip.qml — the capture-mode row, in the secondary (100×26) tier.
//
// The four capture pages are SIBLINGS at one stack depth. Picking a mode
// replaces the current page instead of pushing, so nothing is ever "inside"
// another mode and the stack never deepens. It lives in the empty middle of
// the bottom bar, so it costs the composed area of a page nothing.
//
// Usage:
//   ModeStrip {
//       mode: "scan"; controller: myFocus
//       onSwitchTo: function(page) { root.StackView.view.replace(
//                       root.StackView.view.currentItem, Qt.resolvedUrl(page)) }
//   }
// and splice `strip.focusTargets` into the host screen's focus list.

import QtQuick
import XylosomeHMI 1.0

Row {
    id: strip

    property string mode: "scan"          // scan | timed | static | jog
    property var    controller: null

    readonly property var focusTargets: [bScan, bTimed, bStatic, bJog]

    signal switchTo(string page)

    spacing: 6

    TerminalButton {
        id: bScan; controller: strip.controller
        width: 76; height: 26; fontSize: Theme.fontMonoS
        label: "[scan]";   active: strip.mode === "scan"
        onClicked: if (strip.mode !== "scan") strip.switchTo("ScreenScan.qml")
    }
    TerminalButton {
        id: bTimed; controller: strip.controller
        width: 76; height: 26; fontSize: Theme.fontMonoS
        label: "[timed]";  active: strip.mode === "timed"
        onClicked: if (strip.mode !== "timed") strip.switchTo("ScreenTimed.qml")
    }
    TerminalButton {
        id: bStatic; controller: strip.controller
        width: 76; height: 26; fontSize: Theme.fontMonoS
        label: "[static]"; active: strip.mode === "static"
        onClicked: if (strip.mode !== "static") strip.switchTo("ScreenStatic.qml")
    }
    TerminalButton {
        id: bJog; controller: strip.controller
        width: 76; height: 26; fontSize: Theme.fontMonoS
        label: "[jog]";    active: strip.mode === "jog"
        onClicked: if (strip.mode !== "jog") strip.switchTo("ScreenJog.qml")
    }
}
