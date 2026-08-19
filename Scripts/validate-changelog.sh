#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CHANGELOG="CHANGELOG.md"
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    source ./Scripts/version-env.sh
    VERSION="$MARKETING_VERSION"
fi

if [ ! -f "$CHANGELOG" ]; then
    echo "error: no $CHANGELOG" >&2
    exit 1
fi

FIRST_SECTION="$(grep -m1 '^## ' "$CHANGELOG" | sed 's/^## //')"
if [ -z "$FIRST_SECTION" ]; then
    echo "error: $CHANGELOG has no '## <version>' section" >&2
    exit 1
fi

case "$FIRST_SECTION" in
    "$VERSION"*) ;;
    *)
        echo "error: the top $CHANGELOG section is '$FIRST_SECTION', expected '$VERSION — <date>'" >&2
        echo "  rename the Unreleased section before releasing $VERSION" >&2
        exit 1
        ;;
esac

if ! grep -qE "^## ${VERSION} — [0-9]{4}-[0-9]{2}-[0-9]{2}$" "$CHANGELOG"; then
    echo "error: no '## $VERSION — YYYY-MM-DD' heading in $CHANGELOG" >&2
    exit 1
fi

BODY="$(./Scripts/changelog-section.sh "$VERSION")"
if [ -z "$(printf '%s' "$BODY" | tr -d '[:space:]')" ]; then
    echo "error: the $VERSION section in $CHANGELOG is empty" >&2
    exit 1
fi

echo "changelog OK for $VERSION"
