// ScreenDisplay.qml — settings ▸ display. WaveShare 5.5" AMOLED.
import QtQuick
import XylosomeHMI 1.0

ChoiceList {
    title: "display"
    entries: [
        { key: "brightness",  value: "100 %", options: ["25 %", "50 %", "75 %", "100 %"] },
        { key: "blank.after", value: "never", options: ["never", "5 min", "15 min", "30 min"] }
    ]
}
