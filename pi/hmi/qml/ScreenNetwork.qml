// ScreenNetwork.qml — settings ▸ network. Pi ↔ Beckhoff C6920 (xylod) link.
import QtQuick
import XylosomeHMI 1.0

ChoiceList {
    title: "network"
    entries: [
        { key: "wifi.mode",      value: "access point",   options: ["access point", "client", "off"] },
        { key: "wifi.ssid",      value: "xylosome01" },
        { key: "ip.addr",        value: "192.168.10.3" },
        { key: "server.port",    value: "8080",           options: ["8080", "80", "9090"] },
        { key: "beckhoff.ip",    value: Beckhoff.host },
        { key: "beckhoff.port",  value: "" + Beckhoff.port },
        { key: "beckhoff.link",  value: Beckhoff.connected ? "connected" : "offline" },
        { key: "beckhoff.state", value: Beckhoff.state }
    ]
}
