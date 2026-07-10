# Camera bus protocol (capture agent)

Newline-delimited JSON over plain TCP, **port 5521**, multi-client broadcast —
the same style as xylod's motion bus (`beckhoff/PROTOCOL.md`), but for the
camera. The agent runs on the **capture PC**, owns the grabber serial port
(`COM3`, TLC 9600-8N1), and is the only thing that talks to the camera.

Two-bus architecture: motion state comes from **xylod :5510** (on the Beckhoff),
camera state from **this agent :5521** (on the capture PC). The HMI and the Suite
each connect to both. Keeping them separate means the motion daemon never has to
know about the camera, and the camera path stays entirely on the capture PC.

Phase 1 = **settings only** (no image path, no Sapera). Line trigger during a
scan is still the grabber's EXSYNC paced by the Beckhoff EL2521 — unaffected by
this bus.

## Commands (client → agent)

```
{"cmd":"hello","client":"hmi"}     -> welcome
{"cmd":"get"}                      -> state (current camera settings)
{"cmd":"set","key":"tdi.stages","value":48}   -> ack, then state broadcast to all clients
```

## Events / replies (agent → clients)

```
{"ev":"welcome","camera":"HS-80-08K80-00-R","version":"0.1"}
{"ev":"state","line.rate":28797.7,"tdi.stages":32,"gain":"0.0",
              "scan.dir":"internal/reverse","model":"HS-80-08K80-00-R",
              "clm":"21, Full, 8 taps, 8 bits, no time MUX"}
{"ack":"set","ok":true,"key":"tdi.stages","value":48,"note":"ok"}
```

A `state` event is broadcast to **every** connected client after any successful
`set`, so the HMI and Suite stay in sync without polling.

## Parameters

| key          | type   | range / values              | TLC command  | gcp readback field |
|--------------|--------|-----------------------------|--------------|--------------------|
| `line.rate`  | number | 3500 – 68610 Hz             | `ssf <Hz>`   | SYNC Frequency     |
| `tdi.stages` | int    | 16, 32, 48, 64, 80, 96      | `stg <n>`    | Stage Selection    |
| `gain`       | number | −10 … +10 dB (all taps)     | `sag 0 <dB>` | Analog Gain (dB)   |
| `scan.dir`   | string | `forward` \| `reverse`      | `scd 0\|1`   | CCD Direction      |

Invalid values are rejected with `{"ack":"set","ok":false,"note":"..."}` and not
applied.

## Notes / caveats

- **`COM3` is single-occupant** — CamExpert (and its Serial Command tab) must be
  closed while the agent runs.
- **Settings are volatile** — a camera power cycle reverts to the stored user
  set. Persist a finalized config with `wus` on the camera (not yet exposed on
  this bus by design — see `docs/cart_startup_checklist.md`).
- **`scan.dir` side effect** — changing CCD direction auto-loads a separate
  gain/offset/coefficient set (per the camera manual).
- **Exposure** is intentionally not a bus param: the HS-80 has no auto/manual
  exposure; `sem` only selects internal/external sync. The old HMI placard's
  "exposure: auto/manual" was fiction.
- **Bit depth / taps** (`clm 21` ↔ `clm 16`) are read-only here (`clm` field);
  changing them needs a coordinated grabber (.ccf/Sapera) reconfig, out of scope
  for phase 1.

## Roadmap (later phases, same agent)

- Subscribe to xylod `:5510` for `pass_start` / `pass_end` → per-pass auto-save.
- Live-focus stream on `:5520` for the Suite (`suite/LIVE_PROTOCOL.md`).
- Report the real max line rate → auto-set `xylod.conf` `line_max_hz`.
- Load the working `.ccf` on the grabber via Sapera at startup.
