#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source ./Scripts/version-env.sh
./Scripts/sync-version.sh --check > /dev/null

APP="dist/Densha.app"
MACOS="$APP/Contents/MacOS"
HELPERS="$APP/Contents/Helpers"

ARCHS=()
if [ "${DENSHA_UNIVERSAL:-0}" = "1" ]; then
    ARCHS=(--arch arm64 --arch x86_64)
    echo "==> building ($CONFIG, universal)"
else
    echo "==> building ($CONFIG)"
fi

swift build -c "$CONFIG" "${ARCHS[@]+"${ARCHS[@]}"}" --product DenshaApp
swift build -c "$CONFIG" "${ARCHS[@]+"${ARCHS[@]}"}" --product denshad
swift build -c "$CONFIG" "${ARCHS[@]+"${ARCHS[@]}"}" --product densha

BIN="$(swift build -c "$CONFIG" "${ARCHS[@]+"${ARCHS[@]}"}" --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$HELPERS" "$APP/Contents/Resources"

cp "$BIN/DenshaApp" "$MACOS/Densha"
cp "$BIN/denshad" "$HELPERS/denshad"
cp "$BIN/densha" "$HELPERS/densha"
cp Resources/Densha.icns "$APP/Contents/Resources/Densha.icns"

echo "==> version $MARKETING_VERSION ($BUILD_NUMBER)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>Densha</string>
	<key>CFBundleIconFile</key>
	<string>Densha</string>
	<key>CFBundleIdentifier</key>
	<string>com.densha.Densha</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Densha</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${MARKETING_VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD_NUMBER}</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSSupportsAutomaticTermination</key>
	<false/>
	<key>NSSupportsSuddenTermination</key>
	<false/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" > /dev/null

IDENTITY="${DENSHA_SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
    echo "==> signing (ad-hoc)"
    SIGN=(codesign --force --options runtime --sign -)
else
    echo "==> signing ($IDENTITY)"
    SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
fi

"${SIGN[@]}" "$HELPERS/denshad"
"${SIGN[@]}" "$HELPERS/densha"
"${SIGN[@]}" "$APP"

echo "==> verifying"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed "s/^/    /"
if [ "$IDENTITY" = "-" ]; then
    echo "    ad-hoc: Gatekeeper will reject this on another Mac (fine for local use)"
fi

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
