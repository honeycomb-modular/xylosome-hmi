# Capture PC — commissioning notes (verified on the bench, 2026-07-09/10)

Written from the **physical units**, not diagram labels. Where this contradicts
older docs, **this file is the ground truth** (corrections listed at the end).

The "capture PC" here = the Windows machine that hosts the frame grabber and runs
Sapera LT / CamExpert. Camera + grabber confirmed working end-to-end, and the PC
is now on the cart network with a verified TCP path to `xylod`.

---

## 1. Frame grabber & camera (verified via `gcp` over serial)

- **Frame grabber — Teledyne DALSA `Xtium-CL MX4`, serial `H1509050`.**
  **NOT** an X64 Xcelera-CL PX4 (older docs are wrong — see corrections below).
  Firmware config loaded: **CameraLink Full Mono**.
- **Camera — Piranha `HS-80-08K80-00-R`, serial `12007537`.**
  Firmware Design Rev `03-081-00162-03`, CCI `03-110-20017-01`, FPGA `03-056-01024-08`.
  8192 x 96 TDI line scan, 7 µm, 8/12-bit, Camera Link (MDR26).
- **Camera Link mode (current working default): `clm 21` = Full, 8 taps, 8-bit.**
  Alternative for dynamic range: `clm 16` = Medium, 4 taps, **12-bit** (see trade-off).
- **Exposure mode 7** (internal sync, free-running, max exposure, no charge reset) —
  produces lines with no external trigger, used for bench testing.

## 2. Serial control path (this is what an HMI/agent uses)

- Grabber's Camera Link serial port speaks **Teledyne DALSA Text Based (TLC), 9600 baud, 8N1**.
- Sapera serial port `Xtium-CL_MX4_1_Serial_0` is mapped to **Windows `COM3`**
  (set in Sapera Configuration → CameraLink Serial Port Configuration).
- Any program can drive the camera by opening **COM3 @ 9600-8N1**, writing TLC
  commands terminated with **CR (`\r`)**; the camera replies and ends with `OK>`.
- **Single-occupant port:** CamExpert (or its Serial Command tab) must release COM3
  before another client can use it. Verified working from PowerShell
  (`SerialPort COM3,9600,None,8,One` → `gcp` → full settings dump).

## 3. Measured line-rate ceilings (fill these into `xylod.conf`)

From HS-80-08k80 config table, confirmed against the camera:

| Mode | Config | Bits | Max line rate |
|---|---|---|---|
| `clm 21` (`sot 640`) | Full, 8 taps | 8  | **68,610 Hz** |
| `clm 16` (`sot 320`) | Medium, 4 taps | 12 | **38,314 Hz** |
| internal-sync floor (TDI) | — | — | **3,500 Hz** |

- `xylod.conf` `line_max_hz` is still the placeholder **20000** — replace with the
  ceiling for the chosen mode (68610 for 8-bit Full, 38314 for 12-bit Medium), minus margin.
- Nominal "34 kHz" for 12-bit in older docs is wrong; measured is **38.3 kHz**.

## 4. Sensitivity levers (all volatile until `wus` on the camera)

- **`stg` — TDI integration stages: 16/32/48/64/80/96, currently 32.** ~linear
  sensitivity, no added noise (charge-domain sum). Cost: smear tolerance tightens
  with stage count — motion sync must be proportionally more precise.
- **`ssf` — sync/line frequency** (exposure per line in TDI). Lower = brighter,
  but scan speed is locked to it. Floor 3,500 Hz.
- **`sbv`/`sbh` — binning** (2x per factor → +1 stop, −resolution; H-binning needs a
  different grabber file).
- **`sag` — analog gain** (−10..+10 dB/tap): amplifies signal *and* noise. Last resort.
- **12-bit costs line rate**: Full (8-tap) has no bandwidth for 12-bit, so it drops
  to Medium (4-tap) → 68.6k → 38.3k Hz. Sensor always digitizes 12 bit internally.

## 5. Working config file (.ccf)

- **`HS-80-08K80_Full_8tap_8bit_WORKING.ccf`**
  - In Sapera library: `C:\Program Files\Teledyne DALSA\Sapera\CamFiles\User\`
    (appears in CamExpert Configuration dropdown under Teledyne DALSA → HS-80-08K80-00-R).
  - Backup: `C:\Users\Hoyte\Desktop\xylosome dalsa settings\`.
- An old wrong "Default Area Scan 1 tap Mono" entry may still be under the same
  camera in the dropdown — ignore/delete (it predates the linescan fix).

---

## 6. Network (cart LAN)

Onboard **Realtek Gaming 2.5GbE ("Ethernet")** adapter, two static IPs, **no gateway**:

| Address | Purpose |
|---|---|
| `192.168.10.1 /24` | bench/capture link segment (matches SESSION_NOTES bench PC) |
| `192.168.2.50 /24` | cart segment — reaches the Beckhoff C6920 / `xylod` |

- Both persist across reboot (`netsh ... add address` is persistent by default;
  GUI static also persists).
- `192.168.2.4` was **already taken** (Windows Duplicate Address Detection flagged it) —
  an **undocumented device** on the cart LAN. Chose `.50` instead. *(TODO: identify `.2.4`.)*

**Verified reachability (2026-07-10):**
- `ping 192.168.2.2` → reply <1 ms (C6920).
- `Test-NetConnection 192.168.2.2 -Port 5510` → `TcpTestSucceeded: True`.
- `xylod` status read: `welcome sim:false version:0.1`; status `op:true, enabled:true,
  estopOk:true, homed:true, drive.fault:0, state:idle, filterSlot:3, posDeg:-20`.
  → real EtherCAT master (not sim), servo enabled and homed, no faults.

**Cart subnet map (current, from SESSION_NOTES + this session):**
- `192.168.2.1` Mac (internet share / gateway)
- `192.168.2.2` Beckhoff C6920 — `xylod` TCP `:5510`
- `192.168.2.3` Pi 5 (also `192.168.10.3`)
- `192.168.2.4` unknown device (found via DAD — to be identified)
- `192.168.2.50` **this capture PC** (new)

---

## 7. Open items (capture-PC side)

- Set `xylod.conf` `line_max_hz` from §3 (currently placeholder 20000).
- Raise Sapera **contiguous memory** from default 8 MB to ~64 MB for multi-second
  host-buffer captures (needs Sapera Configuration **as administrator** + reboot;
  the section is greyed out without elevation).
- External line trigger / EXSYNC wiring per `docs/grabber_io_wiring.md`
  (**MX4 uses J1**, shaft-encoder pins 3/2/6/5; ext-trigger pin is board-rev dependent).
  `pos_el2521` is still disabled in `xylod.conf`.
- Build the capture agent (Sapera): xylod `:5510` client for pass bracketing;
  live-focus server on `:5520` (see `suite/LIVE_PROTOCOL.md`); per-pass auto-save to SMB.
- Identify the device squatting on `192.168.2.4`.

## 8. Corrections to existing docs (superseded by this file)

- **Grabber is `Xtium-CL MX4` (serial H1509050), not `OR-X4C0-XPF00` / Xcelera-CL PX4.**
  Affects `PROJECT_OVERVIEW.md` §3.2 + hardware table, `docs/camera_capture_note.md`,
  `docs/architecture/xylosome_beckhoff.svg`. (`docs/grabber_io_wiring.md` and
  `docs/capture_pc_build.md` already say MX4 — trust those.)
- **External I/O is on `J1`** (bracket DH60-27P); "Trigger-In = J4 pin 11/12" is the
  Xcelera pinout and does not apply to the MX4.
- **12-bit line rate is 38.3 kHz**, not 34 kHz.
- **TDI stages are configurable 16–96 (currently 32)**, not a fixed 96.
