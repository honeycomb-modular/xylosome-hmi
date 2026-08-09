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
        targets: [navScan, navTimed, navStatic, navChrono, navJog, backBtn]
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

    // Which one you are in now — stated rather than highlighted, since the rows
    // are a destination list, not a radio group. Sits in the header because the
    // planned block below took the space under the live rows.
    Text {
        x: Theme.marginX + Theme.contentW - width; y: 48
        text:  "currently in " + root.fromPage.replace("Screen", "").replace(".qml", "").toLowerCase()
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

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
        id: navChrono
        controller: modeFocus
        x: Theme.marginX; y: Theme.contentTop + 40 + Theme.rowStride * 3; width: Theme.contentW
        rowName: "chrono"; rowDesc: "the same frame on an interval — time-lapse"
        onClicked: root.goTo("ScreenChrono.qml")
    }
    NavRow {
        id: navJog
        controller: modeFocus
        x: Theme.marginX; y: Theme.contentTop + 40 + Theme.rowStride * 4; width: Theme.contentW
        rowName: "jog";    rowDesc: "position the axis — nothing is captured"
        onClicked: root.goTo("ScreenJog.qml")
    }

    // ── Planned modes ─────────────────────────────────────────────────────────
    // Roadmap, not product. These have no parameter page yet, so they are
    // deliberately NOT in modeFocus.targets and cannot be clicked — there is
    // nothing behind them to open. As each one is built it graduates up into the
    // live list above, so this page states the build status without anyone
    // maintaining it by hand.
    //
    // Order is by reach, not by taste — reading down the columns, the reachable
    // ones come first: stack/trichrome/ramp/gradient need no xylod change, the
    // rest are blocked on reversible motion or a flexible pass count.
    // See docs/superpowers/specs/2026-08-09-capture-art-modes.md §5.
    Hairline { x: Theme.marginX; y: 374; width: Theme.contentW }

    Text {
        x: Theme.marginX; y: 386
        text:  "planned"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

    Repeater {
        model: [
            { name: "stack",     desc: "pass averaging"    },
            { name: "trichrome", desc: "R/G/B passes"      },
            { name: "ramp",      desc: "velocity over arc" },
            { name: "gradient",  desc: "exposure over arc" },
            { name: "hdr",       desc: "exposure brackets" },
            { name: "superres",  desc: "sub-pixel passes"  },
            { name: "party",     desc: "back/forth bursts" },
            { name: "pendulum",  desc: "sine motion"       },
            { name: "echo",      desc: "repeat / offset"   }
        ]

        delegate: Item {
            x: Theme.marginX + Math.floor(index / 3) * 308
            y: 408 + (index % 3) * 22

            readonly property var rowData: modelData

            // One notch dimmer than a live row throughout: name reads as a live
            // row's description, description as its faintest text.
            Text {
                text:  rowData.name
                color: Theme.colorTextDim
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
            }
            Text {
                x: 110
                text:  rowData.desc
                color: Theme.colorTextFaint
                font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
            }
        }
    }

    // ── Bottom bar ────────────────────────────────────────────────────────────

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
