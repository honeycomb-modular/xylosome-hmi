# Camera + capture domain — where the settings live (note, 2026-06-09)

Written after the first Pi ⇄ Beckhoff bench session, while discussing whether
TDI / exposure can be reached from the HMI. Short answer: not yet, by design.

## Verified hardware (2026-06-13)

The imaging chain, confirmed from the actual units (not the old diagram labels):

- **Camera — Teledyne DALSA Piranha `HS-80-08K80-00-R`.** 8192 x 96 TDI line
  scan, 7 um pixels, 8/12-bit, line rate **34 / 68 kHz** (two modes).
  Interface is **Camera Link** (MDR26, control+data shared) — *not* CoaXPress
  or CLHS. ("HS" = High Sensitivity / TDI, not Camera Link HS — that naming
  trap is what put "CLHS" on the architecture diagram.) Line trigger is
  **EXSYNC**, enabled over the serial link; the camera reads out on the
  **falling edge** of EXSYNC.
- **Frame grabber — Teledyne DALSA `OR-X4C0-XPF00`** = **X64 Xcelera-CL PX4**
  (Camera Link, PCIe x4; also sold/labelled "Aquarius CL" under the same OR-
  code). Camera Link <-> Camera Link: matched to the camera.
- **The grabber generates EXSYNC** and sends it to the camera over the Camera
  Link control line — the camera is not triggered directly. The grabber's
  external I/O is on connector **J4**: a balanced **Trigger-In** (Trigger In 1 =
  J4 pin 11 +, pin 12 -) and **shaft-encoder** inputs. This J4 is what the
  incoming breakout board lands.

### Two ways to pace the line trigger — **decided 2026-07-24: option 2 is built**

1. **EL2521 pulse -> Trigger-In -> grabber -> EXSYNC -> camera.** The Beckhoff
   pulse follows the speed curve (geometry <-> sampling). Not used.
2. **Quadrature -> grabber shaft-encoder inputs. ← THIS IS WHAT RUNS.** The
   EL2521 is set to *incremental encoder simulation* and drives A/B into the
   grabber's shaft-encoder pins; the grabber synthesises EXSYNC on CC1. Wiring
   in `grabber_io_wiring.md`; xylod writes the terminal's CoE at startup.

**Direction matters, and it is not optional.** The axis returns over the same
arc after every pass. If the grabber cannot resolve direction it clocks that
return as more forward lines and each scan comes back as its own mirror. Two
things must both hold, or you get the mirror back:

- the EL2521 must be in encoder-sim mode (`0x8000:0E = 2`) so **B is driven** —
  in the default frequency-modulation mode only A pulses and direction is
  physically unknowable to the grabber;
- the `.ccf` must set `Shaft Encoder Direction = 1` (FORWARD). The default `0`
  is `DIRECTION_IGNORE`, i.e. count both ways.

The terminal's own ramp (`0x8000:06`) must also be **off**: it lags the
commanded frequency, starving short sweeps and spilling pulses into the return.
The artist's speed curve is the ramp. See `beckhoff/README.md` and `1023e8d`.

**Line-rate ceilings (measured 2026-07-24, supersedes the old "placeholder
20 kHz" note).** The camera's `ssf` is only a *readout ceiling* under ext sync —
the EL2521 emit sets the geometry, and a trigger arriving before the previous
line has been read out is dropped **silently**. Real numbers:

| | value |
|---|---|
| camera hard limit, 8-bit 8-tap Full | **68610 Hz** (~34 kHz at 12-bit) |
| `line_max_hz` in the box's `/etc/xylod.conf` | **50000** |
| camera `ssf`, set by the agent at startup | **50000** — deliberately equal |

Keeping the last two equal is the point: the trigger can then never outrun what
the camera can service, so no per-curve tuning is needed. Raising one means
raising the other. It costs nothing in light — 20000 and 50000 are
indistinguishable in brightness, because under `sem 3` the EXSYNC period sets
exposure, not `ssf`.

## Who owns what

| Setting | Lives where | Set how |
|---|---|---|
| Exposure, gain | Camera (Dalsa Piranha) | Frame grabber on capture PC — CamExpert / Sapera |
| TDI stages | Camera | Same — capture PC |
| Max line rate | Camera readout ceiling (`ssf`) | capture agent `STARTUP_CAM`, reapplied every start — **50000** |
| Line trigger frequency | Beckhoff EL2521 | xylod — follows the speed curve (`line.baseHz`, mode curve/fixed) |
| Trigger ceiling `line_max_hz` | `xylod.conf` | **50000 — keep equal to the camera `ssf` above** |
| EL2521 output mode + ramp | Terminal CoE, RAM only | xylod rewrites at every start (`EcBackend.cpp`) |
| Pass bracketing | EL2xxx DO: `pass_active` + `pass_index` pulse | wired to capture breakout; also TCP events `pass_start`/`pass_end` |

The Pi HMI's camera screen is static display text today — same as the other
settings pages. The Pi and the Beckhoff never speak to the camera; the only
physical meeting point of the two domains is the EL2521 trigger wire into the
frame grabber.

## Coupling rules (matter as soon as the camera is on the bench)

1. **Trigger ≤ max line rate.** xylod clamps at `line_max_hz`; if that clamp sits
   above the camera's `ssf`, lines drop **with no error anywhere** and the
   geometry lies. Closed 2026-07-24 by setting both to 50000 — but the two are
   still configured in different places on different machines and nothing
   enforces the relationship, so moving either one silently re-opens this.
2. **TDI wants lockstep.** TDI integrates while the image moves across the
   sensor — subject motion and line rate must stay in step or the image smears
   beyond the *intentional* fringing, and the smear scales with the stage count:
   a given velocity error costs ~6x more at 96 stages than at 16. Note the
   trigger is locked to *commanded* motion (the EL2521 simulates an encoder from
   the curve), not measured shaft position — so the servo's following error, not
   the camera, sets the practical stage ceiling. That is what the encoder-echo /
   locked-mode open item addresses (EL5152 is already in the segment for it).

## TDI stages — what changes and what doesn't (manual, checked 2026-07-24)

`stg` takes 16/32/48/64/80/96 (factory 96; the HS-82 model halves these).

- **Sensitivity scales with stages** — manual §4.2 describes `stg` as adjusting
  "the sensitivity level" and nothing else. Expect to rebalance gain after a
  change: 48→96 is roughly +1 stop, 48→16 roughly −1.6.
- **Max line rate does NOT change with stages.** The TDI-mode help screen prints
  `ssf 3499.87-68610.6 Hz` alongside all six `stg` values, unqualified, and §4.2
  mentions no rate penalty. So the 50000 ceiling holds at any stage count.
  (Beware: **Area mode** reports `ssf 1-6169.03 Hz` — a different mode, not a
  contradiction. `clm`/`sot` changes could move the range; stages don't.)
- **The old "48 stages is best" result predates the trigger being fixed.** It was
  measured in free-run, when the terminal's ramp meant the line rate never
  tracked the curve — so high stage counts were being punished by sync error
  that no longer exists. Worth re-testing 64/80/96.

### Gain is stored PER CCD DIRECTION

Manual §4.3.3: analog gain, analog offset, digital gain, digital offset,
background subtract and pixel coefficients are **stored separately for forward
and reverse**, and are swapped in automatically when `scd` changes. So any gain
or flat-field calibration is only valid for the direction it was done in, and a
direction change will appear to "reset" gain when it has really loaded the other
set. `STARTUP_CAM` asserts `scan.dir` on every agent start — set direction
first, calibrate second.

(`scd 2` also exists: direction taken from Camera Link **CC3**, i.e. the grabber
tells the camera which way it is going. Unused — direction is resolved at the
grabber's shaft-encoder decode instead.)

## Capture agent — BUILT (`capture/capture_agent.py`), not future

A service on the capture PC using the Sapera API. Done:

- connects to xylod :5510 as a TCP client (the protocol already broadcasts to
  any client — pass timing arrives for free)
- accepts camera-feature commands on :5521 → line rate, TDI stages, gain,
  scan direction
- owns the grabber: LIVE focus waterfall on :5520, per-pass TIFF capture to
  `CAPTURE_DIR`, mutually exclusive via one board lock

Still open:

- **reports the camera's actual max line rate back → `line_max_hz` set
  automatically instead of hand-typed.** This is the unenforced coupling in
  rule 1 above; it is the fix that would close it properly.

Design decision to make first: which camera knobs the artist owns from the
pendant vs what stays fixed in CamExpert. (Exposure = creative axis 3 on the
diagram, so probably at least that one.)
