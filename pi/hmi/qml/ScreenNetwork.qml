// ScreenNetwork.qml — settings ▸ network. Pi ↔ ClearCore link + web control.
import QtQuick
import XylosomeHMI 1.0

ChoiceList {
    title: "network"
    entries: [
        { key: "wifi.mode",     value: "access point",   options: ["access point", "client", "off"] },
        { key: "wifi.ssid",     value: "xylosome01" },
        { key: "ip.addr",       value: "192.168.10.2" },
        { key: "server.port",   value: "8080",           options: ["8080", "80", "9090"] },
        { key: "clearcore.ip",  value: "192.168.10.10" },
        { key: "clearcore.link",value: "tcp / cat6" }
    ]
}
