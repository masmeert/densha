#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUTPUT="${1:-dist/ThirdPartyLicenses.txt}"
CHECKOUTS=".build/checkouts"

if [ ! -d "$CHECKOUTS" ]; then
    echo "error: no $CHECKOUTS — run 'swift build' first" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
{
    echo "Densha bundles the following third-party software."
    echo "Each component is covered by the license reproduced below."
} > "$OUTPUT"

COUNT=0
for directory in "$CHECKOUTS"/*; do
    [ -d "$directory" ] || continue
    license="$(find "$directory" -maxdepth 1 -type f \
        \( -iname 'license' -o -iname 'license.*' -o -iname 'copying' -o -iname 'copying.*' \) \
        -print -quit)"
    if [ -z "$license" ]; then
        echo "error: '$(basename "$directory")' ships no license file" >&2
        rm -f "$OUTPUT"
        exit 1
    fi

    {
        echo
        echo "================================================================"
        echo "$(basename "$directory")"
        echo "================================================================"
        echo
        cat "$license"
    } >> "$OUTPUT"
    COUNT=$((COUNT + 1))
done

if [ "$COUNT" = 0 ]; then
    echo "error: no dependency checkouts found" >&2
    rm -f "$OUTPUT"
    exit 1
fi

echo "collected $COUNT third-party licenses into $OUTPUT"
