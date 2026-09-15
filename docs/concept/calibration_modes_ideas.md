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

**Built 2026-09-15 (`capture.xerox`, xylod `xerox` execute flag) — untested on hardware.**

- [x] **Decide: FOV vs duration** → (b) **travel fixed**, duration extends by the halted time (Hoyte 2026-09-15).
  - The line count grows by `rate × halted time`; the image gets longer, never cut short.
  - The machine never speeds up to catch up — the rate is flat for the whole pass.
- [x] Rebind execute button during scan: BTN1 held = halt, released = go. Abort is `[abort]` on the ring.
  - `PendantReader` now forwards `BTN1 UP` as a key release; `main.qml` routes it to `btn1Release()`.
- [x] **Free-run line trigger** — not needed as such: the EL2521 *is* the grabber's "encoder", and xylod
  keeps emitting at the flat rate while the axis stands still, so the grabber keeps clocking lines.
  (`lineHzNow = effBase` in every state of a xerox pass, including paused.)
- [ ] Make **TDI stages** a control in this mode
  - 1 stage = clean repeated lines, true xerox smear. 48 stages (current) with the object
    stationary = blurred stripe. Both usable. Camera-side setting, capture agent owns it.
- [~] Stripe **edges**: `[brake]` on the screen = hard (accel limit) · medium 150 ms · soft 600 ms,
  a linear velocity slew (= constant decel). Drive quick-stop not tried.
- [~] **Stripe length** = `hold duration × line rate`; the screen shows the rate and counts halted lines live.
  - Brightness is unchanged — stripe is repeated, not brighter (same integration time per line).
- [x] **Frame room**: `haltBudgetS = (65000 − FOV lines) / rate` is sent; xylod adds it to `plannedLines`
  so the agent sizes the frame, and refuses halts once spent. Settle is 2000 ms (big buffer clear).
- [ ] **Verify on hardware**: halt/release latency, stripe edge look per brake setting, frame arm time
  with a ~65000-line buffer, and that the FOV completes after a spent budget.
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
  Also the code default in `Calib.qml` since `tdi.sync` was verified.
- [x] **Verified on a real curve scan** (scan 1817, 48 stages, −6 dB, focus on
  the bin between the two cars). Full-res crops of the bin at equal angular
  size, `docs/concept/tdi_sync_bin_compare.png` (`capture/tdi_sync_crop.py`):

  | crop | scan | setup | bin score |
  |---|---|---|---|
  | left | 1804 | curve, 175.3 lines/deg | 0.23 — edges doubled along scan |
  | middle | 1817 | curve, 149.5 lines/deg + 27.1 ms trigger delay | **0.52** |
  | right | 1812 | constant speed, 150 | 0.43 |

  The curve scan now beats the constant-speed one, so the speed changes no
  longer add blur: the trigger delay and the sync value are both doing their job.
  1817 logged 21528 lines / 144° = 149.5 and `axis lag ~29.5 ms`.
- [ ] Explain the 175.3 vs 149.5 gap. Sync depends on subject distance from the
  axis, so the square target likely sat at a different distance — re-check by
  placing it at the scene's depth. Until then, `C = 9310` is aspect-only.
- [ ] Re-run the sweep whenever the lens, focus distance or subject depth changes.

### Every mode on one sync rule — 2026-09-13

Rule: trigger rate = lines/deg × actual speed, lines/deg from `Calib`.
- [x] Curve, timed, HDR, stack, gradient, ramp (curve) take lines from `Calib`.
- [x] Pendulum and party: lines are now automatic (`Calib.linesForTravel`), not
  typed in; execute blocks if the trigger would pass 37 kHz or one frame
  (65000 lines) (`e014962`).
- [x] Line mode (curve/fixed) is a saved setting only ramp/gradient wrote, so a
  ramp scan on `[line: fixed]` silently broke the next curve/timed/hdr/stack/
  pendulum/party scan. Each now sets curve before executing (`e014962`).
- [x] Time-indexed passes emitted 1.04% more lines than planned (sample mean
  over n instead of the n−1 intervals) and cut the end off every pendulum.
  Fixed in xylod + `Calib` (`d5cc024`); verified on the cart: 64376 emitted =
  64376 planned.
- Deliberately unsynced: freerun, ramp `[line: fixed]`, static/chrono.

### Sharp return strokes — tried, not viable this way

- [x] Mid-grab TDI direction flip (`scd 2` + grabber `LINESCAN_DIRECTION_OUTPUT`
  set at each turnaround): the scan armed and ran, but the agent's scan thread
  never came back from the first flip — scan 1824 lost, agent restart needed.
  Reverted (`aa15750`, message has the details).
- [ ] Remaining routes, both separate projects: serial `scd 0/1` per stroke
  (slow; only long periods), or a dedicated hardware line to CC3.
  Until then use `[lines: forward]`.
- [ ] Agent `read_state()` crashes on an empty SYNC Frequency reply
  (`float('')`) — seen when the camera was stuck in sem 3 + scd 2. One-line guard.

---

## 7. Banding lines across the whole frame — IN PROGRESS (2026-09-13, top priority)

Symptom (Hoyte): thin lines across the whole panorama, always in the same place,
clearest in sky. In the scan they run along the scan axis = fixed SENSOR COLUMNS.

Measured (`capture/sensor_bands_measure.py` on scans 1694, 1723, 1785, 1786 —
four different scenes, all 16 stages / 0 dB; today's scans 1787–1841 were
deleted in the Suite so could not be used):
- Column-scale pattern correlates 0.72–0.75 between different scenes →
  sensor-fixed, ~1.2–1.7% rms.
- Mostly NARROW DARK lines, a few px wide, always darker (never brighter),
  densest in columns ~2000–4100. Deepest: columns 2404–2415, ≈ −8%, identical
  in all four scans. Other sharp steps at 5115 (+3.4%), 6656 (−4%).
- NO steps at the 4-tap boundaries (2048/4096/6144) → not tap mismatch.
  (WRONG — see flat-target scans below: steps every 512 columns.)
- Plot: `docs/concept/sensor_bands_profile.png` (top: whole sensor, blue lines =
  tap boundaries; bottom: columns 2300–2520, one colour per scan).
- Diagnosis: dust/particles on the sensor window (thin dark shadows), plus a
  smaller general PRNU underneath.

**Flat-target scans 1792/1793 (2026-09-13, 48 stages, 0 dB, forward)** — Hoyte
scanned an evenly lit surface. Scripts `capture/sensor_flat_check.py`, `capture/sensor_tap_steps.py`; plot `docs/concept/sensor_flat_1793.png` (image, column means + trend, % vs trend).
- The two scans' column patterns correlate 0.99; first vs second half of 1793: 0.996.
- **Correction to the above: there ARE tap steps — at every 512 columns** (the
  sensor's 16 taps; `sag`/`sao`/`ssg` take tap 0–16), not at the 4 Camera Link
  taps. The 129-px running median followed the steps, so the high-pass hid them.
  Steps at 512…7680 (%): +17.0 +12.3 +8.9 +5.3 +1.1 −0.7 +0.1 −0.4 −2.2 −0.5
  −3.7 −5.2 −6.3 −2.6 −1.7. Largest toward the edges, where the falloff is steep.
- Same left-side steps (+17 +13/14 +9 +6) in old scene scans 1694, 1723, 1785,
  1786 (16 stages, 0 dB) → long-standing, not caused by today's gain change.
- Large-scale falloff centre/edge ≈ 1.7 (lens vignetting + lighting, can't separate).
- Dark lines on the flat (vs local trend): 2403–2422 −7.5%, 802–819 −5.3%,
  1954–1970 −3.9%, 5816–5834 −3.9%, 6657–6667 −2.7%, single column 1024 −2.4%,
  + ~14 more between −1.5 and −2.2%. Column-scale ripple 0.57% rms.
- Open: why the taps mismatch. Candidates: pixel coefficients off / not the
  factory set (`gcp` → "FFC Coefficient Set", "FPN/PRNU Coefficients"), or the
  agent's `sag 0 <dB>` flattening per-tap gain trims. `ccp` corrects taps,
  vignetting and dust in one go regardless (per-pixel coefficients).

Decision pending (Hoyte) — the question last asked:
- [ ] **Option 1 — clean the sensor window** (manual p.113: lens off, compressed
  air; if needed ESD-safe wiper + alcohol, slowly, across the short width; no
  cotton swabs). Then one scan with sky → re-run the measure script.
- [x] Hoyte chose **Option 2** (2026-09-13). Raw serial pass-through added to the
  agent (`{"cmd":"raw","line":...}` on :5521, allowlisted, ccf/ccp/gla hold the
  board) + client `capture/cam_raw.py`. Uncommitted; needs the elevated agent restart.
**Root cause found (2026-09-13, via the pass-through):**
- The raw sensor (`gla`, no coefficients) has NO section steps. They came from the
  loaded **FFC set 3**: FPN all 0, PRNU jumping at section edges (px 7680→7681:
  1360→600 → predicted +16.2% vs measured +17.0% at image col 512; px 512→513
  predicted −1.6% vs −1.7%). Coefficient = 1 + value/4096. User sets 1, 2, 4 had
  the same fault; factory set 0 was sane (FPN ~78, +0.9% at that edge).
- **Reverse** carried per-section analog *reference* gains of +5.6…+8.9 dB
  (bathtub, highest at the edges = an old `ccg` run with the lens on); forward was
  0. So reverse passes were ~2–2.7× brighter than forward.
- Camera is mirrored (`Mirroring Mode: 1, right to left`): image col c = sensor px 8193−c.

**Done (Hoyte approved; lens, aperture and target as at the time of calibration):**
- Reverse reference cleared: `sag t −ref` per section (exact values from `get ugr t`)
  → totals 0.0 → `ugr`. Raw reverse then matched forward within 1–3% per section.
- Set 1 recalibrated both directions, 48 stages, 0 dB: `ccf` lens capped (dark ≈79–81),
  `wfc 1`; `ccp` on the flat target at `ssf 15000` (brightest px 82–84%), `wpc 1`.
  No warnings. Forward coefficients lift the dust line (px 5770–5797: 745→1072→719);
  reverse shows no bump there or mirrored — reverse probably uses the other
  48 stage rows, so it doesn't see that particle.
- Restored `scd 0`, `ssf 38000`, `epc 1 1`, then `wus`. Old sets 2, 3, 4 untouched (all bad).
- Pass-through allowlist now also has `sag`/`ugr`; `gla` timeout 120 s (a full-width
  `gla` takes ~70 s at 9600 baud and spilled into the next reply at 30 s).
- [x] Verified with flat scans (Hoyte: "looks good"). Forward 1796 / reverse 1797:
  section steps within ±0.3% (were up to +17%), dark lines deeper than −1.5%: 0
  (were 20), ripple 0.10 / 0.08% rms (was 0.57%), mean 2893 vs 2790 DN (directions
  now match). Residual: edges ~10% BRIGHTER than centre (centre/edge 0.90) — `ccp`
  saw one static patch whose lighting differs from the scanned average; redo `ccp`
  on a more even / defocused target if it shows in scenes. (1794/1795 were clipped.)
- Sync check after the calibration (Hoyte asked): Pi `syncLinesPerDeg=149.5`,
  `syncEnabled=true`; xylod trigger delay 27.1 ms, axis lag ~29.5 ms (same as 1817);
  camera 48 stages, no binning, clm 16 — all unchanged. Street scans 1798–1803 are
  smeared along the scan (sync-score bands down to 0.07–0.2; defocus would sit near 1)
  because the camera was left in **reverse** after the reverse flat check
  (`camera_settings.json` `"scan.dir": "reverse"`), not because of the FFC.
  Confirmed: back to forward, same scene, scans 1808/1809 sharp (Hoyte), street
  bands 0.83–2.5 vs 0.47–0.8 in reverse 1801. Lesson: after any reverse test, set
  scan.dir back to forward — the setting persists across agent restarts.
- [ ] Reverse 1797 collected 7909/8972 lines ("frame not filled", ~12% short;
  forward ~7 short) — grab/trigger side, unrelated to the calibration. Look into it.
- [ ] Recalibrate if aperture, stages, or gain change (`ccp` at least).
- [ ] Old, now superseded: **Option 2 — camera flat-field correction** for what remains: `ccf` (FPN,
  lens capped), `ccp` (PRNU, even defocused white target), save `wfc`/`wpc`,
  enable `epc 1 1`. At working setup: 48 stages, −6 dB, forward (scd 0), and
  redo if aperture changes. COM3 is owned by the capture agent → needs a small
  calibration pass-through in the agent (one elevated restart) OR stop the agent
  and use CamExpert.
- [ ] Option 3 (fallback) — software per-column gain from a flat scan, applied at save.
- [ ] Unknown: whether pixel coefficients (`epc`) are already enabled — the
  agent's `read_state()` doesn't expose that gcp line.
