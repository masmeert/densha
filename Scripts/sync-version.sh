#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="${1:-write}"
case "$MODE" in
    write | --write) MODE=write ;;
    --check | check) MODE=check ;;
    *)
        echo "usage: $(basename "$0") [--write|--check]" >&2
        exit 2
        ;;
esac

source ./Scripts/version-env.sh

GENERATED="Sources/DenshaCore/Version.swift"

render() {
    cat <<SWIFT
public enum DenshaVersion {
    public static let marketing = "$MARKETING_VERSION"
    public static let build = "$BUILD_NUMBER"
}
SWIFT
}

if [ "$MODE" = check ]; then
    if [ ! -f "$GENERATED" ]; then
        echo "error: $GENERATED is missing — run 'make version'" >&2
        exit 1
    fi
    if ! diff -u "$GENERATED" <(render) > /dev/null; then
        echo "error: $GENERATED is stale — run 'make version'" >&2
        diff -u "$GENERATED" <(render) || true
        exit 1
    fi
    echo "version OK: $MARKETING_VERSION ($BUILD_NUMBER)"
    exit 0
fi

render > "$GENERATED"
echo "wrote $GENERATED: $MARKETING_VERSION ($BUILD_NUMBER)"
