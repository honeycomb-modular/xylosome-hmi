// FaultChip.qml — drive-fault surface for the secondary (26 px) tier.
//
// A faulted drive silently swallows every motion command, so without this the
// pendant just goes dead and [execute] does nothing visible. Present only while
// the drive is actually faulted, and only then does it take a focus stop.
//
// The drive reports 0xFF00 for every vendor alarm, so the text points at the
// drive's own display rather than pretending the hex means something.

import QtQuick
import XylosomeHMI 1.0

Row {
    id: chip

    property var controller: null

    readonly property bool faulted: Beckhoff.connected && Beckhoff.state === "fault"
    readonly property var  focusTargets: chip.faulted ? [bClear] : []

    visible: chip.faulted
    spacing: 8

    Text {
        anchors.verticalCenter: parent.verticalCenter
        text:  Beckhoff.faultText + " — alarm no. on the drive panel"
        color: Theme.danger
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    TerminalButton {
        id: bClear; controller: chip.controller
        width: 116; height: 26; fontSize: Theme.fontMonoS
        label: "[clear fault]"
        textColor:   Theme.danger
        borderColor: focused ? Theme.accent : Theme.danger
        onClicked: Beckhoff.faultReset()
    }
}
