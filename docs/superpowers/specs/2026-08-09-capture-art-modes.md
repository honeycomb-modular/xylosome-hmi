# Xylosome Capture Modes — Plan (recorded 2026-08-09)

Existing and proposed art/capture modes for the Pi HMI. Proposed modes were
designed in conversation on mobile and never committed until now. UI pattern:
modes page → per-mode graphic parameter screen (same as existing modes, see
`ScreenModes.qml`).

§1–4 are the plan as authored. **§5 is a feasibility triage added at the Capture
PC the same day**, checked against `beckhoff/PROTOCOL.md` and the HMI source at
`0caeca3`.

---

## 1. Existing modes (implemented)

1. **Curve scan** — motion follows a user-drawn velocity curve
2. **Static scan** — fixed-speed pass
3. **Timed scan** — timer-driven moving scan

## 2. Proposed modes

| Mode | Concept | Parameter screen design |
|---|---|---|
| **Party** | Motor back/forth with varied start/stop patterns | Seeded motion-path preview + energy slider + reroll button |
| **HDR** | Bracketed exposures of the same scene | Exposure ladder: bracket count + stop spacing |
| **Super-res / dither** | Sub-pixel offset passes | Offset pattern picker: interlace / 2×2 / 3×3 |
| **Stack** | Multi-pass averaging for SNR | Pass stepper with live SNR-in-stops readout |
| **Trichrome** | Sequential R/G/B filter passes | R/G/B pass swatches + full-screen filter-swap interstitials |
| **Velocity ramp** | Speed varies over the scan | Reuse curve-editor widget, target = velocity |
| **Exposure gradient** | Exposure varies over the scan | Reuse curve-editor widget, target = exposure |
| **Echo** | Repeated/offset structure | Reuse curve-editor widget, target = echo param |
| **Pendulum** | Sinusoidal motion | Draggable sine: amplitude / frequency / drift |
| **Chrono** | Interval-timed repeated captures | Timeline strip: interval, count, finish-time readout |

Shared component: **pass-progress strip** for all multi-pass modes.

## 3. Implementation decomposition (accepted for consideration)

Every mode decomposes into four independent axes:

- **Motion program** — Beckhoff (xylod)
- **Pass structure** — sequencer, proposed Beckhoff-owned; signals pass boundaries
- **Exposure policy** — capture PC
- **Assembly** — capture PC

HMI sends a job spec; Beckhoff signals pass boundaries over :5510 events.

## 4. Open questions (parked)

- Curve editor: reusable component vs. baked into the curve page?
- Per-pass preview data path back to the Pi?
- Mid-sequence failure/resume behavior?

### Related

- Dynamic-range motivation for HDR: line scanner's biggest problem is clean
  B&W without clipped highlights; alternating per-line exposures considered.
- Suite side: pass structure feeds the Review Suite's pass pairing
  (`docs/concept/review_suite_plan.md`).

---

## 5. Feasibility triage — added 2026-08-09 at the Capture PC

### 5a. The three constraints that decide everything

From `beckhoff/PROTOCOL.md` `execute` and `pi/hmi/src/BeckhoffLink.h:69-78`:

1. **`profile[]` is an *unsigned speed* curve** — N uniform samples `0..1`, scaled
   between `minVelDegS`/`maxVelDegS`, direction fixed by `arcStartDeg →
   arcEndDeg`. Motion within a pass is **monotonic. No reversal is expressible.**
2. **`minVelDegS` is a floor** — the axis never truly stops mid-sweep, so there is
   no dwell/freeze primitive.
3. **Pass count is locked to 1 or 4** — `colorMode` 0 = 4 passes R/G/B/C,
   1 = 1 pass Clear. No arbitrary N, no custom filter order, and one `profile`
   serves *all* passes. `setFilter` acts only from idle (`Sequencer.cpp:189`),
   so nothing can change filter mid-sweep.

**Already built, contrary to §3's "proposed":** pass boundaries are *already*
signalled — `pass_start` (with `"filter":"R"`), `pass_end`, `seq_done` are in
`PROTOCOL.md` today. The pass-progress strip is free UI work, not new plumbing.

**Unexploited lever:** `line.mode` is `"curve"` (rate ∝ instantaneous velocity)
or `"fixed"` (constant `baseHz`). Fixed + a varying profile deliberately breaks
geometry — the subject stretches where the axis is slow, compresses where fast.

*Corrected 2026-08-09 after reading the source:* it is **not** hardcoded.
`BeckhoffLink.cpp:154-158` already reads it from QSettings —
`beckhoff/lineMode` (default `"curve"`) and `beckhoff/lineBaseHz` (default
5000). But **nothing writes either key**: no QML and no C++ sets them, so the
lever is dormant and reachable only by hand-editing the Pi's settings file.
There is therefore *no code change at all* needed to use fixed mode — only a UI
control to select it. Cheaper than first assessed.

### 5b. Buckets

**A — already exists; UI-only work**

- **Velocity ramp** — this *is* curve scan. Only distinct if framed as a
  simplified linear-ramp preset over the same `execute`.
- **Trichrome** — the motion/filter machinery is `colorMode 0` and already runs
  R/G/B/C with internal filter changes. A true *three*-pass variant (no Clear)
  hits constraint 3; four-pass trichrome is available now.
- **Pass-progress strip** — events already exist.

**B — possible today, HMI-only, no daemon change**

- **Chrono** — fire `execute` on a timer. Cheapest mode on the list.
- **Stack** — loop N BW (`colorMode 1`) executes and average on the PC. Sidesteps
  the pass-count limit entirely; costs a settle/home between passes.

**C — capture-PC only; independent of xylod, can proceed in parallel**

- **Exposure gradient** — vary exposure during acquisition. No motion change at
  all. Sync source would be axis progress/position from the 10 Hz status push
  (coarse) or PC-side timing (finer).
- **HDR** — exposure bracketing is a capture-agent concern. Only the *pass
  structure* touches xylod. The "alternating per-line exposures" idea in §4 is a
  **camera capability question** (does the Dalsa support dual-exposure TDI?), not
  a motion one — worth answering before designing the mode.

**D — blocked on the two keystone gaps**

- **Party**, **Pendulum** — both need reversal (constraint 1). Pendulum also wants
  dwell at the turning points (constraint 2).
- **Super-res / dither** — needs per-pass sub-pixel arc offsets; today one arc
  serves all passes (constraint 3).
- **HDR / Stack** *as native multi-pass* — need arbitrary N (constraint 3).

**Underspecified — needs definition before it can be triaged**

- **Echo** — "repeated/offset structure" doesn't yet say whether the repetition is
  in motion, in exposure, or in assembly. Those are three different projects.

### 5c. The keystone

Five of ten modes are blocked by exactly **two** gaps in `xylod`:

1. **Signed / reversible motion** within a job (unlocks Party, Pendulum)
2. **Arbitrary pass count with per-pass arc offset** (unlocks Super-res, native
   Stack, native HDR)

One focused daemon change addresses both, and it is the *only* motion work the
whole list needs. Everything else is HMI or capture-PC work that can proceed
without touching the proven motion path.

**Suggested order:** Chrono and Stack first (bucket B — real modes, zero risk,
they exercise the UI pattern), then the `line.mode` unlock (one line, new look),
then the capture-PC exposure axis (bucket C), and only then the xylod keystone.

### 5d-bis. Build log

**2026-08-09, branch `art-modes`** (not merged to `main`):

- `bbb355f` — modes picker lists the planned modes, greyed, under a hairline.
  Not in `modeFocus.targets`, so they are not focusable or clickable.
- `240c61e` — **`capture.chrono` built.** Each frame is an `executeStatic`; a
  `Timer` spaces them. Per-frame shape is read from `capture.static`'s saved
  settings rather than duplicated. Refuses to start when interval ≤ frame span,
  because the second `executeStatic` would restart the first mid-frame rather
  than queue. chrono graduated into the live list; planned block reflowed 3×3.

Verified: all 31 QML files compile under `qmlcachegen` (msys2 UCRT64 Qt6).
`qmllint` alone was **not** sufficient — it passed a duplicate
`Component.onCompleted` that `qmlcachegen` caught. Use qmlcachegen for QML
verification on the Capture PC; a full build cannot run there because
`PendantReader.cpp` is Linux-only.

**Not visually verified** — needs the 960×540 panel. Open: planned-block row
spacing at 22 px, whether the greyed treatment reads as disabled rather than
broken, and chrono's two-slider layout.

**Stack deliberately not built.** Its HMI half is trivial (loop N BW executes)
but its *value* is the averaging, which is capture-PC work — and COOP.md §5
says the capture agent must not be restarted from code. Building only the HMI
half would ship something that duplicates chrono without the payoff. Needs
Hoyte present.

### 5d. UI consequence

`ScreenModes.qml` currently lists four rows at
`Theme.contentTop + 40 + Theme.rowStride * n`, with slot 4 holding the
"currently in…" line — roughly two or three free slots. **4 existing + 10
proposed = 14 rows.** The flat list will not hold; it needs grouping (e.g.
`capture` vs. `art`) or paging before the proposed modes land. Worth deciding
before the first new mode, not after.

---

## 6. Bench findings, 2026-08-09 evening

### 6a. The optical calibration — MEASURED

TDI needs the subject to advance exactly one pixel per line trigger. That ratio
is fixed by the optics; it is **not** a free parameter. Every mode used to
default to `lines: 22200` regardless of arc, which can only be right at one
field width.

Measured against a scan Hoyte confirmed correct by eye:

    26726 lines over 177.4 deg (arc -76.0 -> 101.4)  =  150.65 lines/deg

Now lives in `pi/hmi/qml/Calib.qml`, persisted, with `lines` DERIVED from the
arc in hdr/stack/ramp. Re-measure by scanning something round: lines scale
linearly, so 1.4x too tall means multiply by 1.4.

**Consequence worth remembering:** `baseHz = lines*maxVel/arc` and
`lines = linesPerDeg*arc`, so the arc cancels — **`baseHz = linesPerDeg *
maxVel`**. Trigger rate depends only on sweep speed, never on field width. That
is what bounds exposure bracketing, since the camera will not sync below
3500 Hz. At 60 deg/s there is only 1.4 stops of headroom; ~245 deg/s gives the
full 3.4.

### 6b. Getting the line count wrong does more than stretch

Too many lines for the arc means the frame cannot fill inside its pass, so the
capture agent's grab stays open into the NEXT pass and one TIFF ends up holding
two different exposures. Stretched geometry, TDI smear, short passes and
exposure bleed are all the same fault.

### 6c. TDI stages — the "48 is best" memory is superseded

`docs/camera_capture_note.md:212` already records that the 48-stage result
predates the trigger being fixed and was measured in free-run. 96 is factory;
48->96 is about +1 stop. **Do not "restore" 48 from memory** — that was done
here on 2026-08-09 and cost a stop for no reason. Re-test 64/80/96.

Separately: the old gain/stages-bracketing hdr left `tdi.stages` at 96 after a
set, which softened every subsequent scan until spotted. That code is gone —
hdr now touches no camera parameter at all.

### 6d. OPEN — triggers lost between the EL2521 and the grabber

**xylod is exonerated by measurement.** Sampling its status stream during a
3-bracket hdr set (velocity scales 1 / 0.5 / 0.25):

| pass | commanded | sustained? | captured | share |
|---|---|---|---|---|
| 0 | 14161.1 Hz | median == max | 14147 Hz | 100% |
| 1 |  7080.6 Hz | median == max |  1132 Hz | **16%** |
| 2 |  3540.3 Hz | median == max |  2705 Hz | 76% |

Motion is exactly right too — pass durations 639/1277/2554 ms are a clean
1x/2x/4x. Reproducible across sets (pass 1: 1435, 1446, 1454, 1454 lines).

Ruled out:
- **daemon scaling** — source inspected in the built tree; commands
  `effBase = lineBaseHz * sc` and sustains it (median == max)
- **a rate floor** — the loss is NON-monotonic; 7080 Hz is far worse than
  3540 Hz
- **agent busy writing the previous TIFF** — ~2 s of gap between sweeps, and
  the log shows the grab arming 5 ms into each settle

Unexplained: why an intermediate rate loses most triggers while both a higher
and a lower rate do not. Next place to look is the EL2521 itself (does it
actually emit the commanded frequency after a mid-sequence change?) and the
grabber's EXSYNC handling — not the daemon.

---

## 7. Multi-pass under EXSYNC — SOLVED, 2026-08-09

Multi-pass had **never worked under EXSYNC**. It was not a regression: EXSYNC was
built and validated for single-pass scans, and 4-pass colour had only ever been
run in freerun. Stack and hdr were simply the first modes to ask for it.

**Two independent faults, stacked** — which is why every single-cause theory
failed for hours.

### 7a. Stale transfer → whole passes returning ZERO

`Grabber.arm()` did `buf.Clear()` + `xfer.Snap(1)`, and `xfer.Abort()` was called
**only when a frame came back incomplete**. So after a FULL pass the next Snap was
issued on a transfer that had completed and was never reset, and sometimes never
took. Pass 0 is the only pass that never inherits a used transfer — and it was the
only pass that reliably filled, in every multi-pass mode.

Fix: `arm()` aborts unconditionally before Clear + Snap. Aborting an idle transfer
is harmless. (Do NOT instead recreate the SapAcquisition per pass — tried, it takes
the native driver down with no traceback and kills the agent.)

### 7b. Blocked status thread → PARTIAL frames

`tifffile.imwrite` of a ~400 MB frame ran on the thread that reads xylod's status.
While it blocked, the status backlog grew, the next pass's settle was read late,
and its Snap was armed after the sweep had already started.

The signature: with 7a fixed, a pass was starved **exactly when the previous pass
produced a big file** — 26756 full / 11058 / 26745 full / 4894, alternating.

Fixes: the write moved to a worker thread (queue depth 1; `seq_done` joins it), and
`settleMs` 150 → 1200 ms to cover what remains. `collect()` still copies the frame
three times (`buf.Read`, `string_at`, `<< RAW_SHIFT`) and `filled_lines()`/`max()`
each scan it again — about a second on a full frame. Slimming that is the way to
claw the settle back; it is also the change that broke the agent when attempted
mid-diagnosis, so do it alone against a known-good baseline.

**Result:** 4-pass colour, all four passes 26745/26756, peak 65520.

### 7c. Ruled out by measurement — do not re-chase

- **xylod** — emits and sustains the commanded rate on every pass (its own
  per-pass log vs the agent's collected count). Fully exonerated.
- **The EL2521 and the grabber's decode** — a speed-curve scan has correct
  geometry, which it could not if quadrature were mis-decoded. No scope needed.
- **Rate, and rate changing between passes** — a same-rate 3-pass stack failed
  identically; 7382 Hz is flawless in a single pass.
- **The inter-pass gap alone** — 150 ms and 1800 ms behaved the same while 7a was
  present.
- **Lines arriving late** — a 4 s collect grace recovered nothing; they never
  arrive.
- **`Shaft Encoder Direction`** — `0` does not mean "count both ways" here, it
  stops the grabber clocking entirely (every pass zero, including pass 0). Leave
  at `1`. Emitting reverse quadrature during the return is also counted, so the
  direction filter does not reject it: pass 0 fell to 62 lines.
- **`tdi.stages`** — `docs/camera_capture_note.md:212` already records that the
  "48 is best" result predates the trigger fix. 96 is factory. It was set to 48
  here from a stale memory note and cost a stop for nothing.

---

## 8. hdr — WORKING, and why it is chained not multi-pass

`capture.hdr` fires **one execute per bracket**, each a single-pass sequence, with
the exposure ladder carried by per-bracket velocity. Verified 2026-08-09:
8285/8288 lines on all three brackets, peak 65520, durations 251/501/1001 ms.

**Why chained.** Multi-pass under EXSYNC still starves the pass after a full
frame by a fixed ~0.44 s even after §7's fixes — with the arm landing 9-14 ms
into a 2.47 s settle and every frame-sized operation moved off the status thread.
4-pass COLOUR fills perfectly with BIGGER frames and a SHORTER gap, so it is not
the settle and not the frame size. Single-pass sequences have never failed.
The multi-pass defect is real and still open; stack still uses that path.

**Two things chaining needs, both learned the hard way:**

- **3 s between brackets.** The agent destroys the Sapera acquisition at
  `seq_done` and creates a new one for the next sequence. Fire the next execute
  on `seq_done` and the third bracket comes back completely black; 1.5 s was
  still not enough (measured 1.53 s sweep-end to execute). 3 s works.
- **minVelDegS must be a FLOOR, not the peak.** Passing the peak for both means
  that when xylod caps `maxVelDegS` to hold the line count, the uncapped min wins
  — the axis outruns the capped max and the trigger overshoots the camera
  ceiling (seen: 37000 intended, 45194 emitted). Pass 1.0.

**Exposure is time, not gain.** Each bracket runs at a different velocity, so the
trigger rate scales with it and each line integrates proportionally longer — same
arc, same line count, same geometry, real photons. Gain sits before the ADC so it
rescues clipped highlights but amplifies noise with signal and collects nothing
extra.

**Known limitation — brackets do not register as tightly as colour mode.** Colour
runs every pass at the SAME speed; hdr runs each at a different one. Any fixed
time latency between sweep start and the first counted line becomes a different
ANGLE at each speed — 10 ms is 2.2 deg at 220 deg/s but 0.55 deg at 55 deg/s. Fix
is to offset each bracket's `arcStartDeg` by `latency * velocity`; the latency is
measurable from the shift between two brackets of known speed ratio. Not done.

Each bracket lands as its own Suite session — grouping them is display work, and
is what the multi-pass detour was originally trying to buy.

### 8a. Bracket registration — measured, corrected, verified

The brackets did NOT register. Global cross-correlation reported zero shift and
that was wrong — it averages a whole frame and happily hides a real offset.
Locating a single hard edge (a doorframe against blown-out sky, centre of frame)
in each bracket is what actually measures it.

**Before**, 3-bracket set at 220 / 110 / 55 deg/s:

    b0  edge line 3462.09   (reference)
    b1  edge line 3015.02   -447.1 lines  -2.97 deg
    b2  edge line 2786.72   -675.4 lines  -4.48 deg

Fits a fixed TIME offset, shift = t * (rate0 - rate_i):
t = 26.98 ms from b1, 27.17 ms from b2 — two brackets agreeing to 0.7%.

Cause: the trigger is paced off COMMANDED motion, so it starts clocking while the
axis is still accelerating. The catch-up costs a constant interval, which becomes
a different ANGLE at each speed. Same-speed modes (colour, stack) share the error
and never show it.

**Correction:** `Calib.triggerLeadSec = 0.0271`; hdr offsets each bracket's whole
arc by `lead * velocity`, both ends together so arc length and derived line count
are unchanged.

**After**, verified on the same edge:

    b0  edge line 9024.56   (reference)
    b1  edge line 9019.77    -4.8 lines  -0.032 deg
    b2  edge line 9012.03   -12.5 lines  -0.083 deg

54x better; 12.5 lines of 22443 is 0.06% of frame. The residual leans the same
way, so the constant is ~0.4 ms low — about 27.5 ms would null it. Not chased:
refining off a single subject risks fitting noise. Average two or three sets if
it is ever worth doing.

**Exposure ladder confirmed working** on that set: medians 3359 / 6554 / 15577 =
x1.95 and x4.64. An earlier set showed only x1.70 / x1.75 and prompted a worry
about an integration ceiling — that set had much shorter sweeps. At these rates
exposure tracks the line period as designed.

### 8b. Method note — how to measure this kind of thing

Global cross-correlation over a full frame is the WRONG tool for a small
geometric offset: it reported 0 lines when the truth was 447. Per-tile 2-D phase
correlation was no better (peaks ~0.013, i.e. noise). What worked was locating
ONE strong known edge sub-line in each frame and differencing. Ask which feature
to use rather than searching blind.
