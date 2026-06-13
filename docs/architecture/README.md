# Architecture diagrams

Two parallel diagram sets live here. As of **2026-06-13**:

- **`xylosome_beckhoff.*` — CURRENT / ACTIVE.** The Beckhoff EtherCAT motion
  stack: C6920 (headless Linux, SOEM master, daemon `xylod`) → EtherCAT bus
  (EK1100 + EL terminals) → StepperOnline A6-EC servo (CiA-402 CSP). The Pi HMI
  is retained and talks to `xylod` over TCP. This is the stack that has run the
  real servo. See `BECKHOFF_PORT.md` and `beckhoff/README.md`.

- **`xylosome_architecture.*` — STALE / FALLBACK.** The original ClearCore
  design: Pi → ClearCore → Panasonic Minas A6 (pulse) + NEMA 17 stepper. Kept
  intentionally as a fallback in case the Beckhoff path doesn't pan out — **not
  deleted, not current.**

Don't mix the two. For anything motion-related, the Beckhoff diagram is the one
that reflects reality.
