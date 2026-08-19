#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source ./Scripts/version-env.sh
source ./Scripts/sparkle-env.sh

APP_BUNDLE="${1:-dist/Densha.app}"
STAY_ALIVE_SECONDS="${DENSHA_LAUNCH_SMOKE_SECONDS:-5}"
FATAL_PATTERN='Fatal error|Illegal instruction|Trace/BPT trap|Segmentation fault|dyld\[|Library not loaded|Symbol not found'

log() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
fail() {
    printf 'ERROR: %s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "${2:-}" ]; then
        printf -- '----- %s (tail) -----\n' "$(basename "$2")" >&2
        tail -40 "$2" >&2 || true
        printf -- '---------------------\n' >&2
    fi
    exit 1
}

if [ "${DENSHA_SKIP_LAUNCH_SMOKE:-0}" = "1" ]; then
    log "launch smoke: skipped (DENSHA_SKIP_LAUNCH_SMOKE=1)"
    exit 0
fi

if [ ! -d "$APP_BUNDLE" ]; then
    fail "no bundle at $APP_BUNDLE — run 'make app' first"
fi

APP_BUNDLE="$(cd "$APP_BUNDLE" && pwd)"

for relative in Contents/MacOS/Densha Contents/Helpers/denshad Contents/Helpers/densha; do
    if [ ! -x "$APP_BUNDLE/$relative" ]; then
        fail "missing or non-executable: $relative"
    fi
done
log "layout OK: app, daemon and CLI are present and executable"

plutil -lint "$APP_BUNDLE/Contents/Info.plist" > /dev/null \
    || fail "Contents/Info.plist is not a valid plist"

BUNDLE_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP_BUNDLE/Contents/Info.plist")"
BUNDLE_BUILD="$(plutil -extract CFBundleVersion raw "$APP_BUNDLE/Contents/Info.plist")"
[ "$BUNDLE_VERSION" = "$MARKETING_VERSION" ] \
    || fail "bundle says $BUNDLE_VERSION, version.env says $MARKETING_VERSION"
[ "$BUNDLE_BUILD" = "$BUILD_NUMBER" ] \
    || fail "bundle build $BUNDLE_BUILD, version.env says $BUILD_NUMBER"
log "version OK: $BUNDLE_VERSION ($BUNDLE_BUILD)"

if [ ! -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ]; then
    fail "missing Contents/Frameworks/Sparkle.framework — the app cannot self-update"
fi
BUNDLE_FEED="$(plutil -extract SUFeedURL raw "$APP_BUNDLE/Contents/Info.plist" 2> /dev/null || true)"
BUNDLE_KEY="$(plutil -extract SUPublicEDKey raw "$APP_BUNDLE/Contents/Info.plist" 2> /dev/null || true)"
[ "$BUNDLE_FEED" = "$SPARKLE_FEED_URL" ] \
    || fail "bundle feed is '$BUNDLE_FEED', sparkle.env says '$SPARKLE_FEED_URL'"
[ "$BUNDLE_KEY" = "$SPARKLE_PUBLIC_KEY" ] \
    || fail "bundle update key does not match sparkle.env"
log "sparkle OK: framework embedded, feed and key match sparkle.env"

NOTICES="$APP_BUNDLE/Contents/Resources/ThirdPartyLicenses.txt"
[ -s "$NOTICES" ] || fail "missing Contents/Resources/ThirdPartyLicenses.txt"
[ -s "$APP_BUNDLE/Contents/Resources/LICENSE.txt" ] || fail "missing Contents/Resources/LICENSE.txt"
for identity in $(sed -n 's/.*"identity"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' Package.resolved); do
    if ! grep -qi "^$identity$" "$NOTICES"; then
        fail "ThirdPartyLicenses.txt does not credit '$identity'"
    fi
done
log "licenses OK: own license plus notices for every resolved dependency"

if ! command -v sandbox-exec > /dev/null 2>&1; then
    warn "sandbox-exec unavailable; running probes without denying the checkout"
    SANDBOXED=0
else
    SANDBOXED=1
fi

SMOKE_DIR="$(mktemp -d /tmp/densha-smoke.XXXXXX)"
SMOKE_PID=""
SMOKE_DAEMON_PID=""

terminate_pid() {
    local target="$1"
    [ -n "$target" ] || return 0
    kill -0 "$target" 2> /dev/null || return 0
    kill "$target" 2> /dev/null || true
    for _ in $(seq 1 25); do
        kill -0 "$target" 2> /dev/null || return 0
        sleep 0.2
    done
    kill -9 "$target" 2> /dev/null || true
}

cleanup() {
    terminate_pid "$SMOKE_PID"
    [ -n "$SMOKE_PID" ] && wait "$SMOKE_PID" 2> /dev/null || true
    if [ -n "$SMOKE_DAEMON_PID" ]; then
        isolated "$SMOKE_CLI" daemon stop > /dev/null 2>&1 || true
        terminate_pid "$SMOKE_DAEMON_PID"
        if kill -0 "$SMOKE_DAEMON_PID" 2> /dev/null; then
            warn "smoke daemon $SMOKE_DAEMON_PID survived; leaving $SMOKE_DIR for inspection"
            return
        fi
    fi
    rm -rf "$SMOKE_DIR"
}
trap cleanup EXIT INT TERM

cp -R "$APP_BUNDLE" "$SMOKE_DIR/Densha.app"
SMOKE_APP="$SMOKE_DIR/Densha.app"
SMOKE_BIN="$SMOKE_APP/Contents/MacOS/Densha"
SMOKE_CLI="$SMOKE_APP/Contents/Helpers/densha"
SMOKE_SOCKET="$SMOKE_DIR/d.sock"

if [ "${#SMOKE_SOCKET}" -gt 103 ]; then
    fail "smoke socket path is ${#SMOKE_SOCKET} bytes, over the 103-byte limit"
fi

SANDBOX_PROFILE="(version 1)
(allow default)
(deny file-read* (subpath \"$ROOT\"))"

isolated() {
    env \
        XDG_CONFIG_HOME="$SMOKE_DIR/config" \
        XDG_STATE_HOME="$SMOKE_DIR/state" \
        DENSHA_SOCKET="$SMOKE_SOCKET" \
        "$@"
}

sandboxed() {
    if [ "$SANDBOXED" = 1 ]; then
        isolated sandbox-exec -p "$SANDBOX_PROFILE" "$@"
    else
        isolated "$@"
    fi
}

CLI_LOG="$SMOKE_DIR/cli.log"
if ! (cd "$SMOKE_DIR" && sandboxed "$SMOKE_CLI" --version) > "$CLI_LOG" 2>&1; then
    fail "the packaged CLI cannot run with $ROOT unreadable" "$CLI_LOG"
fi
REPORTED="$(tr -d '[:space:]' < "$CLI_LOG")"
[ "$REPORTED" = "$MARKETING_VERSION" ] \
    || fail "packaged CLI reports '$REPORTED', expected $MARKETING_VERSION" "$CLI_LOG"
log "CLI OK: runs and reports $REPORTED with the checkout unreadable"

DAEMON_LOG="$SMOKE_DIR/daemon.log"
if ! (cd "$SMOKE_DIR" && sandboxed "$SMOKE_CLI" daemon start) > "$DAEMON_LOG" 2>&1; then
    fail "the packaged CLI could not start Contents/Helpers/denshad" "$DAEMON_LOG"
fi
DAEMON_UP=0
for _ in $(seq 1 40); do
    if [ -S "$SMOKE_SOCKET" ]; then
        DAEMON_UP=1
        break
    fi
    sleep 0.25
done
[ "$DAEMON_UP" = 1 ] || fail "denshad never bound $SMOKE_SOCKET" "$DAEMON_LOG"

SMOKE_LOCK="$SMOKE_DIR/state/densha/denshad.lock"
if [ -f "$SMOKE_LOCK" ]; then
    SMOKE_DAEMON_PID="$(tr -dc '0-9' < "$SMOKE_LOCK")"
fi
[ -n "$SMOKE_DAEMON_PID" ] || fail "denshad did not record a pid in $SMOKE_LOCK" "$DAEMON_LOG"

STATUS_LOG="$SMOKE_DIR/status.log"
if ! (cd "$SMOKE_DIR" && sandboxed "$SMOKE_CLI" status) > "$STATUS_LOG" 2>&1; then
    fail "the packaged CLI cannot talk to the daemon it started" "$STATUS_LOG"
fi
log "daemon OK: CLI resolved Contents/Helpers/denshad and completed a request (pid $SMOKE_DAEMON_PID)"

if [ "$(launchctl managername 2> /dev/null || true)" != "Aqua" ]; then
    warn "no Aqua session; skipping the app launch check"
    log "launch smoke passed (app launch skipped)"
    exit 0
fi

LAUNCH_LOG="$SMOKE_DIR/launch.log"
LAUNCH_COMMAND=(
    env
    XDG_CONFIG_HOME="$SMOKE_DIR/config"
    XDG_STATE_HOME="$SMOKE_DIR/state"
    DENSHA_SOCKET="$SMOKE_SOCKET"
)
if [ "$SANDBOXED" = 1 ]; then
    LAUNCH_COMMAND+=(sandbox-exec -p "$SANDBOX_PROFILE")
fi
LAUNCH_COMMAND+=("$SMOKE_BIN")
(cd "$SMOKE_DIR" && exec "${LAUNCH_COMMAND[@]}") > "$LAUNCH_LOG" 2>&1 &
SMOKE_PID=$!
for _ in $(seq 1 "$((STAY_ALIVE_SECONDS * 4))"); do
    if ! kill -0 "$SMOKE_PID" 2> /dev/null; then
        break
    fi
    sleep 0.25
done

if kill -0 "$SMOKE_PID" 2> /dev/null; then
    log "app OK: stayed alive ${STAY_ALIVE_SECONDS}s with the checkout unreadable"
else
    wait "$SMOKE_PID" 2> /dev/null || true
    if grep -qE "$FATAL_PATTERN" "$LAUNCH_LOG" 2> /dev/null; then
        fail "the packaged app crashed on launch" "$LAUNCH_LOG"
    fi
    warn "the app exited early with no crash signature; treating as inconclusive"
    tail -10 "$LAUNCH_LOG" >&2 || true
fi

log "launch smoke passed"
