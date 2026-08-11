# xylod wire protocol — Pi HMI / Capture PC ⇄ Beckhoff C6920

Newline-delimited JSON over plain TCP, **port 5510**. One JSON object per line,
UTF-8, `\n` terminated. Human-debuggable with `nc 192.168.10.20 5510`.

Two client roles share the same socket protocol: the **Pi HMI** (commands +
telemetry) and the **Capture PC** (event listener — pass timing). Multiple
simultaneous clients are allowed; events and status are broadcast to all.

---

## Client → server (commands)

Every command may carry an optional `"id"` (int) which is echoed in the ack.

| cmd | payload | effect |
|---|---|---|
| `hello` | `{"cmd":"hello","client":"hmi"}` | identify; server replies with `welcome` |
| `enable` | — | CiA-402 → Operation Enabled |
| `disable` | — | drive → Switched On (no torque) |
| `home` | `{"velDegS":10.0}` (optional) | move scan axis to configured home position |
| `set_home` | — | teach: current pose becomes 0°, persisted to `home_file`. Idle only; needs drive in absolute mode (C00.07=2) |
| `jog` | `{"velDegS":-5.0}` | constant velocity jog; `0` stops |
| `moveTo` | `{"posDeg":12.5,"velDegS":20.0}` | absolute move (output degrees) |
| `filter` | `{"slot":2}` | filter wheel → slot 0=R 1=G 2=B 3=C |
| `execute` | see below | run the full scan sequence |
| `pause` | — | freeze a running pass (velocity ramps to 0, position held) |
| `resume` | — | continue a paused pass |
| `stop` | — | abort sequence / motion, controlled decel |
| `fault_reset` | — | CiA-402 fault reset + clear E-stop latch (if input OK) |
| `status` | — | request one immediate status push |

### `execute`

```json
{
  "cmd": "execute",
  "colorMode": 0,              // 0 = color (4 passes R/G/B/C), 1 = BW (1 pass, Clear)
  "arcStartDeg": 0.0,          // scan axis output angle, pass start (dial hand 1)
  "arcEndDeg": 90.0,           // pass end (dial hand 2)
  "maxVelDegS": 100.0,         // velocity at profile value 1.0
  "minVelDegS": 2.6,           // velocity floor (HMI playhead floor, precomputed)
  "profile": [0.04, 0.05, ...],// N uniform samples of the speed curve, 0..1,
                               // sampled by the HMI from the curve editor —
                               // what the artist draws is what executes
  "settleMs": 300,             // dwell at arc start before each pass
  "returnVelDegS": 40.0,       // re-position speed between passes
  "line": { "mode": "curve",   // "curve" = rate ∝ instantaneous velocity
            "baseHz": 5000.0 } // Hz at maxVelDegS  ("fixed" = constant baseHz)
}
```

#### Optional: multi-pass structure

| field | default | meaning |
|---|---|---|
| `passes` | `0` | explicit pass count (1–64). `0` keeps the `colorMode` behaviour: 1 pass BW, 4 passes colour. Needed by stacking, exposure bracketing and dithering, none of which fit 1-or-4. |
| `passOffsetDeg` | `0.0` | shifts the whole arc by `pass * passOffsetDeg`. Sub-pixel dither: the same sweep nudged a fraction of a pixel each pass. |
| `filterSlot` | `-1` | `-1` walks the filters per pass (R/G/B/C). `0–3` pins one slot for every pass, so an N-pass stack does not drag the wheel round between passes. Out-of-range pass indices clamp to the last slot. |

#### Optional: `tag` — opaque job label

| field | default | meaning |
|---|---|---|
| `tag` | `""` | Arbitrary short string, echoed verbatim on every `pass_start` of this job and **never interpreted by the daemon**. It exists so a client that issues several *separate* executes can tell the capture side they belong together. |

The HMI's HDR mode fires one single-pass `execute` per bracket (multi-pass under
EXSYNC starves the pass after a full frame), so each bracket lands as its own
scan and its own Review Suite session. The tag is the only thing tying them
together; without it the Suite sees N unrelated scans. Its format is a client
convention — currently `hdr:<setId>:<n>/<total>:<ev>`.

The daemon filters the tag to `[A-Za-z0-9:/.+-_]` and 63 chars before embedding
it (it goes straight into the event JSON). With no tag the `pass_start` event is
byte-identical to what it has always been, so older clients are unaffected.

#### Optional: `timeProfile` — reversible motion

```json
{ "cmd": "execute", "timeProfile": true, "durationS": 12.0,
  "arcStartDeg": 0.0, "maxVelDegS": 60.0,
  "profile": [0.0, 1.0, 0.0, -1.0, 0.0] }
```

Normally `profile[]` is indexed by **position** along the arc, which makes the
sweep monotonic by construction — `x = arcS/arc` only ever grows, so the axis
physically cannot turn around. With `timeProfile` the profile is indexed by
**time** through the pass and its samples are **signed**: negative means
reverse. That is what pendulum and party motion need.

- `durationS` is **required** and bounds the pass; `arcEndDeg` is ignored.
- `arcStartDeg` is still where the pass begins (the axis repositions there).
- `minVelDegS` is **not** applied. The floor exists to stop a position-indexed
  sweep stalling at v=0 forever; here it would make the turnaround impossible,
  since the axis could never pass through zero.
- Travel is bounded **only by the soft limits**, which are enforced every cycle.
  A profile whose mean is non-zero drifts, and the limits are what stop it.
- Line pacing uses `mean|profile|`, not peak velocity: a reversing sweep has no
  single peak to slow down, so a `lines` target that needs more than
  `line_max_hz` is clamped and the pass delivers fewer.
- Mutually exclusive with `static` — rejected with `"static and timeProfile are
  exclusive"`.

The server acks immediately (`{"ack":"execute","ok":true}`) and then drives the
sequence; progress arrives via events + status pushes.

---

## Server → clients

### Acks
`{"ack":"<cmd>","id":7,"ok":true}` or `{"ack":"<cmd>","ok":false,"err":"reason"}`

### Events (pushed immediately)

| ev | payload | meaning |
|---|---|---|
| `welcome` | `{"ev":"welcome","version":"x.y","sim":false}` | connection established |
| `pass_start` | `{"ev":"pass_start","pass":0,"filter":"R","tMs":123456}` | pass began (motion start). Carries `"tag":"..."` as well when the job was given one — see `execute` ▸ `tag`. |
| `pass_end` | `{"ev":"pass_end","pass":0,"tMs":126456}` | pass reached arc end |
| `seq_done` | `{"ev":"seq_done","passes":4}` | full sequence finished, axis homed back |
| `homed` | `{"ev":"homed"}` | homing complete |
| `fault` | `{"ev":"fault","text":"..."}` | drive fault / E-stop / EtherCAT loss |

`tMs` is the daemon monotonic clock in ms — pass timing for the Metadata
Infuser and for the capture PC to bracket acquisitions.

### Status (10 Hz while any client is connected)

```json
{ "ev":"status",
  "state":"idle",          // idle|homing|moving|filter|settle|running|paused|estop|fault
  "op": true,              // EtherCAT segment OPERATIONAL
  "enabled": true,         // drive in Operation Enabled
  "homed": true,
  "pass": 1,               // current pass 0..3, -1 outside a sequence
  "progress": 0.42,        // 0..1 along the arc within the current pass
  "posDeg": 37.8,          // scan axis output angle
  "velDegS": 41.2,
  "filterSlot": 1,         // -1 while moving / unhomed
  "lineHz": 2061.0,        // current EL2521 output frequency
  "estopOk": true,
  "drive": { "sw": 4663, "fault": 0 },
  "echo": 123456           // EL5152 counter (encoder echo), raw counts
}
```

---

## Hardware-side signals (not on this socket)

- **EL2521 ch1** → camera frame-grabber line trigger. Frequency follows the
  speed curve (`line.mode == "curve"`) — geometry ⇄ sampling, the third axis.
- **EL2xxx DO bit 0** `pass_active` — high for the duration of each pass.
- **EL2xxx DO bit 1** `pass_index` — 50 ms pulse at each pass start (pass
  counting on the capture side without parsing TCP).
