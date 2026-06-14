# XYLOSOME — Project Overview (single source of truth)

**This is the canonical orientation document for the whole Xylosome system.**
If you are a human on a new machine, or an AI model starting cold, **read this
first** — it ties together the motion stack, the imaging chain, the HMI, the
review suite, the hardware, and the cross-machine workflow, and points at the
deeper docs for each.

- **Last updated:** 2026-06-13
- **Repo:** `github.com/honeycomb-modular/xylosome-hmi` (GitHub is the source of
  truth — see [Working across machines](#working-across-machines))
- **Keep this current:** when a subsystem's status changes materially, update
  the relevant section here *and* its detailed doc. This file is the map; the
  linked docs are the territory.

---

## 1. What Xylosome is

A custom motion-controlled **color line-scan camera** built as an artistic
instrument. A BW line-scan camera makes **four sequential passes** through
different color filters (R / G / B / C); the four BW scans are composited into
one color image in post (Photoshop). **Subject motion between passes creates
color fringing — this is the intended artwork, not a defect.** The artist draws
a speed curve on the pendant; what is drawn is what the motion executes (WYSIWYG).

The system has **three computers** on the cart, plus the pendant:

1. **Pi HMI** — Qt6/QML touchscreen + pendant; the artist's control surface.
2. **C6920 (Beckhoff IPC)** — headless Linux motion controller running `xylod`.
3. **Capture PC** — hosts the frame grabber (Sapera/CamExpert); owns raw images.
4. **Review Suite** — desktop app on the cart's review computer; shows/judges/keeps.

---

## 2. System architecture (current)

> ⚠️ **The motion stack moved from ClearCore to Beckhoff EtherCAT (2026-06).**
> The **Beckhoff path is ACTIVE**; the **ClearCore path is STALE but retained as
> a deliberate fallback** (kept, not deleted). Anything describing ClearCore as
> the live controller is legacy design.

```
                 ┌─────────────── Pi HMI (Qt6/QML, touchscreen) ───────────────┐
                 │  draws speed curve · trigger · metadata SVG (MetadataRecorder)│
                 │  BeckhoffLink: QTcpSocket JSON-lines client                   │
                 └───────────────┬───────────────────────────────────────────────┘
   Teensy 4.1 pendant            │ TCP :5510  (newline-JSON, broadcast)
   (Grayhill encoder + buttons)  │
        USB ──► Pi               ▼
                        ┌──────────────────── C6920 (headless Linux) ───────────┐
                        │  xylod = SOEM EtherCAT master + 4-pass Sequencer       │
                        │  EcBackend (real) / SimBackend (--sim)                 │
                        └───────────────┬───────────────────────────────────────┘
                                        │ EtherCAT (NIC enp4s0, 1 kHz, DC SYNC0)
              EK1100(1) ─ EL1008(2) ─ EL2008(3) ─ EL7047(4) ─ A6-EC servo(5)
                                        │                         │
                          EL2521 line-trigger (planned)     scan axis → Harmonic 50:1 → output flange
                                        │
                                        ▼  EXSYNC (via grabber)
   Piranha HS line-scan camera ◄── Camera Link ── Xcelera-CL PX4 grabber ── Capture PC (Sapera)
                                                                              │ writes TIFFs → SMB share
                                                                              ▼
                                                              Review Suite (watches share, pairs ↔ passes)
```

The Review Suite and the Capture PC are also `xylod` TCP clients on `:5510` —
they receive `pass_start/pass_end/seq_done/status` for free (session sync by
design).

---

## 3. Subsystem status

### 3.1 Motion stack — Beckhoff / `xylod`  ✅ real servo has run

- **Controller:** Beckhoff **C6920** (Celeron 2000E, 2C/2T, fanless, 24 VDC),
  headless Linux, **SOEM** userspace EtherCAT master. Bind SOEM to the **i210**
  NIC (`enp4s0` on the bench). PREEMPT_RT kernel is still an open item for
  smoothest CSP.
- **Daemon `xylod`** (`beckhoff/xylod/`): layered as `IBackend` (contract) →
  `EcBackend` (real SOEM) / `SimBackend` (`--sim`, no hardware), a 4-pass
  `Sequencer` running inside the 1 kHz cyclic callback, `Cia402` DS402 helper,
  and a `TcpServer` (newline-JSON, port 5510). Wire protocol: `beckhoff/PROTOCOL.md`.
- **Drive:** StepperOnline **A6-EC** servo (enumerates as **"ANCTL AS715N"**,
  slave 5). CiA-402 **CSP** mode. 220 V single-phase on **L1+L2**. Manual:
  `beckhoff/docs/A6-EC_series_servo_drive_manual.pdf`.
- **Milestone (2026-06-12): the artist's speed curve ran on the real servo over
  EtherCAT, triggered from the pendant.** Harmonic **50:1** confirmed fitted;
  `gear_ratio=50` in `xylod.conf` (HMI degrees = output-flange degrees).
- **The Er74.1 "no sync" recipe** (now in `EcBackend`): master-started SYNC0
  (`ec_dcsync0`), drive panel **C13.05 = 2**, explicit `0x1C32/0x1C33` config,
  all in **PRE-OP before** `ec_config_map`, plus a gap-free phase-locked cyclic
  thread (SCHED_FIFO + mlockall), wake-zero for the multiturn encoder. PDO remap
  is legal only in PRE-OP and does **not** survive power-off — reconfigure every run.
- **Bench bus order (per `ec_scan`):** `EK1100(1) · EL1008(2) · EL2008(3) ·
  EL7047(4) · A6-EC(5)`. EL2008 carries `pass_active`/`pass_index`.
- **Auto-start:** `xylod` runs REAL as an enabled **systemd service**
  (`/etc/systemd/system/xylod.service` → `/usr/local/bin/xylod --config
  /etc/xylod.conf`), verified `sim:false` / `op:true` on boot (2026-06-13). The
  sim is opt-in via a `sim.conf` drop-in. See `SESSION_NOTES.md` — including the
  "won't turn from the Pi" gotcha (a `--sim` drop-in had it booting the
  simulator, which fakes a healthy status). Update the installed binary after
  code changes: `sudo cmake --install . && sudo systemctl restart xylod`.
- **Open / before garage:** wire the **E-stop chain** (din currently off),
  **EL7047 filter-wheel adaptation** + `xylod.conf` rewrite, **line-trigger
  terminal** (EL2521), PREEMPT_RT, and a C13.04 jitter audit after long runs.
- **Permanent absolute home (decided 2026-06-13, not built):** no switch / no
  hard stop — use the **multi-turn absolute encoder + battery + stored home
  offset**, replacing `xylod`'s wake-zero. Battery encoder cable **ordered**
  (StepperOnline `AS7-C-ENC076-BAT-3.0`); then set `C00.07` multi-turn mode,
  clear the first-connect `Er208`, teach the offset once. Full plan in
  `SESSION_NOTES.md`.
- **Fallback:** the original ClearCore + Panasonic Minas A6 (pulse) path —
  `firmware/clearcore/`, ClearCore-era HMI code — is intact and untouched.
- **Detail docs:** `BECKHOFF_PORT.md`, `beckhoff/README.md`, `beckhoff/PROTOCOL.md`.

### 3.2 Imaging chain — camera / grabber / sync  ✅ specs verified 2026-06-13

- **Camera:** Teledyne DALSA **Piranha HS-80-08K80-00-R** — 8192 × **96 TDI**,
  7 µm pixels, 8/12-bit, line rate **34 / 68 kHz**, **Camera Link** (MDR26).
  Line trigger = **EXSYNC**, enabled over serial, **falling-edge** readout.
  ("HS" = High Sensitivity / TDI — *not* Camera Link HS. That naming trap is why
  the old diagram wrongly said "CLHS".)
- **Frame grabber:** **OR-X4C0-XPF00** = Teledyne DALSA **X64 Xcelera-CL PX4**
  (Camera Link, PCIe x4; also labelled **"Aquarius CL"** under the same OR-
  code). Camera Link ↔ Camera Link — matched.
- **Sync model:** the **grabber generates EXSYNC** to the camera over the Camera
  Link control line (the camera is not triggered directly). The grabber's
  external I/O is on connector **J4** — balanced **Trigger-In** (Trigger In 1 =
  J4 pin 11 +, pin 12 −) and **shaft-encoder** inputs.
- **Breakout (arriving ~within a week):** lands the grabber's J4 pins so the
  sync wires can be terminated. Two ways to pace the line trigger:
  1. **EL2521 pulse → J4 Trigger-In → grabber → EXSYNC → camera** (rate follows
     the speed curve; matches `line.mode == "curve"`).
  2. **Quadrature encoder → J4 shaft-encoder inputs** → grabber EXSYNC is
     position-locked — the robust path for clean 96-stage TDI (line rate must
     track velocity or the image smears past the *intentional* fringing). This
     is the encoder-lock open item.
- **`line_max_hz`** in `xylod.conf` is a placeholder **20 kHz**; real camera
  ceiling is **up to 68 kHz** (mode-dependent). Set the working value from
  **CamExpert** for the chosen exposure/TDI — don't assume.
- **Still open:** exact full J4 pinout (pull from the Xcelera-CL PX4 manual when
  the breakout is in hand); scan **bit depth + typical dimensions** (read a real
  TIFF header — sets the 4 GB layered-TIFF vs PSB export question).
- **Detail doc:** `docs/camera_capture_note.md` (who owns which setting; the Pi
  and Beckhoff never talk to the camera — the only meeting point is the EL2521
  trigger wire into the grabber).

### 3.3 Pi HMI  ✅ working on Pi 4

- Qt6/QML, the artist's control surface: draggable-box curve editor (aspect →
  duration, curve → speed ramp), trigger, settings pages navigated by the Teensy
  dial/buttons. **Design language:** dark technical instrument — monospace,
  minimal, R/G/B/C the only color.
- **`BeckhoffLink`** (QML singleton `Beckhoff`): QTcpSocket JSON-lines client,
  auto-reconnect, mirrors `xylod` status, relays events. When no controller is
  reachable it falls back to the local playhead simulation (byte-for-byte the
  old behavior).
- **Metadata Infuser** (done on Pi 4): `MetadataRecorder` C++ singleton records
  per-pass timing (R/G/B/C, t_start/t_end/duration) + the drawn curve and
  exports one **SVG per session** for Photoshop compositing. Pass timing now
  comes from real `xylod` events via `BeckhoffLink`.
- **Active dev target: Pi 4 @ `192.168.10.2`** (EGLFS, TigerVNC, `make`). Pi 5
  is the final pendant (Wayland/labwc, `ninja`) — **do not conflate the two**.
- **Detail docs:** `pi/hmi/METADATA_INFUSER.md`, `SESSION_NOTES.md`,
  `docs/concept/xylosome_ui_concept.docx`.

### 3.4 Review Suite  ✅ phases 0–3, CI green (Windows ingest open)

- The cart's third system: *HMI triggers → xylod scans → **suite shows, judges,
  keeps***. Cross-platform (Windows 11 primary, macOS/Linux). Lives in `suite/`.
- Another `xylod` TCP client (`client:"suite"`). Watches the **SMB capture
  share**, pairs files↔passes by the `tMs` window (capture writes temp name →
  renames, so no half-written ingest). One **libvips `dzsave`** pass per TIFF →
  JPEG tile pyramid + ≤2048 px preview + 16-bit histogram/clip stats in a single
  streamed read. State is **sidecar JSON** (`schema:1`, UUID sessions); **no Save
  command** (write-through); TIFFs are read-only. `XylodLink` is a port of the
  HMI's `BeckhoffLink`.
- **Status:** phases 0–3 built and live against `fake_xylod` / `xylod --sim`, CI
  green on all three OSes — sessions filmstrip, pairing, ingest, deep-zoom to
  1:1, channel solo (R/G/B/C), stars/reject sidecars, crash-safe re-ingest.
- **The one open wound:** Windows `libvips` — MSVC ⇄ MinGW-libvips link dies at
  `LNK1181: intl.lib`; the Windows CI artifact is **judging-only** until the job
  moves to **msys2 UCRT64** (qt6 + libvips native). This is the recommended fix
  and is doable with no hardware.
- **Next:** msys2 Windows ingest → Phase 4 (library grid⇄timeline, notes,
  quarantine→permanent delete + disk gauge, incomplete-session salvage) → 4b
  importer (backfill old TIFF archives) → layered-TIFF export (5) → capture
  agent (6) → compare/offload/recall-to-pendant (7).
- **Detail docs:** `docs/concept/review_suite_plan.md`, `suite/README.md`,
  `suite/NEXT_SESSION.md`.

### 3.5 Pendant & electronics

- **Teensy 4.1** reads the **Grayhill 61C11-01-08-02** rotary encoder (push) +
  hard buttons; talks to the Pi over USB. Full UI navigation = 2 buttons + dial.
- Custom **Teensy 4.1 pendant carrier PCB** (KiCad, **JLCPCB** fab) in
  `electronics/pendant_carrier/teensy41_pendant_carrier/`. See its `README.md`,
  `WIRING.md`, and `ENCODER_DIAGNOSIS.md`/`ENCODER_FIXES.md`.
- **PCB rule:** all PCB designs use only parts available on **JLCPCB**.

---

## 4. Hardware inventory (key part numbers)

| Item | Part | Notes |
|---|---|---|
| Motion controller | Beckhoff **C6920-1107-0050** (CB3060-0007) | Celeron 2000E, dual Intel NIC (i210/i218), 24 VDC, fanless |
| Servo drive | StepperOnline **A6-EC** ("ANCTL AS715N") | EtherCAT CiA-402 CSP; 220 V on L1+L2 |
| Gearbox | Harmonic Drive, **50:1** (several on hand) | CSF-14-80 family; exact model **undecided / not load-bearing** (8 mm WG bore measured) |
| EtherCAT coupler | Beckhoff **EK1100** | E-bus head station |
| Digital in | Beckhoff **EL1008** | E-stop / endstops (not yet wired) |
| Digital out | Beckhoff **EL2008** | `pass_active` / `pass_index` |
| Stepper terminal | Beckhoff **EL7047** | drives the filter-actuator stepper |
| Line trigger (planned) | Beckhoff **EL2521** | pulse → grabber J4 trigger-in |
| Filter test motor | **Hanpose 20HT24-T5×1** (NEMA 8 linear) | tested; ~10 rev/s ceiling. Filter-wheel redesign in progress (3 filters behind lens, future) |
| Camera | Teledyne DALSA **Piranha HS-80-08K80-00-R** | 8192×96 TDI, Camera Link, EXSYNC falling-edge |
| Frame grabber | Teledyne DALSA **OR-X4C0-XPF00** = Xcelera-CL PX4 ("Aquarius CL") | Camera Link, PCIe x4; J4 trigger/encoder I/O |
| Grabber breakout | (arriving ~1 week) | lands J4 pins for sync wiring |
| Pendant MCU | **Teensy 4.1** + Grayhill **61C11-01-08-02** | on custom JLCPCB carrier |
| HMI computer | Raspberry **Pi 4** (dev) / **Pi 5** (final) | PoE; touchscreen |
| **Incoming** | several more **Beckhoff EtherCAT modules** (within days) | slot into `xylod.conf` positions + EcBackend on arrival |

**Beckhoff family rule:** K-bus (BK/KL) and E-bus (EK/EL) never mix — "K goes
with K, E goes with E." The old BK9050 + KL4404 + KL9010 Modbus-TCP brick is a
separate island (auxiliary analog out), not part of the EtherCAT motion chain.

---

## 5. Power & field setup

- **Field constraint: only 120 V is fed to the cart.** The A6-EC servo needs
  **240 V**, so a **120 V → 240 V step-up** transformer powers only the drive.
- **Transformer: Phoenix Contact `CPT-480-220/120-110/500`** (500 VA, DIN-rail),
  **reverse-fed** (120 V into the 120 V winding, 240 V off the 220/240 winding —
  it is an isolation transformer, runs either direction). **Ordered.** Fuse the
  120 V input ~5–6 A time-delay; expect ~230 V loaded (fine for the 200 V-class
  drive's ~170–264 V window).
- Bench 24 V (C6920 + EtherCAT Us/Up rail + stepper) from a **Mean Well
  EDR-120-24** (24 V/5 A).
- **EL7047 has two supplies:** motor current on terminal points 3'/7', and drive
  *control power* via the EK1100 +/− power-contact rail — feed the rail or you
  get `0xA010:08` "no control power".

---

## 6. Working across machines

> **GitHub is the single source of truth — not iCloud.** Full rules in
> `WORKFLOW.md`. Read it before moving code between machines or to a Pi.

- Hoyte works from a **portable Mac** (away-from-bench) and a **Windows garage
  PC** (at the bench). Both have historically pointed at the same iCloud folder,
  but **iCloud is unreliable for a live git repo** — clone from GitHub instead.
- **Every machine and Pi gets code by cloning/pulling from
  `github.com/honeycomb-modular/xylosome-hmi`.** `git pull` before, `git commit`
  + `git push` after, every session.
- **An AI session can read/edit/commit files but CANNOT authenticate a push** —
  it hands the push to whichever machine Hoyte is on (terminal, or GitHub
  Desktop → Push origin). Verify a push landed via a **raw** URL (not the
  HTML-cached repo page), e.g.
  `raw.githubusercontent.com/honeycomb-modular/xylosome-hmi/main/<file>`.
- **Two Pi targets, never mix:** Pi 4 dev @ `192.168.10.2` (EGLFS, make);
  Pi 5 final @ `192.168.2.2` (also `192.168.10.3` on the garage wired link;
  Wayland/labwc, ninja).
- **C6920 (Beckhoff):** `beckhoff-pc`, Ubuntu 26.04. SSH `ssh hoyte@192.168.2.2`
  (confirmed 2026-06-13). `eno1` = LAN `192.168.2.2/24` (gw `.2.1` = the Mac);
  `enp4s0` = EtherCAT (no IP). The Pi reaches `xylod` at `192.168.2.2:5510`
  (Pi is dual-homed `192.168.10.3` + `192.168.2.3`) — **confirmed working**.
  `xylod` **auto-starts real** on boot (systemd). Details + the sim-trap writeup
  in `SESSION_NOTES.md`.
- `.claude/memory/` is write-protected in the Cowork session — **persist durable
  knowledge in the repo** (this file, `DEVLOG.md`) so it syncs everywhere.

---

## 7. Consolidated next-steps backlog

**Sandbox-doable now (no hardware):**
- Suite: move the **Windows CI job to msys2 UCRT64** (fixes libvips ingest on
  the cart's own platform).
- Suite **Phase 4** (library grid⇄timeline, notes, quarantine + disk gauge,
  incomplete-session salvage) and **4b** importer — all testable on `--sim`.
- `xylod`: draft the **E-stop abort path** + **systemd service**; verify
  `EcBackend` against the bench-proven Er74.1 recipe.

**Bench / hardware-gated:**
- Wire the **E-stop chain** (turn `pos_el_din` back on).
- **EL7047 filter-wheel adaptation** in `EcBackend` + `xylod.conf` rewrite once
  the filter mechanism (rotary wheel vs linear slide, 3 filters) is settled.
- Add the **EL2521 line-trigger** terminal; map **EL2521 / encoder → grabber
  J4** when the breakout arrives; pull the exact J4 pinout.
- Slot **incoming Beckhoff modules** into `xylod.conf` + EcBackend on arrival.
- Read a real **scan TIFF header** (bit depth + dimensions) and set the real
  **`line_max_hz`** from CamExpert.

**Decisions pending (not blocking):**
- Filter mechanism geometry + inter-pass time budget.
- Which 50:1 harmonic drive to fit.
- Capture-agent scope (minimal auto-save+naming first vs camera control from the
  pendant).

---

## 8. Document map

| Doc | What it covers |
|---|---|
| **`PROJECT_OVERVIEW.md`** (this file) | The whole system, start here |
| `CLAUDE.md` | AI behavioral guidelines + read-first list + architecture status |
| `WORKFLOW.md` | Cross-machine workflow; GitHub as source of truth |
| `BECKHOFF_PORT.md` | What the Beckhoff EtherCAT port built; bench to-verify list |
| `beckhoff/README.md` | C6920 / `xylod` bring-up (OS, network, build, first motion, service) |
| `beckhoff/PROTOCOL.md` | `xylod` wire protocol (Pi/Capture ⇄ daemon, port 5510) |
| `DEVLOG.md` | Session-by-session history; the running record |
| `SESSION_NOTES.md` | Pi 4 vs Pi 5 targets, deploy/SSH/build commands |
| `pi/hmi/METADATA_INFUSER.md` | Metadata Infuser spec + implementation |
| `docs/camera_capture_note.md` | Camera/grabber ownership + verified imaging chain |
| `docs/concept/review_suite_plan.md` | Full Review Suite plan + design decisions |
| `suite/README.md`, `suite/NEXT_SESSION.md` | Suite build + resume handoff |
| `docs/architecture/README.md` | Which architecture diagram is current vs stale |
| `docs/concept/xylosome_ui_concept.docx` | Full screen spec + pendant interaction model |

---

*Maintenance: this overview is meant to be the first thing read and the easiest
thing to keep accurate. When you change a subsystem, update its section here in
the same commit as the detailed doc.*
