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
- **`T_HS-80-08K80-00-R_Linescan_HS-80-08K80_4tap_12bit_WORKING.ccf`** — the
  **camera config in use since 2026-07-24**: 4 taps, **12-bit**, on the board's
  *Full Mono* data path. Built in CamExpert and verified grabbing. This is the
  file `capture_agent.py` loads (`CAM_MODE[12]["ccf"]`); the copy it actually
  reads lives in `Sapera\CamFiles\User\`, so **restore this file there** if that
  machine is ever rebuilt.
- **`HS-80-08K80_Full_8tap_8bit_WORKING.ccf`** — the previous known-good config
  (Full CameraLink, 8 taps, 8-bit). Still the fallback: set `CAM_BITS = 8` and
  the agent switches back to it. Reference/restore point.

**Do not hand-edit either file to change bit depth** — build a new one in
CamExpert. Patching the depth/tap keys hung the board on 2026-07-24; the
non-obvious key is `Horizontal Active` (per-tap width: 1024 at 8 taps, **2048**
at 4). See `docs/camera_capture_note.md`.

## Live control (how the code drives the camera)

The agent talks to the camera over a **serial CameraLink command channel (COM3)**,
not GenICam. Command set + ranges live in `capture/capture_agent.py`
(`apply_set`) and `capture/PROTOCOL.md`:

| setting     | serial cmd  | range / values                    |
|-------------|-------------|-----------------------------------|
| TDI stages  | `stg <N>`   | **{16, 32, 48, 64, 80, 96}** (min 16) |
| line rate   | `ssf <Hz>`  | 3500 – 38314 Hz (12-bit; 68610 at 8-bit) |
| gain        | `sag 0 <dB>`| −10 … 10 dB                       |
| direction   | `scd 0\|1`  | forward / reverse                 |

Current working point (baked into each TIFF `ImageDescription`):
`tdi.stages 48`, `scan.dir internal/forward`, `4 taps / 12-bit` (`clm 16`),
camera `ssf` 38000 → achieved 37986.7. Under `sem 3` the `line.rate` recorded in
a scan's metadata is the *measured* EXSYNC rate, i.e. what the EL2521 actually
drove (5389 Hz on scan_0285), not the ceiling.

## Note — smear vs. EXSYNC

TDI wants one sensor row advanced per line clock. Today the camera **free-runs**
(internal line rate, no EXSYNC) because the EL2521 line-trigger cable isn't wired
yet, so any velocity mismatch smears ×(stages), and the variable-speed artwork
makes that worse. Stages floor is **16**, so the only in-camera smear lever is
32→16 (a 2× reduction, at −1 stop of light). The real fix is EXSYNC. See the
`capture-agent-modes` notes and the camera manual's TDI / EXSYNC sections.
