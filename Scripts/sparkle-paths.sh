#!/usr/bin/env bash
set -euo pipefail

SPARKLE="${1:?usage: sparkle-paths.sh /path/to/Sparkle.framework}"

if [ -L "$SPARKLE" ] || [ ! -d "$SPARKLE" ]; then
    echo "error: not a framework directory: $SPARKLE" >&2
    exit 1
fi

VERSIONS="$SPARKLE/Versions"
if [ ! -d "$VERSIONS" ]; then
    echo "error: missing $VERSIONS" >&2
    exit 1
fi

if [ -e "$VERSIONS/Current" ]; then
    VERSION_DIR="$(cd "$VERSIONS/Current" && pwd -P)"
else
    VERSION_DIR=""
    for candidate in "$VERSIONS"/*; do
        [ -d "$candidate" ] || continue
        if [ -n "$VERSION_DIR" ]; then
            echo "error: several version directories and no Versions/Current: $VERSIONS" >&2
            exit 1
        fi
        VERSION_DIR="$(cd "$candidate" && pwd -P)"
    done
    if [ -z "$VERSION_DIR" ]; then
        echo "error: no version directory under $VERSIONS" >&2
        exit 1
    fi
fi

VERSIONS_ROOT="$(cd "$VERSIONS" && pwd -P)"
if [ "$(dirname "$VERSION_DIR")" != "$VERSIONS_ROOT" ]; then
    echo "error: $VERSION_DIR resolves outside $VERSIONS_ROOT" >&2
    exit 1
fi

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
    if [ -L "$target" ]; then
        echo "error: signing target must not be a symlink: $target" >&2
        exit 1
    fi
    if [ ! -e "$target" ]; then
        echo "error: missing Sparkle signing target: $target" >&2
        echo "  Sparkle's framework layout changed — update Scripts/sparkle-paths.sh" >&2
        exit 1
    fi
    printf '%s\n' "$target"
done
