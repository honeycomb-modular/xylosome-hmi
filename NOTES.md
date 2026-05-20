# XYLOSOME HMI — Session Notes

## Current status — all sync working ✅

- Pi node drag → browser ✅
- Browser node drag → Pi ✅
- Pi double-click insert node → browser ✅
- Browser double-click insert node → Pi ✅
- Pi double-click delete node → browser ✅
- Browser double-click delete node → Pi ✅
- Pi handle drag (box width) → browser ✅
- Browser handle drag → Pi ✅
- Play / pause both directions ✅
- Endpoint gap fixed (nodes always pinned nx=0 and nx=1) ✅

## Key lessons learned

### QML changes require a clean build

`qt_add_qml_module` compiles QML into the binary via `qmlcachegen`.
Incremental `touch` + `make` often silently skips QML recompilation.
**Always do a clean rebuild when QML changes:**

```bash
cd ~/xylosome_pi && rm -rf build && mkdir build && cd build && cmake .. -DCMAKE_BUILD_TYPE=Release && make -j4
```

Use `make -j4`, NOT `ninja -j4` — cmake generates Makefiles on this Pi setup.

### rsync preserves Mac timestamps

rsync `-av` keeps the source file's mtime. If Mac mtime < last Pi build time,
make may skip recompilation. Clean build avoids this entirely.

### Q_INVOKABLE vs property assignment from QML

Plain C++ setters are not callable as QML methods unless marked `Q_INVOKABLE`.
Use property assignment `Motor.x = val` for WRITE setters.
Use `Q_INVOKABLE` for methods called directly: `Motor.setNodesFromJson(...)`.

### QVariantList/QJSValue ambiguity

`Motor.nodes = jsArray` from QML stores inner objects as QJSValue, not QVariantMap.
`v.toMap()` on QJSValue returns empty maps in C++.
Fix: JSON string round-trip via `Motor.setNodesFromJson(JSON.stringify(arr))`.

## Deploy procedure

**Mac — rsync sources:**
```bash
rsync -av /Users/hoytevhoytema/Documents/projects/xylosome_pi/src/ hoyte@192.168.2.2:~/xylosome_pi/src/
rsync -av /Users/hoytevhoytema/Documents/projects/xylosome_pi/qml/ hoyte@192.168.2.2:~/xylosome_pi/qml/
```

**Pi — clean build:**
```bash
cd ~/xylosome_pi && rm -rf build && mkdir build && cd build && cmake .. -DCMAKE_BUILD_TYPE=Release && make -j4
```

**Pi — launch:**
```bash
sudo killall xylosome_hmi 2>/dev/null; sleep 1; XDG_RUNTIME_DIR=/run/user/$(id -u) WAYLAND_DISPLAY=wayland-0 QT_QPA_PLATFORM=wayland QT_WAYLAND_SHELL_INTEGRATION=xdg-shell ~/xylosome_pi/build/xylosome_hmi &
```

## Hardware

- Raspberry Pi 5, booting from NVMe (OSCOO M-key + PoE hat)
- BOOT_ORDER=0xf416 (NVMe first)
- Display: HDMI, rotated 270°, **scale 2** via wlr-randr → exact 960×540 logical px (no fractional hairline)
- Wayland compositor: labwc
- autostart: `~/.config/labwc/autostart`

## Screen resolution — 960×540 @ scale 2

All QML screens are written for **960×540** logical pixels (was 854×480).

The root cause of the right-edge hairline was fractional wlroots scaling:
`1920 ÷ 2.25 = 853.33 px` — non-integer, so the compositor left a 1 px gap.

Fix: change wlr-randr to `--scale 2`:
- `1920 ÷ 2 = 960 px` — perfect integer, no rounding artifact.
- All QML coordinates scaled ×1.125 (= 960/854 ≈ 540/480) from the old values.

**Pi autostart change required** — edit `~/.config/labwc/autostart`:
```
wlr-randr --output HDMI-A-1 --transform 270 --scale 2
```
(was `--scale 2.25`)

### labwc server-side window decoration (SSD) — right-edge line + left-side clip

Even with `Qt.FramelessWindowHint`, labwc adds a 1 px SSD border (from the PiXtrix
theme) unless told otherwise. This shifts window content 1 px right, clips the
playhead/content at the left edge, and leaves a 1 px gap on the right.

**Symptom**: red playhead disappears when it crosses the left edge of the canvas.

**Fix**: add `<core><decoration>client</decoration></core>` to `~/.config/labwc/rc.xml`.
This tells labwc to use client-side decoration for all windows. Combined with
Qt's `FramelessWindowHint`, the result is zero border.

**`~/.config/labwc/rc.xml`** must contain:
```xml
<?xml version="1.0"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
    <touch deviceName="11-0038 generic ft5x06 (79)" mapToOutput="DSI-2" mouseEmulation="yes"/>
    <touch deviceName="Waveshare  Waveshare" mapToOutput="HDMI-A-1" mouseEmulation="yes"/>
    <core>
        <decoration>client</decoration>
    </core>
    <theme><font place="ActiveWindow"><name>Nunito Sans</name><size>12</size><weight>Light</weight><slant>Normal</slant></font><font place="InactiveWindow"><name>Nunito Sans</name><size>12</size><weight>Light</weight><slant>Normal</slant></font><name>PiXtrix</name></theme>
</openbox_config>
```

Note: `QT_WAYLAND_DISABLE_WINDOWDECORATION=1` and `windowRule serverDecoration="none"`
do NOT work — labwc ignores them. The `<core><decoration>client</decoration></core>`
setting is the correct and confirmed fix.

## Screen layout — ScreenSequences as root

`ScreenSplash` (3 s) → `ScreenSequences` (root/home) → `ScreenHome` (nav menu, via ⚙ button)

**ScreenSequences layout:**
- Top half (y 0–270): motion curve canvas, full width
- Bottom half (y 270–540): XYLOSOME title + subtitle (left), play/stop buttons (right), ⚙ gear (bottom-left → ScreenHome)
