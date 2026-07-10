# Cart startup / state-persistence checklist (capture PC)

What to expect when the whole cart — **including the capture PC** — is powered up
cold, what comes back on its own, what still needs a manual touch today, and the
path to fully hands-off. Companion to `docs/capture_pc_commissioning.md`.

Verified state as of 2026-07-10.

---

## 1. Comes back automatically (no action)

- **Network** — the capture PC's two static IPs, `192.168.10.1/24` and
  `192.168.2.50/24` (no gateway), are in the persistent store and survive reboot.
- **Sapera serial config** — grabber serial port → `COM3`, detection
  "Teledyne DALSA Text Based" @ 9600, saved in Sapera Configuration; persists.
- **Files** — `.ccf` configs (Sapera library + `Desktop\xylosome dalsa settings`),
  the repo clone at `C:\dev\xylosome-hmi`, git credentials, helper scripts.
- **Motion (on the cart)** — `xylod` runs as an enabled systemd service on the
  Beckhoff C6920, so motion control comes up by itself.

## 2. Manual bring-up steps today

1. **Verify the network is up** (PowerShell):
   ```powershell
   ping 192.168.2.2                         # Beckhoff C6920
   Test-NetConnection 192.168.2.2 -Port 5510   # xylod reachable
   ```
2. **Load the grabber config** — CamExpert does NOT auto-load a `.ccf`. Open
   CamExpert, select the Xtium-CL MX4 device, and load
   **`HS-80-08K80_Full_8tap_8bit_WORKING`** from the Configuration dropdown
   (Teledyne DALSA → HS-80-08K80-00-R).
3. **Check the camera state** — the camera reverts to its stored user set on a
   power cycle (see §3). Confirm with a `gcp` over `COM3` (close CamExpert first —
   `COM3` is single-occupant), e.g. run `camera_agent_proto.ps1`, or:
   ```powershell
   $p = New-Object System.IO.Ports.SerialPort COM3,9600,None,8,One
   $p.Open(); $p.Write("gcp`r"); Start-Sleep 2; $p.ReadExisting(); $p.Close()
   ```

## 3. Camera settings persistence — the `wus` lever

- Camera settings changed over serial (`stg`, `ssf`, `sag`, `scd`, exposure mode)
  are **volatile** — a camera power cycle reverts them to the camera's stored
  **user set**, not wherever they were left. (Power-on baud is always 9600.)
- **`wus`** (write user settings) bakes the *current* camera state into the
  power-on user set, so the camera boots into it next time.
- **Do NOT `wus` a half-tuned state.** As of now the camera is experimental
  (stg 32, ssf ~28.8 kHz). Finalize the production config first —
  circle test for square pixels → chosen line rate/stages → 8- vs 12-bit →
  FFC (FPN/PRNU) calibration — **then** `wus` once so power-on = production state.

## 4. Path to fully hands-off (future work)

Delivered by the capture-agent build (see the two-bus plan / `LIVE_PROTOCOL.md`):

- **Capture agent as an auto-start Windows service** — comes up with the PC,
  opens `COM3`, and (via Sapera) loads the working `.ccf` on the grabber, so no
  manual CamExpert step.
- **`wus` the finalized camera config** so the camera itself powers on correct.
- **Raise Sapera contiguous memory to ~64 MB** (Sapera Configuration *as
  administrator* + reboot; currently default 8 MB) — needed for multi-second
  host-buffer captures. One-time, then persistent.
- Result: cold power-up → network up, motion service up, camera in production
  state, grabber configured, agent serving the HMI + Suite — nothing to click.

## 5. Open items gating "hands-off"

- Finalize + `wus` the production camera config (blocked on bench tuning).
- Build the capture agent (COM3 control proven; TCP broadcast service next).
- Set Sapera contiguous memory 64 MB.
- Set `xylod.conf` `line_max_hz` from the measured ceiling (68610 / 38314 Hz).
- Identify the unknown device at `192.168.2.4`.
