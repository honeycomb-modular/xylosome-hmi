// ScreenDevices.qml — connected devices status. Read-only until the ClearCore
// TCP client and pendant serial bridge are wired; values reflect reality (no
// live links yet).
import QtQuick
import XylosomeHMI 1.0

ChoiceList {
    title: "connected devices"
    entries: [
        { key: "clearcore",  value: "link down" },
        { key: "teensy",     value: "usb: n/a" },
        { key: "camera",     value: "capture pc (separate)" },
        { key: "hmi",        value: "online" }
    ]
}
