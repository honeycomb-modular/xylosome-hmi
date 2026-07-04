#!/usr/bin/env bash
# install-pi.sh — restore the Pi's boot/splash/cursor setup from the repo.
# Run on the Pi:  bash pi/provisioning/install-pi.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
LOGO="$REPO/pi/hmi/HMLOGO.png"          # bright master logo (235 on black)

echo "[1/5] labwc autostart + environment"
mkdir -p "$HOME/.config/labwc"
install -m644 "$HERE/labwc/autostart"   "$HOME/.config/labwc/autostart"
install -m644 "$HERE/labwc/environment" "$HOME/.config/labwc/environment"

echo "[2/5] Plymouth theme (boot/shutdown splash)"
sudo mkdir -p /usr/share/plymouth/themes/xylosome
sudo install -m644 "$HERE/plymouth/xylosome/xylosome.plymouth" /usr/share/plymouth/themes/xylosome/
sudo install -m644 "$HERE/plymouth/xylosome/xylosome.script"   /usr/share/plymouth/themes/xylosome/
sudo cp "$LOGO" /usr/share/plymouth/themes/xylosome/logo.png
sudo plymouth-set-default-theme xylosome
sudo update-initramfs -u -k all          # the command that actually reaches the boot splash

echo "[3/5] transparent cursor theme"
mkdir -p "$HOME/.icons/transparent/cursors"
python3 - "$HOME/.icons/transparent/cursors/left_ptr" <<'PY'
import struct, sys
SIZE=24
chunk = struct.pack('<9I',36,0xfffd0002,SIZE,1,1,1,0,0,0)+b'\x00\x00\x00\x00'
data  = b'Xcur'+struct.pack('<III',16,0x00010000,1)+struct.pack('<III',0xfffd0002,SIZE,28)+chunk
open(sys.argv[1],'wb').write(data)
PY
for n in default arrow top_left_arrow pointer xterm text; do
  ln -sf left_ptr "$HOME/.icons/transparent/cursors/$n"
done
printf '[Icon Theme]\nName=transparent\n' > "$HOME/.icons/transparent/index.theme"

echo "[4/5] greeter wallpaper -> bright logo"
sudo cp "$LOGO" /usr/share/rpd-wallpaper/xylosome-logo.png
sudo sed -i 's#^wallpaper=.*#wallpaper=/usr/share/rpd-wallpaper/xylosome-logo.png#' /etc/lightdm/pi-greeter.conf || true

echo "[5/5] sudoers: allow the HMI/Beckhoff to poweroff without a password"
echo 'hoyte ALL=(root) NOPASSWD: /usr/bin/systemctl poweroff' | sudo tee /etc/sudoers.d/poweroff >/dev/null
sudo chmod 440 /etc/sudoers.d/poweroff

echo
echo "Done. Reboot to apply.  Manual steps NOT scripted (see README.md):"
echo "  - Beckhoff-side shutdown hook (beckhoff/ folder)"
echo "  - Beckhoff root SSH key authorized on this Pi"
echo "  - touch calibration (rc.xml / udev rule) if reflashed"
