#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:?usage: changelog-section.sh <version>}"

# Print this version's section, trimmed of leading and trailing blank lines.
awk -v version="$VERSION" '
    /^## / {
        if (inside) { exit }
        heading = substr($0, 4)
        if (heading == version || index(heading, version " ") == 1) { inside = 1; next }
    }
    !inside { next }
    /^[[:space:]]*$/ { if (started) { pending = pending $0 "\n" }; next }
    { printf "%s", pending; pending = ""; started = 1; print }
' CHANGELOG.md
