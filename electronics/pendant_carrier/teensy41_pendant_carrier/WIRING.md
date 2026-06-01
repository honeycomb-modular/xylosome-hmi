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
Encoder entered (B,A) so CW=+1; COUNTS_PER_DETENT=2 for the 61C11.
Protocol: READY, BTN1/2 DOWN/UP, ENC_SW DOWN/UP, JOG 1, JOG -1.

## Buttons
J1=BTN1->D2, J2=BTN2->D3 (other pin GND, Teensy INPUT_PULLUP).

## When fitting the real 62AG22-H5-P
The board is designed for the 62AG; its pin numbering differs again.
Re-derive the adapter from the 62AG datasheet and update THIS file.
