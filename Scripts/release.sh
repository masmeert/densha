#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: make release VERSION=0.1.2" >&2
    exit 1
fi

case "$VERSION" in
    v*)
        echo "drop the leading v: VERSION=${VERSION#v}" >&2
        exit 1
        ;;
esac

if ! printf '%s' "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "VERSION must look like 0.1.2" >&2
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "working tree is dirty — commit or stash first" >&2
    exit 1
fi

BRANCH="$(git branch --show-current)"
if [ "$BRANCH" != "main" ]; then
    echo "releases are cut from main, not $BRANCH" >&2
    exit 1
fi

if git rev-parse -q --verify "refs/tags/v$VERSION" > /dev/null; then
    echo "tag v$VERSION already exists" >&2
    exit 1
fi

source ./Scripts/version-env.sh
PREVIOUS_VERSION="$MARKETING_VERSION"
NEXT_BUILD_NUMBER=$((BUILD_NUMBER + 1))

cat > version.env <<ENV
MARKETING_VERSION=$VERSION
BUILD_NUMBER=$NEXT_BUILD_NUMBER
ENV

./Scripts/sync-version.sh

echo "==> $PREVIOUS_VERSION -> $VERSION (build $NEXT_BUILD_NUMBER)"

make --no-print-directory lint
make --no-print-directory test

git add version.env Sources/DenshaCore/Version.swift
git commit -m "chore: release v$VERSION"
git tag "v$VERSION"
git push origin main "v$VERSION"

echo "pushed v$VERSION — follow it with: gh run watch"
echo
echo "once CI has published the release, make the update visible to existing installs:"
echo "  make appcast && git add appcast.xml && git commit -m 'chore: appcast for v$VERSION' && git push"
