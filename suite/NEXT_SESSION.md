# Suite — next session handoff (written 2026-06-11, late)

Read `docs/concept/review_suite_plan.md` for the full plan; this file is
only what's needed to resume.

> **UPDATE 2026-07-10** — the Windows build is no longer parked. The Suite
> was built and run on the **capture PC** via **msys2 UCRT64** (Qt6 + gcc
> from pacman, no libvips), and the **LIVE** button drives the real capture
> agent (`capture/live_agent.py`) on `:5520` — live focus works in the Suite
> on Windows. Recipe in `suite/README.md`. Remaining Windows item is only
> libvips-for-ingest (one `pacman -S mingw-w64-ucrt-x86_64-libvips`).

## Where things stand

Phases 0–3 built, tested live on the Mac, CI green on all three platforms
(run #13). The suite connects to xylod (or `fake_xylod.py`), shows sessions
live, pairs TIFFs to passes, ingests to tile pyramids + histograms, deep-
zooms to 1:1, and persists stars/reject via sidecar JSON. Windows CI
artifact is **judging-only** (no libvips) — see parked item below.

## Dev rig (no hardware, two terminals)

```
# A — daemon + fake capture PC
python3 suite/tools/fake_xylod.py --write-files ~/xylosome-test-capture

# B — the suite
XYLOD_HOST=127.0.0.1 CAPTURE_DIR=$HOME/xylosome-test-capture \
  ./build/xylosome-suite.app/Contents/MacOS/xylosome-suite
```

Gotchas learned the hard way:
- **Two separate Terminal windows** — the daemon owns its terminal; pasting
  the app command under it does nothing.
- Restarting `fake_xylod` **resets its file counter** — wipe
  `~/xylosome-test-capture` (incl. `.xylosome/`) for a clean test, or old
  sidecars absorb/ignore the reused filenames.
- Suite log: `~/Library/Application Support/Honeycomb Modular/Xylosome
  Suite/suite.log` — `[vips]`, `[sessions]`, `[watcher]` prefixes.
- Keys: `1–5`/`0` stars, `X` reject, `←→` select, `R/G/B/C` solo, `A` auto,
  `Z` fit⇄1:1.

## Parked: Windows libvips (the one open wound)

> **RESOLVED 2026-07-10 (toolchain).** Built + ran on the capture PC via
> **msys2 UCRT64** — one toolchain, Qt6 + gcc from pacman, no import-lib
> archaeology. Live focus + judging build with **no libvips**. Only ingest
> (pyramids) still wants libvips, now a one-line `pacman -S` on msys2. The
> MSVC + MinGW-libvips notes below are superseded; kept for history.

MSVC + official MinGW-built libvips binaries (`build-win64-mxe` releases;
vcpkg has **no** libvips port). C API rewrite fixed the ABI question and
Windows *compiles* — but linking dies at `LNK1181: cannot open intl.lib`
even after .pc prefix relocation, phantom-include-dir creation, import-lib
aliasing, and stripping unresolvable `-l` entries. Diagnostics were added
to the install step (prints final Libs line + lib dir listing) — **that
log was never read**; check it first if retrying the current approach
(gate: repo variable `SUITE_WIN_VIPS=true`).

**Recommended instead**: switch the Windows job to **msys2**
(`msys2/setup-msys2` action, UCRT64: `mingw-w64-ucrt-x86_64-qt6` +
`-libvips` + `-gcc`) — one toolchain, both packages native, no import-lib
archaeology. windeployqt exists there too. Replace the aqt/MSVC Windows job
wholesale. (Proven locally 2026-07-10 — see the UPDATE banner.)

## Next build steps (in plan order)

1. **Windows ingest via msys2** — toolchain now proven locally; remaining is
   `pacman -S mingw-w64-ucrt-x86_64-libvips` + reconfigure to enable pyramids,
   then port the CI Windows job to `msys2/setup-msys2` (UCRT64).
2. **Phase 4**: library grid ⇄ timeline toggle (`G`?), notes input field,
   quarantine → permanent delete with GB-reclaimed report + deletion log,
   disk gauge ("sessions remaining"), incomplete-session salvage UI.
3. **Phase 4b importer** — backfill real archives; also the first chance to
   zoom real >1 GB scans (fake TIFFs are 256×160 — architecture verified,
   not perf).
4. Then: layered TIFF export (phase 5), capture agent (6), compare view /
   offload / recall-to-pendant (7).

## Open questions still unanswered (from the plan)

- Scan bit depth + typical dimensions — read any real scan's TIFF header
  (sets the 4 GB layered-TIFF vs PSB question for export).
- Capture agent scope (minimal auto-save+naming first?).

## Architecture cheat-sheet

```
xylod :5510 ─events→ XylodLink ─→ SessionStore ←─ FolderWatcher (capture dir)
                                   │   └─ pairing: wall-clock window
                                   │      + filename token + hole sealing
                                   ├─→ VipsEngine (QThread): dz pyramid +
                                   │   preview + histogram → .xylosome/proxies/<uuid>/
                                   └─→ sidecars .xylosome/sessions/<uuid>.json (schema 1)
QML: Main.qml (indicator, image field + ZoomView, metadata strip, filmstrip)
```
