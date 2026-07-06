# Live focus protocol — Suite ⇄ capture agent, port 5520

For finding focus: the camera free-runs on its internal line trigger (no
motion, no xylod involvement) and the agent streams downsampled lines to
the suite, which renders a rolling waterfall + focus metric.

Same style as xylod's :5510 — newline-JSON — except pixel payloads, which
follow their JSON header as raw bytes (length in the header).

## Client (suite) → agent

| cmd | payload | effect |
|---|---|---|
| `hello` | `{"cmd":"hello","client":"suite"}` | identify → `welcome` |
| `live_start` | `{"width":1024,"maxHz":30}` | start streaming; agent downsamples the 8K line to `width` px, ≤ `maxHz` lines/s |
| `live_stop` | — | stop streaming, release camera to CamExpert defaults |

## Agent → suite

`{"ev":"welcome","version":"x.y","camera":"Piranha 8K","sim":false}`

Line block — JSON header, then raw payload on the same socket:

```
{"ev":"lines","count":8,"width":1024,"bytes":8192,"focus":0.417,"tMs":123456}
<8192 raw bytes: count × width, uint8, most recent line last>
```

- `focus`: agent-computed line-contrast metric (RMS of horizontal gradient,
  normalized 0..1 against a running max) — the number that climbs as the
  lens approaches focus. Computed on the FULL-resolution line before
  downsampling, so it sees detail the preview can't.
- `{"ev":"live_stopped"}` on stop; `{"ev":"error","text":"..."}` on failure.

## Real agent notes (capture PC, Sapera)

- Switch the camera to internal line trigger for live; restore the EL2521
  external trigger configuration on `live_stop` — scanning must be
  untouched by focus sessions.
- Downsample by simple decimation; JPEG not needed at 1024 px × 30 Hz
  (~30 KB/s raw).
- `sim` agent for development: `suite/tools/fake_capture_agent.py`.
