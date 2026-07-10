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

- **Windows (proven, recommended): msys2 UCRT64** — see the block below.
- **macOS**: `brew install qt vips pkgconf` then the commands above;
  produces `xylosome-suite.app`.
- **Linux**: `apt install qt6-base-dev qt6-declarative-dev libqt6svg6-dev
  qml6-module-qtquick-controls qml6-module-qtquick-dialogs libvips-dev`
  then the commands above (needs a distro shipping Qt ≥ 6.4).

### Windows via msys2 UCRT64 (proven 2026-07-10, capture PC)

This replaces the old MSVC + MinGW-libvips route (the `LNK1181: intl.lib`
wound). One toolchain, Qt6 + gcc from pacman, **no libvips needed** for the
live-focus + judging build:

```
winget install MSYS2.MSYS2
# then in the "MSYS2 UCRT64" shell (not MINGW64/MSYS):
pacman -Syu                          # rerun if it closes the terminal
pacman -S --needed mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-cmake \
    mingw-w64-ucrt-x86_64-ninja mingw-w64-ucrt-x86_64-qt6 mingw-w64-ucrt-x86_64-pkgconf
cd /c/dev/xylosome-hmi
cmake -S suite -B build-suite -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build-suite
./build-suite/xylosome-suite.exe     # run from the UCRT64 shell (Qt DLLs on PATH)
```

- Configure reports `libvips NOT found — building without ingest
  (judging-only)`; that is expected and fine. Live focus + judging work.
- The **LIVE** button drives the real capture agent (`capture/live_agent.py`)
  on `:5520` — live waterfall + focus, verified in the Suite on Windows.
- To add image ingest (tile pyramids), one line, no MSVC pain:
  `pacman -S mingw-w64-ucrt-x86_64-libvips`, then re-run cmake. libvips is
  optional (`HAVE_VIPS`): without it the suite still builds and runs.

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
