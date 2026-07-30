#!/bin/bash
# build-suite-mac.sh — build the Xylosome Suite on macOS and install it as a Dock app.
#
#   bash build-suite-mac.sh
#
# macOS counterpart of start-suite.ps1's role on the capture PC: the installed
# app launches rig-connected (XYLOD_HOST=192.168.2.2) and falls back to a plain
# offline viewer when the rig is unreachable. Capture dir: ~/xylosome-capture.
# Logs everything to build-suite-mac.log in the repo root.
set -uo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
LOG="$REPO/build-suite-mac.log"
exec > >(tee "$LOG") 2>&1

step() { echo; echo "==== $* ===="; }
fail() { echo "FAILED: $*"; echo "END-STATUS: FAIL"; sleep 1; exit 1; }

step "environment"
sw_vers
if ! command -v brew >/dev/null 2>&1 && [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi
command -v brew >/dev/null 2>&1 || fail "Homebrew not found — install it from https://brew.sh first"
brew --version | head -1

step "dependencies (brew: cmake qt vips pkgconf)"
brew install --quiet cmake qt vips pkgconf || fail "brew install"

step "configure"
cmake -S "$REPO/suite" -B "$REPO/build-suite-mac" -DCMAKE_BUILD_TYPE=Release || fail "cmake configure"

step "build"
cmake --build "$REPO/build-suite-mac" -j"$(sysctl -n hw.ncpu)" || fail "cmake build"

APP="$REPO/build-suite-mac/xylosome-suite.app"
[ -d "$APP" ] || fail "expected bundle not found: $APP"

step "bake launch environment into the bundle (LSEnvironment)"
mkdir -p "$HOME/xylosome-capture"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :LSEnvironment" "$PLIST" 2>/dev/null
/usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$PLIST" \
  && /usr/libexec/PlistBuddy -c "Add :LSEnvironment:XYLOD_HOST string 192.168.2.2" "$PLIST" \
  && /usr/libexec/PlistBuddy -c "Add :LSEnvironment:CAPTURE_DIR string $HOME/xylosome-capture" "$PLIST" \
  || fail "Info.plist edit"

step "install to /Applications"
rm -rf "/Applications/xylosome-suite.app"
ditto "$APP" "/Applications/xylosome-suite.app" || fail "copy to /Applications"
# Editing Info.plist broke the ad-hoc code seal; re-sign or Apple Silicon refuses to launch.
codesign --force --deep --sign - "/Applications/xylosome-suite.app" || fail "ad-hoc codesign"

step "pin to Dock"
if defaults read com.apple.dock persistent-apps 2>/dev/null | grep -q "xylosome-suite"; then
    echo "already pinned — skipping"
else
    defaults write com.apple.dock persistent-apps -array-add \
      '<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>/Applications/xylosome-suite.app</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>' \
      || fail "dock defaults write"
    killall Dock
fi

step "launch"
open -a "/Applications/xylosome-suite.app" || fail "open"
echo "END-STATUS: OK"
sleep 1
