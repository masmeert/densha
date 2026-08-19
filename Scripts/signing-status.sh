#!/usr/bin/env bash
set -euo pipefail

echo "codesigning identities in this keychain:"
security find-identity -v -p codesigning 2> /dev/null | sed 's/^/  /' || echo "  (none)"
echo

COMMON_NAME=$(security find-identity -v -p codesigning 2> /dev/null \
    | grep -m1 -E 'Developer ID Application|Apple Development' \
    | sed -E 's/^[^"]*"([^"]*)".*/\1/')
TEAM_ID=$(security find-certificate -c "$COMMON_NAME" -p 2> /dev/null \
    | openssl x509 -noout -subject 2> /dev/null \
    | tr '/' '\n' | sed -n 's/^OU=//p' | head -1)

if security find-identity -v -p codesigning 2> /dev/null | grep -q 'Developer ID Application'; then
    echo "Developer ID Application: present — 'make notarize' will pick it up"
else
    echo "Developer ID Application: MISSING (local ad-hoc builds still work here)"
    echo
    echo "Xcode only auto-issues 'Apple Development' certificates; a Developer ID"
    echo "must be added by hand. Requires a paid membership and Account Holder/Admin:"
    echo "  Xcode > Settings > Accounts > select the team"
    echo "    > Manage Certificates > + > Developer ID Application"
fi
echo

if [ -n "$TEAM_ID" ]; then
    echo "team id (from certificate OU): $TEAM_ID"
else
    echo "no Apple certificate found, so no team id to report"
fi
echo

echo "notary credentials — 'make notarize' uses the first that is complete:"
if [ -n "${NOTARY_ASC_KEY_P8:-}" ] && [ -n "${NOTARY_ASC_KEY_ID:-}" ] \
    && [ -n "${NOTARY_ASC_ISSUER_ID:-}" ]; then
    echo "  1. App Store Connect API key: set"
else
    echo "  1. App Store Connect API key: not set (preferred — survives password rotation)"
    echo "     Create one at appstoreconnect.apple.com > Users and Access > Integrations >"
    echo "     App Store Connect API, role 'Developer', then set:"
    echo "       NOTARY_ASC_KEY_ID, NOTARY_ASC_ISSUER_ID, NOTARY_ASC_KEY_P8 (the .p8 contents)"
fi

printf "  2. keychain profile '%s': " "${NOTARY_PROFILE:-densha}"
if xcrun notarytool history --keychain-profile "${NOTARY_PROFILE:-densha}" > /dev/null 2>&1; then
    echo "configured"
else
    echo "not configured"
    if [ -n "$TEAM_ID" ]; then
        echo "     xcrun notarytool store-credentials densha \\"
        echo "       --apple-id YOUR_APPLE_ID --team-id $TEAM_ID"
        echo "     (password is an app-specific password from appleid.apple.com)"
    fi
fi

if [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ]; then
    echo "  3. Apple ID and app-specific password: set"
else
    echo "  3. Apple ID and app-specific password: not set"
fi
