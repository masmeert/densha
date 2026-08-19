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

# Package.resolved is the authoritative dependency list, so a newly added
# dependency cannot ship without its notice going unnoticed.
IDENTITIES="$(sed -n 's/.*"identity"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' Package.resolved)"
if [ -z "$IDENTITIES" ]; then
    echo "error: no dependencies found in Package.resolved" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
{
    echo "Densha bundles the following third-party software."
    echo "Each component is covered by the license reproduced below."
} > "$OUTPUT"

MISSING=0
for identity in $IDENTITIES; do
    directory=""
    for candidate in "$CHECKOUTS"/*; do
        [ -d "$candidate" ] || continue
        name="$(basename "$candidate")"
        lowered="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
        if [ "$lowered" = "$identity" ]; then
            directory="$candidate"
            break
        fi
    done

    if [ -z "$directory" ]; then
        echo "error: no checkout for '$identity' — cannot collect its license" >&2
        MISSING=1
        continue
    fi

    license=""
    for candidate in "$directory"/LICENSE "$directory"/LICENSE.* "$directory"/COPYING*; do
        if [ -f "$candidate" ]; then
            license="$candidate"
            break
        fi
    done

    if [ -z "$license" ]; then
        echo "error: '$identity' ships no license file — attribution would be incomplete" >&2
        MISSING=1
        continue
    fi

    location="$(sed -n "/\"identity\"[[:space:]]*:[[:space:]]*\"$identity\"/,/}/p" Package.resolved \
        | sed -n 's/.*"location"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"

    {
        echo
        echo "================================================================"
        echo "$(basename "$directory")"
        [ -n "$location" ] && echo "$location"
        echo "================================================================"
        echo
        cat "$license"
    } >> "$OUTPUT"
done

if [ "$MISSING" != 0 ]; then
    rm -f "$OUTPUT"
    exit 1
fi

COUNT="$(printf '%s\n' $IDENTITIES | wc -l | tr -d ' ')"
echo "collected $COUNT third-party licenses into $OUTPUT"
