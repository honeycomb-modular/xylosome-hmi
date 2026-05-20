# XYLOSOME HMI — Qt6/QML Port · Session Notes

## What this project is
A Qt6/QML port of the XYLOSOME ESP32/LVGL touchscreen HMI.
Single-motor art installation controller running on Raspberry Pi 5.
Currently running on a WaveShare 5.5" AMOLED 1080×1920 (portrait physical,
rotated to landscape via wlr-randr, scaled to 853×480 logical).

Dev workflow: edit files on Mac → rsync to Pi → rebuild with ninja on Pi.
Primary: VS Code Remote SSH → edit directly on Pi → rebuild in integrated terminal.

Rsync from Mac:
`rsync -av /Users/hoytevhoytema/Documents/projects/xylosome_pi/qml/ hoyte@192.168.2.2:~/xylosome_pi/qml/`

---

## Status: RUNNING ON PI ✓  — splash screen, all screens navigating, touch working

```
xylosome_pi/
├── CMakeLists.txt
├── HMLOGO.png          ← startup splash logo (800×480, black bg)
├── qml_bg.png          ← texture asset (unused currently)
├── deploy.sh
├── src/
│   ├── main.cpp
│   ├── MotorModel.h
│   ├── MotorModel.cpp
│   ├── HttpServer.h
│   └── HttpServer.cpp
└── qml/
    ├── main.qml
    ├── Theme.qml
    ├── BackButton.qml
    ├── Hairline.qml
    ├── LabelledValue.qml
    ├── NavRow.qml
    ├── TerminalButton.qml
    ├── ScreenSplash.qml
    ├── ScreenHome.qml
    ├── ScreenLive.qml
    ├── ScreenSequences.qml
    ├── ScreenSettings.qml
    └── ScreenPlaceholder.qml
```

---

## What is built and working

### C++ layer
- **MotorModel** — QObject singleton, Q_PROPERTY bindings for mode, setpoint,
  enabled, position, velocity, current, tempC. QTimer at 100ms simulates motor.
  Motor.setpoint and Motor.mode must be set via QML property assignment
  (`Motor.setpoint = value`) NOT method call (`Motor.setSetpoint(value)`) —
  the setters are not Q_INVOKABLE.
- **HttpServer** — QTcpServer, same 5 REST endpoints as ESP32:
  GET /, GET /api/state, POST /api/setpoint, /api/mode, /api/enable, /api/zero.
  Web UI at http://192.168.2.2:8080 (ethernet) or hotspot IP:8080.
- **main.cpp** — registers Motor singleton, starts HTTP server on :8080, loads QML.

### QML layer
- **Theme.qml** — pragma Singleton. All property names camelCase (qmlcachegen
  rejects uppercase first letters). Colors: bg=#050505, accent=#4ADE80, danger=#F87171.
- **main.qml** — ApplicationWindow fullscreen, StackView anchors.fill.
  initialItem: ScreenSplash. Fade transitions on push/pop.
- **ScreenSplash** — HMLOGO.png fade-in (600ms) → hold (1500ms) → fade-out (500ms)
  → Timer (2700ms) navigates to ScreenHome via StackView.replace().
  Requires `import QtQuick.Controls` for StackView attached property.
- **ScreenHome** — 5 NavRows, status block, live clock. Width: 853px.
- **BackButton** — `root.parent.StackView.view.pop()`.
- **ScreenLive** — mode ComboBox, setpoint slider (width 773), enable/zero buttons,
  telemetry. Slider touch zone 44×48px. Width: 853px.
- **ScreenSequences** — Catmull-Rom spline editor. Current state:
  - Canvas: 793×340px, dark fill (#0A0A0A), fine grid (10px minor / 50px major).
    No box border.
  - Nodes: small green squares (7×9px visual), 44×44px touch zone.
  - Resize grip: single green (accentDim) bar, 35px wide, full box height,
    flush against right edge of box.
  - Vertical dashed "speed" axis centred in box. Horizontal "time" label on zero axis.
  - Bottom left: live aspect ratio and lines count.
  - Insert marker: vertical red hairline tracking the last inserted node's x position.
    Appears on double-tap (insert), follows node as it's dragged.
  - Double-tap canvas → insert node (uses onDoubleClicked — required for touch).
  - Double-tap node → delete node (uses onDoubleClicked).
  - Node drag uses onPressed + onPositionChanged on MouseArea.
  - Canvas repaints throttled to ~60Hz via Timer.
- **ScreenSettings** — brightness slider (cosmetic only), config rows. Width: 853px.
- **ScreenPlaceholder** — stub for Presets and Telemetry. Width: 853px.

---

## Display: WaveShare 5.5" AMOLED (HDMI)

Physical: 1080×1920 portrait. Logical after transform+scale: 853×480 landscape.

### labwc autostart (~/.config/labwc/autostart)
```bash
wlr-randr --output HDMI-A-1 --transform 270 --scale 2.25
sleep 0.5
QT_WAYLAND_SHELL_INTEGRATION=xdg-shell /home/hoyte/xylosome_pi/build/xylosome_hmi -platform wayland &
```

### Touch calibration
Device: Waveshare  Waveshare, /dev/input/event5, usb:0712:000a
Mapped to output in ~/.config/labwc/rc.xml:
```xml
<touch deviceName="Waveshare  Waveshare" mapToOutput="HDMI-A-1" mouseEmulation="yes"/>
```
Rotation calibration matrix in /etc/udev/rules.d/99-waveshare-touch.rules:
```
ATTRS{idVendor}=="0712", ATTRS{idProduct}=="000a", ENV{LIBINPUT_CALIBRATION_MATRIX}="0 1 0 -1 0 1"
```

### UI width
All screens updated from 800→853px, content width 740→793px (30px margins each side).

---

## Dev setup

### Network
Pi connected to Mac via ethernet cable + USB-C adapter.
Mac Internet Sharing enabled → Pi gets IP **192.168.2.2**.
SSH: `ssh hoyte@192.168.2.2`
Hotspot fallback IP (last known): 172.20.10.64 (check with `hostname -I` on Pi)

### VS Code Remote SSH (primary workflow)
1. Cmd+Shift+P → Remote-SSH: Connect to Host → `hoyte@192.168.2.2`
2. File → Open Folder → `/home/hoyte/xylosome_pi`
3. Edit QML files directly — saves go straight to Pi
4. Terminal → New Terminal (Ctrl+`) to rebuild

### Build
```bash
cd ~/xylosome_pi/build
ninja
```

### Clean rebuild (fixes stale qmlcachegen artifacts)
```bash
cd ~/xylosome_pi/build && rm -rf * && cmake .. -G Ninja && ninja
```
Run cmake (not just ninja) when: new QML files added, CMakeLists.txt changed,
or after clean rebuild.

### Run
```bash
QT_WAYLAND_SHELL_INTEGRATION=xdg-shell ./xylosome_hmi -platform wayland
```

---

## Bugs fixed (useful reference)

- **qmlcachegen rejects uppercase property names** — all Theme properties camelCase
- **StackView black screen** — use `initialItem:`, not `Component.onCompleted: push(...)`
- **StackView.view is null** — use `root.StackView.view`, not bare `StackView.view`
- **BackButton pop() fails** — use `root.parent.StackView.view.pop()`
- **StackView.replace() needs QtQuick.Controls import** — ScreenSplash must import it
- **visibility enum undefined** — requires `import QtQuick.Window`
- **Theme colors black** — stale qmlcachegen; clean rebuild fixes it
- **EGLFS permission denied** — labwc running; use `-platform wayland`
- **Slider snaps to 0 on release** — Motor setters not Q_INVOKABLE; use property
  assignment: `Motor.setpoint = value`, not `Motor.setSetpoint(value)`
- **Aspect ratio / lines count wrong reference** — use `canvasH` (340) not `plotH` (262)
- **Touch X/Y swapped after display rotation** — udev calibration matrix `0 1 0 -1 0 1`
- **autostart typo** — `-plaXtform` instead of `-platform` silently killed autostart
- **Double-tap onClicked/onPressed unreliable on touch** — mouseEmulation converts
  double-taps to Qt double-click events; use `onDoubleClicked` for both insert and delete
- **TapHandler/DragHandler grabs exclusive touch** — blocked all other UI; reverted to
  MouseArea with onDoubleClicked
- **Ninja "no work to do"** — new QML file added but cmake not re-run; always run
  `cmake .. -G Ninja` when adding files to CMakeLists.txt

---

## Screens still to build
- **ScreenPresets** — save/load velocity programs (currently placeholder)
- **ScreenTelemetry** — dedicated telemetry/logging view (currently placeholder)

## Known TODOs
- ScreenSequences: touchR=22 may still benefit from increase
- ScreenSettings: "tap a row to edit" is a TODO in the file
- Brightness slider cosmetic only (no backlight PWM API in Qt on Pi)
- HttpServer: upgrade to QHttpServer if `qt6-httpserver-dev` installed on Pi
- Wire up real motor over UART when hardware is ready (replace MotorModel simulation)
- Consider full 1920×1080 logical resolution redesign for the AMOLED display

---

## Pi hardware notes
- Raspberry Pi 5
- WaveShare 5.5" AMOLED, 1080×1920, USB touch (0712:000a), HDMI connection
- (Old) Official DSI touchscreen 800×480 — no longer in use
- USB-C port is power-only (no USB gadget/OTG)
- Wayland compositor: labwc (NOT wayfire)
- SSH enabled, user: hoyte
- Ethernet IP (via Mac Internet Sharing): 192.168.2.2
