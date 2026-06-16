# XYLOSOME HMI — Qt6/QML Port · Session Notes

> ⚠️ **ClearCore = STALE/fallback (since 2026-06-13).** The motion stack is now
> Beckhoff EtherCAT (C6920 + `xylod`, see `BECKHOFF_PORT.md` / `CLAUDE.md`).
> The "via ClearCore" description below is the retained fallback design — kept,
> not the active controller. The Pi/HMI, pendant, and deploy notes here still apply.

## What this project is
A Qt6/QML port of the XYLOSOME HMI.
Art installation controller — Panasonic servo + NEMA 17 stepper via ClearCore,
line scanner camera, pendant controls (Teensy 4.1 + Grayhill encoder + 3 buttons).

> ⚠️ **Two Pi targets — read carefully before deploying.**
> All active development as of 2026-05-24 is on **Pi 4** (dev unit).
> The final pendant hardware is **Pi 5**. The two have different display stacks,
> compositors, and build workflows. Do not mix up deploy commands.

---

## 🔌 GARAGE BENCH — Windows PC ⇄ Pi 5 (READ FIRST when "can't reach the Pi")

This is the **day-to-day connection in the garage**, NOT the Mac/192.168.2.2 path.

- **PC `Ethernet` adapter = STATIC `192.168.10.1` /24, no gateway** — a direct wired link to the Pi.
- **Pi 5 (`xylosome-pi`) = `192.168.10.3` on eth0.** Connect: `ssh -o PubkeyAuthentication=no hoyte@192.168.10.3` (password auth — the `PubkeyAuthentication=no` flag matters, same as Pi 4).
- Pi is ALSO on Wi-Fi (`192.168.4.x`) — that's its internet path.
- Pi powered by the **PoE+ HAT**. After a reboot it can take ~1 min to answer; `arp -a -N 192.168.10.1` should list `192.168.10.3`. Empty arp cache ≠ Pi offline — just `ssh` it.

### Pi has no internet (THE recurring one — "the Pi's not on the internet")
The Pi keeps a wired default route via eth0 → `192.168.10.1` (the PC, which does NOT route to the internet), and it beats the Wi-Fi route. Kill it **on the Pi**:
```
sudo ip route del default via 192.168.10.1 dev eth0
```
Then `ping 8.8.8.8`, `git pull`, NTP all work (internet goes out wlan0).

### When `ssh hoyte@192.168.10.3` times out (after a Pi reboot, or a cable bumped during housing work):
`Connection timed out` / `Destination host unreachable` = **network, not password** — SSH never reached the login prompt, so retyping the password does nothing.

1. PC `ipconfig` → the **Ethernet** adapter must read `192.168.10.1`. If it lost it, re-set that static IP.
2. PC `arp -a` → under the `192.168.10.1` interface. **No `192.168.10.3` line = the Pi is off the link.**
3. **Reseat the Ethernet** at the Pi / PoE-HAT and at the switch.
4. On the Pi (USB keyboard → `Ctrl+Alt+F2` → login `hoyte`): `ip a`.
   If eth0 has no `192.168.10.3`:
   - quick (reachable immediately): `sudo ip addr add 192.168.10.3/24 dev eth0`
   - persist: fix `/etc/netplan/*-eth0.yaml` (static `192.168.10.3/24`, **no gateway line**) → `sudo netplan apply`

### ✅ SOLVED 2026-06-04 — "eth0 has no IP after every reboot" (duplicate NM profile)
**Root cause:** there were **two NetworkManager profiles both named `eth0`** (a leftover merged from Pi 4 sessions), and **both had `autoconnect = no`**. So on every boot NM activated *neither* profile, eth0 came up with no IPv4, and the PC couldn't reach `192.168.10.3`. It was never the cable, the switch, or PoE — those were red herrings (the PHY link/green light is up regardless of whether NM assigned an address).

**Permanent fix (run once, over SSH):**
```
# 1. list profiles — look for two ethernet rows both named eth0
nmcli -f NAME,UUID,TYPE,DEVICE,AUTOCONNECT connection show
# 2. delete the stale duplicate (the one with DEVICE = --)
sudo nmcli connection delete <STALE-UUID>
# 3. make the real one static + auto-connect on boot (use its UUID)
sudo nmcli connection modify <GOOD-UUID> ipv4.method manual ipv4.addresses 192.168.10.3/24 ipv4.gateway "" connection.autoconnect yes
sudo nmcli connection up <GOOD-UUID>
```
Then `sudo reboot` and `ssh hoyte@192.168.10.3` — confirmed it now comes back on its own. The `connection.autoconnect yes` is the bit that was missing.

**If locked out again (recovery via monitor + USB keyboard on the Pi):**
1. `Ctrl+Alt+F2` → login `hoyte`. Console font tiny? `sudo setfont Lat15-Terminus32x16` (no desktop exists — this Pi is a labwc kiosk, `Ctrl+Alt+F1` just returns to the HMI).
2. `ip a` → if eth0 shows only an `inet6 … scope link` line and **no `inet`**, it has no IPv4.
3. Temp IP to get SSH back immediately: `sudo ip addr add 192.168.10.3/24 dev eth0`
4. SSH in from the PC and apply the permanent fix above.

**Handy: find the Pi on a link with no known IP (IPv6 neighbor trick).** Set PC Ethernet to *Automatic* (it takes APIPA `169.254.x.x`), then `netsh interface ipv6 show neighbors interface=15` — the Pi shows as a `fe80::…` neighbor with a Pi-OUI MAC (`88:a2:9e`, `d8:3a:dd`, `2c:cf:67`, `dc:a6:32`, `b8:27:eb`). Set the PC **back to static `192.168.10.1/24`, no gateway** when done.

---

## Pi 4 — current dev unit ⬅️ active

- **IP**: 192.168.10.2
- **Display stack**: EGLFS (no desktop compositor)
- **Remote access**: TigerVNC via systemd (`sudo systemctl restart tigervnc`)
- **SSH**: `ssh -o PubkeyAuthentication=no hoyte@192.168.10.2`
- **Repo path on Pi**: `/home/hoyte/xylosome-hmi/pi/hmi/`
- **Build**: `make` (Unix Makefiles, not Ninja)
- **SVG export path**: `/home/hoyte/xylosome_exports/`

### Pi 4 deploy sequence

```bash
# 1. Rsync (Mac terminal)
rsync -av --exclude='.git' --exclude='build' \
  "/Users/hoytevhoytema/Library/Mobile Documents/com~apple~CloudDocs/Documents/projects/xylosome_pi/pi/hmi/" \
  hoyte@192.168.10.2:/home/hoyte/xylosome-hmi/pi/hmi/

# 2. SSH in
ssh -o PubkeyAuthentication=no hoyte@192.168.10.2

# 3. Build
cd /home/hoyte/xylosome-hmi/pi/hmi/build && make -j$(nproc)

# 4. Restart UI
sudo systemctl restart tigervnc
```

### Pi 4 first-time cmake (if build dir is clean)
```bash
cd /home/hoyte/xylosome-hmi/pi/hmi
mkdir -p build && cd build
cmake .. -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
```

---

## Pi 5 — final pendant hardware (not yet in use for this codebase)

> All notes below describe the Pi 5 setup. This is the target platform
> for production, but the HMI has not yet been deployed or tested here.
> When ready: redo cmake, display config, and autostart for Wayland/labwc.

- **IP**: 192.168.2.2 (Mac Internet Sharing ethernet)
- **Display stack**: Wayland / labwc compositor
- **Build**: Ninja
- **SSH**: `ssh hoyte@192.168.2.2`

Rsync from Mac:
`rsync -av /Users/hoytevhoytema/Documents/projects/xylosome_pi/qml/ hoyte@192.168.2.2:~/xylosome_pi/qml/`

---

## Beckhoff C6920 — `xylod` motion controller (Linux IPC)

### CONFIRMED — read off the box 2026-06-13 (`ip -br addr` / `ip route`)
- **Hostname `beckhoff-pc`, Ubuntu 26.04 LTS** (kernel 7.0.0-22), root disk ~908 GB.
- **SSH: `ssh hoyte@192.168.2.2`** (user `hoyte`).
- **`eno1` = LAN / SSH NIC → `192.168.2.2/24`, default gateway `192.168.2.1`.**
  The gateway `192.168.2.1` is the **Mac** (last login came from it), so the
  C6920's LAN side currently lives on the **Mac's `192.168.2.x` network**, NOT
  the garage `192.168.10.x` net. Default route is `proto static` (looks like a
  netplan static config — confirm in `/etc/netplan/` before changing it).
- **`enp4s0` = EtherCAT NIC → UP, link-local IPv6 only, NO IPv4** (raw SOEM
  frames, exactly as expected).
- **`xylod` runs REAL as a systemd service, auto-starting on boot** (set up +
  verified 2026-06-13). Unit `/etc/systemd/system/xylod.service` (enabled) runs
  `/usr/local/bin/xylod --config /etc/xylod.conf` (no `--sim`). Verified live:
  `welcome` → `sim:false`, bus → `op:true`, drive → Operation Enabled
  (statusword `0x1637`), `fault:0`.
  - **After code changes, update the installed binary the service runs:**
    `cd ~/xylosome-hmi/beckhoff/xylod/build && sudo cmake --install . && sudo systemctl restart xylod`
  - Manage: `systemctl status|restart|stop xylod`; live log `journalctl -u xylod -f`.
  - **Sim still available on demand:** `sudo ./xylod --sim` by hand, or re-add a
    `/etc/systemd/system/xylod.service.d/sim.conf` drop-in (`ExecStart=` then
    `ExecStart=/usr/local/bin/xylod --config /etc/xylod.conf --sim`).

### ⚠️ The 2026-06-13 "won't turn from the Pi" gotcha — SOLVED, don't relive it
Symptom: after power-on the pendant connected and motosome streamed the curve,
but the servo never moved. **Cause: the systemd service was booting with a
`sim.conf` drop-in (`ExecStart=… --sim`)**, so the **simulator** was answering on
`:5510` — and the sim *fakes* `op:true` / `enabled:true` / `homed:true`, so it
looks perfectly healthy. The fix above (install real binary, remove the sim
drop-in, reload, restart) made the service real.
**Tell-tale:** the `welcome` line's `"sim"` flag is ground truth — always check it
first (`printf '{"cmd":"status"}\n' | nc -w1 127.0.0.1 5510 | head -1`).

### Pi ↔ xylod path — CONFIRMED working 2026-06-13
- The **Pi (`xylosome-pi`)** carries both `192.168.10.3` *and* `192.168.2.3` on
  `eth0`, so it shares the `192.168.2.x` net with the C6920 (`192.168.2.2`). The
  HMI's `beckhoff/host` is already correct — `xylod` logs
  `client connected: 192.168.2.3` + `cmd: execute (from hmi)`.
- (The old doc default host `192.168.10.20` was never valid — the C6920 is
  `192.168.2.2:5510`. HMI default in code is still `192.168.10.20`; the Pi's
  saved QSetting overrides it correctly.)
- Longer-term: `192.168.2.2` rides the Mac-shared net (gw `192.168.2.1` = Mac).
  For a standalone cart, pin C6920 + Pi onto one subnet and record it here.

### ⚠️ Three gotchas solved 2026-06-16

**1. Motor wouldn't run — `xylod` crash-looping ("A6-EC PDO remap failed / slave 5").**
A **second EL2008 was added to the bus**, which shifted every downstream slave:
`1 EK1100  2 EL1008  3 EL2008  4 EL2008  5 EL7047  6 A6-EC` (drive moved 5→6).
`xylod.conf` still said `pos_drive=5`, so the servo PDO remap hit the EL7047. Fix:
`pos_drive = 6` (done in repo conf). **Rule: adding/removing ANY Beckhoff terminal
shifts all downstream `pos_*` — update `xylod.conf`.** (Future hardening: match the
drive by name "ANCTL AS715N" instead of fixed position.)

**2. Boot hung ~2 min on a prompt.** `systemd-networkd-wait-online` was waiting for
the **IP-less EtherCAT NIC `enp4s0`** (it had `accept-ra: true` → stuck
"configuring" → 120 s timeout). Fix in `/etc/netplan/00-installer-config.yaml`:
set `enp4s0` to `dhcp4/6: false`, `accept-ra: false`, **`optional: true`**, then
`sudo netplan generate && sudo netplan apply`. Verified the wait-online ExecStart
now lists only `eno1`. (`eno1` is **static** `192.168.2.2` — the box keeps its IP
with or without the Mac; the Mac is only the default gateway.)

**3. After a reboot, drive faulted `0x8700` (Er74.1 "no sync"), `op:false`.**
Power-up race: the systemd service starts `xylod` before the A6-EC finishes its
own boot, so the DC-sync handshake fails. A plain `sudo systemctl restart xylod`
(drive already up) clears it. Permanent fix = a startup delay drop-in
`/etc/systemd/system/xylod.service.d/wait-drive.conf` → `ExecStartPre=/bin/sleep 15`
+ `daemon-reload`. (Better long-term: have `xylod` fail/retry bus-init until OP so
systemd's `Restart=on-failure` auto-recovers — code change, not done.)

### Homing / absolute home — DECISION 2026-06-13 (noted, NOT built)
Constraints from Hoyte: **no hard-stop homing, no home switch.** (Homing on every
startup is acceptable in principle, but not via a switch or a stop.)

Why a plain "<360° so single-turn is enough" shortcut does NOT work: the encoder
is on the **motor**, before the 50:1 harmonic reduction. Output travel is <360°
(soft limits −10..200 = 210°), but that's ~**29 motor revolutions**, so a
single-turn absolute reading is ambiguous (~29×) over the range.

**Chosen route: let the absolute encoder BE the home** — 17-bit **multi-turn
absolute + backup battery + a stored home offset**. No homing move at all: on
power-up the drive already knows true position; `xylod` applies a fixed offset so
"home" is the same physical place every boot. Cleanest fit given no switch/stop.

To build later (NOT done) — hardware path now committed:
- **Encoder battery cable ORDERED 2026-06-13: StepperOnline `AS7-C-ENC076-BAT-3.0`**
  (3 m, A6 17-bit, battery box inline). It **replaces** the current encoder cable
  at the motor ↔ drive **CN2**. Product:
  https://www.omc-stepperonline.com/3m-118-11-encoder-cable-with-battery-box-for-a6-series-17-bit-servo-motor-as7-c-enc076-bat-3-0
  (5 m / 10 m variants exist if the run needs it.) Confirm it matches the exact
  motor connector (brake vs non-brake) on arrival.
- **On first connect: `Er208` (battery fault) is expected** → reset via
  `F31.10` / `2031.11h`, power-cycle, then run absolute-position setup.
- **Set the drive to multi-turn absolute mode: `C00.07` (`2000.08h`)** (not
  single-turn `60E6h`).
- **Teach the home offset once** (`607Ch` home offset, or store in `xylod`):
  define "this physical position = 0".
- **Replace `xylod`'s wake-zero** (today it zeros to wherever the shaft sits at
  OP — `xylod.conf` note) **with absolute-position + stored offset.**

Trade-off (price of no switch / no stop): the battery is a consumable. If it dies
or is replaced → `Er208`, multi-turn count lost → re-teach home once. Same if the
keyway/coupling or harmonic drive is ever reassembled. Otherwise: zero-touch,
instant-ready home on every boot.

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

Physical: 1080×1920 portrait. Logical after transform 270 + scale 2.0: **960×540 landscape**.
(Scale 2.25 → 853×480 but pushes the bottom button row off-screen — **use 2.0**.)

### labwc autostart (~/.config/labwc/autostart) — actual current contents
```bash
swaybg -c '#000000' &
sleep 2 && WAYLAND_DISPLAY=wayland-0 wlr-randr --output HDMI-A-1 --transform 270 --scale 2.0 &
sleep 1 && XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 QT_QPA_PLATFORM=wayland /home/hoyte/xylosome-hmi/pi/hmi/build/xylosome_hmi &
```

> ⚠️ **HDMI port name matters.** The `wlr-randr` line targets a specific output by name. The plug currently sits on the port that enumerates as **`HDMI-A-1`**. If you move the micro-HDMI plug to the *other* Pi port it becomes **`HDMI-A-2`**, the line silently fails, and the screen comes up portrait + tiny. Fix: `sed -i 's/HDMI-A-[12]/HDMI-A-<new>/' ~/.config/labwc/autostart`.
> To check the live output name + current transform: `WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/1000 wlr-randr`. Apply a change live (no reboot): same command + `--output HDMI-A-1 --transform 270 --scale 2.0`.

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
