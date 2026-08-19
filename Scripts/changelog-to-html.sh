#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    source ./Scripts/version-env.sh
    VERSION="$MARKETING_VERSION"
fi

./Scripts/changelog-section.sh "$VERSION" | awk -v version="$VERSION" '
function escape(text) {
    gsub(/&/, "\\&amp;", text)
    gsub(/</, "\\&lt;", text)
    gsub(/>/, "\\&gt;", text)
    return text
}

function inline(text,    inner) {
    while (match(text, /\*\*[^*]+\*\*/)) {
        inner = substr(text, RSTART + 2, RLENGTH - 4)
        text = substr(text, 1, RSTART - 1) "<strong>" inner "</strong>" \
            substr(text, RSTART + RLENGTH)
    }
    while (match(text, /`[^`]+`/)) {
        inner = substr(text, RSTART + 1, RLENGTH - 2)
        text = substr(text, 1, RSTART - 1) "<code>" inner "</code>" \
            substr(text, RSTART + RLENGTH)
    }
    return text
}

function close_list() {
    if (in_list) { print "</ul>"; in_list = 0 }
}

BEGIN { printf "<h2>Densha %s</h2>\n", version }

/^### / {
    close_list()
    printf "<h3>%s</h3>\n", inline(escape(substr($0, 5)))
    next
}

/^[[:space:]]*-[[:space:]]/ {
    if (!in_list) { print "<ul>"; in_list = 1 }
    sub(/^[[:space:]]*-[[:space:]]+/, "")
    printf "<li>%s</li>\n", inline(escape($0))
    next
}

/^[[:space:]]*$/ { close_list(); next }

{
    close_list()
    printf "<p>%s</p>\n", inline(escape($0))
}

END { close_list() }
'
