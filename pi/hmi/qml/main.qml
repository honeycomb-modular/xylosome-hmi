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

        // ── Pendant input router ────────────────────────────────────────────────
        // Maps keyboard keys to the focus grammar for dev/testing. The Teensy
        // pendant will later feed the same actions via serial, no screen changes needed.
        //
        // Pendant grammar:
        //   ENC rotate       → moveNext / movePrev
        //   ENC push         → enter (navigate mode) OR focusContext (editing mode)
        //   BTN2             → back / cancel, one level at a time
        //   BTN1             → btn1Execute (dedicated execute, not in focus chain)
        //
        // Key simulation:
        //   ↓ / → / Tab     → moveNext       ↑ / ← / Backtab → movePrev
        //   Enter / Space   → ENC push       Esc / Backspace  → BTN2 back
        //   Delete          → BTN1 execute
        focus: true
        Keys.onPressed: function(event) {
            var s  = nav.currentItem
            var fc = (s && s.focusController) ? s.focusController : null
            switch (event.key) {
            case Qt.Key_Down: case Qt.Key_Right: case Qt.Key_Tab:
                if (fc) { fc.moveNext(); event.accepted = true } break
            case Qt.Key_Up: case Qt.Key_Left: case Qt.Key_Backtab:
                if (fc) { fc.movePrev(); event.accepted = true } break
            case Qt.Key_Return: case Qt.Key_Enter: case Qt.Key_Space:
                // ENC push: editing → focusContext (confirm/context); navigate → fc.enter (activate).
                if (fc && fc.editing && s && typeof s.focusContext === "function") {
                    s.focusContext(); event.accepted = true
                } else if (fc) {
                    fc.enter(); event.accepted = true
                }
                break
            case Qt.Key_Delete:   // BTN1 — dedicated execute, not in focus chain
                if (s && typeof s.btn1Execute === "function") { s.btn1Execute(); event.accepted = true }
                break
            case Qt.Key_Escape: case Qt.Key_Backspace:
                if (fc && fc.editing) { fc.back(); event.accepted = true }
                else if (s && typeof s.focusBack === "function") { s.focusBack(); event.accepted = true }
                break
            }
        }

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
