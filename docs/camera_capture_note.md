# Camera + capture domain — where the settings live (note, 2026-06-09)

Written after the first Pi ⇄ Beckhoff bench session, while discussing whether
TDI / exposure can be reached from the HMI. Short answer: not yet, by design.

## Verified hardware (2026-06-13)

The imaging chain, confirmed from the actual units (not the old diagram labels):

- **Camera — Teledyne DALSA Piranha `HS-80-08K80-00-R`.** 8192 x 96 TDI line
  scan, 7 um pixels, 8/12-bit, line rate **38.3 kHz at 12-bit / 68.6 kHz at
  8-bit** (manual Table 14 — the old "34 / 68 kHz" here was approximate).
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
| camera hard limit, 12-bit 4-tap Medium (`clm 16`) | **38314 Hz** |
| camera `ssf` requested by the agent at startup | **38000** |
| camera `ssf` *achieved* (quantised, from the log) | **37986.7** |
| `line_max_hz` in the box's `/etc/xylod.conf` | **37000** |

(Was 68610 / 50000 / 50000 in the old 8-bit 8-tap Full mode — see the bit-depth
section below for why the ceiling halved.)

**The rule is `line_max_hz` ≤ *achieved* `ssf`, not "keep them equal."** The
camera quantises `ssf` to its own clock and the step is not constant: 8500 lands
on 8499.79, 50000 landed exactly (which is why "equal" worked and hid this), and
38000 lands on **37986.7** — 13 Hz *below* the request. Setting the clamp equal to
the requested value would put the trigger above what the camera can service, and
the overrun is dropped silently. Read the achieved rate off the agent's
`startup line.rate` log line and leave margin below it.

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
| Bit depth + tap layout | Camera (`clm`/`sot`) **and** the grabber `.ccf` | capture agent — `CAM_BITS` drives both, reapplied every start |
| Max line rate | Camera readout ceiling (`ssf`) | capture agent `STARTUP_CAM`, reapplied every start — **38000** |
| Line trigger frequency | Beckhoff EL2521 | xylod — follows the speed curve (`line.baseHz`, mode curve/fixed) |
| Trigger ceiling `line_max_hz` | `xylod.conf` | **37000 — keep ≤ the camera's *achieved* `ssf` above** |
| EL2521 output mode + ramp | Terminal CoE, RAM only | xylod rewrites at every start (`EcBackend.cpp`) |
| Pass bracketing | EL2xxx DO: `pass_active` + `pass_index` pulse | wired to capture breakout; also TCP events `pass_start`/`pass_end` |

The Pi HMI's camera screen is static display text today — same as the other
settings pages. The Pi and the Beckhoff never speak to the camera; the only
physical meeting point of the two domains is the EL2521 trigger wire into the
frame grabber.

## Coupling rules (matter as soon as the camera is on the bench)

1. **Trigger ≤ max line rate.** xylod clamps at `line_max_hz`; if that clamp sits
   above the camera's `ssf`, lines drop **with no error anywhere** and the
   geometry lies. Closed 2026-07-24 by setting both to 50000, then re-set the
   same day for the 12-bit move to `ssf` 38000 (achieved 37986.7) and
   `line_max_hz` **37000** — but the two are still configured in different places
   on different machines and nothing enforces the relationship, so moving either
   one silently re-opens this.
2. **TDI wants lockstep.** TDI integrates while the image moves across the
   sensor — subject motion and line rate must stay in step or the image smears
   beyond the *intentional* fringing, and the smear scales with the stage count:
   a given velocity error costs ~6x more at 96 stages than at 16. Note the
   trigger is locked to *commanded* motion (the EL2521 simulates an encoder from
   the curve), not measured shaft position — so the servo's following error, not
   the camera, sets the practical stage ceiling. That is what the encoder-echo /
   locked-mode open item addresses (EL5152 is already in the segment for it).

## Bit depth — 8-bit → 12-bit (moved 2026-07-24)

`clm` sets the Camera Link configuration, the tap count **and** the bit depth in
one command; `sot` sets the pixel strobe. Manual Table 14 gives this model only
three rows, and no 12-bit row keeps 8 taps:

| `clm` | CL config | taps | bits | `sot` | max line rate |
|---|---|---|---|---|---|
| 21 | Full | 8 | 8 | 640 (80 MHz) | 68610 Hz ← was the default |
| **16** | **Medium** | **4** | **12** | **320 (80 MHz)** | **38314 Hz** ← now |
| 15 | Medium | 4 | 8 | 320 (80 MHz) | 38314 Hz |

So 12-bit costs **half the line-rate ceiling** — Camera Link Full carries 64 data
bits per clock, which 8 taps × 8 bits fills exactly and 12-bit cannot. Nothing
else about the camera changes: TDI stages, exposure and the `ssf`-is-only-a-
ceiling behaviour are all as before.

**What it does and doesn't buy.** It does not make scans brighter — that is
exposure/gain. It buys shadow resolution: at the old 8-bit working exposure
(scan_0255 mean 10.7 of 255) a frame was quantised into ~11 usable levels, a
12-bit one into ~170.

**But the exposure problem has since flipped, and it needs attention.** Under
`sem 3` the EXSYNC period *is* the exposure, so the artist's slow sweeps (~960 Hz
on a 25 s pass, vs ~8500 free-run) put roughly 9× more light on each line. The
first 12-bit scans at gain 0.0 dB clip hard: scan_0286 **24.4% of pixels at full
scale**, 0287 16.4%, 0289 8.6%, means 27–40% of 65535. Clipped is unrecoverable —
depth does not help. Pull it back with aperture/illumination first, then negative
analog gain (`sag`, −10…+10 dB, ≈ −6 dB halves it), remembering gain is stored
**per CCD direction** (§4.3.3) so direction must be asserted before calibrating.
The agent logs `peak N/65535` per scan; 65520 means clipping.

**Both ends must agree, and the agent owns both.** `CAM_BITS` in
`capture/capture_agent.py` drives, from one constant:

- the camera — `clm`/`sot` asserted at every agent start;
- the grabber — the matching **base `.ccf`**, one per bit depth;
- the `ssf` clamp on the `:5521` settings bus.

### Do NOT hand-patch a .ccf to change bit depth (learned the hard way)

The first attempt patched `Pixel Depth`/`Taps`/`Camera Link Configuration`/
`Pixel Mask` onto the 8-bit file at runtime. It **hung the board**:
`SapAcquisition` never returned, so `board_lock` was held forever (LIVE reported
"board busy"), nothing was logged, and the camera sat stranded in `sem 3` —
silent, hence **no pixel clock and a red CL2 LED** on the grabber.

The missing key was **`Horizontal Active`**, the *per-tap* line width:
8192/8 = 1024 at 8 taps, but **2048** at 4 taps. Left at 1024 the grabber waits
for 4096 pixels a line while the camera sends 8192. Sapera's stock reference
`.cca` files carry 1024 in *both* their 8-tap and 4-tap variants, which is
exactly what made it look like it did not matter. Also: `Pixel Mask` stays
**255** (widening it was wrong) and `Tap Output` stays **2**.

So each depth gets its own CamExpert-built, verified-grabbing file, selected by
`CAM_MODE[...]["ccf"]`. The runtime patch still applies the frame height and the
six `EXTSYNC_EDITS` keys, and now **warns** if a base file lacks any key it means
to patch (`re.sub` is a silent no-op otherwise — the trap that would put the
mirrored scans back).

Where the settings live in CamExpert, which is not where the file implies:
- **Camera Link configuration** = the Device-row dropdown, and there is **no
  "Medium Mono"** — mono offers only `CameraLink Full Mono`, within which tap
  count and depth express Medium. (`CameraLink Medium Color RGB` is a colour
  path and wrong for this camera.)
- **Taps** = Basic Timing → **Camera Sensor Geometry** (`8X-1Y` → `4X-1Y`)
- **Depth** = Basic Timing → **Pixel Depth**

CamExpert needs the agent **stopped and disabled** — COM3 and the board are
single-occupant, and the scheduled task will otherwise re-take them.

It does **not** drive `line_max_hz` — that lives in `/etc/xylod.conf` on the
C6920 and is coupling rule 1's unenforced half.

**Storage convention changed with it.** The board returns uint16 with the data
right-justified (0..4095 at 12-bit, 0..255 at 8-bit), which any normal TIFF
viewer renders as near-black — this is why scans looked black outside the suite.
The agent now shifts once at the source (`RAW_SHIFT = 16 - CAM_BITS`), so what
lands on disk is an honest left-justified 16-bit image. File size is unchanged
(the TIFFs were always uint16). Scans captured before this are still readable —
`VipsEngine::to8()` probes the max and takes the legacy low-byte path for them.

## TDI stages — what changes and what doesn't (manual, checked 2026-07-24)

`stg` takes 16/32/48/64/80/96 (factory 96; the HS-82 model halves these).

- **Sensitivity scales with stages** — manual §4.2 describes `stg` as adjusting
  "the sensitivity level" and nothing else. Expect to rebalance gain after a
  change: 48→96 is roughly +1 stop, 48→16 roughly −1.6.
- **Max line rate does NOT change with stages.** The TDI-mode help screen prints
  `ssf 3499.87-68610.6 Hz` alongside all six `stg` values, unqualified, and §4.2
  mentions no rate penalty. So the ceiling holds at any stage count.
  (Beware: **Area mode** reports `ssf 1-6169.03 Hz` — a different mode, not a
  contradiction. `clm`/`sot` changes DO move the range — that help screen was
  read in `clm 21`; at 12-bit the ceiling is 38314 — but stages don't.)
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
