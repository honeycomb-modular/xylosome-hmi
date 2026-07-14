# Xylosome Network

Single reference for every IP address, interface, service port, and how the
machines are wired together. **Snapshot: 2026-07-13** (capture-PC values read
live off the box that day; the rest from the code defaults + `SESSION_NOTES.md`
/ `PROJECT_OVERVIEW.md`).

> Scope note: the **Beckhoff EtherCAT** path is the active motion stack. The old
> **ClearCore** path (`192.168.1.100`) is a deliberately-kept fallback and is
> **not on the live network** — see the Legacy section at the bottom. The Pi 4
> (`192.168.10.2`) is retired; ignore it everywhere.

---

## 1. The three machines (+ what they own)

| Node | Role | OS | Owns |
|------|------|----|------|
| **Capture PC** (this dev box, `C:\dev\xylosome-hmi`) | Camera capture + Review Suite + runs the capture agent | Windows 11 | DALSA Piranha **HS-80-08K80-00-R** line-scan camera → Camera Link (Full, 8-tap, 8-bit) → Teledyne **Xtium** grabber (Sapera). Scans → local disk **`D:\capture`**. |
| **Beckhoff C6920** (`beckhoff-pc`) | Motion controller — SOEM EtherCAT master, runs **`xylod`** | Headless Linux (Ubuntu) | EtherCAT chain → StepperOnline **A6-EC** servo (CiA-402 CSP), Harmonic 50:1. |
| **Pi 5** (`xylosome-pi`) | HMI / touch pendant (Qt6/QML) | Raspberry Pi OS, labwc/Wayland | Touchscreen UI, Teensy 4.1 pendant over **USB**, metadata SVG export. |

The **Teensy 4.1 pendant** (Grayhill encoder + buttons) is **USB-attached to the
Pi** — it is *not* a network node.

---

## 2. Physical topology

All three machines share **one 1 Gbps PoE switch** (the Pi is PoE-powered from
it). Two logical `/24` subnets run over that single segment; the capture PC and
the Pi each carry **both** subnets on a **single physical NIC**.

```
                         ┌───────────────────────────┐
                         │   1 Gbps PoE switch        │
                         │   (one L2 segment)         │
                         └──┬──────────┬──────────┬───┘
             Ethernet 2 /   │          │          │   \ eno1
              (Marvell,     │          │          │
               1 Gbps)      │          │          │
        ┌───────────────────┴──┐   ┌───┴────┐   ┌─┴────────────────────┐
        │  CAPTURE PC (Win11)  │   │  Pi 5  │   │  BECKHOFF C6920      │
        │  .10.1  +  .2.50     │   │ eth0:  │   │  eno1: 192.168.2.2   │
        │                      │   │ .10.3  │   │  gw .2.1             │
        │  capture_agent.py    │   │ + .2.3 │   │  ┌────────────────┐  │
        │   :5520 live-focus   │   │        │   │  │ xylod  :5510   │  │
        │   :5521 camera bus   │   │ HMI    │   │  └────────────────┘  │
        │   xylod client ──────┼───┼────────┼──►│  enp4s0 = EtherCAT   │
        │  Review Suite        │   │ :8080  │   │  (no IP) ──► servo    │
        │  COM3 → camera        │   └────────┘   └──────────────────────┘
        └──────────┬───────────┘
                   │ Camera Link (Full 8-tap, NOT network)
             Piranha HS-80 camera        Images: camera → grabber → D:\capture
                                         (image data never crosses the network)

  Internet (separate): Capture PC Wi-Fi 192.168.4.43 · Pi wlan0 · Beckhoff via gw .2.1
```

**Key point:** image data never touches the network — Camera Link into the
grabber, TIFFs to local `D:\capture`. The LAN only carries small newline-JSON
control traffic. So today's 1 Gbps is not a capture bottleneck.

---

## 3. Subnets

| Subnet | Name / purpose | Members | Gateway |
|--------|----------------|---------|---------|
| **192.168.2.0/24** | Rig / control net — where **`xylod` (:5510)** lives | Beckhoff `eno1` **.2.2** · Pi `eth0` **.2.3** · Capture PC `Ethernet 2` **.2.50** | **.2.1** (historically the Mac via Internet Sharing; may be absent in the garage) |
| **192.168.10.0/24** | Capture-PC ↔ Pi direct channel (camera bus + HMI web) | Capture PC `Ethernet 2` **.10.1** · Pi `eth0` **.10.3** | none (no internet on this net) |
| 192.168.4.0/22 | Capture PC internet (Wi-Fi) | Capture PC Wi-Fi **192.168.4.43** | home AP |
| 172.17.16.0/20 | Hyper-V virtual switch (ignore) | Capture PC vEthernet 172.17.16.1 | — |

Both `192.168.2.x` and `192.168.10.x` ride the **same physical adapter**
(capture PC `Ethernet 2`; Pi `eth0`), so every node is reachable at L2 on the
one switch — the split is purely logical addressing.

---

## 4. Interfaces per node

### Capture PC (Windows) — verified live 2026-07-13
| Adapter | Hardware | Address | Notes |
|---------|----------|---------|-------|
| **Ethernet 2** | Marvell AQtion 10 Gbit | **192.168.10.1/24** + **192.168.2.50/24** | Up, negotiated **1 Gbps** (into the 1 G PoE switch). Carries all control traffic + reaches the Beckhoff on-link. |
| Ethernet | Realtek 2.5 GbE | — | **Disconnected / free** — reserved for the future fast image-offload plane. |
| Wi-Fi | RZ616 6E | 192.168.4.43/22 | Internet only. |
| vEthernet (Default Switch) | Hyper-V virtual | 172.17.16.1/20 | Virtual, ignore. |

### Beckhoff C6920 (Linux)
| Interface | Address | Purpose |
|-----------|---------|---------|
| **eno1** | **192.168.2.2/24** static, gw 192.168.2.1, DNS 1.1.1.1/8.8.8.8 | LAN / SSH / `xylod` |
| **enp4s0** | *no IP* | EtherCAT master → servo (1 kHz, DC SYNC0) |

**Verified static 2026-07-13.** `eno1` is pinned in netplan
(`/etc/netplan/00-installer-config.yaml`): `dhcp4: false`, a fixed
`192.168.2.2/24`, and **MAC-matched** (`00:01:05:30:50:36` → `set-name: eno1`)
so the NIC can't be renamed/reassigned on reboot. `ip addr` shows
`valid_lft forever` (a real static, not a DHCP lease) — the old DEVLOG
"sticky DHCP lease from the Mac" note is stale. Minor: both `NetworkManager`
and `systemd-networkd` run; netplan (networkd renderer) owns `eno1` and it's
stable, but the dual stack is worth tidying someday.

### Pi 5 (`xylosome-pi`)
| Interface | Address | Purpose |
|-----------|---------|---------|
| **eth0** | **192.168.10.3/24** + **192.168.2.3/24**, gw 192.168.2.1 | Static (NetworkManager conn name `eth0`, `autoconnect yes`). `.10.3` = link to capture PC; `.2.3` = reach the Beckhoff. |
| wlan0 | (DHCP) | Internet, separate from eth0. |

---

## 5. Services / ports

| Port | Host (listens) | Service | Clients |
|------|----------------|---------|---------|
| **5510** | Beckhoff `192.168.2.2` | **`xylod`** — motion daemon, newline-JSON, multi-client broadcast (`pass_start/pass_end/seq_done/status`) | Pi HMI, Review Suite, Capture agent |
| **5520** | Capture PC (`0.0.0.0`) | Capture agent **live-focus** — waterfall + focus metric | Suite LIVE (local `127.0.0.1`) |
| **5521** | Capture PC (`0.0.0.0`) | Capture agent **camera-settings bus** — `line.rate`, `tdi.stages`, `gain`, `scan.dir` | Suite (local), Pi HMI camera screen (`192.168.10.1`) |
| **8080** | Pi `192.168.10.3` | HMI **HttpServer** | Review Suite `HmiLink` |
| COM3 | Capture PC (serial) | Camera control (single-occupant) | capture agent only |
| Camera Link | Capture PC ↔ camera | Full 8-tap pixel data (not IP) | grabber |
| EtherCAT | Beckhoff `enp4s0` ↔ servo | CiA-402 CSP (not IP) | servo chain |

**LIVE vs capture are mutually exclusive** (single grabber owner): the `:5520`
live waterfall and the per-pass TIFF capture cannot run at once.

---

## 6. Who connects to whom (control plane)

| From | To | Address:port | What |
|------|----|--------------|------|
| Pi HMI `BeckhoffLink` | Beckhoff `xylod` | **192.168.2.2:5510** | motion commands / status (via Pi `.2.3`) |
| Pi HMI `CameraLink` | Capture agent | **192.168.10.1:5521** | camera knobs (via Pi `.10.3`) |
| Review Suite `XylodLink` | Beckhoff `xylod` | **192.168.2.2:5510** | builds sessions from pass events |
| Review Suite `LiveLink` | Capture agent | **127.0.0.1:5520** | live focus (Suite runs on the capture PC) |
| Review Suite `CameraLink` | Capture agent | **127.0.0.1:5521** | camera settings display |
| Review Suite `HmiLink` | Pi HMI | **192.168.10.3:8080** | HMI web link |
| Capture agent | Beckhoff `xylod` | **192.168.2.2:5510** (`XYLOD_HOST`) | receives pass events to name/capture TIFFs |

**Code default vs reality:** some hard-coded defaults are stale and are
overridden at runtime by `QSettings` / env vars — trust this table, not the
defaults:
- Pi HMI `BeckhoffLink` default `192.168.10.20:5510` → real value **192.168.2.2:5510** (`beckhoff/host` QSetting).
- Suite `XylodLink` default `192.168.10.20:5510` → set via **`XYLOD_HOST=192.168.2.2`** (or `xylod/host` QSetting).
- Suite `CameraLink`/`LiveLink` default `127.0.0.1` (correct — Suite is on the capture PC); override with `CAMERA_HOST` / `LIVE_HOST`.
- Pi HMI `CameraLink` default **192.168.10.1:5521** (correct); override with `camera/host` QSetting.

---

## 7. Access / SSH cheat-sheet

```bash
# Pi 5 (the HMI) — password auth; the PubkeyAuthentication=no flag matters
ssh -o PubkeyAuthentication=no hoyte@192.168.10.3

# Beckhoff C6920 (xylod host)
ssh hoyte@192.168.2.2

# Capture PC = this Windows box (local); services:
#   live-focus  127.0.0.1:5520   camera bus 127.0.0.1:5521
# Read camera state (one command per connection):
#   printf '{"cmd":"get"}\n' | <tcp to 127.0.0.1:5521>

# Launch the Suite against real data (on the capture PC, msys2 UCRT64):
CAPTURE_DIR=D:/capture XYLOD_HOST=192.168.2.2 build-suite/xylosome-suite.exe
```

- After a Pi reboot it can take ~1 min to answer. If `ssh 192.168.10.3` times
  out: confirm the capture-PC `Ethernet 2` still holds `192.168.10.1`, then
  check `arp -a` for a `192.168.10.3` line. Full recovery steps in
  `SESSION_NOTES.md` (the `.10.3`/`.2.3` netplan + NetworkManager `autoconnect`).
- The capture agent runs as the SYSTEM scheduled task **`XylosomeCaptureAgent`**
  (auto-restart on crash) via `capture/run_agent.cmd`; log at `C:\dev\capture_agent.log`.

---

## 8. Future: fast image-offload plane (planned, not built)

Images are local today, but when offload is needed:
- **Control plane** stays on the slow net (Pi ↔ Beckhoff ↔ capture PC, 1 Gbps is fine — control is tiny JSON).
- **Data plane:** dedicate the capture PC's free **10 G Marvell** (or the 2.5 G Realtek) to a **direct point-to-point** link to an image-store box with a fast NIC **and NVMe**. The whole path must be fast — `D:\` read speed included — or the slowest hop caps it. The Pi is hard-capped at 1 GbE and stays control-only.

---

## 9. Legacy / not on the live network

| Thing | Address | Status |
|-------|---------|--------|
| **Pi 4** | 192.168.10.2 | Retired from Xylosome long ago. Ignore. |
| **ClearCore** motion (fallback) | 192.168.1.100 · TCP 23 (telnet) · 8888 (ws) | Deliberately-kept fallback for the Beckhoff path. Not powered on the live net; do not extend or delete. |
| **Mac Internet Sharing** bench path | Mac = gw 192.168.2.1 (`bridge100`) | Old bench bring-up. The `.2.1` gateway on the rig net is the Mac; may be absent in the garage (rig net can run gateway-less). |
