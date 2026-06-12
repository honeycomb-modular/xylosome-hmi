// Xylosome Suite — main window.
// Splash → live review: scan indicator, image field (pass previews,
// channel solo), metadata strip, filmstrip, keyboard judging.
// Design decisions: docs/concept/review_suite_plan.md → "Design language".

import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
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

    function stars(n) { return "★".repeat(n) }

    FolderDialog {
        id: captureDialog
        title: qsTr("Capture folder")
        onAccepted: {
            let p = decodeURIComponent(selectedFolder.toString()).replace(/^file:\/\//, "")
            if (/^\/[A-Za-z]:/.test(p))   // Windows: /C:/… → C:/…
                p = p.slice(1)
            Sessions.captureDir = p
        }
    }

    // Keyboard-first judging (plan → Design / Input)
    Shortcut { sequences: ["1"]; onActivated: Sessions.setRating(strip.currentIndex, 1) }
    Shortcut { sequences: ["2"]; onActivated: Sessions.setRating(strip.currentIndex, 2) }
    Shortcut { sequences: ["3"]; onActivated: Sessions.setRating(strip.currentIndex, 3) }
    Shortcut { sequences: ["4"]; onActivated: Sessions.setRating(strip.currentIndex, 4) }
    Shortcut { sequences: ["5"]; onActivated: Sessions.setRating(strip.currentIndex, 5) }
    Shortcut { sequences: ["0"]; onActivated: Sessions.setRating(strip.currentIndex, 0) }
    Shortcut { sequences: ["X"]; onActivated: Sessions.setRejected(strip.currentIndex,
                                                                   !(strip.currentItem && strip.currentItem.sRejected)) }
    Shortcut { sequences: [StandardKey.MoveToPreviousChar]; onActivated: strip.decrementCurrentIndex() }
    Shortcut { sequences: [StandardKey.MoveToNextChar]; onActivated: strip.incrementCurrentIndex() }

    // Channel solo (plan → Judging aids): R/G/B/C keys, A back to auto
    property string soloChannel: "auto"
    Shortcut { sequences: ["R"]; onActivated: root.soloChannel = "R" }
    Shortcut { sequences: ["G"]; onActivated: root.soloChannel = "G" }
    Shortcut { sequences: ["B"]; onActivated: root.soloChannel = "B" }
    Shortcut { sequences: ["C"]; onActivated: root.soloChannel = "C" }
    Shortcut { sequences: ["A"]; onActivated: root.soloChannel = "auto" }
    Shortcut { sequences: ["Z"]; onActivated: zoomView.toggleFit() }

    // Index of the pass shown in the image field for the current session
    readonly property int shownPass: {
        const it = strip.currentItem
        if (!it) return -1
        if (soloChannel !== "auto") {
            for (let i = 0; i < it.sPassFilters.length; i++)
                if (it.sPassFilters[i] === soloChannel && it.sPassPreviews[i] !== "")
                    return i
            return -1
        }
        for (let i = it.sPassPreviews.length - 1; i >= 0; i--)
            if (it.sPassPreviews[i] !== "")
                return i
        return -1
    }

    // ── Menus (every item shows its key — the menu is the cheat sheet)
    menuBar: MenuBar {
        background: Rectangle { color: "#FFFFFF" }
        Menu {
            title: qsTr("&File")
            MenuItem {
                text: qsTr("Open capture folder…")
                onTriggered: captureDialog.open()
            }
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
            MenuItem {
                text: qsTr("Channel solo R/G/B/C — A auto")
                enabled: false   // reference only; the keys do the work
            }
            MenuItem {
                text: qsTr("Zoom fit ⇄ 1:1\tZ · wheel · double-click")
                onTriggered: zoomView.toggleFit()
            }
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

    // ── Main screen ──────────────────────────────────────────────────
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
                Label {
                    text: Sessions.captureDir === ""
                          ? qsTr("no capture folder")
                          : Sessions.captureDir.split("/").pop()
                            + (Sessions.unpairedFiles > 0
                               ? qsTr(" · %1 unpaired").arg(Sessions.unpairedFiles) : "")
                    color: Sessions.captureDir === "" ? root.inkFaint : root.inkMuted
                    font.pixelSize: 11
                }
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

        // Image field — fit preview of the shown pass (deep-zoom tiles
        // come with the phase 3 viewer); neutral gray surround.
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: root.imageField

            ZoomView {
                id: zoomView
                anchors.fill: parent
                anchors.margins: 24
                visible: root.shownPass >= 0
                tileBase: root.shownPass >= 0 && strip.currentItem
                          ? strip.currentItem.sPassTileBases[root.shownPass] : ""
                imgW: root.shownPass >= 0 && strip.currentItem
                      ? strip.currentItem.sPassDims[root.shownPass].w : 0
                imgH: root.shownPass >= 0 && strip.currentItem
                      ? strip.currentItem.sPassDims[root.shownPass].h : 0
            }

            // zoom readout — bottom right
            Label {
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 12
                visible: zoomView.visible && zoomView.imgW > 0
                text: zoomView.atFit ? qsTr("fit")
                                     : Math.round(zoomView.zoom * 100) + " %"
                color: "#CCCCCC"
                font.pixelSize: 11
            }

            // channel badge — bottom left, the only color on the field
            Row {
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.margins: 12
                spacing: 8
                visible: root.shownPass >= 0 && strip.currentItem !== null
                Label {
                    text: strip.currentItem && root.shownPass >= 0
                          ? strip.currentItem.sPassFilters[root.shownPass] : ""
                    color: root.filterColor(text)
                    font.pixelSize: 13
                }
                Label {
                    text: root.soloChannel === "auto" ? qsTr("auto") : qsTr("solo")
                    color: "#CCCCCC"
                    font.pixelSize: 11
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            Column {
                anchors.centerIn: parent
                spacing: 8
                visible: strip.currentItem !== null && root.shownPass < 0
                Label {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: strip.currentItem ? "session " + strip.currentItem.sSeq : ""
                    color: "#DDDDDD"
                    font.pixelSize: 16
                    font.letterSpacing: 2
                }
                Label {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: strip.currentItem
                          ? (root.soloChannel !== "auto"
                             ? qsTr("%1 — no image yet").arg(root.soloChannel)
                             : strip.currentItem.sState
                               + (strip.currentItem.sRejected ? qsTr(" · rejected") : ""))
                          : ""
                    color: strip.currentItem && strip.currentItem.sState === "partial"
                           ? "#FFFFFF" : "#AAAAAA"
                    font.pixelSize: 11
                }
            }
            Label {
                anchors.centerIn: parent
                visible: strip.count === 0
                text: Sessions.captureDir === ""
                      ? qsTr("File → Open capture folder…") : qsTr("no sessions yet")
                color: "#AAAAAA"
                font.pixelSize: 12
            }
        }

        // Metadata strip — film-data-strip: per-pass timing for the
        // selected session, real numbers from xylod events.
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 64
            color: "#FFFFFF"
            Rectangle { width: parent.width; height: 1; color: root.hairline }
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                spacing: 20
                Repeater {
                    model: strip.currentItem ? strip.currentItem.sPassFilters : []
                    RowLayout {
                        spacing: 5
                        required property int index
                        required property string modelData
                        Label {
                            text: parent.modelData
                            color: root.filterColor(parent.modelData)
                            font.pixelSize: 11
                        }
                        Label {
                            text: {
                                if (!strip.currentItem) return ""
                                const d = strip.currentItem.sPassDurations[parent.index]
                                const paired = strip.currentItem.sPassPaired[parent.index]
                                return (d >= 0 ? d.toFixed(1) + " s" : "…")
                                       + (paired ? "" : " ○")
                            }
                            color: root.inkMuted
                            font.pixelSize: 11
                        }
                    }
                }
                Item { Layout.fillWidth: true }
                Label {
                    text: {
                        if (!strip.currentItem || root.shownPass < 0) return ""
                        const c = strip.currentItem.sPassClips[root.shownPass]
                        if (!c || c.black < 0) return ""
                        return qsTr("clip ▼%1% ▲%2%")
                            .arg(c.black.toFixed(2)).arg(c.white.toFixed(2))
                    }
                    color: root.inkMuted
                    font.pixelSize: 11
                }
                Label {
                    text: strip.currentItem && strip.currentItem.sRating > 0
                          ? root.stars(strip.currentItem.sRating) : ""
                    color: root.ink
                    font.pixelSize: 12
                }
                Label {
                    text: strip.currentItem ? strip.currentItem.sNote : ""
                    color: root.inkFaint
                    font.pixelSize: 11
                }
            }
        }

        // Filmstrip — slim, always visible; live session joins the row.
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 72
            color: "#FFFFFF"
            Rectangle { width: parent.width; height: 1; color: root.hairline }
            Label {
                anchors.centerIn: parent
                visible: strip.count === 0
                text: qsTr("today’s sessions appear here")
                color: root.inkFaint
                font.pixelSize: 11
            }
            ListView {
                id: strip
                anchors.fill: parent
                anchors.topMargin: 6
                anchors.bottomMargin: 4
                anchors.rightMargin: 10
                anchors.leftMargin: 16
                orientation: ListView.Horizontal
                spacing: 8
                clip: true
                model: Sessions
                onCountChanged: if (Sessions.liveRow >= 0) currentIndex = Sessions.liveRow
                                else if (currentIndex < 0 && count > 0) currentIndex = count - 1
                delegate: Item {
                    id: cell
                    required property int index
                    required property int seq
                    required property string sessionState
                    required property int rating
                    required property bool rejected
                    required property string note
                    required property var passFilters
                    required property var passPaired
                    required property var passDurations
                    required property var passPreviews
                    required property var passClips
                    required property var passDims
                    required property var passTileBases
                    // surfaced for the rest of the UI via strip.currentItem
                    readonly property int sSeq: seq
                    readonly property string sState: sessionState
                    readonly property int sRating: rating
                    readonly property bool sRejected: rejected
                    readonly property string sNote: note
                    readonly property var sPassFilters: passFilters
                    readonly property var sPassPaired: passPaired
                    readonly property var sPassDurations: passDurations
                    readonly property var sPassPreviews: passPreviews
                    readonly property var sPassClips: passClips
                    readonly property var sPassDims: passDims
                    readonly property var sPassTileBases: passTileBases
                    width: 56
                    height: strip.height
                    Column {
                        anchors.fill: parent
                        spacing: 2
                        Rectangle {
                            width: parent.width
                            height: 28
                            color: cell.rejected ? "#F2F2F2"
                                 : cell.sessionState === "live" ? "#F2F2F2" : "#2C2C2C"
                            opacity: cell.rejected ? 0.5 : 1
                            border.width: cell.ListView.isCurrentItem ? 1.5 : 0
                            border.color: root.ink
                            clip: true
                            Image {
                                anchors.fill: parent
                                source: {
                                    for (let i = 0; i < cell.passPreviews.length; i++)
                                        if (cell.passPreviews[i] !== "")
                                            return "file:///" + cell.passPreviews[i].replace(/^\//, "")
                                    return ""
                                }
                                sourceSize.height: 60
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                opacity: cell.rejected ? 0.4 : 1
                            }
                            Label {
                                anchors.centerIn: parent
                                visible: cell.sessionState === "live"
                                text: qsTr("· · ·")
                                color: root.inkMuted
                                font.pixelSize: 10
                            }
                        }
                        Row {
                            spacing: 2
                            Repeater {
                                model: cell.passFilters
                                Rectangle {
                                    required property int index
                                    required property string modelData
                                    width: 12
                                    height: 3
                                    color: cell.passPaired[index]
                                           ? root.filterColor(modelData) : "#E0E0E0"
                                }
                            }
                        }
                        Label {
                            text: ("000" + cell.seq).slice(-4)
                                  + (cell.rejected ? " ×" : "")
                            color: cell.ListView.isCurrentItem ? root.ink : root.inkFaint
                            font.pixelSize: 10
                        }
                        Label {
                            visible: cell.rating > 0
                            text: root.stars(cell.rating)
                            color: cell.ListView.isCurrentItem ? root.ink : root.inkFaint
                            font.pixelSize: 9
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: strip.currentIndex = cell.index
                    }
                }
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
