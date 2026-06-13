# Metadata Infuser — Xylosome HMI

> This file lives at `pi/hmi/` alongside `CMakeLists.txt` and `deploy.sh`.  
> Any Claude session that reads this file has full context to continue implementation.

> ⚠️ **Motion-source note (2026-06-13):** references below to "ClearCore" as the
> source of pass events are **stale**. The active stack feeds pass timing from
> the Beckhoff `xylod` daemon via `BeckhoffLink` (`Beckhoff` QML singleton) — the
> Recorder now gets real pass start/end events from there (see `BECKHOFF_PORT.md`).
> The metadata/SVG design itself is unchanged. ClearCore remains a kept fallback.

---

## What This Is

The Metadata Infuser is a new settings page in the Xylosome HMI that records the precise temporal and geometric conditions of every trigger event, then exports a single SVG file per session for manual compositing in Photoshop.

It is not a display tool — it is a forensic recorder. The SVG output becomes part of the final artwork.

---

## The Xylosome System

### Hardware Chain

```
ClearCore (motion controller, Ethernet/PoE)
    ↓ orchestrates
Panasonic Minas A6 — MHMF042L1V2M
    14mm keyway shaft, 60mm flange, 3000 RPM rated
    ↓ drives
Harmonic Drive (50:1) — camera scan motion
    ↓
Camera bracket — Dalsa Piranha HS-80-08K80-00-R (8k x 96 TDI, Camera Link) BW line scanner
    ↓
Teledyne frame grabber — separate capture machine (not Pi)

Pi HMI Box (PoE powered via same Ethernet switch)
    ├── Raspberry Pi — Qt/QML touchscreen UI
    └── Teensy — hard buttons + click-push dial encoder

Vertical slider — HGR20 1200mm linear rail, 2× HGH20CA blocks
    (static height adjustment only, not part of scan motion)
```

### The Scan Process

One trigger → 4 sequential passes across the field, each in a different color channel:

| Pass | Channel |
|------|---------|
| 1    | Red (R) |
| 2    | Green (G) |
| 3    | Blue (B) |
| 4    | Clear (C) |

- The camera is a BW line scanner — color is constructed from 4 separate passes
- The motion is perfectly repeatable (harmonic drive + servo)
- Subject motion **between** passes creates color offset/fringing — this is intentional, it is the artistic content
- The speed curve is the geometric ruler: it determines how subject motion translates to spatial offset

### Communication

- Pi ↔ ClearCore: **Ethernet**, same PoE switch that powers the Pi
- Pi receives ClearCore events (pass start/end, speed state) over the network
- The capture machine (frame grabber) is entirely separate — no direct connection to Pi

---

## What the Metadata Infuser Records

### Per Trigger Event

```
Trigger
├── Pass 1 (R)
│   ├── t_start
│   ├── t_end
│   ├── duration
│   └── speed_curve  ← exact curve drawn in UI, not measured
├── Pass 2 (G)
│   └── (same structure)
├── Pass 3 (B)
│   └── (same structure)
└── Pass 4 (C)
    └── (same structure)
```

### Speed Curve Source

The speed curve is **read directly from the UI state** — it is the curve the artist drew in the draggable box editor, not a post-hoc measurement from the ClearCore. The Minas A6 executes the programmed curve with enough precision that what was drawn is what happened.

### What Is Not Recorded

- Raw image data (lives on the capture machine)
- Subject motion (derived in Photoshop from color offset)
- Frame grabber metadata

---

## UI Specification

### Existing UI Pattern

The current HMI uses a **draggable box** as the primary control:
- Dragging the box sets **aspect ratio → duration**
- Inside the box is a **curve editor** that sets the **speed ramp**
- A **trigger button** fires the sequence
- All functions accessible via **2 hard buttons + click-push encoder dial** (Teensy)

### Metadata Infuser Page

- Lives as a **settings page** within the existing page navigation
- Accessible via the same Teensy dial/button navigation as all other pages
- No new navigation paradigm — just another page on the stack

### Page Content

1. **Per-pass timing display** — t_start, t_end, duration for each of R/G/B/C
2. **Speed curve graph** — visual of the curve as drawn/executed, per pass overlaid
3. **Session history** — list of trigger events in current session
4. **Export button** — generates and saves the SVG

---

## SVG Output Specification

### Purpose

A standalone SVG file, one per trigger session, to be imported into Photoshop as a smart object and composited manually over the scan.

### Aesthetic

**Technical. Dry. Sober. Non-decorative.**

Reference aesthetic: Arri camera metadata strip, oscilloscope readout, Leica viewfinder data overlay. Functional beauty through precision — no color fills, no gradients, no icons. Monochrome. Tight typography. Every element earns its place by carrying information.

### Content Layout

```
┌─────────────────────────────────────────────────────┐
│  XYLOSOME — [SESSION ID] — [DATE / TIME]            │
│                                                     │
│  SPEED CURVE                                        │
│  ┌─────────────────────────────┐                    │
│  │  [graph — 4 pass curves     │                    │
│  │   overlaid, labeled R/G/B/C]│                    │
│  └─────────────────────────────┘                    │
│                                                     │
│  PASS   CH    t_start    t_end      DURATION        │
│  1      R     00:00.000  00:02.143  2.143s          │
│  2      G     00:02.200  00:04.341  2.141s          │
│  3      B     00:04.400  00:06.538  2.138s          │
│  4      C     00:06.600  00:08.741  2.141s          │
│                                                     │
└─────────────────────────────────────────────────────┘
```

### Technical Spec

- Format: SVG (vector, infinite scale)
- Typography: monospace, system or embedded
- Colors: monochrome only (black on white or white on black — TBD)
- Dimensions: TBD — should match 8K scan output width so it registers 1:1 in Photoshop
- Generation: programmatic from Pi (Qt SVG generator or Python `svgwrite`)
- Naming: `xylosome_[YYYYMMDD]_[HHMMSS]_[session_index].svg`

---

## Implementation Plan

### Stack

- **Language**: Qt/QML + C++
- **Build**: CMake
- **Repo**: `github.com/honeycomb-modular/xylosome-hmi`
- **Structure**: `qml/` (UI screens), `src/` (C++ backend)

### New Components

#### C++ — `src/MetadataRecorder.h/.cpp`

- `Q_OBJECT` class exposed to QML
- Listens for ClearCore pass events (Ethernet)
- Stores per-pass records in memory
- Provides `Q_INVOKABLE exportSvg(QString path)` method
- Exposes pass data as `QAbstractListModel` for QML binding

#### QML — `qml/MetadataPage.qml`

- New page in existing page stack/navigation
- Displays per-pass timing table
- Renders speed curve graph (QML Canvas)
- Export button → calls `MetadataRecorder.exportSvg()`
- Navigable via Teensy encoder/buttons (same as all other pages)

### Integration Points

1. **ClearCore event parsing** — how does the Pi currently receive pass start/end signals from ClearCore? First thing to establish before writing recorder logic.
2. **Page navigation** — how are existing pages registered and navigated? MetadataPage needs to slot into the same system.
3. **Speed curve data** — where is the curve state stored in the existing C++ backend? MetadataRecorder needs a reference to read it at trigger time.

---

## Open Questions (resolve before coding)

1. What is the ClearCore→Pi message format for pass start/end? (TCP/UDP? JSON? Binary protocol?)
2. What is the existing QML page navigation pattern? (StackView? SwipeView? Custom?)
3. Where is the speed curve stored in the C++ backend?
4. Should the SVG match the 8K output dimensions (8192px wide) so it registers 1:1 in Photoshop?
5. Should the SVG be white-on-black (film rebate aesthetic) or black-on-white?
6. One SVG per trigger, or multiple triggers per SVG session file?

---

## Motion Rebuild (hardware — separate from software)

Replacing the existing 10:1 belt drive with harmonic drive for zero-backlash precision:

- **Purchased**: CSF-14-80-2UH Cut Flange (~$150, genuine Harmonic Drive)  
  Input bore is 8mm — assess coupling geometry when unit arrives to determine adapter approach
- **Purchased**: 50:1 strain wave gearhead with native 14mm bore  
  Direct fit to MHMF042L1V2M shaft, no adapter needed
- **Vertical positioning**: HGR20 1200mm linear rail + 2× HGH20CA carriage blocks (static height adjustment)
- **Note**: Do not attempt to bore/machine the CSF-14 wave generator hub — hardened steel, not practical

---

*Last updated: 2026-05-24*  
*To continue: read this file, then read `qml/` and `src/` structure for implementation context.*
