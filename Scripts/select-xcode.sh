#!/usr/bin/env bash
# CI helper: pin the newest Xcode 26 the runner offers.
set -euo pipefail

for candidate in /Applications/Xcode_26.4.app \
                 /Applications/Xcode_26.3.app \
                 /Applications/Xcode_26.2.app; do
    if [ -d "$candidate" ]; then
        sudo xcode-select -s "$candidate/Contents/Developer"
        echo "DEVELOPER_DIR=$candidate/Contents/Developer" >> "$GITHUB_ENV"
        break
    fi
done
version="$(xcodebuild -version)"
version="${version%%$'\n'*}"
case "$version" in
    "Xcode 26."*) ;;
    *)
        echo "::error::expected Xcode 26.x, runner offers '$version'"
        exit 1
        ;;
esac
