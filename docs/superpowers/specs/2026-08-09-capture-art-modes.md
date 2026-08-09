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
