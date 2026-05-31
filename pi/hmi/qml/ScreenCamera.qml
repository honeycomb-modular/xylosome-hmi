// ScreenCamera.qml — settings ▸ camera. Dalsa Piranha 8K BW line scanner via
// Teledyne frame grabber (capture PC owns acquisition; these are the params the
// operator references per pass).
import QtQuick
import XylosomeHMI 1.0

ChoiceList {
    title: "camera"
    entries: [
        { key: "line.rate",   value: "40 kHz",  options: ["20 kHz", "40 kHz", "80 kHz"] },
        { key: "tdi.stages",  value: "128",     options: ["64", "128", "256"] },
        { key: "exposure",    value: "auto",    options: ["auto", "manual"] },
        { key: "gain",        value: "0 dB",    options: ["0 dB", "6 dB", "12 dB"] },
        { key: "scan.dir",    value: "forward", options: ["forward", "reverse"] }
    ]
}
