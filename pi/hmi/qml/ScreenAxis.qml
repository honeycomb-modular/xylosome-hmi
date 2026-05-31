// ScreenAxis.qml — settings ▸ axis / motion. Panasonic Minas A6 servo +
// 50:1 harmonic drive, orchestrated by ClearCore.
import QtQuick
import XylosomeHMI 1.0

ChoiceList {
    title: "axis / motion"
    entries: [
        { key: "gear.ratio",  value: "50:1" },
        { key: "max.speed",   value: "100 deg/s", options: ["50 deg/s", "100 deg/s", "200 deg/s"] },
        { key: "accel",       value: "medium",    options: ["low", "medium", "high"] },
        { key: "homing.dir",  value: "ccw",       options: ["cw", "ccw"] },
        { key: "motion.bus",  value: "clearcore / tcp" }
    ]
}
