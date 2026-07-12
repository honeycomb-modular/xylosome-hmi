---
name: project-xylosome
description: Xylosome HMI project — what it is, current status, Pi 4 vs Pi 5 targets, key file locations
metadata:
  type: project
---

Xylosome is a handheld art scanning unit. Qt6/QML HMI on Raspberry Pi. Line scanner camera (Dalsa Piranha 8K BW). Pendant: Teensy 4.1 + Grayhill encoder + 3 buttons.

**Motion stack — ACTIVE = Beckhoff (as of 2026-06-13):** the axis is driven by a Beckhoff C6920 running headless Linux as a SOEM EtherCAT master (`beckhoff/`, daemon `xylod`), commanding a StepperOnline A6-EC servo (CiA-402 CSP). The real servo has run the artist's curve over EtherCAT. The Pi HMI is retained and talks to `xylod` over TCP. See `BECKHOFF_PORT.md` and `beckhoff/README.md`.

**STALE / FALLBACK:** the original ClearCore path (Panasonic Minas A6 pulse drive + NEMA 17 stepper, controlled via ClearCore over TCP/Ethernet) is **kept, not deleted**, as a fallback if Beckhoff doesn't pan out. ClearCore references elsewhere in the repo are legacy design — don't treat them as current and don't delete that code.

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

## Update 2026-07-11 — capture agent consolidated; Suite renders real scans

- `capture/capture_agent.py` (on the capture PC) is the consolidated always-on agent:
  settings `:5521` + live-focus `:5520` + per-pass capture from xylod `:5510` -> `D:\capture`,
  one board lock (LIVE and capture mutually exclusive). Runs under Windows Python
  (Sapera/pythonnet); grabber `Xtium-CL_MX4_1`, camera Piranha HS-80-08K80, COM3 TLC 9600.
- Grabber-side **line count = aspect** (width fixed 8192; square = 8192x8192). `CAP_LINES`
  env (default 8192, range 1..65000) sets the frame height via a derived `.ccf`. This is the
  internal-sync stand-in for the EXSYNC/EL2521 trigger-driven line count that the HMI aspect
  box (green-box drag) will drive once the trigger/pulse is wired. Camera `:5521` bus stays
  creative-knobs only.
- Review Suite builds+runs on the capture PC (msys2 UCRT64, Qt6 + libvips). ZoomView deep-zoom
  tile bug fixed (blank main window on real 8192-tall scans) — real scans render, square confirmed.
