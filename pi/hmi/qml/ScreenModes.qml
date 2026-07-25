// ScreenModes.qml — capture mode picker.
//
// The modes are still siblings at ONE stack depth: this page replaces the
// capture page you came from, and picking a mode replaces this one. Nothing is
// ever nested inside a mode, and the encoder ring on each capture page stays
// short — one [modes] button instead of four mode buttons to cycle past.
//
// `fromPage` is the page that opened this one, so [back] returns to the mode
// you were actually in rather than guessing.

import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root
    width: 960; height: 540

    property string fromPage: "ScreenScan.qml"

    function goTo(page) {
        root.StackView.view.replace(root.StackView.view.currentItem,
                                    Qt.resolvedUrl(page))
    }

    property var focusController: modeFocus
    function focusBack() { root.goTo(root.fromPage) }

    FocusController {
        id: modeFocus
        targets: [navScan, navTimed, navStatic, navJog, backBtn]
        onActivated: function(item) { item.clicked() }
    }

    // ── Header ────────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: Theme.titleY
        text:  "capture.modes"
        color: Theme.colorText
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }
    Text {
        x: Theme.marginX; y: 48
        text:  "what the axis does while the camera scans"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
    }
    Hairline { x: 0; y: Theme.hairlineTopY; width: 960 }

    // ── The modes ─────────────────────────────────────────────────────────────
    NavRow {
        id: navScan
        controller: modeFocus
        x: Theme.marginX; y: Theme.contentTop + 40; width: Theme.contentW
        rowName: "scan";   rowDesc: "velocity curve over an arc — 1 or 4 pass"
        onClicked: root.goTo("ScreenScan.qml")
    }
    NavRow {
        id: navTimed
        controller: modeFocus
        x: Theme.marginX; y: Theme.contentTop + 40 + Theme.rowStride; width: Theme.contentW
        rowName: "timed";  rowDesc: "constant crawl over a span — seconds to 24 h"
        onClicked: root.goTo("ScreenTimed.qml")
    }
    NavRow {
        id: navStatic
        controller: modeFocus
        x: Theme.marginX; y: Theme.contentTop + 40 + Theme.rowStride * 2; width: Theme.contentW
        rowName: "static"; rowDesc: "lines only — the camera never moves"
        onClicked: root.goTo("ScreenStatic.qml")
    }
    NavRow {
        id: navJog
        controller: modeFocus
        x: Theme.marginX; y: Theme.contentTop + 40 + Theme.rowStride * 3; width: Theme.contentW
        rowName: "jog";    rowDesc: "position the axis — nothing is captured"
        onClicked: root.goTo("ScreenJog.qml")
    }

    // Which one you are in now — stated rather than highlighted, since the rows
    // are a destination list, not a radio group.
    Text {
        x: Theme.marginX; y: Theme.contentTop + 40 + Theme.rowStride * 4 + 12
        text:  "currently in " + root.fromPage.replace("Screen", "").replace(".qml", "").toLowerCase()
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

    // ── Bottom bar ────────────────────────────────────────────────────────────
    Hairline { x: 0; y: Theme.bottomBarY; width: 960 }

    TerminalButton {
        id: backBtn
        controller: modeFocus
        x: Theme.marginX
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: Theme.bottomBtnW; height: Theme.bottomBtnH
        label: "[back]"; active: false
        onClicked: root.goTo(root.fromPage)
    }

    FaultChip {
        id: faultChip
        controller: null
        anchors { left: backBtn.right; leftMargin: 24; bottom: parent.bottom; bottomMargin: 27 }
    }
}
