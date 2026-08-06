#!/bin/zsh
# Integration smoke test for the safety properties of "Usa iMac": a persisted
# stopped state rejects reconnecting Senders, and only one Receiver may run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$ROOT/TBReceiverC"
TEST_ROOT="$(mktemp -d /private/tmp/targetbridge-monitor-mode-smoke.XXXXXX)"
STATE_HOME="$TEST_ROOT/home"
STATE_DIR="$STATE_HOME/Library/Application Support/TargetBridge/Receiver"
PRIMARY_LOG="$TEST_ROOT/primary.err"
SECONDARY_LOG="$TEST_ROOT/secondary.err"
PRIMARY_PID=""
FAILURES=0
RECEIVER_BIN="${TB_RECEIVER_EXECUTABLE:-}"

pass() { print -P "%F{green}PASS%f  $1"; }
fail() { print -P "%F{red}FAIL%f  $1"; FAILURES=$((FAILURES + 1)); }

wait_for_listener() {
    local pid="$1" tries=0
    while (( tries < 100 )); do
        if /usr/sbin/lsof -nP -a -p "$pid" -iTCP:54321 -sTCP:LISTEN >/dev/null 2>&1; then
            return 0
        fi
        kill -0 "$pid" >/dev/null 2>&1 || return 1
        /bin/sleep 0.1
        tries=$((tries + 1))
    done
    return 1
}

cleanup() {
    if [[ -n "$PRIMARY_PID" ]]; then
        kill "$PRIMARY_PID" >/dev/null 2>&1 || true
        wait "$PRIMARY_PID" >/dev/null 2>&1 || true
    fi
    /bin/rm -rf "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

if [[ -z "$RECEIVER_BIN" ]]; then
    TB_BUILD_DIR="$TEST_ROOT/build" \
        TB_SKIP_BUNDLE_DYLIBS=1 \
        "$SCRIPT_DIR/build_tbreceiver_c_app.sh" >/dev/null || {
        print -u2 -- "Receiver app build failed"
        exit 1
    }
    RECEIVER_BIN="$TEST_ROOT/build/TargetBridge Receiver.app/Contents/MacOS/TargetBridgeReceiver"
fi
[[ -x "$RECEIVER_BIN" ]] || {
    print -u2 -- "Receiver executable not found: $RECEIVER_BIN"
    exit 1
}

/bin/mkdir -p "$STATE_DIR"
(
    umask 077
    print -- "version=1"
    print -- "enabled=0"
    print -- "action=path auto"
) > "$STATE_DIR/monitor-mode.state"

env TB_RECEIVER_STATE_HOME="$STATE_HOME" TB_LANG=en \
    "$RECEIVER_BIN" --windowed 2>"$PRIMARY_LOG" &
PRIMARY_PID=$!
if wait_for_listener "$PRIMARY_PID"; then
    pass "stopped Receiver remains available and listening locally"
else
    fail "stopped Receiver did not reach its local listener"
    /usr/bin/tail -n 20 "$PRIMARY_LOG" >&2
fi

python3 "$SRC/tests/mock_sender.py" --mode handshake --duration 1 >/dev/null 2>&1 || true
/bin/sleep 1
if /usr/bin/grep -qF "rejecting client while monitor mode is suspended" "$PRIMARY_LOG"; then
    pass "persisted Usa iMac state rejects a reconnecting Sender"
else
    fail "reconnecting Sender was not explicitly rejected"
fi
if /usr/bin/grep -qF "hello from sender" "$PRIMARY_LOG"; then
    fail "a stopped Receiver processed a Sender session"
else
    pass "stopped Receiver never enters a Sender session"
fi

env TB_RECEIVER_STATE_HOME="$STATE_HOME" TB_LANG=en \
    "$RECEIVER_BIN" --windowed 2>"$SECONDARY_LOG"
secondary_status=$?
if [[ $secondary_status -eq 0 ]] &&
   /usr/bin/grep -qF "another Receiver instance is already running" "$SECONDARY_LOG"; then
    pass "second Receiver instance exits cleanly"
else
    fail "second Receiver instance was not blocked by the ownership lock"
fi

if (( FAILURES == 0 )); then
    print -P "%F{green}monitor-mode smoke: all phases passed%f"
    exit 0
fi
print -P "%F{red}monitor-mode smoke: $FAILURES failure(s)%f"
exit 1
