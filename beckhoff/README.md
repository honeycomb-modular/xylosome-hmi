# beckhoff/ — XYLOSOME Beckhoff EtherCAT path

Alternative motion path per `docs/architecture/xylosome_beckhoff.svg`:
the ClearCore + Minas A6 (pulse) route is replaced by a **Beckhoff C6920**
running headless Linux as **SOEM EtherCAT master**, driving a StepperOnline
**A6-EC** servo (CiA-402, CSP) plus Beckhoff EL terminals. The Pi HMI is
retained and talks to the C6920 over Ethernet/TCP (see `PROTOCOL.md`).

```
beckhoff/
├── PROTOCOL.md          wire protocol — Pi HMI / capture PC ⇄ xylod
├── README.md            this file — bring-up
├── xylod/               the C6920 daemon
│   ├── CMakeLists.txt
│   ├── src/             EcBackend (SOEM) · SimBackend (--sim) · Sequencer · TcpServer
│   ├── config/xylod.conf
│   └── systemd/xylod.service
└── tools/
    ├── ec_scan.cpp      list slaves on the segment
    └── motor_test.cpp   standalone CiA-402 CSP sine-sweep bench test
```

---

## C6920 bring-up

### 1. OS prerequisites

```bash
sudo apt install build-essential cmake git
# strongly recommended for smooth CSP at 1 kHz (open item on the diagram):
sudo apt install linux-image-rt-amd64        # Debian PREEMPT_RT kernel
```

SOEM: either let CMake fetch it (needs internet at configure time), or install
once system-wide:

```bash
git clone https://github.com/OpenEtherCATsociety/SOEM.git && cd SOEM
mkdir build && cd build && cmake .. && make -j && sudo make install
```

### 2. Network

- **MAC2 / LAN** — normal IP, on the garage switch. Suggested static:
  `192.168.10.20/24` (PC is `.1`, Pi 5 is `.3`).
- **MAC1 / EtherCAT** — no IP. This NIC goes straight to the A6-EC's
  EtherCAT-IN. Find its name with `ip a` and set `ec_iface` in `xylod.conf`.

### 3. Build + verify the segment

```bash
cd beckhoff/xylod && mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release && make -j
sudo ./ec_scan eth1            # expect: A6-EC, EK1100, EL7031, EL2521, EL5152, EL2xxx, EL1xxx
```

Fix the `pos_*` entries in `xylod.conf` to match the scan order.

### 4. First motion — bench test, motor on the desk, nothing attached

```bash
sudo ./motor_test eth1 1 10 10      # slave 1, ±10° output sweep, 10 s
```

### 5. Run the daemon

```bash
sudo ./xylod --config ../config/xylod.conf
# protocol smoke test from any machine:
nc 192.168.10.20 5510
{"cmd":"status"}
{"cmd":"enable"}
{"cmd":"jog","velDegS":5}
{"cmd":"jog","velDegS":0}
```

Install as a service:

```bash
sudo make install
sudo cp ../config/xylod.conf /etc/xylod.conf
sudo cp ../systemd/xylod.service /etc/systemd/system/
sudo systemctl enable --now xylod
```

### 6. HMI without hardware — sim mode

`xylod --sim` runs the identical protocol with a software axis — develop the
Pi HMI against it on any machine (even the Pi itself).

---

## To verify on the bench (carried over from the diagram + new)

- [ ] A6-EC PDO remap accepted (watch xylod startup log; consult drive manual
      if 0x1600/0x1A00 are read-only — then adjust struct offsets to its
      default mapping)
- [ ] EL7031 in velocity-direct mode (CoE 0x8012:01 = 0) and speed range CoE
      matched to `fw_vel_steps_s`
- [x] EL2521 base frequency CoE **0x8001:02** = `el2521_base_hz` (verified 50000
      on the terminal 2026-07-24; the old `0x8000:02` here was the wrong index).
      xylod now writes it, plus output mode 0x8000:0E = 2 (incremental encoder
      simulation — drives A *and* B, so the grabber can reject the return sweep)
      and ramp off 0x8000:06 = 0. Read the terminal back with
      `sudo ./ec_coe enp4s0 5`.
- [ ] E-stop wired normally-closed → `estop_active_low = true`
- [ ] PREEMPT_RT installed; `cyclictest` jitter < 100 µs
- [ ] Encoder-echo (EL5152) wired if locked-mode is pursued
