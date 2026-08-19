#!/usr/bin/env bash

_version_env_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -f "$_version_env_root/version.env" ]; then
    echo "error: $_version_env_root/version.env is missing" >&2
    return 1 2>/dev/null || exit 1
fi

source "$_version_env_root/version.env"

if ! printf '%s' "${MARKETING_VERSION:-}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "error: MARKETING_VERSION must look like 0.1.2, got '${MARKETING_VERSION:-}'" >&2
    return 1 2>/dev/null || exit 1
fi

if ! printf '%s' "${BUILD_NUMBER:-}" | grep -qE '^[1-9][0-9]*$'; then
    echo "error: BUILD_NUMBER must be a positive integer, got '${BUILD_NUMBER:-}'" >&2
    return 1 2>/dev/null || exit 1
fi

export MARKETING_VERSION BUILD_NUMBER
unset _version_env_root
