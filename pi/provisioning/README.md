# Provisioning — Pi & Beckhoff system config (so a reflash is reproducible)

These are the system files that live *outside* the build (in `/usr`, `/etc`,
`~/.config`) and would otherwise be lost on a reflash. They're version-controlled
here; the install scripts copy them back into place.

## Pi side

Run on the Pi after `git pull`:

```bash
bash pi/provisioning/install-pi.sh
sudo reboot
```

What it sets up:

| Repo file | Installed to | Purpose |
|---|---|---|
| `labwc/autostart` | `~/.config/labwc/autostart` | rotate+scale screen, swaybg logo background, launch HMI |
| `labwc/environment` | `~/.config/labwc/environment` | `XCURSOR_THEME=transparent` (hides the pointer) |
| `plymouth/xylosome/*` | `/usr/share/plymouth/themes/xylosome/` | boot + shutdown splash (logo on black) |
| `pi/hmi/HMLOGO.png` | theme `logo.png` + greeter wallpaper | the one bright master logo (235 on black) |
| (generated) | `~/.icons/transparent/` | blank cursor theme |
| (generated) | `/etc/sudoers.d/poweroff` | let the HMI/Beckhoff `poweroff` without a password |

**Key gotcha:** the boot splash is baked into the **initramfs**. After ANY change
to the Plymouth theme, the command that actually reaches the boot screen is
`sudo update-initramfs -u -k all` — *not* `plymouth-set-default-theme -R`.

## Beckhoff side (shutdown button → also powers off the Pi)

On the Beckhoff:

```bash
sudo install -m755 pi/provisioning/beckhoff/poweroff-pi.sh   /usr/local/bin/poweroff-pi.sh
sudo install -m644 pi/provisioning/beckhoff/poweroff-pi.service /etc/systemd/system/poweroff-pi.service
sudo systemctl daemon-reload && sudo systemctl enable poweroff-pi.service
```

## Manual steps (not scriptable)

- **Beckhoff → Pi SSH key:** `sudo ssh-keygen -t ed25519 -f /root/.ssh/id_pi -N ''`
  then `sudo ssh-copy-id -i /root/.ssh/id_pi.pub hoyte@192.168.2.3`.
- **C6920 BIOS:** "Restore on AC Power Loss" = **Power On** (so mains-on = boot).
- **Touch calibration** (if reflashed): `~/.config/labwc/rc.xml` touch
  `mapToOutput="HDMI-A-1"` + udev `LIBINPUT_CALIBRATION_MATRIX` (see SESSION_NOTES).
- **Drive:** absolute mode `C00.07=2`, `F31.10=4` to clear `Er208` (drive panel).

## Known issue

The **boot** logo comes up rotated (the early framebuffer is in the panel's
native orientation and `Plymouth.GetMode()` can't branch boot vs shutdown on this
build). Shutdown + session logos are upright. To fix boot: bake a rotated
`logo.png` into the initramfs *only* — take a photo of the boot screen first to
get the angle right. 🏆 (left as-is on purpose)
