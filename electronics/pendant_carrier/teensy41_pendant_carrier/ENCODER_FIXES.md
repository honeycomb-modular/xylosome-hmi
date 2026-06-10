# Encoder fixes — three paths out of the dead-click

Companion to `ENCODER_DIAGNOSIS.md`. Applies **if** test T1 confirms marginal
analog levels at the dead detent (rest voltage between ~0.8 V and ~2.4 V on
ENC_A or ENC_B). Run T1 first — these fixes assume its result.

Premise (from the diagnosis): the carrier pulls the encoder's open-collector
outputs up to 3.3 V, but the 62AG's output levels are specified against a 10 k
pull-up to its own 5 V supply (low ≤ 1.0 V, high ≥ 3.0 V). The Teensy's 3.3 V
CMOS threshold (V_IL ≈ 0.99 V) sits exactly on the encoder's worst-case low.
A half-on phototransistor at one rest position per cycle parks the pin at an
indeterminate voltage → deterministic dead click → firmware rounds the
following double click down → "skips every 4th click."

---

## Fix 0 — firmware corrections (do these regardless, any path)

Correct per datasheet whichever fix is chosen; 2 lines in
`firmware/teensy_pendant/teensy_pendant.ino`:

```cpp
pinMode(PIN_ENC_A, INPUT);   // was INPUT_PULLUP — board already has 10k;
pinMode(PIN_ENC_B, INPUT);   // the internal pull-up RAISES marginal lows
static constexpr unsigned long SETTLE_MS = 45;  // was 15 — optics can take
                                                // 30 ms to finish an edge
```

These alone may *reduce* the symptom (weaker pull-up = lower marginal lows).
They will not fix a level that is genuinely mid-band. Re-run the 4-click test
after applying — record the result before moving on.

---

## Fix 1 — swap to the 3.3 V encoder variant (zero board changes)

**Part: `62VG22-H5-P`** — identical body, pinout, 2×3 .050" header, panel
cutout, detents and feel (H = high torque, 5 = 510 g pushbutton). The VG style
is the same encoder built for a 3.3 V supply: feed pin 6 with **3V3 instead of
5 V** and the carrier's 10 k-to-3V3 pull-ups become exactly the datasheet
circuit.

Wiring change: the J3 adapter cable's +5 V wire moves to a 3.3 V source.
Simplest: on the carrier, J3 pin 1 is fed from VIN — cut that trace or rework
the cable to pick up the Teensy 3V3 pin instead. (Rev C of the board should
make this a solder-jumper choice: VIN / 3V3 to J3-1.)

Honesty about margins: VG worst-case high is ≥ 2.0 V vs Teensy worst-case
V_IH ≈ 2.31 V — not bulletproof *on paper*, but it is the configuration
Grayhill sells for 3.3 V logic and typical units sit far from worst case.
Measure A/B at all four detent codes after the swap (same DMM drill as T1)
and keep the numbers in this file.

- Cost: one encoder (~$15–20), cable rework.
- Risk: low. Reversible. No board respin.

## Fix 2 — software Schmitt trigger on analog pins (zero new parts, do today)

The dead click exists because a *fixed digital threshold* meets an
*in-between voltage*. Read the voltage instead and apply hysteresis in
firmware — the information is present on the pin, just not where the digital
input commits.

- Two bodge wires: ENC_A node → **A0 (pin 14)**, ENC_B node → **A1 (pin 15)**.
  Pick the signals up at R1/R2 or the J3 pads; D4/D5 can stay connected
  (harmless in `INPUT` mode).
- Firmware: `analogRead` A0/A1 at a few kHz; software hysteresis, e.g.
  LOW when V < 1.2 V, HIGH when V > 2.0 V, hold state in between. Feed the
  resulting clean 2-bit code into the existing QTAB/landing decoder.
- Bonus: diagnostic mode logs the rest voltage at every detent — this IS the
  T1 measurement, automated, and documents whatever unit is fitted.

- Cost: zero parts, ~an afternoon of firmware.
- Risk: none to hardware. Slightly inelegant (bodge wires inside the pendant)
  but entirely serviceable as a permanent solution; the carrier is socketed
  and the wires are short.
- Could be made permanent in Rev C by simply routing ENC_A/B to
  analog-capable pins.

## Fix 3 — carrier Rev C: proper 5 V signal chain (the textbook fix)

Keep the 62AG at 5 V and give it the signal conditioning the loose spec
deserves:

```
encoder A/B (open collector)
   → 10 k pull-up to +5 V            (datasheet circuit, real swing restored)
   → LM393 dual comparator @ 5 V     (threshold ≈ 2.0 V from divider,
                                      ~±0.3 V hysteresis via feedback R)
   → LM393 open-collector output
   → 10 k pull-up to +3V3            (Teensy-safe clean edges)
   → Teensy D4 / D5
```

Margins after this: encoder low ≤ 1.0 V vs comparator threshold ~1.7 V;
encoder high ≥ 3.0 V vs ~2.3 V. Real numbers on both sides, plus hysteresis —
no rest position can sit on a knife edge.

Parts (JLCPCB-stocked, basic/extended): LM393 (SOIC-8), 6× 0805 resistors
(2 pull-up 5 V, divider pair, 2 feedback), 2× 0805 100 nF decoupling, plus the
existing R1/R2 repurposed as the 3V3-side pull-ups. Board stays 2-layer; same
outline; opportunity to also add the VIN/3V3 solder jumper for J3-1 (Fix 1)
and route A/B to analog-capable pins (Fix 2) so all three strategies stay
open on one board.

- Cost: small respin + parts pennies. You've fabbed this board before.
- Risk: lowest of all once built — this is the "next decade" version.

---

## Suggested order

1. **Fix 0** now (free, correct regardless) → re-test, record.
2. **Fix 2** to convert the hypothesis into logged voltages and get a working
   1:1 pendant immediately.
3. Then choose: **Fix 1** if the VG unit measures clean (tidiest), or
   **Fix 3** when the next board order goes out (most robust). Rev C should
   carry the solder-jumper + analog routing so the choice stays open.

## Record

| Step | Date | Result |
|---|---|---|
| Fix 0 applied + 4-click re-test | | |
| Fix 2 voltages (4 detents, A/B) | | |
| Fix 1 VG unit measured | | |
| Rev C ordered / verified | | |
