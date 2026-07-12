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

    function folderFromUrl(u) {
        let p = decodeURIComponent(u.toString()).replace(/^file:\/\//, "")
        if (/^\/[A-Za-z]:/.test(p))   // Windows: /C:/… → C:/…
            p = p.slice(1)
        return p
    }

    FolderDialog {
        id: captureDialog
        title: qsTr("Capture folder")
        onAccepted: Sessions.captureDir = root.folderFromUrl(selectedFolder)
    }

    property string archiveDir: ""
    property var archiveProposals: []
    FolderDialog {
        id: archiveDialog
        title: qsTr("Archive folder")
        onAccepted: {
            root.archiveDir = root.folderFromUrl(selectedFolder)
            root.archiveProposals = Sessions.scanArchive(root.archiveDir)
        }
    }

    // All single-key shortcuts die while a text field has focus.
    readonly property bool keysLive: !noteField.activeFocus

    // Keyboard-first judging (plan → Design / Input)
    Shortcut { enabled: root.keysLive; sequences: ["1"]; onActivated: Sessions.setRating(strip.currentIndex, 1) }
    Shortcut { enabled: root.keysLive; sequences: ["2"]; onActivated: Sessions.setRating(strip.currentIndex, 2) }
    Shortcut { enabled: root.keysLive; sequences: ["3"]; onActivated: Sessions.setRating(strip.currentIndex, 3) }
    Shortcut { enabled: root.keysLive; sequences: ["4"]; onActivated: Sessions.setRating(strip.currentIndex, 4) }
    Shortcut { enabled: root.keysLive; sequences: ["5"]; onActivated: Sessions.setRating(strip.currentIndex, 5) }
    Shortcut { enabled: root.keysLive; sequences: ["0"]; onActivated: Sessions.setRating(strip.currentIndex, 0) }
    Shortcut { enabled: root.keysLive; sequences: ["X"]; onActivated: Sessions.setRejected(strip.currentIndex,
                                                                   !(strip.currentItem && strip.currentItem.sRejected)) }
    Shortcut { enabled: root.keysLive; sequences: [StandardKey.MoveToPreviousChar]; onActivated: strip.decrementCurrentIndex() }
    Shortcut { enabled: root.keysLive; sequences: [StandardKey.MoveToNextChar]; onActivated: strip.incrementCurrentIndex() }

    // Channel solo (plan → Judging aids): R/G/B/C keys, A back to auto
    property string soloChannel: "auto"
    Shortcut { enabled: root.keysLive; sequences: ["R"]; onActivated: root.soloChannel = "R" }
    Shortcut { enabled: root.keysLive; sequences: ["G"]; onActivated: root.soloChannel = "G" }
    Shortcut { enabled: root.keysLive; sequences: ["B"]; onActivated: root.soloChannel = "B" }
    Shortcut { enabled: root.keysLive; sequences: ["C"]; onActivated: root.soloChannel = "C" }
    Shortcut { enabled: root.keysLive; sequences: ["A"]; onActivated: root.soloChannel = "auto" }
    Shortcut { enabled: root.keysLive; sequences: ["Z"]; onActivated: zoomView.toggleFit() }

    // Notes, library, deletion
    Shortcut { enabled: root.keysLive; sequences: ["N"]; onActivated: noteField.beginEdit() }
    Shortcut { enabled: root.keysLive; sequences: ["L"]; onActivated: root.libraryOpen = !root.libraryOpen }
    Shortcut { enabled: root.keysLive && root.libraryOpen; sequences: ["T"]
               onActivated: root.libraryTimeline = !root.libraryTimeline }
    Shortcut { enabled: root.libraryOpen; sequences: ["Escape"]
               onActivated: root.libraryOpen = false }

    property bool libraryOpen: false
    property bool libraryTimeline: false
    property bool metaShown: true
    Shortcut { enabled: root.keysLive; sequences: ["M"]
               onActivated: root.metaShown = !root.metaShown }
    Shortcut { enabled: root.keysLive; sequences: ["W"]
               onActivated: if (strip.currentItem)
                   Sessions.setMetaWhite(strip.currentIndex,
                                         !strip.currentItem.sMetaWhite) }

    // ── deletion confirm (design-true: white card, hairline, no drama) ──
    property int confirmMode: 0      // 0 none · 1 delete current · 2 empty quarantine
    function fmtGB(gb) { return gb >= 1 ? gb.toFixed(1) + " GB" : Math.round(gb * 1000) + " MB" }

    // transient reclaim report
    property string reclaimText: ""
    Connections {
        target: Sessions
        function onReclaimed(gb, sessions) {
            root.reclaimText = qsTr("%1 reclaimed · %2 session%3 deleted")
                .arg(root.fmtGB(gb)).arg(sessions).arg(sessions > 1 ? "s" : "")
            reclaimTimer.restart()
        }
    }
    Timer { id: reclaimTimer; interval: 5000; onTriggered: root.reclaimText = "" }

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
            MenuItem {
                text: qsTr("Import archive…")
                enabled: Sessions.captureDir !== ""
                onTriggered: archiveDialog.open()
            }
            MenuSeparator {}
            MenuItem { text: qsTr("Export session…"); enabled: false }
            MenuItem { text: qsTr("Offload keepers…"); enabled: false }
            MenuSeparator {}
            MenuItem {
                text: qsTr("Empty quarantine… (%1 rejected)").arg(Sessions.rejectedCount)
                enabled: Sessions.rejectedCount > 0
                onTriggered: root.confirmMode = 2
            }
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
            MenuItem {
                text: qsTr("Library\tL · T grid⇄timeline")
                onTriggered: root.libraryOpen = !root.libraryOpen
            }
            MenuItem {
                text: qsTr("Channel solo R/G/B/C — A auto")
                enabled: false   // reference only; the keys do the work
            }
            MenuItem {
                text: qsTr("Zoom fit ⇄ 1:1\tZ · wheel · double-click")
                onTriggered: zoomView.toggleFit()
            }
            MenuItem {
                text: qsTr("Metadata block\tM · drag moves · corner scales")
                onTriggered: root.metaShown = !root.metaShown
            }
            MenuItem {
                text: qsTr("Metadata black ⇄ white\tW")
                enabled: strip.currentItem !== null && strip.currentItem.sMetaSvg !== ""
                onTriggered: Sessions.setMetaWhite(strip.currentIndex,
                    !(strip.currentItem && strip.currentItem.sMetaWhite))
            }
            MenuItem { text: qsTr("Gray surround"); enabled: false }
        }
        Menu {
            title: qsTr("&Session")
            MenuItem { text: qsTr("Rate\t1–5 · 0 clears"); enabled: false }
            MenuItem {
                text: qsTr("Reject\tX")
                enabled: strip.currentItem !== null
                onTriggered: Sessions.setRejected(strip.currentIndex,
                                                  !(strip.currentItem && strip.currentItem.sRejected))
            }
            MenuItem {
                text: qsTr("Note…\tN")
                enabled: strip.currentItem !== null
                onTriggered: noteField.beginEdit()
            }
            MenuSeparator {}
            MenuItem {
                text: qsTr("Delete now…")
                enabled: strip.currentItem !== null
                         && strip.currentItem.sState !== "live"
                onTriggered: root.confirmMode = 1
            }
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
                Label {
                    text: root.reclaimText
                    color: root.inkMuted
                    font.pixelSize: 11
                    visible: root.reclaimText !== ""
                    leftPadding: 16
                }
                Item { Layout.fillWidth: true }
                Label {
                    visible: Sessions.freeGB >= 0
                    text: Sessions.sessionsRemaining >= 0
                          ? qsTr("disk %1 GB · ~%2 sessions")
                                .arg(Math.round(Sessions.freeGB))
                                .arg(Sessions.sessionsRemaining)
                          : qsTr("disk %1 GB").arg(Math.round(Sessions.freeGB))
                    color: Sessions.sessionsRemaining >= 0 && Sessions.sessionsRemaining < 5
                           ? root.ink : root.inkFaint
                    font.pixelSize: 11
                }
                Label { text: "·"; color: root.inkFaint; font.pixelSize: 11; visible: Sessions.freeGB >= 0 }
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
                Label { text: "·"; color: root.inkFaint; font.pixelSize: 11 }
                Label {
                    text: qsTr("library")
                    color: root.libraryOpen ? root.ink : root.inkMuted
                    font.pixelSize: 11
                    font.underline: libMouse.containsMouse
                    MouseArea {
                        id: libMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.libraryOpen = !root.libraryOpen
                    }
                }
                Item { width: 8; height: 1 }
                // LIVE — a mode switch, so the only bordered control in the
                // header: unmissable but still in the language.
                Rectangle {
                    Layout.preferredWidth: liveRow.width + 24
                    Layout.preferredHeight: 24
                    color: Live.running ? root.ink : (liveMouse.containsMouse ? "#F2F2F2" : "#FFFFFF")
                    border.width: 1
                    border.color: root.ink
                    Row {
                        id: liveRow
                        anchors.centerIn: parent
                        spacing: 7
                        Rectangle {
                            id: liveDot
                            width: 7; height: 7; radius: 3.5
                            anchors.verticalCenter: parent.verticalCenter
                            color: Live.running ? root.chR : "transparent"
                            border.width: Live.running ? 0 : 1
                            border.color: root.inkFaint
                            SequentialAnimation on opacity {
                                running: Live.running
                                loops: Animation.Infinite
                                onStopped: liveDot.opacity = 1
                                NumberAnimation { to: 0.3; duration: 600 }
                                NumberAnimation { to: 1.0; duration: 600 }
                            }
                        }
                        Label {
                            text: Live.running ? qsTr("LIVE — STOP") : qsTr("LIVE")
                            color: Live.running ? "#FFFFFF" : root.ink
                            font.pixelSize: 11
                            font.letterSpacing: 2
                        }
                    }
                    MouseArea {
                        id: liveMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Live.running ? Live.stop() : Live.start()
                    }
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
                metaSource: strip.currentItem ? strip.currentItem.sMetaSvg : ""
                metaX: strip.currentItem ? strip.currentItem.sMetaX : 0.04
                metaY: strip.currentItem ? strip.currentItem.sMetaY : 0.78
                metaW: strip.currentItem ? strip.currentItem.sMetaW : 0.25
                metaVisible: root.metaShown
                onPlacementChanged: (x, y, w) =>
                    Sessions.setMetaPlacement(strip.currentIndex, x, y, w)
            }

            // bottom right: metadata toggle + zoom readout
            Row {
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 12
                spacing: 14
                Label {
                    visible: zoomView.visible && zoomView.metaSource !== ""
                    text: root.metaShown ? qsTr("meta on") : qsTr("meta off")
                    color: root.metaShown ? "#FFFFFF" : "#AAAAAA"
                    font.pixelSize: 11
                    font.underline: metaMouse.containsMouse
                    MouseArea {
                        id: metaMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.metaShown = !root.metaShown
                    }
                }
                Label {
                    visible: zoomView.visible && zoomView.metaSource !== ""
                             && root.metaShown
                    text: strip.currentItem && strip.currentItem.sMetaWhite
                          ? qsTr("white") : qsTr("black")
                    color: "#CCCCCC"
                    font.pixelSize: 11
                    font.underline: bwMouse.containsMouse
                    MouseArea {
                        id: bwMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Sessions.setMetaWhite(strip.currentIndex,
                            !(strip.currentItem && strip.currentItem.sMetaWhite))
                    }
                }
                Label {
                    visible: zoomView.visible && zoomView.imgW > 0
                    text: (zoomView.atFit ? qsTr("fit")
                                          : Math.round(zoomView.zoom * 100) + " %")
                          + (zoomMouse.containsMouse ? (zoomView.atFit ? "  → 1:1" : "  → fit") : "")
                    color: "#CCCCCC"
                    font.pixelSize: 11
                    MouseArea {
                        id: zoomMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: zoomView.toggleFit()
                    }
                }
            }

            // channel solo — bottom-left segmented control; the active
            // channel fills with its own color, auto fills ink. Click a lit
            // channel to clear it. (mirrors the R/G/B/C · A keys and the
            // per-pass labels in the metadata strip)
            Row {
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.margins: 12
                spacing: 2
                visible: strip.currentItem !== null
                Repeater {
                    model: ["R", "G", "B", "C"]
                    ToggleChip {
                        required property string modelData
                        text: modelData
                        minWidth: 26
                        fontPx: 12
                        active: root.soloChannel === modelData
                        activeColor: root.filterColor(modelData)
                        idleText: root.filterColor(modelData)
                        hoverColor: "#9A9A9A"
                        onClicked: root.soloChannel =
                            root.soloChannel === modelData ? "auto" : modelData
                    }
                }
                ToggleChip {
                    text: qsTr("auto")
                    active: root.soloChannel === "auto"
                    activeColor: root.ink
                    idleText: "#CCCCCC"
                    hoverColor: "#9A9A9A"
                    onClicked: root.soloChannel = "auto"
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
                            font.underline: chMouse.containsMouse
                            font.bold: root.soloChannel === parent.modelData
                            MouseArea {
                                id: chMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.soloChannel =
                                    root.soloChannel === parent.parent.modelData
                                        ? "auto" : parent.parent.modelData
                            }
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
                Row {
                    spacing: 1
                    visible: strip.currentItem !== null
                    Repeater {
                        model: 5
                        Label {
                            required property int index
                            text: strip.currentItem && strip.currentItem.sRating > index ? "★" : "☆"
                            color: strip.currentItem && strip.currentItem.sRating > index
                                   ? root.ink : root.inkFaint
                            font.pixelSize: 12
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    const n = parent.index + 1
                                    Sessions.setRating(strip.currentIndex,
                                        strip.currentItem.sRating === n ? 0 : n)
                                }
                            }
                        }
                    }
                }
                Label {
                    visible: strip.currentItem !== null
                    text: "×"
                    color: strip.currentItem && strip.currentItem.sRejected
                           ? root.ink : root.inkFaint
                    font.pixelSize: 14
                    font.bold: strip.currentItem && strip.currentItem.sRejected
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Sessions.setRejected(strip.currentIndex,
                            !(strip.currentItem && strip.currentItem.sRejected))
                    }
                }
                TextField {
                    id: noteField
                    Layout.preferredWidth: 220
                    visible: strip.currentItem !== null
                    text: strip.currentItem ? strip.currentItem.sNote : ""
                    placeholderText: qsTr("note")
                    font.pixelSize: 11
                    color: root.inkMuted
                    background: Rectangle {
                        color: "transparent"
                        border.width: 0
                        Rectangle {
                            anchors.bottom: parent.bottom
                            width: parent.width
                            height: 1
                            color: noteField.activeFocus ? root.ink : "transparent"
                        }
                    }
                    function beginEdit() {
                        if (strip.currentItem) {
                            forceActiveFocus()
                            selectAll()
                        }
                    }
                    onAccepted: {
                        Sessions.setNote(strip.currentIndex, text)
                        strip.forceActiveFocus()
                    }
                    Keys.onEscapePressed: {
                        text = strip.currentItem ? strip.currentItem.sNote : ""
                        strip.forceActiveFocus()
                    }
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
                    required property string metaSvg
                    required property double metaX
                    required property double metaY
                    required property double metaW
                    required property bool metaWhite
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
                    readonly property string sMetaSvg: metaSvg
                    readonly property double sMetaX: metaX
                    readonly property double sMetaY: metaY
                    readonly property double sMetaW: metaW
                    readonly property bool sMetaWhite: metaWhite
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

    // ── Live focus overlay — camera free-runs, waterfall + focus metric
    Rectangle {
        visible: Live.running || Live.error !== ""
        anchors.fill: parent
        anchors.topMargin: 36
        anchors.bottomMargin: 72
        color: "#0A0A0A"
        z: 45

        Column {
            anchors.centerIn: parent
            spacing: 16
            width: Math.min(parent.width - 96, 1024)

            RowLayout {
                width: parent.width
                Label {
                    text: qsTr("live · focus")
                    color: "#FFFFFF"
                    font.pixelSize: 12
                    font.letterSpacing: 2
                }
                Item { Layout.fillWidth: true }
                Label {
                    text: Live.connected ? qsTr("agent connected") : qsTr("waiting for agent…")
                    color: Live.connected ? "#AAAAAA" : root.chR
                    font.pixelSize: 11
                }
                Label {
                    text: qsTr("stop ×")
                    color: "#FFFFFF"
                    font.pixelSize: 11
                    leftPadding: 16
                    font.underline: stopMouse.containsMouse
                    MouseArea {
                        id: stopMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Live.stop()
                    }
                }
            }

            // waterfall — newest lines at the bottom
            Rectangle {
                width: parent.width
                height: 380
                color: "#000000"
                border.width: 1
                border.color: "#333333"
                Image {
                    anchors.fill: parent
                    anchors.margins: 1
                    source: "image://live/w?" + Live.frameSerial
                    cache: false
                    fillMode: Image.Stretch
                    smooth: false
                }
            }

            // focus metric — the number that climbs as the lens gets there
            RowLayout {
                width: parent.width
                spacing: 16
                Label {
                    text: qsTr("focus")
                    color: "#AAAAAA"
                    font.pixelSize: 11
                }
                Rectangle {
                    Layout.fillWidth: true
                    height: 6
                    color: "#222222"
                    Rectangle {
                        width: parent.width * Math.min(1, Live.focus)
                        height: parent.height
                        color: "#FFFFFF"
                    }
                    // peak marker
                    Rectangle {
                        x: parent.width * Math.min(1, Live.focusPeak) - 1
                        width: 2
                        height: parent.height
                        color: root.chR
                    }
                }
                Label {
                    text: (Live.focus * 100).toFixed(1)
                          + qsTr("  peak ") + (Live.focusPeak * 100).toFixed(1)
                    color: "#FFFFFF"
                    font.pixelSize: 14
                }
            }

            Label {
                visible: Live.error !== ""
                width: parent.width
                wrapMode: Text.Wrap
                text: Live.error
                color: root.chR
                font.pixelSize: 11
            }
        }
    }

    // ── Library overlay — grid ⇄ timeline (L opens, T switches) ──────
    Rectangle {
        visible: root.libraryOpen
        anchors.fill: parent
        anchors.topMargin: 36
        anchors.bottomMargin: 72
        color: "#FFFFFF"
        z: 40

        RowLayout {
            id: libHeader
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: 16
            height: 24
            Label {
                text: root.libraryTimeline ? qsTr("library · timeline") : qsTr("library · grid")
                color: root.ink
                font.pixelSize: 12
                font.letterSpacing: 1
            }
            Item { Layout.fillWidth: true }
            Label {
                text: qsTr("grid")
                color: root.libraryTimeline ? root.inkFaint : root.ink
                font.pixelSize: 11
                font.underline: gridMouse.containsMouse
                MouseArea {
                    id: gridMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.libraryTimeline = false
                }
            }
            Label {
                text: qsTr("timeline")
                color: root.libraryTimeline ? root.ink : root.inkFaint
                font.pixelSize: 11
                font.underline: tlMouse.containsMouse
                MouseArea {
                    id: tlMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.libraryTimeline = true
                }
            }
            Label {
                text: qsTr("close ×")
                color: root.inkMuted
                font.pixelSize: 11
                font.underline: closeMouse.containsMouse
                leftPadding: 12
                MouseArea {
                    id: closeMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.libraryOpen = false
                }
            }
        }

        GridView {
            visible: !root.libraryTimeline
            anchors.top: libHeader.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: 16
            clip: true
            cellWidth: 168
            cellHeight: 132
            model: Sessions
            delegate: Item {
                id: gcell
                required property int index
                required property int seq
                required property int rating
                required property bool rejected
                required property string sessionState
                required property var passPreviews
                readonly property string firstPreview: {
                    for (let i = 0; i < passPreviews.length; i++)
                        if (passPreviews[i] !== "")
                            return "file:///" + passPreviews[i].replace(/^\//, "")
                    return ""
                }
                width: 160
                height: 124
                Column {
                    spacing: 4
                    Rectangle {
                        width: 160
                        height: 92
                        color: "#2C2C2C"
                        opacity: gcell.rejected ? 0.4 : 1
                        clip: true
                        Image {
                            anchors.fill: parent
                            source: gcell.firstPreview
                            sourceSize.height: 184
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                        }
                    }
                    Label {
                        text: ("000" + gcell.seq).slice(-4)
                              + (gcell.rejected ? " ×" : "")
                              + (gcell.rating > 0 ? "  " + root.stars(gcell.rating) : "")
                              + (gcell.sessionState === "partial" ? qsTr("  partial") : "")
                        color: root.inkMuted
                        font.pixelSize: 11
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: { strip.currentIndex = gcell.index; root.libraryOpen = false }
                }
            }
        }

        ListView {
            visible: root.libraryTimeline
            anchors.top: libHeader.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: 16
            clip: true
            spacing: 1
            model: Sessions
            delegate: Rectangle {
                id: tcell
                required property int index
                required property int seq
                required property int rating
                required property bool rejected
                required property string note
                required property string sessionState
                required property var passFilters
                required property var passDurations
                required property var passPreviews
                required property double createdWallMs
                readonly property string firstPreview: {
                    for (let i = 0; i < passPreviews.length; i++)
                        if (passPreviews[i] !== "")
                            return "file:///" + passPreviews[i].replace(/^\//, "")
                    return ""
                }
                width: ListView.view.width
                height: 44
                color: "#FFFFFF"
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.hairline }
                RowLayout {
                    anchors.fill: parent
                    anchors.rightMargin: 8
                    spacing: 16
                    Rectangle {
                        Layout.preferredWidth: 64
                        Layout.preferredHeight: 36
                        color: "#2C2C2C"
                        opacity: tcell.rejected ? 0.4 : 1
                        clip: true
                        Image {
                            anchors.fill: parent
                            source: tcell.firstPreview
                            sourceSize.height: 72
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                        }
                    }
                    Label {
                        text: ("000" + tcell.seq).slice(-4)
                        color: root.ink
                        font.pixelSize: 11
                    }
                    Label {
                        text: new Date(tcell.createdWallMs).toLocaleTimeString(Qt.locale(), "hh:mm:ss")
                        color: root.inkMuted
                        font.pixelSize: 11
                    }
                    Row {
                        spacing: 8
                        Repeater {
                            model: tcell.passFilters
                            Label {
                                required property int index
                                required property string modelData
                                text: modelData + " " +
                                      (tcell.passDurations[index] >= 0
                                       ? tcell.passDurations[index].toFixed(1) + "s" : "…")
                                color: root.filterColor(modelData)
                                font.pixelSize: 11
                            }
                        }
                    }
                    Label {
                        text: tcell.sessionState === "partial" ? qsTr("partial") : ""
                        color: root.ink
                        font.pixelSize: 11
                    }
                    Item { Layout.fillWidth: true }
                    Label {
                        text: tcell.note
                        color: root.inkFaint
                        font.pixelSize: 11
                        elide: Text.ElideRight
                        Layout.maximumWidth: 260
                    }
                    Label {
                        text: (tcell.rejected ? "× " : "")
                              + (tcell.rating > 0 ? root.stars(tcell.rating) : "")
                        color: root.ink
                        font.pixelSize: 11
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: { strip.currentIndex = tcell.index; root.libraryOpen = false }
                }
            }
        }
    }

    // ── Import proposals overlay ─────────────────────────────────────
    Rectangle {
        visible: root.archiveProposals.length > 0
        anchors.fill: parent
        color: "#80FFFFFF"
        z: 55
        MouseArea { anchors.fill: parent; onClicked: root.archiveProposals = [] }

        Rectangle {
            anchors.centerIn: parent
            width: 520
            height: Math.min(parent.height - 120, importCol.height + 48)
            color: "#FFFFFF"
            border.width: 1
            border.color: root.ink
            MouseArea { anchors.fill: parent }   // swallow clicks
            Column {
                id: importCol
                anchors.top: parent.top
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.topMargin: 24
                width: parent.width - 48
                spacing: 14
                Label {
                    text: qsTr("Import archive — %1 proposed session(s)")
                            .arg(root.archiveProposals.length)
                    color: root.ink
                    font.pixelSize: 13
                    font.letterSpacing: 1
                }
                Label {
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: qsTr("Grouped by filename letter and timing. Originals stay in the archive untouched; proxies are built into the capture folder. Already-imported files are skipped.")
                    color: root.inkMuted
                    font.pixelSize: 11
                }
                ListView {
                    width: parent.width
                    height: Math.min(280, count * 30)
                    clip: true
                    model: root.archiveProposals
                    delegate: RowLayout {
                        required property var modelData
                        width: ListView.view.width
                        height: 30
                        spacing: 12
                        Label {
                            text: parent.modelData.start
                            color: root.inkMuted
                            font.pixelSize: 11
                        }
                        Row {
                            spacing: 4
                            Repeater {
                                model: parent.parent.modelData.filters
                                Label {
                                    required property string modelData
                                    text: modelData
                                    color: root.filterColor(modelData)
                                    font.pixelSize: 11
                                }
                            }
                        }
                        Label {
                            Layout.fillWidth: true
                            text: parent.modelData.files.join("  ")
                            color: root.inkFaint
                            font.pixelSize: 10
                            elide: Text.ElideMiddle
                        }
                    }
                }
                Row {
                    spacing: 12
                    anchors.right: parent.right
                    Button {
                        text: qsTr("Cancel")
                        flat: true
                        font.pixelSize: 11
                        onClicked: root.archiveProposals = []
                    }
                    Button {
                        text: qsTr("Import all")
                        flat: true
                        font.pixelSize: 11
                        palette.buttonText: root.ink
                        onClicked: {
                            const n = Sessions.importArchive(root.archiveDir)
                            root.archiveProposals = []
                            root.reclaimText = qsTr("%1 session(s) imported").arg(n)
                            reclaimTimer.restart()
                        }
                    }
                }
            }
        }
    }

    // ── Delete confirmation overlay ──────────────────────────────────
    Rectangle {
        visible: root.confirmMode > 0
        anchors.fill: parent
        color: "#80FFFFFF"
        z: 60
        MouseArea { anchors.fill: parent; onClicked: root.confirmMode = 0 }

        Rectangle {
            anchors.centerIn: parent
            width: 380
            height: confirmCol.height + 48
            color: "#FFFFFF"
            border.width: 1
            border.color: root.ink
            Column {
                id: confirmCol
                anchors.centerIn: parent
                width: parent.width - 48
                spacing: 14
                Label {
                    text: root.confirmMode === 2
                          ? qsTr("Empty quarantine")
                          : qsTr("Delete session %1").arg(strip.currentItem ? strip.currentItem.sSeq : "")
                    color: root.ink
                    font.pixelSize: 13
                    font.letterSpacing: 1
                }
                Label {
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: root.confirmMode === 2
                          ? qsTr("%1 rejected session(s) — TIFFs, proxies and sidecars are permanently deleted. Not the OS trash. No undo.")
                                .arg(Sessions.rejectedCount)
                          : qsTr("%1 — TIFFs, proxies and sidecar are permanently deleted. Not the OS trash. No undo.")
                                .arg(root.fmtGB(Sessions.sessionGB(strip.currentIndex)))
                    color: root.inkMuted
                    font.pixelSize: 11
                }
                Row {
                    spacing: 12
                    anchors.right: parent.right
                    Button {
                        text: qsTr("Cancel")
                        flat: true
                        font.pixelSize: 11
                        onClicked: root.confirmMode = 0
                    }
                    Button {
                        text: root.confirmMode === 2 ? qsTr("Delete all rejected") : qsTr("Delete permanently")
                        flat: true
                        font.pixelSize: 11
                        palette.buttonText: root.ink
                        onClicked: {
                            if (root.confirmMode === 2)
                                Sessions.emptyQuarantine()
                            else
                                Sessions.deleteSession(strip.currentIndex)
                            root.confirmMode = 0
                        }
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
