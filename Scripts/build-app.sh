#!/bin/bash
# Assembles Densha.app. SwiftPM cannot emit a bundle, so the executables it builds
# are copied into a hand-made one.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="dist/Densha.app"
MACOS="$APP/Contents/MacOS"
# The helpers CANNOT live in Contents/MacOS: this volume is case-insensitive, so
# `densha` and `Densha` are one file there and the CLI would overwrite the app.
HELPERS="$APP/Contents/Helpers"

echo "==> building ($CONFIG)"
swift build -c "$CONFIG" --product DenshaApp
swift build -c "$CONFIG" --product denshad
swift build -c "$CONFIG" --product densha

BIN="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$HELPERS" "$APP/Contents/Resources"

# The SwiftPM product is DenshaApp because `Densha` and `densha` would collide in the
# build directory on a case-insensitive volume; the bundle wants the capitalised name.
cp "$BIN/DenshaApp" "$MACOS/Densha"
# Shipping these inside the bundle means the app never depends on PATH, and never
# talks to a mismatched daemon left over from another install.
cp "$BIN/denshad" "$HELPERS/denshad"
cp "$BIN/densha" "$HELPERS/densha"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature: enough for local use, and required for a stable identity so
# macOS does not re-prompt for permissions on every rebuild.
echo "==> signing (ad-hoc)"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || {
    echo "warning: codesign failed; the app will still run locally" >&2
}

# Guard against the case-insensitivity trap ever returning: on a case-insensitive
# volume, copying `densha` into Contents/MacOS would silently replace `Densha`.
# Checked by inspecting the link table rather than by running it — the app is a GUI
# binary that would never exit.
if ! otool -L "$MACOS/Densha" | grep -q SwiftUI; then
    echo "error: $MACOS/Densha does not link SwiftUI, so it is not the app binary" >&2
    exit 1
fi

echo
echo "built $APP"
echo
echo "  run it:            open $APP"
echo "  install the CLI:   ln -sf \"$ROOT/$HELPERS/densha\" /usr/local/bin/densha"
echo "  start at login:    densha daemon install"
