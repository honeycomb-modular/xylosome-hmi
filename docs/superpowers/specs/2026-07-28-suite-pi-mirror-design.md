# Mirroring the Pi HMI into the Review Suite — design

- **Date:** 2026-07-28
- **Status:** Design / exploration captured. **Not started.** Resume at the Capture PC.
- **Goal (as chosen during brainstorming):** See and drive *everything the Pi
  HMI controls* from the Capture PC, in a window that's part of the Suite —
  **for convenience, with the Pi up and running.** Not a Pi-down backup, not a
  replacement of the Pi.

---

## 1. What we decided, in one line

Put the Pi's **live screen** in the Suite (a VNC view of the running HMI), rather
than rebuilding the Pi's control surface inside the Suite. This is **"C-remote"**
below. It is the cheapest, safest option *precisely because the Pi stays up.*

---

## 2. Load-bearing findings from the code (why the decision went this way)

These are the facts that shaped the choice. Verify them again if the code has
moved since 2026-07-28.

1. **`xylod` has no arbitration between clients.** The wire protocol is
   multi-client and symmetric — any TCP client on `:5510` can send the full
   command set (`beckhoff/PROTOCOL.md`). And in `beckhoff/xylod/src/Sequencer.cpp`,
   `execute` / `home` / `jog` / `moveTo` are **not gated on idle** — they take
   over immediately (only `estop`/`fault` block them at `Sequencer.cpp:161`; only
   `set_home` and `filter` require idle). An `execute` arriving mid-scan
   overwrites the running job and restarts from pass 0 (`Sequencer.cpp:191`).
   → **Any second *authoring* surface would need arbitration built by us; the
   daemon won't protect against two writers.**

2. **The scan curve is stateless in `xylod`.** The `profile[]` arrives fresh with
   every `execute` (`TcpServer.cpp:122`) and is **never echoed in `status`**
   (`PROTOCOL.md` status block has no profile). → A Suite-native surface could not
   "re-fire what the Pi staged"; it would have to carry its own curve.

3. **The Suite already has the plumbing for the *observer* half.**
   `suite/src/XylodLink.cpp` is a port of the Pi's `BeckhoffLink` but is
   deliberately observer-only (`XylodLink.cpp:96` — "observer sends only
   hello/status; nothing to track"). It already receives full status + all events
   at 10 Hz, so a **native status mirror is essentially free** and can sit next to
   the remote window.

4. **The Suite already knows if the Pi is reachable.** `suite/src/HmiLink.cpp`
   probes the Pi's HTTP server on `:8080` every 2 s (`HmiLink.h`). Reuse this to
   gate/enable the remote-view panel.

5. **The Pi is labwc/Wayland (wlroots).** `pi/provisioning/labwc/autostart` drives
   the display with `wlr-randr` (rotate 270, scale 2.0) → wlroots compositor.
   **The existing "TigerVNC via systemd" (`SESSION_NOTES.md:122`) is an X11
   server** — it serves its own separate virtual desktop and will **not** mirror
   the live fullscreen HMI. To mirror the *actual running HMI* we need
   **`wayvnc`** (uses `wlr-screencopy` + virtual pointer/keyboard, which labwc
   supports). **This is the #1 thing to verify on the box.**

6. **The pendant stays live for free.** Because C-remote drives the Pi's *one real
   UI*, the USB pendant (`pi/hmi/src/PendantReader`) and the PC mouse both drive
   the same screen. No two-writers problem, no lost pendant.

---

## 3. Options considered

| Option | What it is | Verdict |
|---|---|---|
| **A — setup panel** | Un-stub `XylodLink` send; Suite buttons for jog/home/filter/enable + always-live STOP. No scan trigger. | Rejected — less than the goal ("everything"). |
| **B — A + preset scan** | A, plus `execute` from a few saved profiles. | Rejected — doesn't reproduce the artist's live curve. |
| **C-native** | Rebuild the whole Pi control surface (curve editor, presets, metadata) inside the Suite, backed by `XylodLink`. | Rejected for *this* goal. Re-introduces every hard problem at full strength: two authors on an unarbitrated daemon (needs a control-ownership token → **daemon change, touches the Pi's proven path**), dual-maintenance of the curve editor (the artistic heart), split metadata-SVG provenance, and still no pendant. This is the "Pi-down backup / replacement" project — a *separate* effort if ever wanted. |
| **C-remote** ✅ | Put the Pi's live screen in a Suite window via VNC; forward mouse/keyboard. | **Chosen.** One real control surface, `xylod` untouched, pendant stays live, independent of the Windows libvips blocker. Cost: needs the Pi up (acceptable — that's the stated use case). |

**Why C-remote dissolves the safety problem:** there is still exactly one control
surface — the Pi's real UI. We're only remoting its input. No arbitration, no
duplicate curve editor, no duplicate metadata recorder, no `xylod` change.

---

## 4. Chosen design — C-remote

```
Capture PC — Suite (Qt6/QML)                 Pi 5  192.168.10.3 (labwc/Wayland)
┌──────────────────────────────┐            ┌───────────────────────────────┐
│ existing: sessions, focus,   │  VNC/RFB   │ xylosome_hmi  (fullscreen)     │
│  XylodLink status mirror     │◄──────────►│ wayvnc :5900                   │
│  HmiLink reachability probe  │  frames    │  (wlr-screencopy +            │
│ NEW: "Pendant" panel  ───────┼─ + input ──┤   virtual pointer/keyboard)   │
│  = embedded VNC view + input │            │                               │
└──────────────────────────────┘            └───────────────────────────────┘
   both on the 192.168.10.x link · the USB pendant still drives the same UI
```

- **Pi side:** `wayvnc` serving the live output on `:5900`, VNC password, started
  from a systemd service or the labwc autostart alongside the HMI.
- **Suite side:** a "Pendant"/"HMI" panel that shows the remote framebuffer and
  forwards input. Sits next to the Suite's own native `XylodLink` status readouts.
- **`xylod`:** unchanged. **Pi HMI code:** unchanged.

---

## 5. Phased plan (cheap → expensive)

**Step 0 — De-risk on the Pi, zero Suite code (~an afternoon). DO THIS FIRST.**
All the project risk is here.
- Install/run `wayvnc` on the Pi 5.
- Point *any* plain VNC viewer from the Capture PC at `192.168.10.3:5900`.
- Confirm: (a) it shows the **live HMI**, not a blank desktop; (b) mouse +
  keyboard input reaches it through labwc's virtual pointer/keyboard; (c) latency
  and the rotated (270°) / scaled (2.0) touchscreen geometry are acceptable in a
  window.
- If `wayvnc` misbehaves on this labwc build, we learn it before writing any C++.

**Step 1 — MVP integration.** A "Pendant"/"HMI" button in the Suite that opens the
view. Cheapest cut: shell out to a bundled VNC viewer window. Proves the workflow
inside the Suite's UX.

**Step 2 — Native panel ("part of the program").** A real Suite tab / detachable
window: a `QQuickPaintedItem` backed by **LibVNCClient** (available in the Suite's
msys2 UCRT64 toolchain) that pumps framebuffer updates into a `QImage` and
forwards QML mouse/key events back as RFB pointer/key events. Docked next to the
native status strip.

---

## 6. Open items to verify on the box (all cheap)

- [ ] **`wayvnc` vs. the existing TigerVNC** — does `wayvnc` capture the *live*
      HMI? Replace or coexist with the X11 TigerVNC service?
- [ ] **Input injection** on this specific labwc build (virtual-pointer /
      virtual-keyboard protocols present and working).
- [ ] **Window scaling** of the rotated/scaled fullscreen UI inside a Suite panel.
- [ ] **Auth** — VNC password on the cart LAN (closed `.10` link, but set one).
- [ ] **Autostart** — systemd service vs. labwc autostart for `wayvnc`; must not
      disturb the HMI (COOP.md: a deploy alone doesn't respawn the HMI; reboot).

---

## 7. Explicitly out of scope (deferred, not forgotten)

- **C-native** (Suite authors/runs scans with the Pi off). If ever wanted, it's a
  *separate* project and its blocker is designing `xylod` control-ownership
  arbitration first (see finding #1).
- **Relaying the pendant** to the PC. Not needed — the pendant drives the Pi UI,
  which C-remote already shows.
- **Any change to `xylod` or the Pi HMI.** C-remote needs neither.

---

## 8. Environment notes for the implementer (from COOP.md / NETWORK.md)

- **Addresses:** Capture PC `192.168.10.1`; Pi 5 `192.168.10.3`; both on the `.10`
  link. SSH to the Pi: `ssh -i ~/.ssh/id_ed25519 hoyte@192.168.10.3` (Pi sudo is
  NOPASSWD).
- **Suite launch (Capture PC):** `pwsh -File start-suite.ps1` — **not** from the
  agent Bash tool (sandbox denies exec). See COOP.md §4.
- **GitHub is source of truth.** An AI session can edit/commit but cannot push —
  hand the push to the machine you're on.

---

## 9. References (files read during exploration)

- `beckhoff/PROTOCOL.md` — wire protocol, status block (no profile)
- `beckhoff/xylod/src/TcpServer.cpp:83-144` — command dispatch
- `beckhoff/xylod/src/Sequencer.cpp:160-265` — command gating (no idle guard on
  execute/home/jog/moveTo)
- `suite/src/XylodLink.cpp:96`, `suite/src/HmiLink.h` — observer link + Pi probe
- `pi/hmi/src/BeckhoffLink.h:69-88` — the Pi's command surface (for reference)
- `pi/provisioning/labwc/autostart` — labwc / wlr-randr (wlroots confirmation)
- `SESSION_NOTES.md:122` — existing TigerVNC (X11) note

---

## 10. Addendum — 2026-08-09, re-verified at the Capture PC

Section 2 asked for its findings to be re-checked. Done, against `b4808b8`.
**All of §2 still holds.** Three things to add — two that strengthen C-remote,
one new option §3 never considered.

### 10a. The Pi HMI is *already* a mouse-and-keyboard UI (strengthens C-remote)

C-remote was costed as "look-only, driven awkwardly." That undersold it. The Pi
UI is fully drivable by mouse and keyboard today, so remoting it yields a real
control surface, not a picture:

- **Every interactive element has a `MouseArea`** — `TerminalButton.qml:52`,
  `NavRow.qml:86`, plus `BackButton`, `FocusIndicator`, `ScreenPresets`. Screens
  that appear to have none (`ScreenHome`, `ScreenJog`, `ScreenLive`) simply
  *compose* those components. The only components without a click path are
  `LabelledValue` and `ChoiceList`, and `LabelledValue` is read-only telemetry.
- **The curve editor is already drag-capable** — `ScreenScan.qml` (5 MouseAreas),
  `ScreenTimed.qml` (3), `ScreenStatic.qml`.
- **The encoder ring travels over VNC for free.** `FocusController.qml` is
  transport-agnostic by design ("driven by keyboard keys in main.qml; later by
  the Teensy pendant… never knows which"). `main.qml:65-84` maps arrows/Tab →
  rotate, Enter/Space → click, Esc/Backspace → back, Delete → BTN1 execute.

→ Mirroring gives clickable + draggable + full pendant grammar, pixel-identical,
with zero UI maintenance. **Suggested addition:** map scroll-wheel → Up/Down in
the Suite panel before forwarding, and the wheel *becomes* the encoder ring.

### 10b. The rotation worry in §6 is smaller than feared

`main.qml:14-15` is a plain landscape `960×540`. The `--transform 270` in
`labwc/autostart` compensates for a physically sideways-mounted panel; the output
post-transform is landscape, so the capture should be an ordinary landscape frame,
not a portrait sliver. Still confirm in Step 0, but don't budget much for it.

### 10c. NEW — option **D**: native PC UI that drives the *Pi*, not xylod

§3 framed the choice as "Suite UI → xylod" (C-native) vs. "mirror" (C-remote) and
missed a third wiring. **The Pi HMI already runs an HTTP server on `:8080`,
in-process** (`main.cpp:51-53`) — the same port `HmiLink` already probes.

A PC UI pointed at *that* keeps the Pi as the **sole xylod client**, so finding
#1's two-writers hazard never arises, no daemon arbitration is needed, and the
pendant stays live. Both surfaces would share `MotorModel`, so the curve is one
object rather than two copies.

**The gap:** `HttpServer` today drives only `MotorModel`, **not** the motion path.
`main.cpp` registers `Motor` and `Beckhoff` as *separate* singletons, and all
motion in QML goes to the latter — `Beckhoff.executeScan` (`ScreenScan.qml:1288`),
`Beckhoff.moveTo` (`ScreenJog.qml:65`), `home`/`stop`/`setFilter`/`faultReset`.
The handlers only touch `m_motor` (setpoint, mode, enable, zero, nodes, presets —
ClearCore/ESP32-era concepts). So `:8080` can edit the curve but **cannot fire a
scan on the Beckhoff path**.

Closing it = expose the twelve `BeckhoffLink.h:69-88` verbs over `:8080`. Small,
contained, Pi-side.

**Residual cost that never goes away:** dual UI maintenance — 27 QML files
including the curve editor. Every Pi change made twice, or the two drift.

### 10d. Recommendation (unchanged in direction, sharper)

| Wiring | Verdict |
|---|---|
| PC UI → xylod directly (C-native) | **No.** Real hazard, needs daemon arbitration. |
| PC UI → Pi `:8080` (new option D) | Viable and safe, but dual UI maintenance forever. |
| Mirror (C-remote) | **Still first.** Everything, ~an afternoon, zero maintenance. |

**They are not exclusive, and the mirror does not block D.** Run the mirror; if
something specifically grates (drag latency in the curve editor is the likely
one), extend `:8080` and build a native panel *for just that*, docked beside the
mirrored view — incremental, not a big-bang reimplementation.

### 10e. New open item — `:8080` is unauthenticated

The legacy surface is reachable by anything on the cart LAN and can rewrite the
curve nodes. Not urgent on a closed link; **becomes urgent if D goes ahead** and
it starts firing motion.

- [ ] Auth on `:8080` before extending it with `BeckhoffLink` verbs.
