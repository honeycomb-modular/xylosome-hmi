// ScreenCalibration.qml — settings ▸ calibration. Homing/zero offsets and touch.
import QtQuick
import XylosomeHMI 1.0

ChoiceList {
    title: "calibration"
    entries: [
        { key: "homing.offset", value: "0.0°",  options: ["-1.0°", "-0.5°", "0.0°", "+0.5°", "+1.0°"] },
        { key: "axis.zero",     value: "set",    options: ["set", "clear"] },
        { key: "touch.cal",     value: "idle",   options: ["idle", "run"] },
        { key: "backlash",      value: "0.00°" }
    ]
}
