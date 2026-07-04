# Capture PC — consolidated build note

**Status:** planning / parts-gathering. Nothing ordered yet.
**Goal:** one box that does *both* frame-grab acquisition **and** the Suite
(image processing), replacing the two-machine split, in a compact rugged
enclosure that suits the cart aesthetically.

## Decision log

- **Consolidate acquisition + Suite on one machine.** Reuse the on-hand
  **Ryzen 7** desktop CPU + its RAM + NVMe drives rather than buying a new IPC.
- **Both grabbers on one box.** Two Teledyne **Xtium-CL MX4** cards
  (full-height PCIe, ~x4 electrical each → 8 lanes total; the Ryzen supplies
  these easily, one from CPU + one from chipset).
- **Form factor: Micro-ATX.** Needed for two usable full-height PCIe slots;
  Mini-ITX (single slot) is out.
- **Case: Sliger CX3150a (3U, 15" deep).** SFX PSU, 8 full-height *vertical*
  PCIe slots, mATX board mounts in the ATX tray. Chosen over:
  - Advantech IPC-5120-30ZBE — functionally fine but ugly, wrong for the cart.
  - Sliger S630 desktop cube — great, but we chose rack instead.
  - 2U — rejected: can't stand two full-height grabbers in native slots
    (2U forces cards flat on a single riser).
- **Mount vertically on the cart.** CX3150a stood on end, **rack ears bolted
  to a vertical bracket/panel** (not just resting on end). Keep top/bottom
  vents clear.
- **Cooling: air, 65 W Ryzen route.** Low-profile / short tower cooler.
  Deliberately avoiding an AIO because vertical mounting imposes pump/radiator
  orientation rules (pump must not be the high point). If a 105 W X-class chip
  is used instead, run eco-mode or accept the AIO orientation constraint.
- **Storage: dual NVMe.** Drive A = raw capture (grabber writes only),
  Drive B = Suite tiles/pyramids. Separate drives so acquisition writes and
  processing I/O never contend. **All-NVMe → vertical mounting & vibration are
  non-issues** (skip the optional HDD bracket).
- **Operating model: concurrency now viable.** The on-hand CPU is a
  **Ryzen 7 9800X3D (8C/16T)** — with 16 threads you can pin ~2 cores to Sapera
  acquisition and leave the rest for the Suite, grabbing and processing at once.
  Temporal separation (grab, then process between shots) is now *optional*, not
  forced as it would be on the 4-core Nuvo.

## Parts list (to order)

| Item | Choice | Notes |
|------|--------|-------|
| Case | Sliger CX3150a (3U, 15") | vertical-mount, air-cool variant |
| Motherboard | **ASRock B850M Pro RS (mATX)** | native Ryzen 9000 support (no BIOS flash). PCIE1 Gen5 x16 + PCIE2 Gen4 x4 = one Xtium each. **Trap: M2_3 shares lanes with PCIE2 — leave M2_3 EMPTY or grabber #2 slot dies.** |
| CPU | on-hand **Ryzen 7 9800X3D** | AM5, Zen5, 8C/16T, ~120 W (162 W peak) |
| RAM | on-hand DDR5 | |
| PSU | SFX, 450 W, quality | 9800X3D + 2× ~10 W grabbers |
| CPU cooler | **Noctua NH-L12S (70 mm) + eco mode** | run 105 W or 65 W PPT so a low-profile air cooler suffices in vertical 3U. Full-power 9800X3D → CX4150a (4U) + tower, or AIO w/ pump-orientation care. |
| Storage | 2× NVMe: **M2_1 = OS+Suite, M2_2 = raw capture** | M2_3 stays empty (see board trap) |
| Grabbers | 2× Xtium-CL MX4 | full-height, native vertical slots (PCIE1 + PCIE2) |
| Mounting | rack ears → vertical bracket on cart | secure against cart bumps |

## Open items

- ~~Confirm socket~~ → **AM5, Ryzen 7 9800X3D** (settled).
- ~~Pick mATX board~~ → **ASRock B850M Pro RS** (settled). On install, verify
  PCIE1/PCIE2 have an empty slot between them for grabber airflow.
- Confirm **CX3150a air-cooler height clearance** for the NH-L12S (3U is tight)
  — if it won't fit, low-profile + deeper eco mode, or step to CX4150a (4U).
- Set CPU **eco mode (105 W or 65 W PPT)** in BIOS for the low-profile-air build.
- Xtium I/O: cable is **DH40-27S** plug (OR-YXCC-27BE2M1) → board J1
  (DH60-27P). See `docs/grabber_io_wiring.md`.
