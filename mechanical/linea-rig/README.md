# Linea rig — camera cage, cheese plate, colour-wheel drive

Mechanical parts that mount the Teledyne Linea HS 16k (HL-HM-16K30H) on the
Xylosome rotation axis, plus the colour-filter wheel and its motor bracket.

Status: **work in progress** (2026-11-13). See "Open issues" before making anything.

## Files

| File | Part | Rev | Material |
|---|---|---|---|
| `linea_cage_R22.step` | One-piece camera cage, M4 cheese-plate grid | R22 | 6061, dark grey anodised |
| `linea_cheese_plate_R11.step` | Plate between cage and harmonic drive | R11 | 6061, dark grey anodised |
| `linea_motor_bracket_R13.step` | L bracket for the Beckhoff AM8111 (colour wheel motor) | R13 | 6061, dark grey anodised |
| `linea_color_wheel_R1.step` | 3-filter colour wheel (R/G/B), printed | R1 | PA6-CF |
| `linea_cage_plate_assembly.f3d` | Fusion export of the whole assembly (Fusion version 10) | — | — |
| `drawings/LINEA-CAGE_R22.pdf` | Machining drawing, cage | R22 | |
| `drawings/LINEA-PLATE_R9.pdf` | Machining drawing, plate | **R9** | |
| `drawings/LINEA-MOTORBRKT_R7.pdf` | Machining drawing, motor bracket | **R7** | |

All STEP files are exported in assembly coordinates: lens axis = Z through the
origin, colour-wheel motor axis at X = -82 mm.

The Fusion source lives in the Fusion project `CAMERAS / LINEA BRACKETS`,
document `linea_cage_plate_assembly`. The `.f3d` here is a snapshot; the motor
(AM8111) and the old wheel are linked documents in Fusion and may not be
embedded in the snapshot.

## Revision mismatch — read this

- The plate and bracket **drawings are R9 and R7**; the STEP files here are the
  later **R11 and R13**. The drawings do not describe the STEP files next to them.
- **Cheese plate R9 is the one that was ordered.**

## Key dimensions

- Cage: 109.1 x 109.1 x 36.2 mm, camera slot 97.30 mm (+0.05/0 after anodising), 5.9 mm walls.
- Colour wheel: filter centres 82 mm from the motor axis, 41.2 deg apart;
  seats Ø54.9 x 4 deep with Ø52 clear aperture (same snap fit as the earlier
  Piranha wheel); outer radius 118.5 mm; hub identical to the earlier wheel
  (Ø50 boss, Ø32.2 x 3 recess, 4 x Ø4.5 holes with Ø8 x 4 counterbores on a Ø23 circle).
- Optics in the assembly: Schneider Apo-Componon 4.5/90 on M90 tube -> M90/M72 adapter.

## Open issues

1. **Motor shaft clashes with the wheel hub** by 3.5 mm at the wheel's current
   axial position. The wheel has no centre bore, and the coupling part that sits
   in the Ø32.2 recess is not modelled.
2. **Clear (unfiltered) pass is blocked**: the wheel skirt overlaps the lens
   front by 4.6 mm, so the wheel cannot swing clear of the lens. Switching
   between the three filters is unaffected.
3. The UniFoc helicoid is a Ø76 placeholder and the filter thickness (3 mm) is a guess.
4. The plate locates on the drive only through the 16 x M3 clearance holes (about +/-0.2 mm).
