# Xylosome Suite

The cart's live review application — Windows 11 (primary), macOS, Linux.
HMI triggers → xylod scans → **the suite shows, judges, keeps**.

Full plan and design decisions: [`docs/concept/review_suite_plan.md`](../docs/concept/review_suite_plan.md)

## Status

Phase 0 — project skeleton. Splash (Honeycomb Modular logo → Xylosome Suite)
fading into the empty main screen: header, gray image field, metadata strip,
filmstrip, standard menu bar. No features yet; the point is that this builds
and packages on all three platforms (see `.github/workflows/suite.yml`).

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
- **macOS**: `brew install qt` then the commands above; produces
  `xylosome-suite.app`.
- **Linux**: `apt install qt6-base-dev qt6-declarative-dev libqt6svg6-dev
  qml6-module-qtquick-controls qml6-module-qtquick-dialogs` then the
  commands above (needs a distro shipping Qt ≥ 6.4).

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
