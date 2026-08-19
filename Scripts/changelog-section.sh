#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:?usage: changelog-section.sh <version>}"

awk -v version="$VERSION" '
    /^## / {
        if (inside) { exit }
        heading = substr($0, 4)
        if (heading == version || index(heading, version " ") == 1) { inside = 1; next }
    }
    inside { print }
' CHANGELOG.md | sed -e '/./,$!d' | awk '
    { lines[NR] = $0 }
    END {
        last = NR
        while (last > 0 && lines[last] ~ /^[[:space:]]*$/) { last-- }
        for (i = 1; i <= last; i++) { print lines[i] }
    }
'
