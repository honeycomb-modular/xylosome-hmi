// FocusIndicator.qml — touch-free focus cursor.
//
// A single overlay drawn as four corner brackets (camera-AF style) around the
// currently focused Item. One instance per screen; bind `target` to the focus
// controller's `current` item and the brackets fly to it.
//
// Usage:
//   FocusIndicator { target: myFocusController.current }
//
// Non-interactive (no MouseArea) — never steals touch from the UI beneath it.

import QtQuick
import XylosomeHMI 1.0

Item {
    id: root

    // Item the brackets should frame. null → hidden.
    property Item target: null

    // Appearance
    property int   pad:       5     // gap between target edge and brackets
    property int   armLen:   14     // length of each bracket arm
    property int   thickness: 2
    property color frameColor: Theme.accent

    z: 100
    visible: target !== null

    // Position over the target, expressed in this item's parent coordinates.
    // Recomputed when `target` changes (targets are static-layout items, so
    // identity change is the trigger we need).
    readonly property point _tl: target ? target.mapToItem(parent, 0, 0) : Qt.point(0, 0)
    x:      target ? _tl.x - pad : 0
    y:      target ? _tl.y - pad : 0
    width:  target ? target.width  + pad * 2 : 0
    height: target ? target.height + pad * 2 : 0

    // Smooth glide between targets.
    Behavior on x      { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
    Behavior on y      { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
    Behavior on width  { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
    Behavior on height { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

    // ── Four corner brackets (two arms each) ────────────────────────────────────
    // Top-left
    Rectangle { color: root.frameColor; x: 0; y: 0; width: root.armLen;   height: root.thickness }
    Rectangle { color: root.frameColor; x: 0; y: 0; width: root.thickness; height: root.armLen }
    // Top-right
    Rectangle { color: root.frameColor; x: root.width - root.armLen;   y: 0; width: root.armLen;   height: root.thickness }
    Rectangle { color: root.frameColor; x: root.width - root.thickness; y: 0; width: root.thickness; height: root.armLen }
    // Bottom-left
    Rectangle { color: root.frameColor; x: 0; y: root.height - root.thickness; width: root.armLen;   height: root.thickness }
    Rectangle { color: root.frameColor; x: 0; y: root.height - root.armLen;    width: root.thickness; height: root.armLen }
    // Bottom-right
    Rectangle { color: root.frameColor; x: root.width - root.armLen;   y: root.height - root.thickness; width: root.armLen;   height: root.thickness }
    Rectangle { color: root.frameColor; x: root.width - root.thickness; y: root.height - root.armLen;    width: root.thickness; height: root.armLen }
}
