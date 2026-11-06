// ScreenColourWheel.qml — settings ▸ calibration ▸ colour wheel. Where each
// filter sits in front of the lens, taught by eye.
//
//   1 pick   a colour: the wheel turns to its stored position and holds there
//   2 jog    it in 1° / 0.1° steps until the filter sits right
//   3 set    where it stands becomes that colour's position (xylod keeps it)
//
// Red is the anchor. xylod's safety window and trip, and green and blue, are
// all measured from red — so setting red moves all three filters together
// (the fix when the whole wheel has shifted), while setting green or blue
// moves only that one. Hence: red first.
//
// Everything is done by xylod ({"cmd":"filter"}, "wheel_jog", "wheel_set");
// this page only sends them and mirrors `wheelDeg` / `wheelSlots` from status.

import QtQuick
import QtQuick.Controls
import XylosomeHMI 1.0

Item {
    id: root
    width: 960; height: 540

    readonly property var names: ["red", "green", "blue"]
    property int    sel:    -1        // colour picked on this page (-1 = none yet)
    property string note:   "pick a colour — the wheel turns to it and holds"
    property bool   failed: false

    // xylod reports wheelDeg only while the wheel is fitted and usable.
    readonly property bool wheelOk: Beckhoff.connected && !isNaN(Beckhoff.wheelDeg)
    // Jog and set act on the wheel where it stands: holding on the picked
    // colour, nothing else going on. xylod ignores them otherwise.
    readonly property bool ready: wheelOk && sel >= 0 && Beckhoff.state === "idle"
    // xylod refuses a larger red move per set (EcBackend.cpp, kWheelRedStepDeg).
    readonly property real redStepMax: 10.0

    function fmt(d)     { return isNaN(d) ? "—" : (d < 0 ? "−" : "+") + Math.abs(d).toFixed(2) + "°" }
    function slotDeg(k) { var s = Beckhoff.wheelSlots; return (s && s.length === 3) ? s[k] : NaN }
    function say(text, bad) { root.note = text; root.failed = (bad === true) }

    function pick(k) {
        if (!root.wheelOk)             { say("wheel not ready — see the line at the top", true); return }
        if (Beckhoff.state !== "idle") { say("busy — wait until the wheel and the axis are at rest", true); return }
        root.sel = k
        say(root.names[k] + ": jog until the filter sits right, then set")
        Beckhoff.setFilter(k)
    }
    function jog(deg) {
        if (root.sel < 0) { say("pick a colour first", true); return }
        if (!root.ready) return
        Beckhoff.wheelJog(deg)
    }
    function setIt() {
        if (root.sel < 0) { say("pick a colour first", true); return }
        if (!root.ready) return
        if (root.sel === 0 && Math.abs(Beckhoff.wheelDeg) > root.redStepMax) {
            say("red moves at most " + root.redStepMax + "° per set — set it in two steps", true)
            return
        }
        Beckhoff.wheelSet(root.sel)
        say(root.sel === 0 ? "red set — green and blue moved with it" : root.names[root.sel] + " set")
    }

    // ── Touch-free focus ────────────────────────────────────────────────────────
    property var focusController: cwFocus
    function focusBack() {
        // Do not leave the wheel holding green/blue, or parked off its red.
        if (root.sel >= 0 && root.wheelOk && Beckhoff.state === "idle") Beckhoff.setFilter(0)
        root.StackView.view.pop()
    }

    FocusController {
        id: cwFocus
        targets: [redBtn, greenBtn, blueBtn, jogM1, jogM01, jogP01, jogP1, setBtn, backBtn]
        onActivated: function(item) { if (item.clicked) item.clicked() }
    }

    // ── Title ───────────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: Theme.titleY
        text:  "settings ▸ calibration ▸ colour wheel"
        color: Theme.colorText
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoM }
    }
    Text {
        x: Theme.marginX; y: 48
        text: "where each filter sits in front of the lens — pick a colour, jog it into place by eye, set"
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
    }
    Text {
        x: Theme.marginX; y: 80
        text: !Beckhoff.connected ? "xylod offline — nothing here works without it"
            : !root.wheelOk       ? "no colour wheel reported — an older xylod, or the wheel is tripped (fault reset on the capture screen)"
                                  : "wheel at " + root.fmt(Beckhoff.wheelDeg) + " from red   ·   + turns toward green, − toward blue"
        color: root.wheelOk ? Theme.colorTextDim : Theme.danger
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }
    Hairline { x: Theme.marginX; y: 106; width: Theme.contentW }

    // ── Row labels ──────────────────────────────────────────────────────────────
    component RowLabel: Text {
        x: Theme.marginX
        color: Theme.colorText
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontH2 }
    }
    component Small: Text {
        color: Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

    // ── 1 colour ────────────────────────────────────────────────────────────────
    RowLabel { y: 124; text: "1  colour" }
    TerminalButton { id: redBtn;   controller: cwFocus; x: 240; y: 124; width: 130; height: 40
        label: "[red]";   active: root.sel === 0; onClicked: root.pick(0) }
    TerminalButton { id: greenBtn; controller: cwFocus; x: 382; y: 124; width: 130; height: 40
        label: "[green]"; active: root.sel === 1; onClicked: root.pick(1) }
    TerminalButton { id: blueBtn;  controller: cwFocus; x: 524; y: 124; width: 130; height: 40
        label: "[blue]";  active: root.sel === 2; onClicked: root.pick(2) }
    // stored position under each colour
    Small { x: 240; y: 170; width: 130; horizontalAlignment: Text.AlignHCenter; text: "anchor" }
    Small { x: 382; y: 170; width: 130; horizontalAlignment: Text.AlignHCenter; text: root.fmt(root.slotDeg(1)) }
    Small { x: 524; y: 170; width: 130; horizontalAlignment: Text.AlignHCenter; text: root.fmt(root.slotDeg(2)) }

    // ── 2 jog ───────────────────────────────────────────────────────────────────
    RowLabel { y: 206; text: "2  jog" }
    TerminalButton { id: jogM1;  controller: cwFocus; x: 240; y: 206; width: 94; height: 40
        label: "−1°";   textColor: root.ready ? Theme.colorText : Theme.colorTextFaint; onClicked: root.jog(-1.0) }
    TerminalButton { id: jogM01; controller: cwFocus; x: 346; y: 206; width: 94; height: 40
        label: "−0.1°"; textColor: root.ready ? Theme.colorText : Theme.colorTextFaint; onClicked: root.jog(-0.1) }
    TerminalButton { id: jogP01; controller: cwFocus; x: 452; y: 206; width: 94; height: 40
        label: "+0.1°"; textColor: root.ready ? Theme.colorText : Theme.colorTextFaint; onClicked: root.jog(0.1) }
    TerminalButton { id: jogP1;  controller: cwFocus; x: 558; y: 206; width: 94; height: 40
        label: "+1°";   textColor: root.ready ? Theme.colorText : Theme.colorTextFaint; onClicked: root.jog(1.0) }
    // live position
    Text {
        x: 700; y: 204
        text: root.wheelOk ? root.fmt(Beckhoff.wheelDeg) : "—"
        color: root.ready ? Theme.accent : Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontH2 }
    }
    Small { x: 700; y: 238; text: "from red, now" }

    // ── 3 set ───────────────────────────────────────────────────────────────────
    RowLabel { y: 280; text: "3  set" }
    TerminalButton { id: setBtn; controller: cwFocus; x: 240; y: 280; width: 272; height: 40
        label: root.sel >= 0 ? "[set as " + root.names[root.sel] + "]" : "[set]"
        textColor: root.ready ? Theme.colorText : Theme.colorTextFaint; onClicked: root.setIt() }
    Small {
        x: 524; y: 292
        text: !root.ready     ? ""
            : root.sel === 0  ? "red moves by " + root.fmt(Beckhoff.wheelDeg) + " — green and blue with it"
                              : "stored " + root.fmt(root.slotDeg(root.sel)) + "  →  now " + root.fmt(Beckhoff.wheelDeg)
    }

    Hairline { x: Theme.marginX; y: 346; width: Theme.contentW }

    // ── Status ──────────────────────────────────────────────────────────────────
    Text {
        x: Theme.marginX; y: 360
        width: Theme.contentW; wrapMode: Text.WordWrap
        text: root.note
        color: root.failed ? Theme.danger : root.sel >= 0 ? Theme.accent : Theme.colorTextDim
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontBody }
    }
    Text {
        x: Theme.marginX; y: 400
        width: Theme.contentW; wrapMode: Text.WordWrap
        text: "red first — it is the anchor: the safety window and green/blue are measured from it, so setting red "
              + "moves all three. Then green and blue, each on its own. Jogging stops at the edge of the window. "
              + "[back] returns the wheel to red."
        color: Theme.colorTextFaint
        font { family: Theme.fontFamilyMono; pixelSize: Theme.fontMonoS }
    }

    // ── [back] ──────────────────────────────────────────────────────────────────
    TerminalButton {
        id: backBtn
        controller: cwFocus
        x: Theme.marginX
        anchors { bottom: parent.bottom; bottomMargin: 18 }
        width: Theme.bottomBtnW; height: Theme.bottomBtnH
        label: "[back]"; active: false
        onClicked: root.focusBack()
    }
}
