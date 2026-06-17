# Cart electrical safety — floating system + insulation monitoring

**Status: design (2026-06-13), not yet built. Must be validated by a qualified
electrician before use — this is life-safety.**

## The problem

The Xylosome cart is an **aluminum frame on rubber wheels** — it moves around
constantly, like a vehicle, so we cannot rely on a permanent earth-rod/strap
connection, and the rubber wheels mean the frame does **not** drain to ground on
its own. If a live conductor ever faults onto the frame, the frame floats at that
voltage and waits for a person to become the path to ground. We need automatic
shock protection that **travels with the cart and does not depend on the quality
of the field outlet's earth.**

## ⚠️ Frame bonding on the 4040 cart — the anodize trap

The cart is an **open 4040 aluminum-extrusion frame** (DIN rails screwed straight to
the chassis, open on all sides). Two consequences:

- **Anodized aluminum is an electrical INSULATOR.** The extrusion surface is Al₂O₃,
  and T-slot joints are mechanical, not electrical — so **the frame is NOT one
  continuous conductor.** Different sections (and the DIN rails bolted to them) can
  sit at different potentials. This silently defeats "bond the frame": a fault could
  energize a section that the PE never actually reached.
- **Open on all sides = touch hazard.** People can reach live terminals, so all
  mains/240 V terminals must be **finger-safe / shrouded**, ideally with a clip-on
  cover over the live bits.

**Do this — build a deliberate bonding star, don't trust the structure:**
- Run a **green PE conductor from every DIN rail, every metal enclosure, and every
  major frame section** back to the central **PE bar**.
- Use **anodize-piercing hardware** at the bond points — serrated/paint-piercing
  washers or **grounding T-nuts** (8020/Misumi) — for a gas-tight metal-to-metal bite.
- **Verify with a meter:** < ~0.1 Ω from the PE bar to *every* spot a hand can reach.
  Anywhere reading open is an unbonded island — fix it.

EMC note (open frame = no shielding): rely on **physical separation + shielded
cables**; keep the drive/motor/240 V region away from EtherCAT/signal (use the
front/back faces of the 4040 to separate). Panel area ≈ 30" × 24" — roomy.
Layout: see `docs/panel_layout.svg`.

## Tier 1 — the cheap, standard solution (do this first, ~$30)

This is how every metal-cased appliance/tool is protected. It's enough for a safe cart.

1. **Bond the aluminum frame to the power-cord's protective-earth (PE) pin** — one
   internal wire, permanent (~$5 in lugs). Earth then arrives automatically through
   the 3-prong plug every time you plug in. **No earth rod, no per-move routine.**
2. **GFCI on the 120 V inlet — ORDERED 2026-06-13: DIN-rail 2-pole GFCI breaker**
   ("Lightning Protection Ground Fault Circuit Breaker"). Confirmed specs:
   **IEC 61009-1 RCBO** (real RCD + overcurrent), 120/240 V AC, **Type C (5–7×)**
   curve, **6 kA** breaking, **20 kA 8/20 µs surge** (SPD), 35 mm DIN.
   Wire **L + N on the 120 V inlet** — bundles GFCI + overcurrent + surge in one rail unit.
   - **Wire-up notes for later:** L+N through the breaker; **bond the frame to its
     earth/PE terminal** (without the bond it only trips reactively on touch); hit
     the **TEST** button after install and periodically.
   - **CHECK ON ARRIVAL — the one spec not on the sheet: residual-current trip
     `IΔn` (mA) + RCD type.** Want **≤ 30 mA (ideally 10 mA)**, **Type A**. If it's a
     100/300 mA unit it's equipment-only, not personnel-grade — measure/confirm.
   - Picked current rating should be **16–20 A** (matches the cord; 40 A would not
     protect the wiring). It's **CE, not UL** — acceptable, known trade.
3. **Leave the 240 V transformer secondary floating** — a single fault to the frame
   then draws no shock current (first fault harmless, "car-like"), free, no device.

Total ≈ $30. The Tier-2 insulation monitor below is an **optional upgrade** that
only adds *detection* of that first floating-side fault — nice-to-have, not required.

## Tier 2 (optional) — make it safe like a car/boat/EV (float + monitor)

Rather than depend on earthing, we isolate the hazardous section and monitor it:

1. **The only real shock hazards are the 120 V inlet and the 240 V servo section.**
   Everything else on the cart is **SELV** (24 V Mean Well rail, 48 V PoE) — below
   the shock threshold, inherently safe.
2. **The 240 V servo runs on the *floating* secondary of the isolation transformer**
   (Phoenix CPT, already in the design). A floating ("IT") system draws no shock
   current on a *single* insulation fault — first fault is harmless, exactly like
   touching a car body.
3. **An Insulation Monitoring Device (IMD)** watches the insulation between the
   240 V conductors and the bonded frame and **trips on the first fault**, before a
   dangerous second fault can stack up. The IMD references the **frame itself**, not
   building earth — so it protects with no earth connection. This is how boats, EVs
   and operating rooms stay safe ungrounded.
4. **A portable Class-A GFCI at the cord** protects the 120 V section and gives
   reactive person-protection regardless of the outlet's earth.
5. **Equipotential bonding** ties the frame and every metal enclosure into one mass,
   so there are never two different potentials a hand could bridge.

## Layered protection

```
 field 120 V outlet
      │
 [Portable Class-A GFCI]  ← travels with the cart; trips at 4–6 mA on leakage
      │                     or person contact, even with a marginal outlet earth
 cart 120 V inlet ───┬──► 24 V PSU (Mean Well EDR-120-24)  → SELV loads (safe)
                     │
                     └──► Phoenix CPT isolation transformer (primary)
                                  │  (galvanic isolation)
                          240 V *floating* secondary (IT system)
                                  │
                     ┌────────────┴──── A6-EC servo drive
                     │
              [Bender ISOMETER IMD]  ← monitors 240 V-to-frame insulation;
                     │                  relay trips on first fault
                     └──► drops the MAIN CONTACTOR (shared with the E-stop chain)
                          → de-energizes the transformer primary / 240 V section

 FRAME + every enclosure ──── equipotential bond bus ──── (cord PE when present)
```

### What each layer protects

- **Portable GFCI (120 V):** the primary side + the 24 V PSU input; trips if a
  person bridges a live 120 V part to a real ground. Standard OSHA jobsite-portable
  protection; rides with the cart.
- **IMD (240 V floating):** the servo/drive section. Detects a live-to-frame
  insulation fault and trips **without needing earth** — the earth-independent,
  "car-like" core of the design.
- **Equipotential bond:** ensures the frame, drive case, transformer case, PSU
  cases are all one potential — no internal step a person can cross.

### Residual risk (stated honestly)

If a **120 V primary** conductor faults to the frame **and** the field outlet's
earth pin is open (no return path), the frame can sit at 120 V until someone
touches it — at which point the GFCI trips on their body current. The frame is
energized beforehand, reactively cleared. This is the standard accepted level for
portable 120 V equipment; eliminating it entirely would require isolating the
120 V inlet too (a second transformer) — overkill for this cart. The dominant
hazard (240 V servo) is fully covered by the float + IMD.

## Bill of materials (candidates — confirm with electrician)

| Item | Candidate part | Notes |
|---|---|---|
| Insulation monitor (IMD) | **Bender ISOMETER `IR425-D4-1`** | **ONLINE/continuous** monitor — AC/DC IT systems, **0–300 V** (covers 240 V), DIN-rail, relay output. Control supply 9.6–94 VDC → **power it from the 24 V rail**. Online alternatives: `IRDH275B`, `iso685`. |

> ⚠️ **Two Bender model traps when shopping the surplus market:**
> 1. **`IR420-D6` is OFFLINE** ("de-energized loads") — must be disconnected while
>    the system is live. Useless for protecting the running servo. Reject it.
> 2. **`IR420-D4` is online but AC-ONLY.** Because the servo drive ties a DC bus
>    to the monitored AC system, an AC-only ISOMETER can under-read DC fault
>    components (same reason a drive needs a **Type B** RCD, not Type A). Prefer
>    the **AC/DC** `IR425-D4-1`. The `IR420-D4-1` is acceptable-but-compromised;
>    a pure-AC isolated system would be fine, a drive ideally wants AC/DC.
>
> Listing tells: "offline / de-energized" = reject; "AC-only" = compromised with a
> drive; "continuous, AC/DC, energized IT systems" = correct.
| Portable GFCI (120 V) | **Leviton `GCA20`** (20 A) or Hubbell inline 15 A | Class-A (4–6 mA), in-line user-attachable plug. Put it at the cord cap. |
| Main contactor | (size to transformer primary inrush) | Coil dropped by IMD relay **and** the E-stop chain. |
| Bonding | PE stud + star washers + anti-oxidant | Aluminum oxide is insulating — needs a gas-tight, scratch-through bond on every panel. |

### Wiring / config notes

- IMD connects to **L1 + L2 of the 240 V IT system** and to the **frame (PE/KE
  terminal)**; it injects a tiny measuring signal and reads insulation resistance.
  Set R/Z mode and threshold so the drive's EMC-filter Y-capacitor leakage doesn't
  read as a fault.
- Wire the **IMD trip relay in series with the E-stop chain** so both drop the same
  main contactor — one shutdown path (ties into the open "E-stop chain" backlog item).
- Bond the frame to the **cord PE** as well: free, real earth whenever a good outlet
  is present (belt-and-suspenders), no per-move routine — it's a one-time internal wire.

## Why this matches "moves like a car"

No earth rod, no per-move grounding ritual. The frame bond is internal and
permanent; earth arrives through the plug automatically when available; and the
240 V hazard is protected by isolation + insulation monitoring referenced to the
frame, so it's safe even with no earth at all.

> ⚠️ Not designed or validated by a licensed electrician. Have a qualified person
> verify the IMD/GFCI selection, the floating-secondary scheme, contactor sizing,
> and bonding against local code before energizing.
