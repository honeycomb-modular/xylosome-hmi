// ScreenModes.qml — capture mode picker.
//
// The modes are still siblings at ONE stack depth: this page replaces the
// capture page you came from, and picking a mode replaces this one. Nothing is
// ever nested inside a mode, and the encoder ring on each capture page stays
// short — one [modes] button instead of four mode buttons to cycle past.
//
// `fromPage` is the page that opened this one, so [back] returns to the mode
// you were actually in rather than guessing.
//
// EVERY mode is on this list, built or not. A row with no `page` is greyed and
// disabled — Item.enabled stops its MouseArea too, so it cannot be clicked, and
// rebuildTargets() leaves it out of the encoder ring. Building a mode is then
// one edit: give its row a page. Fourteen rows do not fit at the standard row
// height, so the list runs compact (see NavRow.rowH / fontSize).

import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root
    width: 960; height: 540

    property string fromPage: "ScreenScan.qml"

    // Compact list geometry — 14 rows between the header and the bottom bar.
    readonly property int listTop:    98
    readonly property int listStride: 26

    function goTo(page) {
        root.StackView.view.replace(root.StackView.view.currentItem,
                                    Qt.resolvedUrl(page))
    }

    property var focusController: modeFocus
    function focusBack() { root.goTo(root.fromPage) }

    function rebuildTargets() {
        var t = []
        for (var i = 0; i < modeRepeater.count; i++) {
            var it = modeRepeater.itemAt(i)
            if (it && it.enabled) t.push(it)      // greyed rows are not in the ring
        }
        t.push(backBtn)
        modeFocus.targets = t
    }

    FocusController {
        id: modeFocus
        targets: [backBtn]
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
        text:  "what the axis does while the camera scans  ·  greyed = not built yet"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
    }

    // Which one you are in now — stated rather than highlighted, since the rows
    // are a destination list, not a radio group.
    Text {
        x: Theme.marginX + Theme.contentW - width; y: 48
        text:  "currently in " + root.fromPage.replace("Screen", "").replace(".qml", "").toLowerCase()
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

    // ── The modes ─────────────────────────────────────────────────────────────
    // Built ones first, then the planned ones ordered by reach: stack ·
    // trichrome · ramp · gradient need no xylod change; the rest are blocked on
    // reversible motion or a flexible pass count. See
    // docs/superpowers/specs/2026-08-09-capture-art-modes.md §5.
    Repeater {
        id: modeRepeater
        onItemAdded:   root.rebuildTargets()
        onItemRemoved: root.rebuildTargets()

        model: [
            { name: "scan",      desc: "velocity curve over an arc — 1 or 4 pass",     page: "ScreenScan.qml"   },
            { name: "timed",     desc: "constant crawl over a span — seconds to 24 h", page: "ScreenTimed.qml"  },
            { name: "static",    desc: "lines only — the camera never moves",          page: "ScreenStatic.qml" },
            { name: "chrono",    desc: "the same frame on an interval — time-lapse",   page: "ScreenChrono.qml" },
            { name: "ramp",      desc: "linear speed ramp — lines follow it, or don't", page: "ScreenRamp.qml"   },
            { name: "freerun",   desc: "speed curve over time — lines run at their own fixed rate", page: "ScreenFreerun.qml" },
            { name: "pendulum",  desc: "swings back and forth while scanning",         page: "ScreenPendulum.qml" },
            { name: "stack",     desc: "N identical sweeps — average, or dither for detail", page: "ScreenStack.qml" },
            { name: "party",     desc: "an irregular dance — seeded, repeatable",      page: "ScreenParty.qml"  },
            { name: "hdr",       desc: "the same sweep at several exposures",          page: "ScreenHdr.qml"    },
            { name: "jog",       desc: "position the axis — nothing is captured",      page: "ScreenJog.qml"    },

            { name: "trichrome", desc: "sequential R/G/B filter passes"      },
            { name: "gradient",  desc: "exposure varies over the scan"       },
            { name: "echo",      desc: "repeated / offset structure"         }
        ]

        delegate: NavRow {
            required property var  modelData
            required property int  index

            controller: modeFocus
            x: Theme.marginX
            y: root.listTop + index * root.listStride
            width: Theme.contentW

            rowH:     root.listStride
            fontSize: Theme.fontMonoS

            enabled:  modelData.page !== undefined
            rowName:  modelData.name
            rowDesc:  modelData.desc

            onClicked: if (modelData.page !== undefined) root.goTo(modelData.page)
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

    Component.onCompleted: root.rebuildTargets()
}
