# capture/ — Xylosome capture agent

The service that runs on the **capture PC** and owns the camera. It is the
camera-side peer of xylod: where xylod (`beckhoff/`) is the motion bus, this is
the **camera bus**. The HMI and the Suite each connect to both.

- `capture_agent.py` — the agent. **Phase 1: camera settings bus** (line rate,
  TDI stages, gain, scan direction) over TCP, applied to the Piranha HS-80 via
  the grabber serial port. No Sapera / no image path yet.
- `PROTOCOL.md` — the wire protocol (port 5521).
- `test_camera_client.ps1` — a PowerShell bench client (acts as the HMI).

## Run (on the capture PC)

Prereqs: Python 3 + pyserial (`pip install pyserial`), and **CamExpert closed**
(`COM3` is single-occupant).

```
python capture_agent.py
```

It prints the camera's current state and listens on `:5521`. Test from a second
window:

```
powershell -ExecutionPolicy Bypass -File .\test_camera_client.ps1
```

## Auto-start (Windows, headless)

The agent runs at boot as a Scheduled Task (`XylosomeCaptureAgent`) under the
SYSTEM account — no login needed, auto-restarts on crash. It runs `run_agent.cmd`
(this folder), which launches `python -u capture_agent.py` and appends live
output to `C:\dev\capture_agent.log`.

Install once, in an **Administrator** PowerShell:

```powershell
$action    = New-ScheduledTaskAction -Execute "C:\dev\xylosome-hmi\capture\run_agent.cmd"
$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName "XylosomeCaptureAgent" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force
```

Manage it:

```powershell
Start-ScheduledTask -TaskName XylosomeCaptureAgent
Stop-ScheduledTask  -TaskName XylosomeCaptureAgent    # frees COM3 so CamExpert can use it
Get-Content C:\dev\capture_agent.log -Tail 20
```

**COM3 is single-occupant** — stop the task before opening CamExpert, start it
again after. `run_agent.cmd` hard-codes the Python path; update it if Python moves.

## Grabber config at boot (D3 green headless)

The grabber's FPGA boots into its default (Medium) config — CL2 (D3 LED) red —
until a Sapera app loads the Full `.ccf`. `configure_grabber_boot.ps1` does that
once at boot via the Sapera .NET API (no CamExpert). The FPGA keeps the config
until the next reboot even after the script exits, so it's a one-shot.

Runs as the `XylosomeGrabberConfig` scheduled task (SYSTEM, at boot, 64-bit).
Logs to `C:\dev\grabber_config.log`. Install once, in an **Administrator** PowerShell:

```powershell
$ps  = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$scr = "C:\dev\xylosome-hmi\capture\configure_grabber_boot.ps1"
$action    = New-ScheduledTaskAction -Execute $ps -Argument "-ExecutionPolicy Bypass -NoProfile -File `"$scr`""
$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName "XylosomeGrabberConfig" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force
```

Notes:
- Uses **only** `DALSA.SaperaLT.SapClassBasic.dll` (64-bit). The mixed-mode
  `...Core.dll` isn't loaded (not needed for acquisition config, and it fails to
  load standalone) — that's expected.
- Configures the board only; it does **not** capture images yet. Actual frame
  grab + save to `D:` is the next step (extend into a held acquisition).
- Independent of the camera-settings agent (that owns COM3; this owns the board).

## Live focus (Suite waterfall)

`live_agent.py` is the **real** live-focus agent — the drop-in replacement for
`suite/tools/fake_capture_agent.py`. It serves the `:5520` protocol
(`suite/LIVE_PROTOCOL.md`): on `live_start` it opens the grabber, grabs frames
from the free-running camera (Sapera via pythonnet), downsamples each 8192-px
line to the requested width, computes the focus metric (RMS of horizontal
gradient), and streams line blocks; on `live_stop` it releases the board.

The Suite's live button drives this unchanged. For use without the Suite,
`live_viewer.py` is a standalone OpenCV viewer (rolling waterfall + focus number)
that connects to `:5520` — pull focus with just these two scripts.

Deps: `pip install pythonnet numpy opencv-python`. Run (CamExpert closed):

```powershell
python live_agent.py      # window A - serves :5520
python live_viewer.py     # window B - shows the waterfall
```

Notes / next:
- Buffer format is **Mono16**; the camera's 8-bit data is in the low byte
  (`clip(0,255)`), confirmed on the bench.
- `grab_test.py` is the minimal grab diagnostic (dimensions + per-line stats).
- Camera is already internal-sync (exposure mode 7), so no trigger switching yet.
  When scanning uses the EL2521 external trigger, `live_start`/`live_stop` should
  switch the camera internal↔external over COM3 (per `LIVE_PROTOCOL.md`).
- One streaming session at a time (single board); `live_agent` holds the board
  only while streaming.

## Status (2026-07-10)

- Camera control proven end-to-end over the bus: networked `set` → COM3 → camera
  obeys → real `state` broadcast back (verified on the bench).
- Verified camera facts and the COM3 mapping live in
  `docs/capture_pc_commissioning.md`.

## Next

- Wire the HMI's `ScreenCamera` to this bus (see `pi/hmi/src/CameraLink.*`) —
  **needs a Pi build to verify**.
- Later phases (same agent): xylod `:5510` subscription for pass bracketing +
  per-pass auto-save; live-focus `:5520` for the Suite; auto-report real
  `line_max_hz`; load the `.ccf` via Sapera at startup; run as an auto-start
  Windows service (see `docs/cart_startup_checklist.md`).
