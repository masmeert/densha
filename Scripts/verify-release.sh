#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="${1:-dist/Densha.app}"

if ! xcrun stapler validate "$APP" > /dev/null 2>&1; then
    echo "FAIL: no stapled notarization ticket" >&2
    exit 1
fi

if codesign -dv "$APP" 2>&1 | grep -q 'adhoc'; then
    echo "FAIL: bundle is ad-hoc signed" >&2
    exit 1
fi

# spctl is soft-deprecated; syspolicy_check is the current distribution check.
if command -v syspolicy_check > /dev/null 2>&1; then
    output=$(syspolicy_check distribution "$APP" 2>&1) || true
else
    output=$(spctl -a -t exec -vv "$APP" 2>&1) || true
fi
echo "$output" | sed 's/^/  /'

if ! echo "$output" | grep -qE 'accepted|passed'; then
    echo "FAIL: Gatekeeper did not accept the bundle" >&2
    exit 1
fi

echo "  OK: notarized, stapled, accepted"
