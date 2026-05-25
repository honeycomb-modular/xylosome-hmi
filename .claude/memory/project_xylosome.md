---
name: project-xylosome
description: Xylosome HMI project — what it is, current status, Pi 4 vs Pi 5 targets, key file locations
metadata:
  type: project
---

Xylosome is a handheld art scanning unit. Qt6/QML HMI on Raspberry Pi. Panasonic servo + NEMA 17 stepper controlled via ClearCore over TCP/Ethernet. Line scanner camera (Dalsa Piranha 8K BW). Pendant: Teensy 4.1 + Grayhill encoder + 3 buttons.

**Why:** The scanning motion creates intentional color fringing as the subject moves between 4 color passes (R/G/B/C). That fringing is the artwork.

## Two Pi targets — never mix up

| | Pi 4 (dev unit) | Pi 5 (final pendant) |
|---|---|---|
| IP | 192.168.10.2 | 192.168.2.2 |
| Display stack | EGLFS | Wayland / labwc |
| Remote access | TigerVNC via systemd | VS Code Remote SSH |
| Build | make (Unix Makefiles) | ninja |
| SSH | ssh -o PubkeyAuthentication=no hoyte@192.168.10.2 | ssh hoyte@192.168.2.2 |
| Repo path on device | /home/hoyte/xylosome-hmi/pi/hmi/ | not yet deployed |
| Status | Active dev | Not yet used for this codebase |

**All work as of 2026-05-24 is on Pi 4. Pi 5 deployment is future work.**

## Repo
github.com/honeycomb-modular/xylosome-hmi
Mac path: /Users/hoytevhoytema/Library/Mobile Documents/com~apple~CloudDocs/Documents/projects/xylosome_pi/

## Screen map (as of 2026-05-24)
- ScreenScan (was ScreenSequences) — PRIMARY root screen
- ScreenHome — secondary nav menu (01 live / 02 camera / 03 presets / 04 telemetry / 05 connected devices / 06 settings / 07 metadata)
- ScreenMetadata — metadata infuser / SVG export
- ScreenSplash boots to ScreenScan

## Metadata Infuser (done 2026-05-24, Pi 4 only)
- MetadataRecorder C++ singleton, QML name "Recorder"
- 4-pass (R/G/B/C) timing per execute, auto-exports SVG
- SVG: 568x200px, XYLOSOME_01 header, timing table + curve, params
- Export path: /home/hoyte/xylosome_exports/
- Test: Recorder.simulateTrigger() from ScreenMetadata

## Key docs
- docs/concept/xylosome_ui_concept.docx — full screen spec, pendant interaction model
- pi/hmi/METADATA_INFUSER.md — infuser spec and implementation notes
- DEVLOG.md — session-by-session dev log
- SESSION_NOTES.md — deploy procedures for both Pi 4 and Pi 5
