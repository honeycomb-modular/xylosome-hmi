# XYLOSOME Pendant - Wiring (SINGLE SOURCE OF TRUTH)

> This supersedes the J3 / encoder pin tables in design-notes.md (sec 4) and
> DEVLOG (2026-05-23). Those used an INCORRECT encoder pin numbering. Use this.
> Verified 2026-06-01 (bench + datasheet).

## Carrier J3 -> Teensy (from KiCad netlist; fixed in copper)
| J3 | Net    | Teensy |
|----|--------|--------|
| 1  | +5V    | VIN |
| 2  | ENC_A  | D4 |
| 3  | ENC_B  | D5 |
| 4  | GND    | -- |
| 5  | ENC_SW | D6 |
| 6  | GND    | -- |

A/B are open-collector; R1/R2 pull up to +3V3 (Teensy-safe).

## Grayhill 61C11 (test encoder) pinout - from datasheet
| Pin | Function |
|-----|----------|
| 1 | GROUND |
| 2 | Pushbutton terminal |
| 3 | Pushbutton terminal |
| 4 | OUTPUT B |
| 5 | OUTPUT A |
| 6 | POWER +5V |

## Adapter cable 61C11 -> J3 (NOT 1:1 - reversal, enc N -> J3 7-N)
| 61C11 pin (fn) | -> J3 | net |
|----------------|-------|-----|
| 6 (+5V)        | 1 | +5V |
| 5 (Output A)   | 2 | ENC_A |
| 4 (Output B)   | 3 | ENC_B |
| 3 (pushbutton) | 4 | GND |
| 2 (pushbutton) | 5 | ENC_SW |
| 1 (GND)        | 6 | GND |

A straight 1:1 cable puts +5V on the encoder's ground and an output into the
power rail - that was the original bug.

## Firmware
firmware/teensy_pendant/teensy_pendant.ino - USB CDC @115200.
Polled full-quadrature decode (B,A order so CW=+1), position-correct + burst-spread.
Protocol: READY, BTN1/2 DOWN/UP, ENC_SW DOWN/UP, JOG 1, JOG -1.

## Encoder detent quirk (DO NOT re-troubleshoot as an electrical fault)
The Grayhill 62AG22 - AND the 61C11 test unit, identically - have detents that
are mechanically OFFSET from the optical code by one position per cycle.
Per 4 physical clicks the raw quadrature reads:
    clean(+1)  clean(+1)  DEAD(0)  DOUBLE(+2)   ... repeat
The DEAD click produces NO electrical change; the next ("double") click sweeps
two states 00->10->11 in <1 ms. The dead click always sits immediately before
the double. Net count over 4 clicks is correct (+4), but it is not 1-per-click.

Diagnosed exhaustively (2026-06): board DRC clean, ground 0.3 ohm, A/B isolation
20 kOhm (R1+R2, no short), R1/R2=10k, C1/C2=470pF, pinout correct, identical on a
spare board and on two different encoders. It is a HARDWARE CHARACTERISTIC of
these Grayhill optical encoders (detent ring vs code-disc alignment), NOT
wiring/ground/solder/layout. Spec: 62AG22 = 16 detents / 16 PPR.

Consequence: perfectly even 1:1 per click is not recoverable in software - the
dead click carries no real-time signal, and capping the double to hide it makes
the count DRIFT. The firmware keeps the count exact (never drifts) and spreads
the double into two quick steps (MIN_GAP_MS). The lone dead click stays inert.
For textbook dead-even 1:1 a properly-aligned encoder is needed; an EC11 is
electrically a drop-in but does NOT match this enclosure cutout (Grayhill =
3/8"-32 bushing + 1/4" shaft; EC11 = M7 bushing + 6 mm shaft).

## Buttons
J1=BTN1->D2, J2=BTN2->D3 (other pin GND, Teensy INPUT_PULLUP).

## Grayhill 62AG22-H5-P (the REAL encoder) pinout
From the datasheet WAVEFORM/TRUTH-TABLE diagram, Style AG (Rev 02/2024).
IDENTICAL pinout to the 61C11. Open-collector outputs; needs 10k pull-up +
<1000pF filter cap = exactly the carrier's R1/R2 + C1/C2. 2x3 .050" pin header -
confirm physical pin 1 on the part before soldering.
NOTE: design-notes.md sec 1/4 had this pinout wrong (power/outputs misplaced).
| Pin | Function |
|-----|----------|
| 1 | GROUND |
| 2 | Pushbutton terminal |
| 3 | Pushbutton terminal |
| 4 | OUTPUT B |
| 5 | OUTPUT A |
| 6 | POWER +5V |

## Adapter cable 62AG -> J3 (same reversal as the 61C11: enc N -> J3 7-N)
| 62AG pin (fn)  | -> J3 | net |
|----------------|-------|-----|
| 6 (+5V)        | 1 | +5V |
| 5 (Output A)   | 2 | ENC_A |
| 4 (Output B)   | 3 | ENC_B |
| 3 (pushbutton) | 4 | GND |
| 2 (pushbutton) | 5 | ENC_SW |
| 1 (GROUND)     | 6 | GND |

The 61C11 and 62AG have the SAME pinout, so the same reversed 6-way cable works
for both - the adapter you made for testing carries straight over.
