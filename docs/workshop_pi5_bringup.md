# Xylosome HMI — Pi 5 Bring-up Runbook

Step-by-step, garage-friendly. Order: **verify Pi setup → display (video + soldered
power) → update the UI on the Pi 5**. Do the parts in order; each ends with a check.

Scope: the HMI box only (Pi 5 + AMOLED + Teensy). Power structure assumes the
**802.3at PoE+** feed from `power_budget_hmi.md` (PoE+ HAT → 5 V / 5 A rail).

> ℹ️ **The Pi 5 already runs an earlier version of this UI.** So this is mostly an
> **update + the display-power rework**, not a first install. Section 1 is "verify /
> adjust what's already there"; the two real jobs are **soldering the display onto
> the 5 V rail (§2)** and **updating to the latest code (§3)** — and §3 needs a
> **cmake re-run**, because new QML files were added since the installed version.

> ⚠️ This is the **Pi 5 / Wayland / Ninja** target — do **not** reuse the Pi 4
> commands (EGLFS / make / 192.168.10.2). Pi 5 is labwc, ninja, **192.168.2.2**.

---

## 0. Before you start — bring / have ready

- Pi 5 with the **PoE+ HAT** fitted, microSD with Raspberry Pi OS (Bookworm, 64-bit).
- WaveShare 5.5" AMOLED (1080×1920), micro-HDMI→HDMI cable for the Pi 5.
- PoE+ (802.3at) switch or injector + CAT6.
- Multimeter (mandatory for the solder step), soldering iron, a spare USB-A cable
  to sacrifice, heatshrink.
- A USB keyboard (for first-boot testing before the pendant is wired).
- Laptop on the same network for SSH.

---

## 1. Pi 5 — verify config (mostly already done)

The OS, Qt, SSH and a working UI are already on this Pi. This section is just
confirm-and-adjust; the only likely change is the display **scale** (§1.5).

### 1.1 SSH in
```
ssh hoyte@192.168.2.2
```

### 1.2 Set the clock (avoids build-skew problems)
```
sudo timedatectl set-ntp true
timedatectl        # confirm "System clock synchronized: yes"
```

### 1.3 USB current limit — important for the display
The Pi 5 caps **all** USB ports at 600 mA unless it knows it has a 5 A supply.
Even though we'll power the display off the 5 V rail (not a USB-A port), set this so
the rail isn't artificially limited:
```
sudo nano /boot/firmware/config.txt
```
Add under `[all]`:
```
usb_max_current_enable=1
```
> Only valid because the PoE+ HAT genuinely delivers 5 A. Save, reboot later.

### 1.4 Confirm the display stack is labwc/Wayland
```
echo $XDG_SESSION_TYPE      # expect: wayland
wlr-randr                   # lists outputs (note the HDMI name, e.g. HDMI-A-1)
```
Note the exact output name — you'll need it in step 2.2 and 3.5.

### 1.5 Check how the current UI launches
```
cat ~/.config/labwc/autostart
```
Note two things: the **`--scale`** value, and the **path** the binary launches from
(e.g. `~/xylosome_pi/...` or `~/xylosome-hmi/...`). The new UI is **960×540** → it
wants **`--scale 2.0`**; if the line says `2.25` (the older 853-wide layout) you'll
fix it in §3.5. The launch path tells you where the installed copy lives (§3.1).

**Check:** you know the HDMI output name, the current scale, and the install path.

---

## 2. Display — video + power

The UI is **touch-free** (encoder-driven), so the display only needs **HDMI (video)**
and **5 V (power)**. You do *not* need the display's USB touch data line.

### 2.1 Sanity check first — power via USB normally
Before any soldering, prove the panel works the easy way:
1. Connect micro-HDMI (Pi) → HDMI (display).
2. Power the display from its **normal USB cable** into a Pi USB-A port (temporary).
3. Boot. You should get the Pi desktop on the panel.

**Check:** panel lights up and shows the desktop. If not, fix HDMI/USB before soldering.

### 2.2 Rotation + scale (do this while still on USB power)
The panel is 1080×1920 portrait, mounted landscape, and the app is **960×540**.
Rotate and scale so 1920×1080 maps 1:1 to 960×540 (**scale 2.0**, not 2.25):
```
wlr-randr --output HDMI-A-1 --transform 270 --scale 2.0
```
(use your actual output name). The desktop should now be landscape and crisp.
**Check:** landscape orientation, sharp text. Tweak `--transform` (90/270) if upside down.

### 2.3 Power the display by soldering to the 5 V rail
Goal: feed the display 5 V from the **PoE-HAT-backed 5 V rail** instead of a USB-A
port — this dodges the 600 mA USB throttle and gives a single clean power path.

**Where to take power:** the Pi 5 GPIO header.
- **5 V** = physical pin **2** or **4**
- **GND** = physical pin **6** (or 9, 14, 20, 25, 30, 34, 39)

> The PoE+ HAT feeds this same 5 V rail, so drawing the display's ~1 A from the
> GPIO 5 V pins pulls from the HAT, within the 5 A budget.

**Cleanest method — sacrificial USB cable (reversible):**
1. Cut a USB-A cable, keep the connector end that plugs into the **display's power
   port**. Strip it: **red = +5 V (VBUS)**, **black = GND** (ignore green/white data).
2. **Multimeter check** the display port first: with the display on its normal USB,
   measure which pins are +5 V and GND, confirm red/black map correctly.
3. Solder **red → Pi 5 V** (pin 2/4) and **black → GND** (pin 6). Heatshrink.
4. Plug the connector into the display. Leave HDMI connected. No Pi USB-A used.

**Alternative — direct to the board:** if the display PCB exposes labelled
`5V`/`GND` pads, solder there instead. Verify pads with the multimeter + WaveShare
datasheet before powering.

> 🛑 **Polarity check before power-on.** Reverse 5 V/GND will kill the panel.
> Meter the soldered joints (5 V vs GND) one more time before applying power.

### 2.4 Verify display on rail power
Power the box from PoE+ only (no USB power to the display). The panel should light
and hold steady at boot and under UI load (no flicker/brownout). If it dims/resets,
see Appendix "display brownout".

**Check:** display runs entirely off the soldered 5 V rail, stable.

---

## 3. Update the UI on the Pi 5

Qt6 + build tools are already installed (the current UI builds and runs). If a build
later complains about a missing QML `import`, install the matching package
(`apt search qml6-module-...`) and rebuild.

### 3.1 Find where the installed UI lives
Use the launch path you noted in §1.5. Check whether it's a git clone of this repo:
```
git -C ~/xylosome-hmi remote -v 2>/dev/null      # exists & points at honeycomb-modular? → Case A
ls -d ~/xylosome_pi ~/xylosome-hmi 2>/dev/null   # see which dirs exist
```

### 3.2 Get the latest code — two cases

**Case A — already a git clone of `xylosome-hmi`:**
```
cd ~/xylosome-hmi
git pull
```

**Case B — older rsync/manual copy (e.g. `~/xylosome_pi`, not a git repo):**
Clone fresh and adopt it going forward (you'll repoint autostart in §3.5; delete the
old copy once the new one runs):
```
cd ~
git clone https://github.com/honeycomb-modular/xylosome-hmi.git
```

### 3.3 Build with Ninja — **re-run cmake** (new files were added)
Since the installed version, new QML files were added (ChoiceList + the six settings
sub-pages + presets/devices), so a plain `ninja` would silently miss them. Build
clean so cmake re-scans:
```
cd ~/xylosome-hmi/pi/hmi
rm -rf build && mkdir build && cd build
cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release
ninja
```
**Check:** build ends with `xylosome_hmi` in `build/`, no errors.

### 3.4 First run — manual, under Wayland
```
QT_WAYLAND_SHELL_INTEGRATION=xdg-shell ./xylosome_hmi -platform wayland
```
**Check:** the scan screen appears, fills the panel, looks correct (960×540 mapped).
Plug a USB keyboard and test cursor nav: arrows move focus, Enter activates, Esc backs.

### 3.5 Update autostart (fix scale → 2.0, and path if it changed)
Edit the existing file — this is also where you correct an old `--scale 2.25` to
`2.0`, and (Case B) repoint the binary path to the new clone:
```
nano ~/.config/labwc/autostart
```
Contents (use your real HDMI output name; adjust the path to where you built):
```
wlr-randr --output HDMI-A-1 --transform 270 --scale 2.0
sleep 0.5
QT_WAYLAND_SHELL_INTEGRATION=xdg-shell /home/hoyte/xylosome-hmi/pi/hmi/build/xylosome_hmi -platform wayland &
```
Reboot and confirm it comes up on its own:
```
sudo reboot
```
**Check:** after boot, the HMI launches fullscreen on the panel automatically.

### 3.6 Re-deploy after code changes (later)
On the Pi:
```
cd ~/xylosome-hmi && git pull
cd pi/hmi/build && ninja        # re-run `cmake .. -G Ninja` if files were added
# restart: kill the app and let autostart relaunch, or re-run the run command
```

---

## 4. Final verification checklist

- [ ] Box runs off a single PoE+ cable; display powered from the soldered 5 V rail.
- [ ] Clock synced (NTP), `usb_max_current_enable=1` set.
- [ ] Display landscape, sharp, stable under load.
- [ ] HMI builds and runs under Wayland.
- [ ] HMI autostarts on boot.
- [ ] Cursor navigation works (keyboard now; Teensy pendant later).

---

## Appendix — troubleshooting

**Black screen / no HDMI:** check the micro-HDMI is in the Pi's HDMI0 (nearest USB-C);
try the other port and re-check the output name with `wlr-randr`.

**Wrong size / off-screen:** scale must be **2.0** for the 960×540 app on a 1920×1080
logical panel. If still off, confirm `wlr-randr` shows the panel at 1920×1080 after
the transform.

**Display brownout / flicker:** the panel isn't getting enough current — verify the
solder joints, that the PoE+ HAT is truly 802.3at (25 W), and `usb_max_current_enable=1`
is set. As a fallback, feed the display from a small dedicated 5 V buck off the PoE rail.

**App won't start under Wayland:** ensure `QT_WAYLAND_SHELL_INTEGRATION=xdg-shell` is
set and labwc is running; check `~/xylosome-hmi/pi/hmi/build/xylosome_hmi` exists.

**Build error about a missing QML import:** install the matching `qml6-module-...`
package and re-run `ninja`.

**The pendant (Teensy) does nothing yet:** expected — the serial bridge isn't wired
into the app. Use a USB keyboard for now (arrows/Enter/Esc). Wiring the Teensy is a
later task.
