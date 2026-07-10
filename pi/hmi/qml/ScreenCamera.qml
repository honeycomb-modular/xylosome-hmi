// ScreenCamera.qml — settings ▸ camera. LIVE control of the Piranha HS-80 via
// the capture agent (camera bus, capture/PROTOCOL.md). Values shown are the
// camera's real state when the screen opens; cycling a row (enter) sends the
// new value to the camera and it is applied over COM3. Real ranges (TDI stages
// 16..96, line rate up to ~68 kHz) — replaces the old fixed placard.
//
// Offline (capture agent unreachable): a single status row, nothing to cycle.
import QtQuick
import XylosomeHMI 1.0

ChoiceList {
    id: cam
    title: "camera"

    entries: Camera.connected ? [
        { key: "line.rate",  value: Camera.lineRate.toFixed(0),
          options: ["7000", "14000", "28000", "57000"] },
        { key: "tdi.stages", value: "" + Camera.tdiStages,
          options: ["16", "32", "48", "64", "80", "96"] },
        { key: "gain",       value: Camera.gain,
          options: ["0", "3", "6"] },
        { key: "scan.dir",   value: Camera.scanDir,
          options: ["forward", "reverse"] },
        { key: "link",       value: Camera.clm }          // read-only (bit depth/taps)
    ] : [
        { key: "status",     value: "capture agent offline" }
    ]

    // ChoiceList has already cycled the row's shown value on enter; push it to
    // the camera. Read-only rows (no options, e.g. "link") send nothing useful,
    // but the agent rejects unknown keys harmlessly.
    onRowActivated: function(idx) {
        if (!Camera.connected) return
        var key = cam.rowKey(idx)
        if (key === "link" || key === "status") return
        Camera.setParam(key, cam.rowValue(idx))
    }
}
