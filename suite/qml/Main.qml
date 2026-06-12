// Xylosome Suite — main window.
// Phase 0: splash → empty main screen in the design language.
// Design decisions: docs/concept/review_suite_plan.md → "Design language".

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import XylosomeSuite.Link

ApplicationWindow {
    id: root
    visible: true
    width: 1280
    height: 800
    title: "Xylosome Suite"
    color: "#FFFFFF"

    // ── Design tokens ────────────────────────────────────────────────
    readonly property color ink: "#1A1A1A"
    readonly property color inkMuted: "#666666"
    readonly property color inkFaint: "#999999"
    readonly property color hairline: "#E8E8E8"
    readonly property color imageField: "#8A8A8A"
    readonly property color chR: "#E24B4A"
    readonly property color chG: "#1D9E75"
    readonly property color chB: "#378ADD"
    readonly property color chC: "#999999"
    readonly property int easeMs: 200

    function filterColor(name) {
        return name === "R" ? chR : name === "G" ? chG
             : name === "B" ? chB : name === "C" ? chC : inkFaint
    }

    // ── Menus (every item shows its key — the menu is the cheat sheet)
    menuBar: MenuBar {
        background: Rectangle { color: "#FFFFFF" }
        Menu {
            title: qsTr("&File")
            MenuItem { text: qsTr("Open capture folder…"); enabled: false }
            MenuItem { text: qsTr("Import archive…"); enabled: false }
            MenuSeparator {}
            MenuItem { text: qsTr("Export session…"); enabled: false }
            MenuItem { text: qsTr("Offload keepers…"); enabled: false }
            MenuSeparator {}
            MenuItem {
                text: qsTr("Quit")
                onTriggered: Qt.quit()
            }
        }
        Menu {
            title: qsTr("&Edit")
            MenuItem { text: qsTr("Undo"); enabled: false }
            MenuSeparator {}
            MenuItem { text: qsTr("Preferences…"); enabled: false }
        }
        Menu {
            title: qsTr("&View")
            MenuItem { text: qsTr("Grid / timeline"); enabled: false }
            MenuItem { text: qsTr("Channel solo"); enabled: false }
            MenuItem { text: qsTr("Zoom 1:1"); enabled: false }
            MenuItem { text: qsTr("Gray surround"); enabled: false }
        }
        Menu {
            title: qsTr("&Session")
            MenuItem { text: qsTr("Rate 1–5"); enabled: false }
            MenuItem { text: qsTr("Reject"); enabled: false }
            MenuItem { text: qsTr("Note…"); enabled: false }
        }
        Menu {
            title: qsTr("&Help")
            MenuItem { text: qsTr("About Xylosome Suite"); enabled: false }
        }
    }

    // ── Main screen (phase 0: layout regions, empty) ─────────────────
    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Header strip
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 36
            color: "#FFFFFF"
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                Label { text: "Xylosome"; color: root.ink; font.pixelSize: 12; font.letterSpacing: 1 }
                Item { Layout.fillWidth: true }
                Label { text: qsTr("no capture folder"); color: root.inkFaint; font.pixelSize: 11 }
                Label { text: "·"; color: root.inkFaint; font.pixelSize: 11 }
                Label {
                    text: Xylod.connected
                          ? (Xylod.sim ? qsTr("xylod · sim") : qsTr("xylod · %1").arg(Xylod.host))
                          : qsTr("xylod · offline")
                    color: Xylod.connected ? root.inkMuted : root.inkFaint
                    font.pixelSize: 11
                }
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.hairline }
        }

        // Live scan indicator — appears only while xylod runs a sequence.
        // The screen stays put; judging continues (plan → Layout).
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: visible ? 30 : 0
            visible: Xylod.running
            color: "#FFFFFF"
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                spacing: 12
                Rectangle {
                    width: 8; height: 8; radius: 4
                    color: root.filterColor(Xylod.filterName)
                }
                Label {
                    text: Xylod.state === "paused" ? qsTr("paused")
                        : Xylod.state === "running" ? qsTr("scanning · pass %1/4").arg(Xylod.passIndex + 1)
                        : Xylod.state   // settle | filter
                    color: root.inkMuted
                    font.pixelSize: 11
                }
                Label {
                    text: Xylod.filterName
                    color: root.filterColor(Xylod.filterName)
                    font.pixelSize: 11
                    visible: Xylod.filterName !== ""
                }
                Rectangle {
                    Layout.fillWidth: true
                    height: 3
                    color: "#EEEEEE"
                    Rectangle {
                        width: parent.width * Xylod.progress
                        height: parent.height
                        color: root.ink
                    }
                }
                Label {
                    text: qsTr("%1% · %2°")
                          .arg(Math.round(Xylod.progress * 100))
                          .arg(Xylod.positionDeg.toFixed(1))
                    color: root.inkMuted
                    font.pixelSize: 11
                }
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.hairline }
        }

        // Fault display — loud, the review screen is the cart's billboard.
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: visible ? 36 : 0
            visible: Xylod.faultText !== "" || (Xylod.connected && !Xylod.estopOk)
            color: "#1A1A1A"
            Label {
                anchors.centerIn: parent
                text: !Xylod.estopOk ? qsTr("E-STOP") : Xylod.faultText
                color: "#FFFFFF"
                font.pixelSize: 13
                font.letterSpacing: 2
            }
        }

        // Image field
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: root.imageField
            Label {
                anchors.centerIn: parent
                text: qsTr("no session")
                color: "#AAAAAA"
                font.pixelSize: 12
            }
        }

        // Metadata strip
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 64
            color: "#FFFFFF"
            Rectangle { width: parent.width; height: 1; color: root.hairline }
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                spacing: 16
                Label { text: "R"; color: root.chR; font.pixelSize: 11 }
                Label { text: "G"; color: root.chG; font.pixelSize: 11 }
                Label { text: "B"; color: root.chB; font.pixelSize: 11 }
                Label { text: "C"; color: root.chC; font.pixelSize: 11 }
                Item { Layout.fillWidth: true }
            }
        }

        // Filmstrip
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 72
            color: "#FFFFFF"
            Rectangle { width: parent.width; height: 1; color: root.hairline }
            Label {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: 16
                text: qsTr("today’s sessions appear here")
                color: root.inkFaint
                font.pixelSize: 11
            }
        }
    }

    // ── Splash ───────────────────────────────────────────────────────
    Rectangle {
        id: splash
        anchors.fill: parent
        color: "#FFFFFF"
        z: 100

        Column {
            anchors.centerIn: parent
            spacing: 18
            Image {
                source: "qrc:/qt/qml/XylosomeSuite/assets/hm_logo_black.svg"
                sourceSize.width: 420
                width: 420
                fillMode: Image.PreserveAspectFit
                anchors.horizontalCenter: parent.horizontalCenter
            }
            Label {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Xylosome Suite"
                color: root.inkMuted
                font.pixelSize: 14
                font.letterSpacing: 3
            }
        }

        Timer {
            interval: 1200
            running: true
            onTriggered: splash.opacity = 0
        }
        Behavior on opacity {
            NumberAnimation { duration: root.easeMs; easing.type: Easing.OutCubic }
        }
        onOpacityChanged: if (opacity === 0) visible = false
    }
}
