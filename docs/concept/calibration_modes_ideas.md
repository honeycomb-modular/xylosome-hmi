# Xylosome — future improvements checklist

*Captured from a claude.ai chat, early Sept 2026. Tick items off as they land;
the notes under each item are the reasoning behind it.*

---

## 0. Answer first — firmware questions (one `gcp` dump answers both)

These change the shape of section 1, so do them before building the exposure panel.

- [ ] **Does the HS-80 allow exposure time shorter than the line period?**
  - If yes: a clean exposure axis independent of velocity — changes the shape of
    the exposure panel, and helps the varying-speed sharpness problem too.
  - If no: velocity / stages / gain is the complete set.
- [ ] **Does a narrower cross-scan ROI raise max line rate?**
  - If yes, narrowing FOV extends the fast end of the velocity range.

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
| Exposure time | ? | Free, if firmware exposes it — see §0 |

- [ ] Build the shared exposure panel, reachable from every mode's parameter screen
- [ ] Show predicted EV delta
- [ ] Show distance to clip (from last pass histogram)
- [ ] Show which limit binds first (max line rate, max axis velocity, min line rate, gain floor)
- [ ] Show predicted pass duration, updated live
- [ ] Tag each route with its cost: `−2 EV · velocity · +6 min`, `−2 EV · stages 8→32 · softer`, `−2 EV · gain · noisier`
- [ ] Grey out unreachable routes (never fail mid-pass)
  - Deficit is computed by the machine; the route is chosen by hand, per subject.

### Parameters live in the HMI
- [ ] Camera: TDI stage count · analog gain · black level · bit depth · TDI direction · exposure time (if available)
- [ ] Motion: velocity · accel · jerk
- [ ] FOV: cross-scan ROI (pixel window along the line) · along-scan start/end
  - Aperture and ND stay **off** the screen — not machine-settable. Accepted
    consequence: EV readout is relative, not absolute. Absolute reference comes
    from the last pass histogram (clip %, shadow floor), measured not declared.

### FOV
Two axes, both settable, **neither in the EV sum** — cropping doesn't change
per-pixel brightness.
- [ ] Cross-scan = sensor ROI (verify whether narrowing raises max line rate — §0)
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

- [ ] Scan a square/grid target of known size, perpendicular to scan axis,
  constant velocity, rigid and flat
- [ ] Measure the result in pixels both ways (cross-scan is the reference — it can't be wrong)
- [ ] Apply ratio as correction (squeezed 8% → encoder counts per EXSYNC × 1.08)
- [ ] Re-scan and confirm 1.00
- [ ] Store as **per-setup calibration** (per lens / working distance), not a global constant
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

- [ ] Same target at 3–4 constant speeds (all sharp → dynamic cause)
- [ ] Velocity ramp — does blur track |accel| or v?
- [ ] Stages 32 → 16 → 8 (blur roughly halving confirms stage mismatch; costs a stop each step)
- [ ] Log Beckhoff actual-vs-commanded following error, correlate with blur bands
