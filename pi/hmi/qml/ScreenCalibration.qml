// ScreenCalibration.qml — settings ▸ calibration. Homing/zero offsets and touch,
// plus the TDI sync override (see Calib.qml): tdi.sync on makes every scan mode
// use lines/deg below instead of its own constant.
import QtQuick
import XylosomeHMI 1.0

ChoiceList {
    id: calList
    title: "calibration"
    entries: [
        { key: "tdi.sync",      value: Calib.syncEnabled ? "on" : "off", options: ["off", "on"] },
        { key: "lines/deg",     value: Calib.syncLinesPerDeg.toFixed(1),
          min: 100, max: 250, step: 0.5, unit: "" },
        { key: "homing.offset", value: "0.0°",  options: ["-1.0°", "-0.5°", "0.0°", "+0.5°", "+1.0°"] },
        { key: "axis.zero",     value: "set",    options: ["set", "clear"] },
        { key: "touch.cal",     value: "idle",   options: ["idle", "run"] },
        { key: "backlash",      value: "0.00°" }
    ]

    onRowActivated: function(idx) {
        var key = calList.rowKey(idx)
        if (key === "tdi.sync")  Calib.setSyncEnabled(calList.rowValue(idx) === "on")
        if (key === "lines/deg") Calib.setSyncLinesPerDeg(parseFloat(calList.rowValue(idx)))
    }
}
