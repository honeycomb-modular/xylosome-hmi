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
