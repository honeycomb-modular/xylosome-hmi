// ScreenAxis.qml — settings ▸ axis / motion. Speeds + drive info.
// A6-EC servo + 50:1 harmonic drive, over EtherCAT (xylod).
import QtQuick
import XylosomeHMI 1.0

ChoiceList {
    title: "axis / motion"
    entries: [
        { key: "active.axis",     value: "A6-EC  ANCTL AS715N" },
        { key: "gear.ratio",      value: "50.0  (harmonic drive)" },
        { key: "max.speed",       value: "300 deg/s  (curve top)" },
        { key: "std.scan.speed",  value: "" + Motor.stdSpeedDegS + " deg/s",
          options: ["40 deg/s", "60 deg/s", "100 deg/s", "140 deg/s", "180 deg/s", "220 deg/s"] },
        { key: "min.speed",       value: "1 deg/s  (curve floor)" },
        { key: "accel",           value: "medium",    options: ["low", "medium", "high"] },
        { key: "motion.bus",      value: "beckhoff / ethercat" }
    ]

    // Persist the standard (curve-centre) scan speed when its row is cycled.
    onRowActivated: function(index) {
        if (entries[index] && entries[index].key === "std.scan.speed")
            Motor.stdSpeedDegS = parseFloat(rowValue(index))
    }
}
