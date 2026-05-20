// Hairline.qml — 1 px horizontal separator.
// Port of theme::hairline() in include/ui/theme.h.
//
// Usage:
//   Hairline { x: 30; y: 80; width: 740 }
//   Hairline { x: 30; y: 80; width: 740; lineColor: Theme.borderDim }

import QtQuick
import XylosomeHMI 1.0

Rectangle {
    property color lineColor: Theme.border

    height: 1
    color:  lineColor
}
