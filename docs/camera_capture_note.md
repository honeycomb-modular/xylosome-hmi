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

### Two ways to pace the line trigger (decide per shot)

1. **EL2521 pulse -> J4 Trigger-In (11/12) -> grabber -> EXSYNC -> camera.**
   The Beckhoff pulse follows the speed curve (geometry <-> sampling). Matches
   the `line.mode == "curve"` design below.
2. **Quadrature encoder -> J4 shaft-encoder inputs -> grabber.** EXSYNC is then
   locked to actual position. With **96 TDI stages** this is the robust path —
   line rate must track velocity or the image smears past the *intentional*
   fringing. This is the encoder-lock open item on the architecture diagram.

`line_max_hz` in `xylod.conf` is a placeholder **20 kHz**; the camera's real
ceiling is **up to 68 kHz** (mode-dependent). Set the working value from
CamExpert for the chosen exposure/TDI — don't assume.

## Who owns what

| Setting | Lives where | Set how |
|---|---|---|
| Exposure, gain | Camera (Dalsa Piranha) | Frame grabber on capture PC — CamExpert / Sapera |
| TDI stages | Camera | Same — capture PC |
| Max line rate | Consequence of the two above | Read it in CamExpert |
| Line trigger frequency | Beckhoff EL2521 | xylod — follows the speed curve (`line.baseHz`, mode curve/fixed) |
| Trigger ceiling `line_max_hz` | `xylod.conf` | **Placeholder 20 kHz — replace with the real max line rate from CamExpert** |
| Pass bracketing | EL2xxx DO: `pass_active` + `pass_index` pulse | wired to capture breakout; also TCP events `pass_start`/`pass_end` |

The Pi HMI's camera screen is static display text today — same as the other
settings pages. The Pi and the Beckhoff never speak to the camera; the only
physical meeting point of the two domains is the EL2521 trigger wire into the
frame grabber.

## Coupling rules (matter as soon as the camera is on the bench)

1. **Trigger ≤ max line rate.** xylod clamps at `line_max_hz`. If the clamp is
   above the camera's real ceiling for the chosen exposure/TDI, lines drop and
   the geometry lies. Set it from CamExpert's number, not optimism.
2. **TDI wants lockstep.** TDI integrates while the image moves across the
   sensor — subject motion and line rate must stay in step or the image smears
   beyond the *intentional* fringing. This is the encoder-echo / locked-mode
   open item on the architecture diagram (EL5152 is already in the segment for
   it). Until that's built, treat high-TDI-stage configs as experiments.

## Future: capture agent (backlog, decided not-tonight)

A small service on the capture PC, using the Sapera API:

- connects to xylod :5510 as a TCP client (the protocol already broadcasts to
  any client — pass timing arrives for free)
- accepts camera-feature commands → ScreenCamera on the pendant becomes live
  (exposure, TDI selection within whatever the camera model allows)
- reports the camera's actual max line rate back → `line_max_hz` set
  automatically instead of hand-typed

Design decision to make first: which camera knobs the artist owns from the
pendant vs what stays fixed in CamExpert. (Exposure = creative axis 3 on the
diagram, so probably at least that one.)
