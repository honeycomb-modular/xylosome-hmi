// ScreenFlatField.qml — settings ▸ calibration ▸ flat field. The camera's own
// flat-field correction, as three buttons.
//
// The HS-80 removes its fixed column pattern (tap steps, dust shadows, lens
// falloff) with per-pixel coefficients it calibrates itself: a dark set (FPN,
// `ccf`) and a white set (PRNU, `ccp`). Done by hand over the agent's raw
// pass-through on 2026-09-13 (docs/concept/calibration_modes_ideas.md); this
// page runs the same steps through the capture agent ({"cmd":"ffc"}):
//
//   1 dark   cap the lens → ccf, written to set 1
//   2 white  white panel filling the view, evenly lit → the agent finds the
//            free-run exposure that puts the brightest columns near 80%, then
//            ccp, written to set 1, line rate restored
//   3 save   epc 1 1 (both sets on) + wus (survives a power cycle)
//
// It calibrates the camera AS IT STANDS: direction, stages, gain, and the lens
// at its working aperture. Redo it when any of those change.

import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root
    width: 960; height: 540

    property string runStep:   ""          // step the agent is running now ("" = none)
    property string note:      ""
    property bool   failed:    false
    // Per-step result shown at the right of each row.
    property string darkResult: "·"
    property string flatResult: "·"
    property string saveResult: "·"

    readonly property bool canRun: Camera.connected && root.runStep === "" && !Beckhoff.running

    function run(step) {
        if (!Camera.connected || root.runStep !== "") return
        if (Beckhoff.running) { root.failed = true; root.note = "a scan is running — wait for it to finish"; return }
        root.runStep = step
        root.failed  = false
        root.note    = "starting " + step
        root.setResult(step, "…")
        Camera.ffc(step)
    }

    function setResult(step, text) {
        if (step === "dark") root.darkResult = text
        else if (step === "flat") root.flatResult = text
        else if (step === "save") root.saveResult = text
    }

    Connections {
        target: Camera
        function onFfcEvent(step, state, note, level, rate) {
            // An agent without the ffc command refuses with a bare
            // {"ack":"ffc","ok":false}: no step, no note. Pin it on the step
            // we asked for and say what that silence means.
            if (step === "") step = root.runStep
            root.note = note !== "" ? note : "capture agent refused the command — is it running the new build?"
            if (state === "running") { root.runStep = step; root.failed = false; return }
            root.runStep = ""
            root.failed  = (state === "failed")
            if (state === "done")
                root.setResult(step, step === "flat"
                               ? "✓ " + Math.round(level * 100) + "% at " + Math.round(rate) + " Hz"
                               : "✓ done")
            else
                root.setResult(step, "✗ failed")
        }
        function onConnectedChanged() {
            if (!Camera.connected && root.runStep !== "") {
                root.setResult(root.runStep, "?")
                root.runStep = ""; root.failed = true
                root.note = "capture agent went away mid-step — check its log"
            }
        }
    }

    // ── Touch-free focus ────────────────────────────────────────────────────────
    property var focusController: ffFocus
    function focusBack() {
        if (root.runStep !== "") return
        root.StackView.view.pop()
    }

    FocusController {
        id: ffFocus
        targets: [darkBtn, flatBtn, saveBtn, backBtn]
        onActivated: function(item) { if (item.clicked) item.clicked() }
    }

    // ── Title ───────────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: Theme.titleY
        text:  "settings ▸ calibration ▸ flat field"
        color: Theme.colorText
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }
    Text {
        x: Theme.marginX; y: 48
        text: "sensor flat-field correction — removes the fixed column pattern (tap steps, dust, falloff)"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
    }
    Text {
        x: Theme.marginX; y: 80
        text: Camera.connected
              ? "camera as it stands: " + Camera.scanDir + " · " + Camera.tdiStages + " stages · "
                + Camera.gain + " dB · " + Camera.lineRate.toFixed(0) + " Hz — redo after changing any of these, or the aperture"
              : "capture agent offline — nothing here works without it"
        color: Camera.connected ? Theme.colorTextDim : Theme.danger
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Hairline { x: Theme.marginX; y: 106; width: Theme.contentW }

    // ── The three steps ─────────────────────────────────────────────────────────
    component StepRow: Item {
        property string num: ""
        property string name: ""
        property string desc: ""
        property string result: "·"
        property bool   running: false
        x: Theme.marginX; width: Theme.contentW; height: 64
        Text {
            x: 0; y: 6
            text: num + "  " + name
            color: running ? Theme.accent : Theme.colorText
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontH2 }
        }
        Text {
            x: 0; y: 40
            text: desc
            color: Theme.colorTextDim
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
        }
        Text {
            x: 470; y: 12
            text: result
            color: result.indexOf("✗") === 0 ? Theme.danger
                 : result.indexOf("✓") === 0 ? Theme.accent : Theme.colorTextDim
            font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
        }
    }

    StepRow { y: 118; num: "1"; name: "dark";  desc: "cap the lens, then run — ccf, up to 2 min";
              result: root.darkResult; running: root.runStep === "dark" }
    StepRow { y: 196; num: "2"; name: "white"; desc: "white panel filling the view, even light, focus does not matter — ccp, up to 2 min";
              result: root.flatResult; running: root.runStep === "flat" }
    StepRow { y: 274; num: "3"; name: "save";  desc: "switch the coefficients on and keep them across power cycles";
              result: root.saveResult; running: root.runStep === "save" }

    TerminalButton { id: darkBtn; controller: ffFocus; x: Theme.marginX + Theme.contentW - 120; y: 124; width: 120; height: 40
        label: root.runStep === "dark" ? "[running]" : "[run]"; active: root.runStep === "dark"
        textColor: root.canRun ? Theme.colorText : Theme.colorTextFaint; onClicked: root.run("dark") }
    TerminalButton { id: flatBtn; controller: ffFocus; x: Theme.marginX + Theme.contentW - 120; y: 202; width: 120; height: 40
        label: root.runStep === "flat" ? "[running]" : "[run]"; active: root.runStep === "flat"
        textColor: root.canRun ? Theme.colorText : Theme.colorTextFaint; onClicked: root.run("flat") }
    TerminalButton { id: saveBtn; controller: ffFocus; x: Theme.marginX + Theme.contentW - 120; y: 280; width: 120; height: 40
        label: root.runStep === "save" ? "[saving]" : "[save]"; active: root.runStep === "save"
        textColor: root.canRun ? Theme.colorText : Theme.colorTextFaint; onClicked: root.run("save") }

    Hairline { x: Theme.marginX; y: 346; width: Theme.contentW }

    // ── Status ──────────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: 360
        width: Theme.contentW; wrapMode: Text.WordWrap
        text: root.note
        color: root.failed ? Theme.danger : root.runStep !== "" ? Theme.accent : Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
    }
    Text {
        x: Theme.marginX; y: 412
        width: Theme.contentW; wrapMode: Text.WordWrap
        text: "run 1 and 2 in order, then 3. Each step holds the grabber while it runs — do not scan or go LIVE meanwhile. "
              + "The white step picks its own exposure: if it reports too dark or clipping, change the light and run it again."
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

    // ── [back] ──────────────────────────────────────────────────────────────────
    TerminalButton {
        id: backBtn
        controller: ffFocus
        x: Theme.marginX
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: Theme.bottomBtnW; height: Theme.bottomBtnH
        label: "[back]"; active: false
        textColor: root.runStep === "" ? Theme.colorText : Theme.colorTextFaint
        onClicked: root.focusBack()
    }
}
