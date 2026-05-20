// LabelledValue.qml — (label / value / unit) triplet for telemetry readouts.
// Port of labelled_value() in src/ui/screen_live.cpp.
//
// Usage:
//   LabelledValue {
//       x: 30; y: 360
//       label: "position"
//       value: Motor.position.toFixed(1)
//       unit:  "deg"
//   }

import QtQuick
import XylosomeHMI 1.0

Item {
    id: root

    property string label: "label"
    property string value: "  0.0"
    property string unit:  ""

    // Shrink-wrap height to content.
    implicitWidth:  valueText.width + unitText.width + 8
    implicitHeight: labelText.height + valueText.height + 2

    // ── Label ─────────────────────────────────────────────────────────────────
    Text {
        id: labelText
        text:  root.label
        color: Theme.colorTextDim
        font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
        anchors { top: parent.top; left: parent.left }
    }

    // ── Value (large) ─────────────────────────────────────────────────────────
    Text {
        id: valueText
        text:  root.value
        color: Theme.colorText
        font { family: Theme.fontFamily; pixelSize: Theme.fontH2 }
        anchors { top: labelText.bottom; topMargin: 2; left: parent.left }
    }

    // ── Unit ──────────────────────────────────────────────────────────────────
    Text {
        id: unitText
        text:  root.unit
        color: Theme.colorTextFaint
        font { family: Theme.fontFamily; pixelSize: Theme.fontBody }
        anchors { baseline: valueText.baseline; baselineOffset: -4; left: valueText.right; leftMargin: 4 }
    }
}
