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
| `pass_start` | `{"ev":"pass_start","pass":0,"filter":"R","tMs":123456}` | pass began (motion start) |
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
