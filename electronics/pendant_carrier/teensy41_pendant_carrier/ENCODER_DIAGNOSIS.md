# Encoder "skips every 4th click" — re-diagnosis (2026-06-10)

Re-opens the verdict in WIRING.md ("hardware characteristic — DO NOT
re-troubleshoot"). That diagnosis verified the **digital** domain (wiring,
shorts, ground, DRC, two boards, two encoders) and then concluded — without
ever measuring the **analog** domain. The datasheet gives three numbers that
point at a systematic design-level cause the prior session never tested.

## 1. What the symptom actually is — three layers

1. **What the artist feels:** every 4th click does nothing.
2. **What the firmware does:** that is a *deliberate choice* (commit d7ec8ec).
   The raw pattern is `clean(+1) clean(+1) DEAD(0) DOUBLE(+2)`; the firmware
   caps the double to one step, so the dead click stays a no-op. 3 moves / 4
   clicks, by design, given the raw pattern.
3. **The real question:** why does the raw pattern exist at all? Per the
   datasheet truth table these encoders change **exactly one bit per detent**
   ("code repeats every four positions"). A correct unit cannot produce a dead
   click. Something makes one state boundary per cycle land *past* its detent.

Downstream is innocent: PendantReader maps JOG→key 1:1; QML consumes 1:1.

## 2. The three datasheet numbers (62AG/VG, Rev 02/2024 — the WIRING.md rev)

| Datasheet says | Our design does | Consequence |
|---|---|---|
| AG style: logic LOW guaranteed only **≤ 1.0 V**, logic HIGH only **≥ 3.0 V** — specified with the required 10 k pull-up to the **5 V** supply | Carrier pulls up to **3.3 V** (for Teensy GPIO safety); firmware *additionally* enables the internal pull-up (~30 k) in parallel, strengthening the pull-up and **raising** any marginal low | Teensy (3.3 V CMOS) thresholds: V_IL ≈ **0.99 V**, V_IH ≈ **2.31 V**. The encoder's guaranteed low (1.0 V) sits **exactly on** the Teensy's V_IL. Zero margin by spec; negative margin for a weak unit. A phototransistor that is only partially on at one specific rest position parks the pin at an indeterminate 1–2 V → that detent reads as *unchanged* = **deterministic DEAD click**, and the boundary is crossed during the next click = **DOUBLE**. |
| **Optical rise/fall time: 30 ms maximum** (phototransistor + light pipe — these are slow parts) | Firmware `SETTLE_MS = 15` declares "landed on detent" after 15 ms of quiet | The landing detector can fire **mid-edge** on a slow transition, splitting one click's count across two landings. Secondary contributor; trivially fixed (raise to ~45 ms). |
| Supply: **5.00 ± 0.25 V** (i.e. ≥ 4.75 V) | Encoder fed from Teensy VIN = Pi USB 5 V minus cable/connector drops | If the rail is < 4.75 V, LED drive falls, photo-current falls, V_OL rises — pushing marginal levels further into the dead zone. Never measured. |

**Why this fits "identical on two encoders and two boards":** a *systematic*
level-budget violation produces the same failure on every conforming unit.
The prior verdict ("mechanical detent/code misalignment inside the part")
required two different Grayhill series to share the same internal defect —
possible, but the level-margin explanation requires nothing unusual at all.

## 3. Discriminating tests — in order, cheapest first

The beauty of a *deterministic* dead detent: it sits still for a multimeter.

**T1 — DMM on the A and B pins at rest (15 min, settles it).**
Find a dead click (turn slowly, watch JOG output or UI). Then measure
ENC_A (Teensy D4) and ENC_B (D5) to GND at each of 4 consecutive detents,
including the dead one.
- All readings < 0.5 V or > 2.8 V → levels are clean → level hypothesis
  **dead**, internal-alignment verdict stands, skip to §5 options c/d.
- Any reading between **0.8 V and 2.4 V** at the dead detent → smoking gun:
  marginal analog level, the Teensy is guessing. Proceed T2–T4.

**T2 — DMM on the +5 V at the encoder (1 min).**
J3 pin 1 to GND, system running. ≥ 4.75 V = in spec. < 4.75 V = out of spec,
contributes to T1's marginal level.

**T3 — firmware micro-fixes (2 lines, 5 min, safe regardless).**
`pinMode(PIN_ENC_A/B, INPUT)` (board already has the 10 k — the internal
pull-up actively hurts) and `SETTLE_MS = 45`. Re-test the 4-click pattern.

**T4 — bench supply (10 min).**
Power the encoder from a clean 5.00 V (common ground), repeat T1/the click
test. Pattern gone → supply path confirmed as cause or contributor.

## 4. Likely verdict (to be confirmed by T1, not assumed)

The error most plausibly lies in the **carrier board's level architecture** —
the "pull the open collector up to 3.3 V to skip a level shifter" decision —
*interacting with* the encoder's very loose value-line output spec. Not the
wiring (verified), not the Teensy code as such (it faithfully decodes what it
sees, then deliberately rounds the damage off), not necessarily the encoder
(it may be entirely within its own loose spec).

## 5. Fix paths, depending on T1

a) **Marginal levels confirmed — clean fix: swap to the VG style.**
   `62VG22-H5-P` = same body, same cutout, same pinout, **native 3.3 V**:
   pull-up to 3.3 V is then exactly the datasheet circuit, V_OH ≥ 2.0 V /
   V_OL ≤ 1.0 V specified *for 3.3 V logic*… note V_OL ≤ 1.0 V is still on
   the Teensy V_IL edge — check T1 voltages on the actual part; combine with
   (b) if needed.
b) **Marginal levels confirmed — keep the AG: restore the 5 V domain.**
   Pull A/B up to 5 V (as the datasheet circuit shows) and add a proper
   threshold: dual comparator or Schmitt buffer powered at 5 V (thresholds
   ~1.5/2.5 V fit the AG spec with margin), then divide down to 3.3 V for the
   Teensy. Small board rev or a piggyback. JLCPCB-stockable parts only
   (e.g. LMV393/74HC14-class).
c) **Levels clean, pattern persists at 5.00 V bench supply** → the internal
   alignment verdict was right after all; software cannot recover a click
   that emits no signal. Options: different encoder family with tight
   phasing (mechanical EC11 fits electrically but not the enclosure cutout —
   would need a panel adapter), or live with feel-first decode.
d) Either way: keep T3's firmware corrections — they are right per datasheet
   regardless of outcome.

## 6. Status

- [ ] T1 voltages: A: ____ ____ ____ ____  B: ____ ____ ____ ____ (4 detents, mark the dead one)
- [ ] T2 supply at encoder: ____ V
- [ ] T3 applied + pattern re-test: ____
- [ ] T4 bench 5.00 V: ____
- [ ] Verdict + chosen fix: ____
