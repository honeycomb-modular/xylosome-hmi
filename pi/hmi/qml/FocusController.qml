// FocusController.qml — non-visual focus state for one screen.
//
// Holds an ordered list of focusable Items and a current index. The pendant
// grammar maps onto it directly:
//   ENC rotate  → moveNext() / movePrev()
//   ENC click   → enter()
//   BTN2 (back) → back()
//
// Two modes:
//   • Navigating (editing == false): rotate moves the cursor between targets,
//     enter emits activated(current), back is handled by the screen.
//   • Editing   (editing == true):  rotate emits adjust(±1), enter emits
//     confirmed(), back emits canceled(). The host screen sets `editing` when a
//     target is "entered" into a deeper edit interaction, and runs its own
//     level logic off these three signals.
//
// Transport-agnostic: today it's driven by keyboard keys in main.qml; later by
// the Teensy pendant over serial. This object never knows which.

import QtQuick

Item {
    id: ctl

    // Ordered focus targets for the host screen. Set as an array of Items.
    property var targets: []

    // Index of the focused target.
    property int index: 0

    // Wrap around the ends (true) or clamp (false).
    property bool wrap: true

    // When true, rotate/enter/back are redirected to the edit signals below.
    property bool editing: false

    // The focused Item, or null when there are no targets.
    readonly property Item current:
        (targets.length > 0 && index >= 0 && index < targets.length)
            ? targets[index] : null

    // Navigating-mode: enter on the focused item.
    signal activated(Item item)
    // Editing-mode signals.
    signal adjust(int delta)   // rotate while editing
    signal confirmed()         // enter while editing
    signal canceled()          // back while editing

    function moveNext() {
        if (editing) { ctl.adjust(1); return }
        if (targets.length === 0) return
        index = wrap ? (index + 1) % targets.length
                     : Math.min(index + 1, targets.length - 1)
    }

    function movePrev() {
        if (editing) { ctl.adjust(-1); return }
        if (targets.length === 0) return
        index = wrap ? (index - 1 + targets.length) % targets.length
                     : Math.max(index - 1, 0)
    }

    function enter() {
        if (editing) { ctl.confirmed(); return }
        if (current) ctl.activated(current)
    }

    function back() {
        if (editing) ctl.canceled()
    }
}
