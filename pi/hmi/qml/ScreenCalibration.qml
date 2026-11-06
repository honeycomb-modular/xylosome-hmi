// ScreenCalibration.qml — settings ▸ calibration. Homing/zero offsets and touch,
// plus the TDI sync override (see Calib.qml): tdi.sync on makes every scan mode
// use lines/deg below instead of its own constant.
import QtQuick
import QtQuick.Controls   // StackView attached property, for the flat.field push
import XylosomeHMI 1.0

ChoiceList {
    id: calList
    title: "calibration"
    entries: [
        { key: "tdi.sync",      value: Calib.syncEnabled ? "on" : "off", options: ["off", "on"] },
        // 0.1 steps: a 96-stage sweep pins the value to +-0.2 (tdi_sync_ratio.py),
        // and 0.1 lines/deg is 0.07 px of smear at 96 stages.
        { key: "lines/deg",     value: Calib.syncLinesPerDeg.toFixed(1),
          min: 100, max: 250, step: 0.1, unit: "" },
        { key: "homing.offset", value: "0.0°",  options: ["-1.0°", "-0.5°", "0.0°", "+0.5°", "+1.0°"] },
        { key: "axis.zero",     value: "set",    options: ["set", "clear"] },
        { key: "touch.cal",     value: "idle",   options: ["idle", "run"] },
        { key: "backlash",      value: "0.00°" },
        // Sensor flat field (camera FPN/PRNU) — opens its own page.
        { key: "flat.field",    value: "dark · white panel · save ▸", options: ["dark · white panel · save ▸"] },
        // Colour-wheel filter positions, taught by eye — opens its own page.
        { key: "colour.wheel",  value: "pick · jog · set ▸", options: ["pick · jog · set ▸"] }
    ]

    onRowActivated: function(idx) {
        var key = calList.rowKey(idx)
        if (key === "flat.field") { calList.StackView.view.push(Qt.resolvedUrl("ScreenFlatField.qml")); return }
        if (key === "colour.wheel") { calList.StackView.view.push(Qt.resolvedUrl("ScreenColourWheel.qml")); return }
        if (key === "tdi.sync")  Calib.setSyncEnabled(calList.rowValue(idx) === "on")
        if (key === "lines/deg") Calib.setSyncLinesPerDeg(parseFloat(calList.rowValue(idx)))
    }
}
