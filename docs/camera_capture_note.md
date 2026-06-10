# Camera + capture domain — where the settings live (note, 2026-06-09)

Written after the first Pi ⇄ Beckhoff bench session, while discussing whether
TDI / exposure can be reached from the HMI. Short answer: not yet, by design.

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
