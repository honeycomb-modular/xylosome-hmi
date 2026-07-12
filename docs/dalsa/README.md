# DALSA camera + grabber reference

Vendor manuals and the working camera config for the Xylosome capture chain.
Copied from Hoyte's Desktop into the repo 2026-07-12 so the reference lives
with the code (GitHub is source of truth — see `WORKFLOW.md`).

## Files

- **`Piranha_HS_Series_Camera_Manual.pdf`** — camera manual. Our sensor is a
  **Piranha HS 8k TDI**, model `HS-80-08K80-00-R`. Covers TDI stage selection,
  line-rate / EXSYNC, direction, gain, and the serial (CameraLink) command set.
- **`Xtium-CL_MX4_Users_Manual.pdf`** — Xtium-CL MX4 frame-grabber manual (the
  Sapera/Xtium board the capture PC uses).
- **`HS-80-08K80_Full_8tap_8bit_WORKING.ccf`** — the **known-good camera config**
  (Full CameraLink, 8 taps, 8-bit). Reference/restore point.

## Live control (how the code drives the camera)

The agent talks to the camera over a **serial CameraLink command channel (COM3)**,
not GenICam. Command set + ranges live in `capture/capture_agent.py`
(`apply_set`) and `capture/PROTOCOL.md`:

| setting     | serial cmd  | range / values                    |
|-------------|-------------|-----------------------------------|
| TDI stages  | `stg <N>`   | **{16, 32, 48, 64, 80, 96}** (min 16) |
| line rate   | `ssf <Hz>`  | 3500 – 68610 Hz                   |
| gain        | `sag 0 <dB>`| −10 … 10 dB                       |
| direction   | `scd 0\|1`  | forward / reverse                 |

Current working point (baked into each TIFF `ImageDescription`):
`tdi.stages 32`, `line.rate 57636.9`, `scan.dir internal/reverse`, `8 taps / 8-bit`.

## Note — smear vs. EXSYNC

TDI wants one sensor row advanced per line clock. Today the camera **free-runs**
(internal line rate, no EXSYNC) because the EL2521 line-trigger cable isn't wired
yet, so any velocity mismatch smears ×(stages), and the variable-speed artwork
makes that worse. Stages floor is **16**, so the only in-camera smear lever is
32→16 (a 2× reduction, at −1 stop of light). The real fix is EXSYNC. See the
`capture-agent-modes` notes and the camera manual's TDI / EXSYNC sections.
