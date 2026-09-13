# Xylosome — future improvements checklist

*Captured from a claude.ai chat, early Sept 2026. Tick items off as they land;
the notes under each item are the reasoning behind it.*

---

## 0. Answer first — firmware questions

These change the shape of section 1, so do them before building the exposure panel.

- [x] **Does the HS-80 allow exposure time shorter than the line period?** — **No.**
  - Answered 2026-09-13 from `docs/dalsa/Piranha_HS_Series_Camera_Manual.pdf`
    §4.3.5, Table 10. The Piranha HS has only two exposure modes, and neither
    has programmable exposure time: **mode 3** (external EXSYNC — what scans use)
    and **mode 7** (internal `ssf` — LIVE / free-run). Both are "maximum exposure
    time with no charge reset", so exposure always equals the line period.
  - So **velocity / stages / gain is the complete set.** The exposure panel has
    three axes, and exposure time cannot help the varying-speed sharpness problem.
- [x] **Does a narrower cross-scan ROI raise max line rate?** — **No.**
  - Manual §4.5.1: `roi` only picks the pixels used for statistics and
    calibration commands (`ccg`, `gla`, `ccf`, …). It does not crop readout.
  - Manual §4.3.5 (`ssf`): max line rate is set by **binning, `sot` throughput,
    Camera Link mode (`clm`) and stage count**. So cross-scan FOV is a crop
    only — in the grabber or at capture — and never extends the velocity range.
  - What *does* raise the ceiling: `clm 21` (8-bit, 8 taps, 68.6 kHz) vs the
    current `clm 16` (12-bit, 4 taps, 38.3 kHz), or horizontal binning (`sbh`,
    halves resolution). Both are real trades, not free.
- [ ] Optional: confirm both on the camera itself with one `gcp` — only through
  the capture agent's existing path, never by restarting it (`COOP.md` §5).

---

## 1. Exposure & focus

### Shared exposure panel
Not a mode. One panel, reachable from every mode's parameter screen, so exposure
never gets configured in three places that drift apart. Everything displayed in
**stops relative to current setting**.

| Axis | Buys | Costs |
|---|---|---|
| Velocity | 1 stop per halving | Time, linearly. Nothing else, if subject is rigid + static |
| TDI stages | 1 stop per doubling | Sharpness (stage count multiplies tracking mismatch). Needs flat subject — depth parallaxes across stages |
| Gain | 1 stop per doubling | Shadow noise, ~halved SNR per stop |
| ~~Exposure time~~ | — | Not available on the HS-80 (§0): exposure = line period |

- [ ] Build the shared exposure panel, reachable from every mode's parameter screen
- [ ] Show predicted EV delta
- [ ] Show distance to clip (from last pass histogram)
- [ ] Show which limit binds first (max line rate, max axis velocity, min line rate, gain floor)
- [ ] Show predicted pass duration, updated live
- [ ] Tag each route with its cost: `−2 EV · velocity · +6 min`, `−2 EV · stages 8→32 · softer`, `−2 EV · gain · noisier`
- [ ] Grey out unreachable routes (never fail mid-pass)
  - Deficit is computed by the machine; the route is chosen by hand, per subject.

### Parameters live in the HMI
- [ ] Camera: TDI stage count · analog gain · black level · bit depth · TDI direction
- [ ] Motion: velocity · accel · jerk
- [ ] FOV: cross-scan ROI (pixel window along the line) · along-scan start/end
  - Aperture and ND stay **off** the screen — not machine-settable. Accepted
    consequence: EV readout is relative, not absolute. Absolute reference comes
    from the last pass histogram (clip %, shadow floor), measured not declared.

### FOV
Two axes, both settable, **neither in the EV sum** — cropping doesn't change
per-pixel brightness.
- [ ] Cross-scan = crop window along the line (grabber/capture crop — the camera's `roi` doesn't crop and doesn't raise line rate, §0)
- [ ] Along-scan = pass start/end (multiplies pass duration alongside velocity)

### Live mode as synthetic preview
Live runs 1 TDI stage (32 stages on a static scene is just a 32× smear), so it's
~5 stops off the pass and can never be a direct photometric preview.
- [ ] Compute offset factor = (pass stages / live stages) × (pass line period / live line period)
- [ ] Scale the live histogram by it and display *that* as the prediction
- [ ] Overlay "these pixels will saturate at current mode settings"
  - Live won't show clipping on its own, and clipping is what's worth knowing.

### Focus readout
A single line of a static scene shows nothing useful visually.
- [ ] 1D focus score (gradient energy across the line) as a large number + peak-hold bar
  - Turn the barrel, chase the peak. Focus stays manual; this is guidance only.

---

## 2. Curve scan

- [ ] Curve goes full screen on selection — own route, not a modal, so the
  pass-progress strip and time readout share the view
- [ ] **Re-map curve node axis from velocity to stops (EV)**
  - Current hard glowing stripe at the slow end is a mapping artefact: curve is
    linear in velocity, exposure is 1/v, so shadows-to-mids compress into the top
    of the range and the bright end explodes.
  - Pick reference velocity = 0 EV; node value in ±EV; `v = v_ref · 2^(−EV)`.
  - A straight diagonal drag then gives an even gradient.
- [ ] Draw the achievable **accel envelope** behind the curve
  - Can't reach −5 EV instantly; the profile clips and actual exposure flattens.
- [ ] Rule out **saturation** as the cause of hard edges
  - Run the same curve 3 stops down; if the edge softens, it was clipping (no
    remapping fixes that).
- [ ] Show live **pass duration** while dragging
  - `∫dx/v`, so slow sections dominate: −4 EV over 10% of travel roughly doubles
    total pass time.

---

## 3. Geometric squeeze — calibration

Scans feel squeezed overall. Cause: trigger interval vs pixel pitch mismatch.
Along-scan spacing = image motion per EXSYNC; cross-scan is fixed by sensor pitch
and optics.

`aspect error = (image motion per EXSYNC) ÷ (effective pixel pitch at image plane)`

Squeezed = numerator too small = too many lines per unit of image travel.

- [x] Scan a square/grid target of known size, perpendicular to scan axis,
  constant velocity, rigid and flat
- [x] Measure the result in pixels both ways (cross-scan is the reference — it can't be wrong)
- [x] Apply ratio as correction
- [x] Re-scan and confirm 1.00
  - **Done 2026-09-12** (`bd6494d`, plus `77849a2` / `60fe3e9` for arcs over 180°).
    The correction went into the HMI line-count constant rather than encoder
    counts per EXSYNC: `C` 8000 → 9310 in `pi/hmi/qml/ScreenScan.qml` (mirrored
    in `pi/hmi/src/HttpServer.cpp`). Square target, 110° arc: +16.89% → −0.43%,
    inside the target's ~0.5% repeatability. If the target is ever rigidly
    fixed, ~9270 is the number to close the gap.
- [ ] Store as **per-setup calibration** (per lens / working distance), not a global constant
  - Today `C = 9310` is a hard-coded literal in two files — valid only for the
    lens and working distance used on 2026-09-12.
- [ ] HMI shows which calibration is loaded, so a pass never runs against another setup's number
- [ ] If the trigger divider is integer-only: take nearest step, correct the
  residual in software as one scale factor at capture
  - Single global scalar — a scaling error, not a curve. One pass to measure, one to verify.

---

## 4. Xerox art mode

Set FOV and duration. Once the scan is running, the red execute button is
re-bound: **press = motor halts, release = motor accelerates back**. Camera keeps
acquiring, so every press paints a smear stripe into the image.

- [ ] **Decide: FOV vs duration** (they conflict as soon as you press; base velocity = FOV/duration, every halt adds time)
  - (a) duration fixed → line count fixed → travel falls short of FOV, or
  - (b) travel fixed → duration extends → image gets longer
  - Don't let the machine speed up to catch up — that changes exposure mid-pass.
- [ ] Rebind execute button during scan: momentary/held, not toggle, must **not** trigger abort
- [ ] **Free-run line trigger** in this mode (hard requirement)
  - If EXSYNC stays encoder-locked, stopping the motor stops the triggers — a gap,
    not a smear. Must run on the internal timer line rate.
- [ ] Make **TDI stages** a control in this mode
  - 1 stage = clean repeated lines, true xerox smear. 32 stages with the object
    stationary = blurred stripe. Both usable.
- [ ] Tune stripe **edges** via decel/jerk; try drive quick-stop (own decel ratio) instead of profile decel
  - Decel ramp puts a gradient tail in; accel ramp puts one on the way out. Soft
    S-curve is the enemy.
- [ ] Show the **stripe length** trade: `hold duration × line rate`
  - Longer line period (brighter) = fewer lines/sec = shorter stripes.
  - Brightness is unchanged — stripe is repeated, not brighter.
- [ ] Set EL1xxx **input filter** to minimum (often 3 ms default)
  - Chain: button → input filter → EtherCAT cycle → NC cycle → decel ramp. Ramp
    dominates: stop distance `v²/2a`. Lower base velocity and higher decel both
    sharpen the stripe.
- [ ] Watch **wear**: drive I²t, heat, structural shock; check the gantry for loosening

---

## 5. Varying-speed sharpness — isolate the cause

Already diagnosed: 32-stage TDI multiplies any mismatch between real image
displacement and the one-pixel-per-EXSYNC charge shift by the stage count.
Constant velocity → constant mismatch → harmless fixed sub-pixel offset. Varying
velocity → time-varying error → blur.

Candidates, most likely first:
1. EXSYNC not tracking actual load (EL2521 pulse train or motor-side encoder →
   follows command, not load; error is dynamic under accel)
2. Free-run line rate in that mode
3. Structural ringing from jerk

**Observation 2026-09-13 (Hoyte): timed scan is sharper than curve scan.**
That is the constant-vs-varying test already done by accident. Code confirms
the two modes differ only in the profile:
- `ScreenTimed.qml` sends a flat 1.0 profile with min = max velocity.
- `ScreenScan.qml` sends the artist's curve.
- In both, xylod paces the trigger from the **commanded** velocity
  (`Sequencer.cpp`, `lineHzNow = effBase * v / effMax`), never from the drive's
  `actualPos` / `actualVel`, which it already receives (`EcBackend.h:79`).
- The axis lags the command by ~27 ms (`Calib.qml` `triggerLeadSec`, measured).
  At constant speed that lag is a fixed offset, so it's harmless. On a curve,
  trigger rate and real image speed disagree by roughly `accel × 0.027 / v`, and
  48 stages multiply that. Example: 100 °/s changing at 500 °/s² → ~13% → ~6 px
  of smear.
- Points to candidate 1. Fix options, least invasive first: (a) delay
  `lineHzNow` by `triggerLeadSec`, (b) pace from `actualVel`, (c) encoder-locked
  trigger (EL5101 echo).

- [x] ~~Same target at 3–4 constant speeds~~ — effectively done: constant-speed timed scan is sharp → dynamic cause
- [ ] Confirm on one curve scan: blur bands should sit where the curve is steepest, not where it's slowest
- [ ] Velocity ramp — does blur track |accel| or v?
- [ ] Stages 32 → 16 → 8 (blur roughly halving confirms stage mismatch; costs a stop each step)
- [x] Log Beckhoff actual-vs-commanded following error — done 2026-09-13: every
  `pass N end` line now reports `axis lag ~N ms`. First real curve scan: 29.6 ms
  (reads ~1 ms high) against the 27.1 ms `line_lag_ms` now in xylod (`91af11d`).

### TDI sync calibration — 2026-09-13 (48 stages, −6 dB)

Stages went 16 → 48 and curve scans looked softer: at 48 stages lines/deg must
be right to ~2%. Modes disagreed (curve 175.3, timed 150, Calib 150.65), so it
was measured instead. Method: xylod driven directly, single constant-speed pass
14° → 158°, line rate held at 10.8 kHz so exposure is identical, lines/deg
swept. Score = along-scan detail energy ÷ across-sensor detail energy in the
same TIFF, after box-resampling every scan to one angular grid (140 lines/deg)
so stretch isn't read as blur. Scripts: `capture/tdi_sync_sweep.py` /
`capture/tdi_sync_score.py`.

| lines/deg | scan | score |
|---|---|---|
| 112.5 | 1809 | 0.235 |
| 125 | 1810 | 0.274 |
| 137.5 | 1811 | 0.445 |
| 145 | 1813 | 0.616 |
| 147.5 | 1814 | 0.628 |
| **150** | 1805 / 1812 | **0.664 / 0.627** |
| 152.5 | 1815 | 0.596 |
| 155 | 1816 | 0.548 |
| 162.5 | 1806 | 0.440 |
| 175 | 1807 | 0.325 |
| 187.5 | 1808 | 0.145 |

(1805–1808 ran at 72 °/s with varying rate; 150 repeated at constant rate agrees.)

- **Peak 149.5 lines/deg** (quadratic fit, 68% bootstrap 147.5–149.8) — within
  1% of the 2026-08-09 doorframe value 150.65. The square target's 175.3 is 17%
  high for this scene (≈8 px of smear at 48 stages).
- Applied: `tdi.sync = on`, `lines/deg = 149.5` (Pi `~/.config/xylosome/XYLOSOME.conf`
  `[calib]`), so every mode uses it. Turn `tdi.sync` off to get the old per-mode numbers.
- [ ] Explain the 175.3 vs 149.5 gap. Sync depends on subject distance from the
  axis, so the square target likely sat at a different distance — re-check by
  placing it at the scene's depth. Until then, `C = 9310` is aspect-only.
- [ ] Re-run the sweep whenever the lens, focus distance or subject depth changes.
