# Xylosome Review Suite — Project Plan (Draft 2)

Cross-platform (Win/Mac/Linux) app for the cart's review computer. The third
member of the cart system: HMI triggers → xylod scans → **suite shows, judges,
keeps**. Replaces the Photoshop-and-folders workflow.

Draft 1 framed this as a post-processing utility. Draft 2 reframes it after
reading the Beckhoff build: a **live tethered-review suite**, a peer on the
cart network.

---

## How it fits the cart

```
[Pi HMI] ──┐
           ├── TCP :5510 (newline-JSON, broadcast) ── [xylod @ C6920]
[capture agent*] ──┤                                       │
[Review Suite] ────┘                                  EL2521 trigger
                                                           │
[capture PC: Sapera/grabber] ── writes scans ── shared folder
                                                    │
                            [Review Suite] watches + pairs files ↔ passes
```

\* capture agent = the backlogged service from `docs/camera_capture_note.md`.

**Session sync — solved by design.** The suite is just another xylod TCP
client (`hello`, `client:"suite"`). It receives:
- `pass_start` / `pass_end` with `tMs` and filter → brackets each pass
- `seq_done` → closes a session
- 10 Hz `status` (`state`, `pass`, `progress`) → live scan indicator, free

File ↔ pass pairing: watch the capture share; a file landing inside (or just
after) a pass bracket belongs to that pass. No naming convention strictly
required — but see dependency below.

## Liveness (chosen: per pass, with live indicator)

| Level | Source | Cost |
|---|---|---|
| 1. Scan indicator — pass #, filter, progress bar, posDeg | xylod status, TCP | Free. Phase 1. |
| 2. Pass appears when its file lands; color builds R→G→B→C | watch folder | Core. Phase 2. |
| 3. Line-by-line preview during scan | capture agent streaming downsampled rows | Later. Never touches the full-res data path — preview side-channel only. |

## ⚠ Key dependency: auto-save on the capture PC

Today scans are saved manually via CamExpert. "Appears the moment it's
scanned" requires per-pass auto-save → the **capture agent** (Sapera API,
already sketched, also a 5510 client) graduates from backlog to prerequisite
for Level 2 liveness. Interim: suite works with manual saves, images simply
appear on save. Capture agent should name files `<session>/<pass>_<filter>.tif`
— then pairing is exact, not inferred.

## What the suite does

1. **Live view** — current session front and center; passes appear as scanned,
   color composite builds up across R/G/B/C
2. **Judge** — keep / reject per session (or per pass), single-keystroke;
   rejects → quarantine folder → confirmed delete (scans are >1 GB; disk
   reclaim is a first-class feature)
   - **Rating** — rudimentary, Lightroom-style: 0–5 stars per session, keys
     `1`–`5` (`0` clears), `X` reject. Stored in the session's sidecar JSON
     (no database — survives copies/moves, human-readable). Library filters
     by rating; exports carry it as standard `xmp:Rating`, so Lightroom /
     Bridge / Photoshop see the same stars.
3. **Library** — contact sheet of kept sessions, proxy-only browsing; the
   TIFFs are never opened again after ingest
4. **Zoom to judge** — focus and exposure check at 1:1 pixels, smooth
   map-style zoom (tile streaming, see proxy pipeline)
5. **Metadata** — session record built from xylod events (real pass timing) +
   the HMI's MetadataRecorder SVG; shown alongside the image
6. **Export** — layered TIFF (R/G/B/C + metadata layer + XMP), pixels
   untouched, Photoshop-ready. Non-destructive imprint = metadata as its own
   layer, never burned into scan pixels. **Batch export**: "all ★★★+ from
   today", walk away.

### Judging aids

- **Per-pass histogram + clipping stats** — computed from the 16-bit TIFF
  during the single ingest read. The 8-bit proxy is for looking; the
  histogram is for trusting. Zebra overlay for clipped highlights.
- **Channel toggle** — solo R/G/B/C or composite on single keys; flicker
  between passes to judge inter-pass motion (the fringing is the artwork).
- **Compare view** — two sessions side by side, synced zoom/pan.

### Operational

- **Disk gauge** — capacity + "sessions remaining" prominently displayed;
  warn before a scan won't fit (~4–5 GB/session).
- **Permanent delete** — two speeds, both real deletes (no OS trash):
  - *Default*: reject → quarantine; "Empty quarantine" permanently deletes
    everything in it (TIFFs + pyramids + sidecars) and reports GB reclaimed.
  - *Direct*: delete-now on any session — skips quarantine, one stronger
    confirmation showing exactly what dies and how many GB return. For test
    scans you already know are garbage.
  - Disk gauge updates live; a small deletion log (what, when, size) keeps
    the forensic habit — names only, nothing recoverable.
- **Offload with verification** — end-of-day checksummed copy of keepers to
  external drive/NAS; only a verified copy unlocks freeing cart disk.
- **Incomplete sessions** — E-stop/fault/stop leaves 1–3 passes: mark
  partial, allow salvage (artistically valid) or quick cull. Never hidden.
- **Fault display** — xylod `fault` events (E-stop, EtherCAT loss) shown
  loudly on the review screen. Free over the existing socket.
- **Crash-safe ingest** — idempotent; on restart, rescan share + reconcile.

### Import / backfill (pre-suite archives)

Existing batches of TIFFs — shot before the suite existed — are first-class:

- Point the importer at any folder; it sorts by file timestamp and proposes
  sessions (groups of 4, or 1 for BW). User confirms or fixes: reassign a
  file, change R/G/B/C order, mark partial.
- Channel mapping set **per batch**, never silently guessed — old shoots may
  not share pass order.
- MetadataRecorder SVGs from the same era are matched by timestamp where
  they exist — curves recovered.
- Once confirmed, an imported session is indistinguishable from a live one:
  same pipeline (pyramid, histogram, sidecar), same rating/compare/export.

### Workflow closure

- **Session notes** — one-line text per session, in the sidecar JSON.
  Stars say how good; notes say why.
- **Shoot log** — the day as a timeline: sessions, durations, settings,
  ratings. Exportable; the Metadata Infuser ethos applied to the whole day.
- **Recall to pendant** — from a starred session, send its motion curve /
  duration back to the HMI: "shoot again like this." Suite → Pi (artist
  confirms on the pendant before triggering; suite never commands xylod
  directly). Touches HMI scope — needs a small receive endpoint there.

**Not:** capture control, motion control, auto-compositing final art.

## Proxy pipeline (review never touches the TIFFs)

When a TIFF lands, one libvips pass (`dzsave`) reads it once — streamed,
constant memory — and writes a **deep-zoom pyramid of JPEG tiles** beside it:

```
session_0142/
├── pass_0_R.tif          ← original, write-once, opened exactly once
└── .proxies/pass_0_R/    ← JPEG tile pyramid, ~1/10 the size
    ├── level 0  (thumbnail — contact sheet)
    ├── …
    └── level N  (1:1 pixels — focus/exposure judging)
```

- All UI reads tiles only. Contact sheet = low levels; zoom streams just the
  tiles in view, map-style, down to 100% — focus check on a >1 GB scan with
  nothing but small JPEG reads.
- Pyramid generation runs in a worker queue as files land; the pass thumbnail
  appears within seconds, deep levels fill in behind it.
- JPEG q≈90, 16-bit → 8-bit with a fixed tone mapping for *judging*; the
  TIFF stays the ground truth for export.
- The same single read also computes the **histogram + clip stats** into the
  sidecar JSON — decided now so it's never a retrofit.
- Reject + delete also removes the pyramid — quarantine handles both.

## Design language (decided 2026-06-11)

Light counterpart to the HMI — related by discipline, not by costume. Where
the pendant is a dark instrument, the suite is a white gallery: airy, calm,
end-user smooth. Images dominate; chrome recedes.

### Look

- **Surface**: pure white `#FFF` chrome. The image itself sits on a
  **neutral mid-gray field** — white directly against a scan biases exposure
  judgment darker.
- **Type**: sans-serif everywhere (clean grotesk). Monospace appears only in
  exported metadata/SVG, where the HMI's voice belongs.
- **Color**: R/G/B/C channel marks are the *only* color in the app.
  Everything else is black on white.
- **Density**: airy / gallery — generous margins, few elements per screen,
  slow looking.
- **Motion**: fast and satisfying — short eased animations (150–250 ms) on
  image events only (pass arrival, crossfade, zoom); chrome snaps instantly.
  Nothing ever waits for an animation.

### Layout

- **One main screen**: selected session large, **slim always-visible
  filmstrip** of the day's sessions along the bottom. Live capture is
  de-emphasized — it joins the filmstrip, it doesn't take over.
- **During a scan**: the screen stays put; a slim progress indicator
  (pass #, filter, progress, posDeg — from xylod status) appears at an edge.
  Judging continues uninterrupted.
- **Metadata**: a strip **below the image** — film-data-strip aesthetic,
  never covers pixels. Curve, pass timings, histogram live here.
- **Library**: grid ⇄ timeline, one-key toggle. Grid to look (uniform
  thumbnails, gallery wall); timeline to study (row per session: thumbnail,
  curve, stars, duration — the shoot log *is* the library).
- **Input**: keyboard-first — stars, reject, channel solo, zoom, view toggle
  all single keys; mouse for zoom/pan. Touch not assumed.
- **Menus**: standard menu bar (native top bar on macOS, in-window on
  Win/Linux) — File / Edit / View / Session / Help; every item shows its
  shortcut, so the menu doubles as the keyboard cheat sheet.
- **No Save command** — there is no document. Ratings/notes/rejects write to
  sidecar JSON instantly; TIFFs are never modified; exports are explicit.
- **Startup screen** — white field, Honeycomb Modular logo centered,
  **"Xylosome Suite"** beneath it; shown while the library/watcher
  initialize, fades into the main screen (same 150–250 ms easing).
  Assets in `suite/assets/`: `hm_logo_black.svg` (splash, derived from the
  vector original) and `hm_logo_orange.svg` (brand original, reference).
  App name everywhere — window title, installers, About — is
  **Xylosome Suite**.

## Stack

| Part | Choice | Why |
|---|---|---|
| UI | Qt 6 / QML, C++ | Same stack as HMI — shared skill set + components (BeckhoffLink pattern reusable nearly verbatim) |
| Image engine | libvips | Streamed processing, >1 GB scans in constant memory |
| xylod link | QTcpSocket JSON-lines | Port of `pi/hmi/src/BeckhoffLink.{h,cpp}` |
| Export | libtiff (BigTIFF) | Layered TIFF opens in Photoshop |
| Build | CMake + GitHub Actions | Repo convention; CI on all 3 OSes |

## Build order

| Phase | Deliverable | Proves |
|---|---|---|
| 0 | CMake skeleton + CI packaging an empty app, all 3 OSes | Cross-platform pipeline before features |
| 1 | XylodLink (BeckhoffLink port) + live scan indicator; test against `xylod --sim` | Session sync end-to-end, no hardware |
| 2 | Watch folder + pass pairing + tile pyramids + histograms/clip stats (one ingest read); crash-safe/idempotent | Big files, live appearance, trustworthy exposure data |
| 3 | Live view + composite build-up + 1:1 zoom + channel toggle + fault display | The seamless moment; focus & fringing judging |
| 4 | Judge/cull + stars + notes + quarantine + incomplete-session handling + library w/ filters + disk gauge | Daily-driver workflow |
| 4b | Importer — backfill existing TIFF archives into sessions | Past work joins the library |
| 5 | Metadata pairing + layered TIFF export + batch export + shoot log | Photoshop round-trip; day closure |
| 6 | Capture agent (capture PC, Sapera) — auto-save + naming | True seamlessness |
| 7 | Compare view · offload w/ verification · recall-to-pendant (HMI endpoint) | The full loop |
| 8 | Level-3 live preview, installers, polish | Ship |

`xylod --sim` means phases 1–5 are buildable and testable with zero hardware.

## Foundations (day-one decisions, painful to retrofit)

1. **Stable session IDs** — UUID per session at creation; all references
   (ratings, logs, exports, offload records) point at IDs, never paths.
   Folders can be renamed/moved/offloaded without breaking anything.
2. **Multi-root library + offline proxies** — the library spans N volumes
   (cart disk + archive disks), any of which may be absent. Offload moves
   TIFFs to archive but **pyramids stay on the cart**: the whole history
   remains browsable/zoomable/rateable at ~5–10% of the space, sessions
   badged "original offline". With permanent delete, this is the complete
   space story.
3. **Sidecar schema version** — `"schema": 1` in every JSON from the first
   build.
4. **Clock discipline** — xylod `tMs` is monotonic, capture-PC file times
   are wall-clock, different machines. Anchor each sequence's tMs to suite
   wall clock at `pass_start` arrival; pair files within that window; NTP
   across the cart LAN. Mispairing passes is the worst silent bug — design
   it out now.
5. **Log file** — the suite journals what it saw (events, file arrivals,
   pairings, deletions) from day one. Cart problems are diagnosed after the
   fact or not at all.

## Open questions

1. ~~Review computer OS?~~ **Answered: Windows 11 primary** (the cart),
   macOS secondary (studio Mac), Linux likely later. CI builds all three
   from phase 0; Windows is the release-gating platform.
2. ~~Capture share transport~~ **Answered: SMB** (capture PC is Windows —
   plain Windows file sharing). Rule: capture side writes to a temp name,
   renames on completion — the watcher never ingests a half-written file.
3. **Scan format** — TIFF (confirmed). Bit depth + typical dimensions: read
   from any existing scan's header when one is at hand. (Sets the 4 GB
   layered-TIFF vs PSB question.)
4. ~~Repo home~~ **Answered: `suite/`** inside xylosome-hmi, next to
   `beckhoff/` and `pi/` — one repo, one cart.
5. **Capture agent scope** — minimal (auto-save + naming only) first, camera
   control from the pendant later?
