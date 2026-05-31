// ScreenSystem.qml — settings ▸ system. Firmware / platform info.
// Enter on fw.version (row 0) plays the Odyssey trailer — the original easter egg.
import QtQuick
import XylosomeHMI 1.0

ChoiceList {
    title: "system"
    entries: [
        { key: "fw.version",  value: "0.1-qt" },
        { key: "fw.platform", value: "qt6 / qml / pi" },
        { key: "hmi.role",    value: "pendant / hmi only" }
    ]
    onRowActivated: function(index) {
        if (index === 0)
            Motor.playVideo("/home/hoyte/TheOdyssey_IMAX-Trailer-3_4K_51_prores.mp4")
    }
}
