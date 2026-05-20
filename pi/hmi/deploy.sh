#!/usr/bin/env bash
# deploy.sh — build and run XYLOSOME HMI on Raspberry Pi 5
#
# Usage (from your Mac):
#   1.  Fill in PI_HOST below (hostname or IP of your Pi).
#   2.  Run:  bash deploy.sh          (full build + deploy + run)
#       Or:   bash deploy.sh run-only (skip build, just rsync + run)
#
# Prerequisites on Pi (run once):
#   sudo apt update
#   sudo apt install -y \
#       cmake ninja-build \
#       qt6-base-dev qt6-declarative-dev qt6-tools-dev-tools \
#       qml6-module-qtquick qml6-module-qtquick-controls \
#       qml6-module-qtquick-layouts \
#       fonts-montserrat
#
#   # Optional — for the native QHttpServer (otherwise QTcpServer fallback is used):
#   sudo apt install -y qt6-httpserver-dev
#
# To check Qt version on Pi:
#   ssh $PI_HOST "dpkg -l | grep 'libqt6' | head -5"

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
PI_HOST="${PI_HOST:-pi@raspberrypi.local}"   # override with PI_HOST=pi@x.x.x.x
PI_DIR="/home/pi/xylosome_hmi"               # destination on Pi
BUILD_DIR="${PI_DIR}/build"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

MODE="${1:-full}"   # full | run-only

# ── Sync source to Pi ─────────────────────────────────────────────────────────
echo "[deploy] syncing source → $PI_HOST:$PI_DIR ..."
rsync -av --exclude='.git' --exclude='build' \
    "$SCRIPT_DIR/" \
    "${PI_HOST}:${PI_DIR}/"

if [ "$MODE" = "run-only" ]; then
    echo "[deploy] run-only: skipping cmake/make"
else
    # ── Configure + Build on Pi ───────────────────────────────────────────────
    echo "[deploy] configuring cmake on Pi ..."
    ssh "$PI_HOST" bash <<EOF
set -euo pipefail
mkdir -p ${BUILD_DIR}
cd ${BUILD_DIR}
cmake .. \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH=/usr/lib/aarch64-linux-gnu/cmake
EOF

    echo "[deploy] building on Pi (this takes a minute on first run) ..."
    ssh "$PI_HOST" bash <<EOF
set -euo pipefail
cd ${BUILD_DIR}
ninja -j\$(nproc)
EOF

    echo "[deploy] build complete."
fi

# ── Run ───────────────────────────────────────────────────────────────────────
echo "[deploy] launching xylosome_hmi on Pi ..."
echo ""
echo "  Platform options (pick one for your setup):"
echo "    EGLFS  (no desktop, direct framebuffer — recommended for kiosk):"
echo "      ./xylosome_hmi -platform eglfs"
echo "    Wayland (if weston/labwc is running):"
echo "      QT_WAYLAND_SHELL_INTEGRATION=xdg-shell ./xylosome_hmi -platform wayland"
echo "    X11:"
echo "      ./xylosome_hmi -platform xcb"
echo ""
echo "  Web control UI (same LAN as Pi):  http://$(ssh "$PI_HOST" hostname -I | awk '{print $1}'):8080/"
echo ""

# Launch detached; stream output back.  Kill with Ctrl-C here.
ssh "$PI_HOST" bash <<'EOF'
cd /home/pi/xylosome_hmi/build
# EGLFS is the right choice for a kiosk with no desktop environment.
# Swap to -platform wayland if running under a Wayland compositor.
QT_QPA_PLATFORM=eglfs \
QT_QPA_EGLFS_ALWAYS_SET_MODE=1 \
./xylosome_hmi 2>&1
EOF
