# Teensy 4.1 Pendant Carrier — KiCad project

A 2-layer carrier board that hosts a socketed Teensy 4.1 and breaks out two
pushbuttons and one Grayhill **62AG22-H5-P** optical encoder to JST-XH
connectors. The Teensy's own micro-USB carries data + power to a Raspberry Pi;
there is no power supply circuitry on the board. The encoder and buttons are
**not** mounted to this PCB — they wire in via ribbon/JST cables.

Complete KiCad **7** project. KiCad 8/9 will open it and offer a format
upgrade — expected and safe.

## This revision: board re-shaped to Sketch10.dxf

The board outline is now built **directly from your `Sketch10.dxf`** — the tall
pendant shape, ~48.7 x 89.3 mm, with the narrow body and the right-side bump,
all 8 filleted corners. The **4 mounting holes are at the exact DXF positions**
(2 on the body centreline, 2 in the bump).

Because the board went from a 95 mm-wide horizontal layout to this narrow
vertical one, everything was re-placed:

- **Teensy U1 is vertical**, in the long narrow body, **USB at the bottom**.
- **J1 / J2 / J3 are in the right-side bump** (the ribbon-cable area), vertical.
- **Passives** sit in the gap between the Teensy's two pin rows.
- Everything fits inside the outline and clears the mounting holes — verified.

## Opening it (close the old version first)

If the previous board is still open in KiCad, **close the project**, then open
`teensy41_pendant_carrier.kicad_pro`. **Just reload — do not run F8 / "Update PCB
from Schematic"** (everything is self-contained now; F8 is what pulled in the
oversized stock footprints last time).

In the PCB editor, press **`B`** to fill the GND-pour zones.

## Routing status

The board is now **fully routed** — all 8 nets are in copper:

- The **5 signal mains** (Teensy ↔ connector for BTN1, BTN2, ENC_A, ENC_B,
  ENC_SW) run on the top copper. To get them all crossing-free on one layer,
  J2 is placed above J1 — that ordering makes the connections monotonic.
- The **encoder pull-up / filter network** (R1, R2, C1, C2), the **debounce
  caps** (C3, C4), and the **power nets** (`+5V`, `+3V3`) route on the bottom
  copper, with **9 vias** dropping from the SMD passive pads to the bottom
  layer. The bottom copper is otherwise just the GND pour.
- **GND** is the pour on both layers — press `B` in the PCB editor to fill it.

I verified the whole thing with my own tooling: schematic netlist == PCB
netlist, **all 8 nets fully connected by copper**, every pad and via inside the
board outline, zero foreign-net crossings, zero trace-over-pad, zero via
clashes, zero trace-clearance violations, zero courtyard overlaps.

**KiCad's own DRC is still the authoritative check** — I built this without a
KiCad instance to test against, so run DRC once you've opened it (and `B` to
fill the zones first). If anything's off, the schematic is the known-good
source — *Tools → Update PCB from Schematic* re-flows it.

## Files

| File | What it is |
|---|---|
| `teensy41_pendant_carrier.kicad_pro` | Project file |
| `teensy41_pendant_carrier.kicad_sch` | Schematic — fully wired, all symbols embedded |
| `teensy41_pendant_carrier.kicad_pcb` | PCB — DXF outline, placed, 5 mains routed, GND zones |
| `teensy41_pendant_carrier.pretty/` | Project footprints: Teensy socket + both JST connectors |
| `fp-lib-table` / `sym-lib-table` | Library tables |
| `Sketch10.dxf` | Your enclosure outline (the source of the board shape) |
| `design-notes.md` | Full design document (part decode, BOM, firmware) |
| `schematic-diagram.svg` | Human-readable connection diagram |

R / C use the universal `Resistor_SMD` / `Capacitor_SMD` KiCad libraries; the
Teensy socket and JST connectors are project-local; mounting holes use the
stock `MountingHole` library.

## Netlist summary  (all routed in copper)

```
+5V     U1.VIN  J3.1  C5.1
+3V3    U1.3V3  R1.1  R2.1
GND     U1.GND  J3.4  J3.6  J1.2  J2.2  C1.2 C2.2 C3.2 C4.2 C5.2   (pour, both layers)
ENC_A   U1.D4   J3.2  R1.2  C1.1
ENC_B   U1.D5   J3.3  R2.2  C2.1
ENC_SW  U1.D6   J3.5
BTN1    U1.D2   J1.1  C3.1
BTN2    U1.D3   J2.1  C4.1
```

## Before fab

Sanity-check the Teensy footprint pin mapping against the official PJRC
pinout. The custom footprint is vertical with USB at the bottom; pads 1–24 are
the right column (digital pins), 25–48 the left column (power/analog). The
design taps pad 1 = GND, 4 = D2, 5 = D3, 6 = D4, 7 = D5, 8 = D6, 25 = VIN,
46 = 3V3.
