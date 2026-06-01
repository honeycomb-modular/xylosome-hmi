# HMI Box — Power Budget

Scope: everything inside the **HMI pendant box** — Raspberry Pi 5, WaveShare 5.5"
AMOLED display, Teensy 4.1, and the Grayhill encoder + buttons. Powered by a
**single PoE cable**. (Motion domain — ClearCore, Minas A6, servo, stepper — and
the capture PC are separate power domains, not covered here.)

---

## Bottom line

- Use **802.3at PoE+** (not plain 802.3af). Peak draw ~16 W exceeds the 12.95 W
  that PoE (af) guarantees at the device; PoE+ delivers **25.5 W**, leaving healthy
  headroom.
- Single CAT6 → **Pi 5 PoE+ HAT** (5 V / 5 A) → Pi powers the display + Teensy over
  USB; Teensy powers the encoder.
- One thing to get right: **enable full Pi 5 USB current** so the display isn't
  throttled (see caveats).

---

## Load table (5 V domain)

| Component | Typical | Peak | Notes |
|---|---:|---:|---|
| Raspberry Pi 5 (+ active cooler) | 4.0 W | 9.0 W | UI workload; the ~16 W figure is 4K-video/heavy-I/O, N/A here |
| WaveShare 5.5" AMOLED (HDMI + USB) | 3.0 W | 6.0 W | **estimate — verify vs datasheet.** AMOLED + near-black UI keeps this low |
| Teensy 4.1 | 0.5 W | 0.7 W | USB from Pi |
| Grayhill encoder + 2 buttons | 0.2 W | 0.3 W | 5 V from Teensy VIN |
| **Subtotal** | **7.7 W** | **16.0 W** | |
| Design target (peak + ~20% margin) | | **~19 W** | |

At 5 V, ~19 W ≈ **3.8 A** on the 5 V rail.

---

## PoE class choice

| Standard | Guaranteed at device | Verdict |
|---|---:|---|
| 802.3af (PoE) | 12.95 W | ✗ below the ~16 W peak |
| **802.3at (PoE+)** | **25.5 W** | ✓ ~19 W design fits, ~6 W headroom |
| 802.3bt (PoE++) | 51 W+ | overkill |

→ Specify an **802.3at PoE+** switch or injector (30 W at the source), and a
**Pi 5-compatible PoE+ HAT** rated for 5 V / 5 A (25 W). Note the Pi 5 moved its
PoE header vs the Pi 4 — use a HAT that fits the Pi 5.

---

## Power distribution

```
  PoE+ switch / injector (802.3at, 30 W)
        │  single CAT6 (data + power)
        ▼
  Pi 5 PoE+ HAT  ──►  5 V / 5 A (25 W) to the Pi
        │
        ├── Pi 5 board + active cooler
        ├── USB-A ─► AMOLED display (5 V)      ← ~1 A
        └── USB   ─► Teensy 4.1 (5 V)          ← ~0.1 A
                         └── VIN 5 V ─► Grayhill encoder + buttons
```

Single cable in; everything downstream of the HAT's 5 V rail.

---

## Caveats / things to get right

1. **Pi 5 USB current limit.** With a supply the Pi thinks is < 5 A, it caps *all*
   USB ports at 600 mA total — the display (~1 A) would brown out. The PoE+ HAT
   must present a 5 A-capable supply, and you may need `usb_max_current_enable=1`
   in `/boot/firmware/config.txt` (only safe because the HAT genuinely delivers
   5 A). Verify the display enumerates and stays stable.
2. **Offload option.** If USB headroom is tight, power the display from a dedicated
   5 V tap off the HAT (or a small 5 V buck on the PoE rail) instead of Pi USB —
   frees the Pi's USB budget and isolates display inrush.
3. **Verify the display figure.** The 3 W/6 W is an estimate; confirm against the
   WaveShare 5.5" AMOLED spec. The dark UI is a real advantage on AMOLED (black
   pixels ≈ off), so typical draw should sit at the low end.
4. **Inrush/peaks.** The Pi 5 has brief current spikes at boot/load; the PoE+
   headroom covers them, but confirm the chosen HAT is rated for Pi 5 transients.
5. **Idle/off draw.** A Pi 5 still pulls ~1.2–1.6 W even shut down — relevant only
   if the installation expects a true-off state.

---

*Figures: Pi 5 idle ~3 W / load ~9 W (raspberry.tips, CNX); PoE af 12.95 W vs PoE+
25.5 W at the device (Wikipedia/CBT Nuggets). Display value to be verified.*
