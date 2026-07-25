// ScreenCamera.qml — settings ▸ camera. LIVE control of the Piranha HS-80 via
// the capture agent (camera bus, capture/PROTOCOL.md). Values shown are the
// camera's real state when the screen opens; cycling a row (enter) sends the
// new value to the camera and it is applied over COM3. Real ranges (TDI stages
// 16..96, line rate up to the camera's readout ceiling) — replaces the old fixed
// placard. That ceiling follows the bit depth: 38314 Hz at 12-bit (clm 16, what
// runs), 68610 at 8-bit 8-tap. The agent rejects anything above it, so a stale
// max here only offers a value that will bounce — but keep the two in step.
//
// Offline (capture agent unreachable): a single status row, nothing to cycle.
import QtQuick
import XylosomeHMI 1.0

ChoiceList {
    id: cam
    title: "camera"

    entries: Camera.connected ? [
        { key: "line.rate",  value: Camera.lineRate.toFixed(0),
          min: 3500, max: 38314, step: 100, unit: "Hz" },
        { key: "tdi.stages", value: "" + Camera.tdiStages,
          options: ["16", "32", "48", "64", "80", "96"] },
        // Full analog range the camera accepts (capture/PROTOCOL.md: -10..+10 dB,
        // enforced in apply_set). A range row rather than a cycle list — 21 stops
        // is far too many to click through, and the old ["0","3","6"] could not
        // reach the negative half at all. Startup default is -6.
        { key: "gain",       value: Camera.gain,
          min: -10, max: 10, step: 1, unit: "dB" },
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
