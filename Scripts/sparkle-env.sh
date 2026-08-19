#!/usr/bin/env bash

_sparkle_env_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -f "$_sparkle_env_root/sparkle.env" ]; then
    echo "error: $_sparkle_env_root/sparkle.env is missing" >&2
    return 1 2>/dev/null || exit 1
fi

source "$_sparkle_env_root/sparkle.env"

if [ -z "${SPARKLE_PUBLIC_KEY:-}" ]; then
    echo "error: SPARKLE_PUBLIC_KEY is empty in sparkle.env" >&2
    return 1 2>/dev/null || exit 1
fi

if [ -z "${SPARKLE_FEED_URL:-}" ]; then
    echo "error: SPARKLE_FEED_URL is empty in sparkle.env" >&2
    return 1 2>/dev/null || exit 1
fi

export SPARKLE_PUBLIC_KEY SPARKLE_FEED_URL
unset _sparkle_env_root
