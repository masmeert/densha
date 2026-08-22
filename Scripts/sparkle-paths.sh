#!/usr/bin/env bash
set -euo pipefail

SPARKLE="${1:?usage: sparkle-paths.sh /path/to/Sparkle.framework}"

if [ ! -d "$SPARKLE/Versions/Current" ]; then
    echo "error: missing $SPARKLE/Versions/Current" >&2
    exit 1
fi
VERSION_DIR="$(cd "$SPARKLE/Versions/Current" && pwd -P)"

# Nested code must be signed before the container that seals it, so this list
# is ordered inside-out and ends at the framework root.
TARGETS=(
    "$VERSION_DIR/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
    "$VERSION_DIR/XPCServices/Downloader.xpc"
    "$VERSION_DIR/XPCServices/Installer.xpc/Contents/MacOS/Installer"
    "$VERSION_DIR/XPCServices/Installer.xpc"
    "$VERSION_DIR/Updater.app/Contents/MacOS/Updater"
    "$VERSION_DIR/Updater.app"
    "$VERSION_DIR/Autoupdate"
    "$VERSION_DIR/Sparkle"
    "$SPARKLE"
)

for target in "${TARGETS[@]}"; do
    if [ ! -e "$target" ]; then
        echo "error: missing Sparkle signing target: $target" >&2
        echo "  Sparkle's framework layout changed — update Scripts/sparkle-paths.sh" >&2
        exit 1
    fi
    printf '%s\n' "$target"
done
