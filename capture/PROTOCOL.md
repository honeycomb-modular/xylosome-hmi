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

After every saved pass the agent broadcasts its brightness, so the HMI's
colour match (settings ▸ colour) can equalise the filters:

```
{"ev":"pass_stats","seq":2231,"pass":1,"filter":"G","lines":26726,"median":18342.0,"p99":41020.0,"gainDb":0.0}
```

(16-bit left-justified values, median and 99th percentile of a subsample.
`gainDb` is the camera gain the pass ran at: xylod's `gainStops` in status
says how many stops its line-rate floor left to gain, and the agent sets
base + 6.02 dB per stop before arming the pass, restoring the base gain when
the sequence closes.)

A `state` event is broadcast to **every** connected client after any successful
`set`, so the HMI and Suite stay in sync without polling.

## Flat-field calibration (settings ▸ calibration ▸ flat field)

The camera's own FPN/PRNU calibration, one step per command. The agent runs the
step in the background (holding the grabber, like a scan) and broadcasts its
progress; the ack only says whether it started.

```
{"cmd":"ffc","step":"dark"}   -> lens capped: ccf, wfc 1
{"cmd":"ffc","step":"flat"}   -> white panel: free-run exposure found (brightest columns ~80%), ccp, wpc 1, line rate restored
{"cmd":"ffc","step":"save"}   -> epc 1 1, wus

{"ack":"ffc","ok":true,"step":"flat","note":"started"}          (false: "board busy (...)")
{"ev":"ffc","step":"flat","state":"running","note":"level 34% -> trying 16200 Hz","level":0.34,"rate":38000}
{"ev":"ffc","step":"flat","state":"done","note":"white (PRNU) calibrated at 16200 Hz, written to set 1","level":0.81,"rate":16200}
{"ev":"ffc","step":"dark","state":"failed","note":"ccf -> Warning 09: ..."}
```

It calibrates the camera as it stands (direction, stages, gain, aperture). The
raw pass-through (`{"cmd":"raw","line":...}`, `capture/cam_raw.py`) is still
there for anything these three steps do not cover.

## Parameters

| key          | type   | range / values              | TLC command  | gcp readback field |
|--------------|--------|-----------------------------|--------------|--------------------|
| `line.rate`  | number | 3500 – 38314 Hz (12-bit)    | `ssf <Hz>`   | SYNC Frequency     |
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

## Line count / aspect — NOT on this bus (grabber-side)

Line count = vertical resolution = aspect (width fixed 8192; square = 8192x8192). It
belongs to the motion/trigger domain: HMI aspect box -> xylod -> EL2521 line trigger ->
EXSYNC -> grabber captures that many lines. Until the trigger is wired, the agent sets
the grabber frame height directly via `CAP_LINES` (env, default 8192, range 1..65000)
by deriving a `.ccf` with `Crop Height`/`Scale Vertical` = N. Keep this bus (`:5521`)
strictly for the camera creative knobs (line.rate, tdi.stages, gain, scan.dir).
