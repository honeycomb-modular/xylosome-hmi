# Xylosome Dev Log

---

## 2026-05-20

### PCB — teensy41_pendant_carrier

- Reviewed KiCad project (Rev B, ~48.7 × 89.3 mm, 2-layer, shaped from Sketch10.dxf)
- DRC has 2 real errors: +5V traces on B.Cu are ~0.08 mm too close to board edge (0.4917 mm vs 0.5 mm rule). Fix: nudge traces inward. JLCPCB real minimum is 0.3 mm so these will likely pass fab, but worth fixing cleanly.
- 14 footprint mismatch warnings + 15 text height warnings — cosmetic, not blocking
- BOM was missing LCSC part numbers — confirmed numbers:
  - 10kΩ 0402 resistors → **C17414**
  - 470pF 0402 caps → **C1572**
  - JST-XH 2-pin connector → **C49678**
  - JST-XH 6-pin connector → **C15850**
- PCB project to be moved into `electronics/pendant_carrier/` (not done yet)

### Encoder — Grayhill 62AG22-H5-P

- Confirmed: optical encoder, **16 detents/rev**, clicks at each detent
- Open-collector outputs — need 10 kΩ pull-ups to 3V3 (on PCB) and 470 pF filter caps
- 30 mm knob on a 16-detent encoder has good tactile weight — not too light, not too heavy
- Firmware divides raw quadrature count by 4 (4 pulses per detent) → Pi receives whole click counts

### Firmware — Teensy 4.1

- Created `firmware/teensy_pendant/teensy_pendant.ino`
  - Libraries: Bounce2 (debounce), Encoder (quadrature)
  - Pins: BTN1=D2, BTN2=D3, ENC_A=D4, ENC_B=D5, ENC_SW=D6
  - Protocol: USB CDC serial 115200 8N1, one ASCII line per event
  - Messages: `READY`, `BTN1 DOWN/UP`, `BTN2 DOWN/UP`, `ENC_SW DOWN/UP`, `JOG <delta>`
- Created `pi/services/pendant_serial.py`
  - Threaded reader, auto-reconnects on disconnect
  - `on_event` callback receives plain dicts: `{"type":"jog","delta":1}`, `{"type":"button","id":"BTN1","state":"down"}`
- Created `firmware/clearcore/README.md` — stub noting responsibilities (servo, stepper, camera timing, TCP)

### Architecture

- Clarified final architecture:
  - **No e-stop on pendant** — hardwired NC loop is external into ClearCore 24V E-STOP IN only
  - **No LEDs or haptics** on pendant
  - ClearCore drives **Panasonic servo** (primary scan axis) + **NEMA 17 stepper** (secondary, role TBD) + coordinates **line scanner camera** trigger timing
  - Pi ↔ ClearCore: TCP over CAT6 PoE (single cable, up to 100 m)
  - Pi ↔ Teensy: USB serial (CDC)
  - Pi ↔ Display: HDMI + USB (touch, but going touch-free — see below)
- Created `docs/architecture/xylosome_architecture.svg` (inline diagram)
- Created `docs/architecture/xylosome_architecture.pdf` (reportlab, Helvetica, dark theme, A4 landscape — universally readable)

### Project structure reorganisation

Moved files into clean hierarchy:

```
xylosome_pi/
  pi/
    hmi/          ← Qt6/QML app (was src/ qml/ etc at root)
    services/     ← pendant_serial.py
  firmware/
    teensy_pendant/
    clearcore/
  docs/
    architecture/
    concept/
  electronics/    ← placeholder for PCB project
```

### Pi HMI code review

Compared architecture to existing `pi/hmi/` Qt6/QML codebase:

- `MotorModel` — mock 10 Hz dynamics. Comment says "swap for UART rx" — stale. Needs real ClearCore TCP client.
- `HttpServer` — QTcpServer REST API on :8080, mirrors Qt state. Functional.
- `ScreenLive.qml` — mode selector, setpoint slider, telemetry — all bound to mock Motor singleton. UI complete.
- `ScreenSequences.qml` (now ScreenScan) — Catmull-Rom spline editor, playhead, motor dial. No real motion yet.
- `ScreenSettings.qml` — has stale labels: `uart.peer = teensy / 1 mbps` and `motor.bus = can / rmd-x8`. Both need updating.

### UI Concept document

- Created `docs/concept/xylosome_ui_concept.docx`
- Covers all 7 screens: Splash, Scan, Live, Camera, Presets, Telemetry, Settings
- Includes per-screen pendant behaviour tables, displays, controls, and wishlist items

### Pendant navigation model

Defined encoder interaction grammar:
- **ENC rotate** → move focus between sections / items / parameters
- **ENC click** → enter / confirm / advance one level
- **BTN2** → back, always, one level at a time
- **BTN1** → context action (screen-specific)

ScreenScan four-section focus layout: Spline editor | Position settings | BTN1 function | BTN2 function

Spline sub-flow (Section 4.3 of concept doc):
1. Aspect select → 2. Value edit → 3. Scrub bar → 4. Speed node drop/edit → 5. Confirm/back

### Touch-free design direction

- Display will be output-only — no touch relied upon for any primary workflow
- Full touch → encoder gesture mapping documented in concept doc Section 4.5
- 4 items marked TBD (mode selector cycling, preset action selection)
- Key implementation note: QML needs a visible focus cursor (highlight ring / underline) so operator always knows what ENC rotate affects

### Display — AMOLED upgrade path

- Current: WaveShare 5.5" HDMI + USB touch (960 × 540 IPS LCD)
- Recommended upgrade: **WaveShare 5.5" HDMI AMOLED** (1080 × 1920)
  - Drop-in replacement: same brand, same HDMI+USB interface, same size
  - True black background suits the dark UI theme
  - Better viewing angles and outdoor/workshop visibility
  - Touch layer still present but irrelevant given touch-free direction
- Also noted: DFRobot 6.67" flexible AMOLED ($199) — interesting but too large for pendant

---

## 2026-05-23

### Firmware — teensy_pendant.ino working ✅

All three inputs confirmed working on hardware:
- BTN1, BTN2 — correct DOWN/UP events
- ENC_SW — correct DOWN/UP events
- JOG — correct signed delta per detent

Key fix: ENC_A (D4) and ENC_B (D5) need `INPUT_PULLUP`, not plain `INPUT`.
The external 10kΩ pull-ups on the PCB are insufficient without the Teensy's
internal pull-up also enabled — likely because the open-collector outputs of the
Grayhill 62AG pull too hard relative to the pull-up value in this wiring.

---

### PCB — J3 encoder connector mapping corrected

The J3 pin table in `design-notes.md` was wrong. The Grayhill 62AG22-H5-P has
a **2×3 pin header** (two rows of 3, 1.27 mm pitch), not a single row of 6.
The adapter cable connects row 2 first then row 1, so the mapping to the
single-row 6-pin JST-XH is:

| J3 pin | Encoder pin | Signal |
|---|---|---|
| 1 | 6 — switch return | GND |
| 2 | 5 — switch NO | ENC_SW → D6 |
| 3 | 4 — Output B | ENC_B → D5 |
| 4 | 1 — Power | +5V (VIN) |
| 5 | 2 — Output A | ENC_A → D4 |
| 6 | 3 — GND | GND |

Firmware Teensy pin assignments (D4=ENC_A, D5=ENC_B, D6=ENC_SW) are unchanged.
design-notes.md Section 4 J3 table updated to reflect this.

---

## 2026-05-24

> ⚠️ **All work below was done on Pi 4 (dev unit at 192.168.10.2, EGLFS + TigerVNC).**
> When the Pi 5 pendant is ready this entire HMI will need to be re-deployed and
> re-tested under Wayland/labwc. Pi 4 and Pi 5 have different display stacks —
> see SESSION_NOTES.md for both configurations.

### Metadata Infuser — implemented ✅

Full implementation of the temporal metadata recorder for scan sessions.

**New files:**
- `pi/hmi/src/MetadataRecorder.h` — C++ singleton registered in QML as `Recorder`
- `pi/hmi/src/MetadataRecorder.cpp` — implementation
- `pi/hmi/qml/ScreenMetadata.qml` — UI page (accessible from ScreenHome row 07)

**How it works:**
- Execute button in ScreenScan triggers 4 sequential passes (R/G/B/C), same curve
- `Recorder.startSession()` called on execute press — snapshots current curve + boxW
- `Recorder.startPass(i)` / `Recorder.endPass(i)` called per pass
- `Recorder.commitSession()` finalises + auto-exports SVG to `/home/hoyte/xylosome_exports/`
- `Recorder.simulateTrigger()` generates a fake complete session for testing (no execute needed)

**SVG output format (final design):**
- 568 × 200 px, transparent background, black on transparent
- Header box (44 px): `XYLOSOME_01` at 20px Courier New + letter-spacing, date right-aligned
- Timing table (328 × 112 px): 4 rows R/G/B/C — t_start / t_end / duration / ms
- Curve box (240 × 112 px): 1px black Catmull-Rom polyline, dashed zero axis
- Params box (44 px): node coords line 1, box_w / aspect / lines line 2 — both 11px, no collision
- Named: `xylosome_YYYYMMDD_HHMMSS.svg`

---

### Screen rename: ScreenSequences → ScreenScan ✅

Aligned with concept document (docs/concept/xylosome_ui_concept.docx):
- `ScreenSequences.qml` renamed to `ScreenScan.qml`
- `ScreenSplash` updated to boot to `ScreenScan`
- CMakeLists updated

---

### ScreenHome restructured ✅

- Removed stale device/motor/bus/net status block
- Nav rows updated to match concept doc screen map:

| Row | Name | Destination |
|-----|------|-------------|
| 01 | live | ScreenLive |
| 02 | camera | ScreenPlaceholder (TODO) |
| 03 | presets | ScreenPlaceholder (TODO) |
| 04 | telemetry | ScreenPlaceholder (TODO) |
| 05 | connected devices | ScreenPlaceholder (TODO) |
| 06 | settings | ScreenSettings |
| 07 | metadata | ScreenMetadata |

"connected devices" replaces the old inline status block — clearcore / teensy / camera info belongs there when the screen is built.

---

## Outstanding items

| Item | Priority | Notes |
|------|----------|-------|
| Fix PCB DRC errors | Medium | Move 2 × +5V traces inward on B.Cu |
| Fill LCSC part numbers in BOM CSV | Low | Numbers above — just paste them in |
| Move PCB project → `electronics/pendant_carrier/` | Low | Folder not created yet |
| Update ScreenSettings.qml stale labels | Medium | uart.peer → usb.pendant, motor.bus → motion=clearcore/tcp |
| Wire pendant_serial.py into Qt app | High | Threading + Qt signal bridge needed |
| Build ClearCore TCP client layer | High | Largest outstanding gap |
| Replace MotorModel.tick() with real telemetry | High | Depends on TCP client |
| Implement ScreenCamera | Medium | Needs camera API details first |
| Implement focus cursor in QML | High | Required for touch-free operation |
| Resolve TBD gesture mappings (mode select, preset actions) | Medium | Before disabling touch |
| Clarify NEMA 17 role | Open question | Focus / Z / indexing? |
| Clarify camera model | Open question | Determines ScreenCamera implementation |
| Clarify ClearCore TCP protocol | Open question | Defines Pi ↔ ClearCore API layer |
