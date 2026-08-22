#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source ./Scripts/version-env.sh
source ./Scripts/sparkle-env.sh

APPCAST="appcast.xml"

if [ ! -f "$APPCAST" ]; then
    echo "error: no $APPCAST — run 'make appcast'" >&2
    exit 1
fi

xmllint --noout "$APPCAST" 2> /dev/null || {
    echo "error: $APPCAST is not well-formed XML" >&2
    exit 1
}

# xmllint --xpath cannot resolve the sparkle: prefix, and Sparkle accepts these
# either as item child elements or as enclosure attributes, so match on
# local-name() and try both placements.
read_value() {
    local value
    value="$(xmllint --xpath "string(//item[1]/*[local-name()='$1'])" "$APPCAST" 2> /dev/null || true)"
    if [ -z "$value" ]; then
        value="$(xmllint --xpath "string(//item[1]/enclosure/@*[local-name()='$1'])" \
            "$APPCAST" 2> /dev/null || true)"
    fi
    printf '%s' "$value"
}

SHORT_VERSION="$(read_value shortVersionString)"
BUILD="$(read_value version)"
SIGNATURE="$(read_value edSignature)"
URL="$(xmllint --xpath "string(//item[1]/enclosure/@url)" "$APPCAST" 2> /dev/null || true)"

fail() {
    echo "error: $1" >&2
    exit 1
}

[ -n "$SIGNATURE" ] || fail "the newest item has no sparkle:edSignature — updates would be rejected"

DESCRIPTION="$(xmllint --xpath "string(//item[1]/description)" "$APPCAST" 2> /dev/null || true)"
[ -n "$(printf '%s' "$DESCRIPTION" | tr -d '[:space:]')" ] \
    || fail "the newest item has no release notes — the update dialog would be empty"
[ "$SHORT_VERSION" = "$MARKETING_VERSION" ] \
    || fail "newest item is $SHORT_VERSION, version.env says $MARKETING_VERSION"
[ "$BUILD" = "$BUILD_NUMBER" ] \
    || fail "newest item is build $BUILD, version.env says $BUILD_NUMBER"

case "$URL" in
    https://github.com/masmeert/densha/releases/download/v$MARKETING_VERSION/*) ;;
    *) fail "newest item points at an unexpected URL: $URL" ;;
esac

echo "appcast OK: $SHORT_VERSION ($BUILD), signed, notes present, $URL"
