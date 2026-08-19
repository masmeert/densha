#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source ./Scripts/version-env.sh

APP="dist/Densha.app"
ZIP="dist/Densha.zip"
DITTO="${DITTO_BIN:-/usr/bin/ditto}"

IDENTITY="${DENSHA_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning 2> /dev/null \
        | grep -m1 'Developer ID Application' \
        | sed -E 's/^[^"]*"([^"]*)".*/\1/')
fi
if [ -z "$IDENTITY" ]; then
    echo "no Developer ID Application certificate found." >&2
    echo "an 'Apple Development' certificate cannot notarize — run 'make signing'." >&2
    exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/densha-notarize.XXXXXX")"
chmod 700 "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

NOTARY_ARGS=()
if [ -n "${NOTARY_ASC_KEY_P8:-}" ] && [ -n "${NOTARY_ASC_KEY_ID:-}" ] \
    && [ -n "${NOTARY_ASC_ISSUER_ID:-}" ]; then
    KEY_PATH="$WORK_DIR/asc-key.p8"
    (
        umask 077
        printf '%s' "$NOTARY_ASC_KEY_P8" | sed 's/\\n/\n/g' > "$KEY_PATH"
    )
    chmod 600 "$KEY_PATH"
    NOTARY_ARGS=(--key "$KEY_PATH" --key-id "$NOTARY_ASC_KEY_ID" --issuer "$NOTARY_ASC_ISSUER_ID")
    echo "==> notarizing with an App Store Connect API key"
elif [ -n "${NOTARY_PROFILE:-}" ]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
    echo "==> notarizing with keychain profile '$NOTARY_PROFILE'"
elif [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ] \
    && [ -n "${NOTARY_TEAM_ID:-}" ]; then
    NOTARY_ARGS=(
        --apple-id "$NOTARY_APPLE_ID"
        --team-id "$NOTARY_TEAM_ID"
        --password "$NOTARY_PASSWORD"
    )
    echo "==> notarizing with an Apple ID and app-specific password"
else
    cat >&2 <<'USAGE'
no notary credentials. Provide one of, in order of preference:
  NOTARY_ASC_KEY_P8 + NOTARY_ASC_KEY_ID + NOTARY_ASC_ISSUER_ID  (App Store Connect API key)
  NOTARY_PROFILE=<name>                                         (a stored keychain profile)
  NOTARY_APPLE_ID + NOTARY_PASSWORD + NOTARY_TEAM_ID            (app-specific password)
run 'make signing' for the one-time setup.
USAGE
    exit 1
fi

echo "==> signing as $IDENTITY"
DENSHA_SIGN_IDENTITY="$IDENTITY" ./Scripts/build-app.sh release

# AppleDouble files break code sealing once the bundle has been zipped and
# unzipped on another machine, so strip extended attributes before every ditto.
scrub_bundle() {
    xattr -cr "$APP"
    find "$APP" -name '._*' -delete
}

scrub_bundle
NOTARIZE_ZIP="$WORK_DIR/DenshaNotarize.zip"
"$DITTO" --norsrc -c -k --keepParent "$APP" "$NOTARIZE_ZIP"

echo "==> submitting for notarization"
xcrun notarytool submit "$NOTARIZE_ZIP" "${NOTARY_ARGS[@]}" --wait

echo "==> stapling"
xcrun stapler staple "$APP"

scrub_bundle
rm -f "$ZIP"
"$DITTO" --norsrc -c -k --keepParent "$APP" "$ZIP"

./Scripts/package-dsyms.sh

echo "==> stapled; $ZIP is the release asset"
