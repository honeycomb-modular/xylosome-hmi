# Beckhoff port — what was built (2026-06-09)

Session summary for the joint commit. The Beckhoff EtherCAT path from
`docs/architecture/xylosome_beckhoff.svg` is now implemented in software:
a new `beckhoff/` tree with the C6920 daemon, plus a surgical adaptation of
the Pi HMI to drive it. The ClearCore path is untouched and still works —
the HMI falls back to the local playhead simulation whenever no Beckhoff
controller is reachable.

---

## New: `beckhoff/` tree

```
beckhoff/
├── README.md            C6920 bring-up: OS, network, build, first motion, service
├── PROTOCOL.md          wire protocol spec — Pi HMI / capture PC ⇄ xylod
├── xylod/               the daemon that runs on the C6920
│   ├── CMakeLists.txt   finds system SOEM/nlohmann-json, else FetchContent
│   ├── src/
│   │   ├── main.cpp         entry — backend + sequencer + TCP server
│   │   ├── Config.{h,cpp}   /etc/xylod.conf — all hardware specifics live here
│   │   ├── Backend.h        hardware abstraction (control-context contract)
│   │   ├── EcBackend.{h,cpp}  SOEM master: A6-EC CiA-402 CSP @ 1 kHz, EL7031
│   │   │                      filter wheel, EL2521 line trigger, EL5152 echo,
│   │   │                      EL1xxx/EL2xxx DIO, WKC watchdog, RT scheduling
│   │   ├── SimBackend.{h,cpp} software twin — `xylod --sim`, no hardware needed
│   │   ├── Cia402.h         DS402 state machine helpers
│   │   ├── Sequencer.{h,cpp}  the 4-pass scan state machine (see below)
│   │   └── TcpServer.{h,cpp}  newline-JSON server, port 5510, multi-client
│   ├── config/xylod.conf
│   └── systemd/xylod.service
└── tools/
    ├── ec_scan.cpp      list slaves on the segment
    └── motor_test.cpp   standalone CiA-402 sine-sweep — the bench motor test,
                         same PDO remap as xylod (runs here ⇒ runs there)
```

### The sequence (one execute)

For each pass (R/G/B/C in color mode, single Clear pass in BW):
filter wheel → channel · axis → arc start (return speed) · settle ·
`pass_index` pulse + `pass_active` high + `pass_start` event ·
**integrate the artist's speed profile into CSP setpoints** while the EL2521
line-trigger frequency follows the instantaneous velocity (the third creative
axis: geometry ⇄ sampling) · `pass_end` · next. Then home back, `seq_done`.

WYSIWYG guarantee: the HMI samples its own curve editor (the same `speedAtX`
evaluator that drives the on-screen playhead) into 128 points and sends them
untouched — including the same velocity floor the simulation applies.

Safety: E-stop input (NC, active-low) and drive faults dominate everything —
torque drop, line trigger off, sequence aborted, `fault` event; recovery via
`fault_reset`. Soft travel limits clamp every setpoint.

---

## Changed: `pi/hmi/` (HMI retained, now Beckhoff-aware)

- **`src/BeckhoffLink.{h,cpp}` (new)** — QTcpSocket JSON-lines client, QML
  singleton `Beckhoff`. Auto-reconnects every 2 s. Mirrors daemon status
  (state, pass, progress, posDeg, lineHz, estopOk, …) as properties; relays
  `pass_start/pass_end/seq_done/homed/fault` as signals. Host/port persist in
  QSettings (`beckhoff/host`, default `192.168.10.20:5510`).
- **`src/main.cpp`** — instantiate + register the `Beckhoff` singleton.
- **`CMakeLists.txt`** — add the two new sources.
- **`qml/ScreenScan.qml`** —
  - execute: when `Beckhoff.connected`, `Recorder.startSession()` then
    `Beckhoff.executeScan(...)`; daemon events drive playhead, pass changes and
    the Recorder (real pass timing now lands in the metadata SVG). When
    offline: the previous local playhead simulation, byte-for-byte.
  - pause/resume → `Beckhoff.pause()/resume()`; [home] → `stop()` + `home()`.
  - new `buildProfile()` (curve → 128 samples) and `minVelDegS()` (same floor
    as the sim, converted to deg/s).
  - link-drop and fault guards reset the run UI instead of hanging it.
- **`qml/ScreenNetwork.qml`** — ClearCore rows replaced by live
  `beckhoff.ip / port / link / state` (bound to the singleton).

ClearCore-era code (HttpServer, MotorModel mock tick) untouched.

---

## Verified

- xylod + both tools compile clean (`-Wall -Wextra`, zero warnings) against
  real SOEM v1.4.0 on Linux.
- `xylod --sim` end-to-end over TCP: 4-pass color execute (R→G→B→C with
  filter moves, reposition, settle), correct event stream, `seq_done`, axis
  returned home. BW single pass. Pause freezes velocity + progress, resume
  completes. Unknown commands and malformed JSON nack cleanly.
- HMI side reviewed (no Qt in this sandbox) — build it on the Pi as usual:
  clean rebuild required (QML changes): `rm -rf build && cmake … && ninja`.

## Open / to verify on the bench

1. **A6-EC PDO remap** — xylod remaps 0x1600/0x1A00 to a fixed CSP set at
   startup. If StepperOnline made these read-only, switch to the drive's
   default mapping and adjust the `DriveRx/DriveTx` structs (startup log will
   show it).
2. **EL7031** in velocity-direct mode (CoE 0x8012:01 = 0); filter wheel is a
   software position loop on the velocity PDO — verify steps/rev + slot
   offsets in `xylod.conf`, and consider homing it off the `di_fw_index` input.
3. **EL2521** base frequency CoE 0x8000:02 must equal `el2521_base_hz`.
4. **PREEMPT_RT** kernel on the C6920 for smooth CSP (diagram open item).
5. C6920 LAN IP: suggested static `192.168.10.20` (PC `.1`, Pi 5 `.3`).
6. This morning's bench SOEM test program can live in `beckhoff/tools/`
   alongside `motor_test.cpp` if worth keeping.

## Suggested first session

```
beckhoff/xylod: mkdir build && cd build && cmake .. && make -j
sudo ./ec_scan eth1                  # confirm bus order ↔ xylod.conf pos_*
sudo ./motor_test eth1 1 5 10       # ±5° sweep, motor on the desk
sudo ./xylod --config ../config/xylod.conf
# then on the Pi: rebuild HMI, set beckhoff host if not .20, press [execute]
```
