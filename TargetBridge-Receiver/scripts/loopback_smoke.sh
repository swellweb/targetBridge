#!/bin/zsh
# loopback_smoke.sh — end-to-end receiver smoke test on one Mac, no
# Thunderbolt hardware and no real sender.
#
# Builds the receiver, runs it windowed, then drives it over 127.0.0.1 with
# tests/mock_sender.py through four phases:
#   1. handshake     -> receiver logs the sender hello
#   2. badlen        -> parser rejects a corrupt length and disconnects
#   3. hang          -> idle watchdog reaps a silent sender (~10s)
#   4. stream        -> real H.264 decode (skipped without ffmpeg CLI or
#                       with --no-stream)
#
# Needs a GUI session (SDL window) and the receiver build deps
# (brew install ffmpeg sdl2 pkgconf). Exits non-zero on any failed phase.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$ROOT/TBReceiverC"
LOG="$(mktemp -t tb_smoke_receiver.err)"
MOCK="$SRC/tests/mock_sender.py"
NO_STREAM=0
[[ "${1:-}" == "--no-stream" ]] && NO_STREAM=1

FAILURES=0
RECEIVER_PID=""

phase() { print -P "%B== $1 ==%b"; }
pass()  { print -P "%F{green}PASS%f  $1"; }
fail()  { print -P "%F{red}FAIL%f  $1"; FAILURES=$((FAILURES + 1)); }

expect_log() {
    local needle="$1" what="$2" tries=0
    while (( tries < 20 )); do
        if grep -qF "$needle" "$LOG"; then pass "$what"; return 0; fi
        sleep 0.5; tries=$((tries + 1))
    done
    fail "$what (missing log line: $needle)"
    return 1
}

cleanup() {
    [[ -n "$RECEIVER_PID" ]] && kill "$RECEIVER_PID" 2>/dev/null
    wait 2>/dev/null
}
trap cleanup EXIT INT TERM

phase "Build receiver"
if ! make -C "$SRC" >/dev/null; then
    print "receiver build failed"; exit 1
fi
pass "build"

phase "Launch receiver (windowed, log -> $LOG)"
TB_LANG=en "$SRC/tbreceiver" --windowed 2>"$LOG" &
RECEIVER_PID=$!
sleep 2
if ! kill -0 "$RECEIVER_PID" 2>/dev/null; then
    print "receiver exited early:"; tail -5 "$LOG"; exit 1
fi
pass "receiver running (pid $RECEIVER_PID)"

phase "Phase 1: handshake"
python3 "$MOCK" --mode handshake --duration 3 || fail "mock handshake exited non-zero"
expect_log "[main] hello from sender" "receiver saw HELLO"
expect_log "[main] teardown requested by sender" "receiver honored TEARDOWN"
sleep 1

phase "Phase 2: corrupt length"
python3 "$MOCK" --mode badlen || fail "mock badlen exited non-zero"
expect_log "bad pkt_len=4294967295" "parser rejected corrupt length"
expect_log "[main] client disconnected" "receiver dropped the corrupt session"
sleep 1

phase "Phase 3: silent sender (idle watchdog)"
python3 "$MOCK" --mode hang --duration 14 || fail "mock hang exited non-zero"
expect_log "closing stale session" "idle watchdog reaped silent sender"
sleep 1

phase "Phase 4: H.264 stream"
if (( NO_STREAM )) || ! command -v ffmpeg >/dev/null; then
    print "skipped (no ffmpeg or --no-stream)"
else
    python3 "$MOCK" --mode stream --duration 4 || fail "mock stream exited non-zero"
    expect_log "param sets changed, opening decoder" "decoder accepted param sets"
    expect_log "[disp] texture " "receiver rendered decoded video"
fi

print ""
if (( FAILURES == 0 )); then
    print -P "%F{green}loopback smoke: all phases passed%f"
    exit 0
fi
print -P "%F{red}loopback smoke: $FAILURES failure(s)%f — log: $LOG"
exit 1
