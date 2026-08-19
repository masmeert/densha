#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source ./Scripts/version-env.sh
source ./Scripts/sparkle-env.sh

TAG="v$MARKETING_VERSION"
ASSET="Densha-$MARKETING_VERSION-universal.zip"
STAGING="dist/appcast-staging"
APPCAST="appcast.xml"
TOOLS=".build/artifacts/sparkle/Sparkle/bin"

if [ ! -x "$TOOLS/generate_appcast" ]; then
    echo "error: $TOOLS/generate_appcast is missing — run 'swift build' first" >&2
    exit 1
fi

PUBLIC_KEY="$("$TOOLS/generate_keys" -p 2> /dev/null || true)"
if [ -z "$PUBLIC_KEY" ]; then
    echo "error: no Sparkle private key in the keychain." >&2
    echo "  Without it you cannot sign updates that existing installs will accept." >&2
    echo "  Restore your backup, or run '$TOOLS/generate_keys' to start over" >&2
    echo "  (a new key orphans every already-installed copy)." >&2
    exit 1
fi
if [ "$PUBLIC_KEY" != "$SPARKLE_PUBLIC_KEY" ]; then
    echo "error: the keychain private key does not match sparkle.env" >&2
    echo "  keychain:    $PUBLIC_KEY" >&2
    echo "  sparkle.env: $SPARKLE_PUBLIC_KEY" >&2
    echo "  shipped apps only trust the key in sparkle.env" >&2
    exit 1
fi

if ! gh release view "$TAG" > /dev/null 2>&1; then
    echo "error: no published release $TAG — tag and let CI publish it first" >&2
    exit 1
fi

rm -rf "$STAGING"
mkdir -p "$STAGING"

# generate_appcast updates an existing feed in place, so seed the staging
# directory with the current one to keep older entries.
if [ -f "$APPCAST" ]; then
    cp "$APPCAST" "$STAGING/$(basename "$APPCAST")"
fi

echo "==> downloading $ASSET from $TAG"
gh release download "$TAG" --pattern "$ASSET" --dir "$STAGING"

echo "==> generating the appcast"
"$TOOLS/generate_appcast" \
    --download-url-prefix "https://github.com/masmeert/densha/releases/download/$TAG/" \
    --link "https://github.com/masmeert/densha" \
    --maximum-deltas 0 \
    "$STAGING"

if [ ! -f "$STAGING/$(basename "$APPCAST")" ]; then
    echo "error: generate_appcast produced no $APPCAST" >&2
    exit 1
fi
cp "$STAGING/$(basename "$APPCAST")" "$APPCAST"

./Scripts/verify-appcast.sh
