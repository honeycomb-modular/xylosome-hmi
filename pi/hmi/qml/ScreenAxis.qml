// ScreenAxis.qml — settings ▸ axis / motion. Panasonic Minas A6 servo +
// 30:10 tooth gear (3.0:1), orchestrated by ClearCore M-1.
import QtQuick
import XylosomeHMI 1.0

ChoiceList {
    title: "axis / motion"
    entries: [
        { key: "active.axis",     value: "M1  panasonic minas a6" },
        { key: "gear.ratio",      value: "3.0  (30:10 tooth)" },
        { key: "max.speed",       value: "100 deg/s", options: ["50 deg/s", "100 deg/s", "200 deg/s"] },
        { key: "home.speed",      value: "20 deg/s",  options: ["5 deg/s", "20 deg/s", "50 deg/s"] },
        { key: "accel",           value: "medium",    options: ["low", "medium", "high"] },
        { key: "homing.dir",      value: "ccw",       options: ["cw", "ccw"] },
        { key: "spline.interval", value: "50 ms",     options: ["25 ms", "50 ms", "100 ms"] },
        { key: "motion.bus",      value: "clearcore / tcp / port 23" }
    ]
}
