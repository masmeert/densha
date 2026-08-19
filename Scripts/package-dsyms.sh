#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source ./Scripts/version-env.sh

APP="dist/Densha.app"
DSYM_DIR="dist/dSYMs"
OUTPUT="dist/Densha-$MARKETING_VERSION-dSYMs.zip"

if [ ! -d "$DSYM_DIR" ]; then
    echo "error: no $DSYM_DIR — run a release build first" >&2
    exit 1
fi

uuids_for() {
    dwarfdump --uuid "$1" | awk '{ print $2 }' | sort
}

verify() {
    local binary="$1" dsym="$2" name="$3"
    if [ ! -f "$binary" ]; then
        echo "error: $name: no binary at $binary" >&2
        exit 1
    fi
    local dwarf="$dsym/Contents/Resources/DWARF/$(basename "$dsym" .dSYM)"
    if [ ! -f "$dwarf" ]; then
        echo "error: $name: no DWARF image at $dwarf" >&2
        exit 1
    fi
    if ! diff <(uuids_for "$binary") <(uuids_for "$dwarf") > /dev/null; then
        echo "error: $name: dSYM does not match the shipped binary" >&2
        echo "  binary: $(uuids_for "$binary" | tr '\n' ' ')" >&2
        echo "  dSYM:   $(uuids_for "$dwarf" | tr '\n' ' ')" >&2
        echo "  a stale dSYM cannot symbolicate this build — rebuild from clean" >&2
        exit 1
    fi
    echo "  $name: $(uuids_for "$binary" | tr '\n' ' ')"
}

echo "==> verifying dSYMs match the shipped binaries"
verify "$APP/Contents/MacOS/Densha" "$DSYM_DIR/DenshaApp.dSYM" DenshaApp
verify "$APP/Contents/Helpers/denshad" "$DSYM_DIR/denshad.dSYM" denshad
verify "$APP/Contents/Helpers/densha" "$DSYM_DIR/densha.dSYM" densha

rm -f "$OUTPUT"
/usr/bin/ditto --norsrc -c -k --keepParent "$DSYM_DIR" "$OUTPUT"
echo "==> wrote $OUTPUT ($(du -h "$OUTPUT" | cut -f1 | tr -d ' '))"
