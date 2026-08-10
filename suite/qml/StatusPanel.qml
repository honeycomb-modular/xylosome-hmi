// StatusPanel — toggle-able cart health + camera board (S opens, Esc closes).
// Top: connection dots for HMI · motion (xylod) · capture agent · camera — ink-filled when up,
// hollow when down (no new colors; the palette stays R/G/B/C + ink). Below:
// the live camera settings from the :5521 bus (read-only — setting stays on the
// HMI). Docks against the right edge of the image field.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import XylosomeSuite.Link

Rectangle {
    id: panel
    color: "#FFFFFF"

    readonly property color ink: "#1A1A1A"
    readonly property color inkMuted: "#666666"
    readonly property color inkFaint: "#999999"
    readonly property color hairline: "#E8E8E8"

    signal closeRequested()

    // left hairline — the seam where the panel meets the gray image field
    Rectangle {
        anchors.left: parent.left
        width: 1; height: parent.height
        color: panel.hairline
    }

    Column {
        anchors.fill: parent
        anchors.leftMargin: 21
        anchors.rightMargin: 20
        anchors.topMargin: 20
        spacing: 20

        // header
        RowLayout {
            width: parent.width
            Label { text: qsTr("system"); color: panel.ink; font.pixelSize: 12; font.letterSpacing: 2 }
            Item { Layout.fillWidth: true }
            Label {
                text: qsTr("close ×")
                color: panel.inkMuted
                font.pixelSize: 11
                font.underline: closeMouse.containsMouse
                MouseArea {
                    id: closeMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: panel.closeRequested()
                }
            }
        }

        // ── connections ─────────────────────────────────────────────
        Column {
            width: parent.width
            spacing: 12
            Label { text: qsTr("connections"); color: panel.inkFaint; font.pixelSize: 10; font.letterSpacing: 1 }
            // The agent and the camera are two separate facts on one socket: the
            // :5521 bus answering means the AGENT process is alive; the camera
            // only counts as up once it has actually replied on the serial line
            // (model non-empty). A live agent in front of a silent camera —
            // black frames, red CL LEDs — used to read as "camera connected".
            Repeater {
                model: [
                    { label: qsTr("HMI"),            up: Hmi.connected,   detail: Hmi.host,
                      upText: qsTr("connected"), downText: qsTr("offline") },
                    { label: qsTr("motion · xylod"), up: Xylod.connected,
                      detail: Xylod.connected ? (Xylod.sim ? qsTr("sim") : Xylod.host) : "",
                      upText: qsTr("connected"), downText: qsTr("offline") },
                    { label: qsTr("capture agent"),  up: Camera.connected,
                      detail: Camera.host + ":" + Camera.port,
                      upText: qsTr("running"), downText: qsTr("not running") },
                    { label: qsTr("camera"),         up: Camera.connected && Camera.model !== "",
                      detail: Camera.connected ? Camera.model : "",
                      upText: qsTr("responding"), downText: qsTr("no reply") }
                ]
                delegate: RowLayout {
                    required property var modelData
                    width: parent.width
                    spacing: 10
                    Rectangle {
                        Layout.alignment: Qt.AlignVCenter
                        width: 9; height: 9; radius: 4.5
                        color: modelData.up ? panel.ink : "transparent"
                        border.width: modelData.up ? 0 : 1
                        border.color: panel.inkFaint
                    }
                    Label { text: modelData.label; color: panel.ink; font.pixelSize: 12 }
                    Item { Layout.fillWidth: true }
                    Label {
                        text: modelData.up ? modelData.upText : modelData.downText
                        color: modelData.up ? panel.inkMuted : panel.inkFaint
                        font.pixelSize: 11
                    }
                    Label {
                        text: modelData.detail
                        color: panel.inkFaint
                        font.pixelSize: 10
                        visible: modelData.detail !== ""
                        elide: Text.ElideRight
                        Layout.maximumWidth: 110
                    }
                }
            }
        }

        Rectangle { width: parent.width; height: 1; color: panel.hairline }

        // ── camera settings (live, read-only) ───────────────────────
        Column {
            width: parent.width
            spacing: 12
            RowLayout {
                width: parent.width
                Label { text: qsTr("camera"); color: panel.inkFaint; font.pixelSize: 10; font.letterSpacing: 1 }
                Item { Layout.fillWidth: true }
                Label {
                    visible: !Camera.connected
                    text: qsTr("no bus")
                    color: panel.inkFaint
                    font.pixelSize: 10
                }
            }
            Repeater {
                model: [
                    { k: qsTr("line rate"),  v: Camera.lineRate > 0 ? Camera.lineRate.toFixed(1) + qsTr(" Hz") : "—" },
                    { k: qsTr("TDI stages"), v: Camera.tdiStages > 0 ? Camera.tdiStages.toString() : "—" },
                    { k: qsTr("gain"),       v: Camera.gain !== "" ? Camera.gain + qsTr(" dB") : "—" },
                    { k: qsTr("scan dir"),   v: Camera.scanDir !== "" ? Camera.scanDir : "—" },
                    { k: qsTr("model"),      v: Camera.model !== "" ? Camera.model : "—" },
                    { k: qsTr("link mode"),  v: Camera.clm !== "" ? Camera.clm : "—" }
                ]
                delegate: RowLayout {
                    required property var modelData
                    width: parent.width
                    spacing: 12
                    Label { text: modelData.k; color: panel.inkMuted; font.pixelSize: 12 }
                    Item { Layout.fillWidth: true }
                    Label {
                        text: modelData.v
                        color: panel.ink
                        font.pixelSize: 12
                        horizontalAlignment: Text.AlignRight
                        elide: Text.ElideRight
                        Layout.maximumWidth: 190
                    }
                }
            }
        }
    }
}
