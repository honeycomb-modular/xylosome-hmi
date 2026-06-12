# Xylosome Suite

The cart's live review application — Windows 11 (primary), macOS, Linux.
HMI triggers → xylod scans → **the suite shows, judges, keeps**.

Full plan and design decisions: [`docs/concept/review_suite_plan.md`](../docs/concept/review_suite_plan.md)

## Status

Phase 2 (a+b) — live tethered review working end-to-end against the fake rig:
xylod events → sessions in the filmstrip → TIFFs paired by wall-clock window
→ libvips ingest (JPEG tile pyramid + ≤2048 px preview + 16-bit histogram /
clip stats) → pixels on screen. Stars (`1–5`), reject (`X`), channel solo
(`R/G/B/C`, `A` auto), sidecar JSON write-through, crash-safe re-ingest,
log file. Not yet: deep-zoom viewer (phase 3), exports, deletion, importer.

Dev rig (no hardware):

```
python3 suite/tools/fake_xylod.py --write-files ~/xylosome-test-capture
XYLOD_HOST=127.0.0.1 CAPTURE_DIR=$HOME/xylosome-test-capture ./build/…/xylosome-suite
```

## Build

Requires CMake ≥ 3.21 and Qt ≥ 6.4 (CI uses 6.8; QtQuick.Dialogs
FolderDialog sets the floor).

```
cmake -S suite -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

- **Windows**: use the Qt 6 MSVC kit (Qt Creator opens `CMakeLists.txt`
  directly), or run the commands above in a "x64 Native Tools" prompt with
  Qt in `CMAKE_PREFIX_PATH`.
- **macOS**: `brew install qt vips pkgconf` then the commands above;
  produces `xylosome-suite.app`.
- **Linux**: `apt install qt6-base-dev qt6-declarative-dev libqt6svg6-dev
  qml6-module-qtquick-controls qml6-module-qtquick-dialogs libvips-dev`
  then the commands above (needs a distro shipping Qt ≥ 6.4).
- **Windows**: `vcpkg install libvips:x64-windows` + pkg-config on PATH
  (see the CI workflow for the exact recipe).

libvips is optional at build time: without it the suite still builds and
runs (sessions, pairing, judging), with ingest disabled and a warning in
the log.

## Conventions

- Design language is decided and documented in the plan — pure white chrome,
  neutral gray image field, R/G/B/C as the only color, sans type, fast
  150–250 ms easing on image events only.
- No Save command, ever — state writes through instantly (sidecar JSON).
- TIFFs are read-only, always. The suite never modifies an original.
- Stable session UUIDs, schema-versioned sidecars, log file from day one
  (plan → "Foundations").

## Layout

```
suite/
├── CMakeLists.txt
├── src/        C++ (entry point; later: watcher, ingest, xylod link)
├── qml/        UI
└── assets/     logos (hm_logo_black.svg = splash; orange = brand original)
```
