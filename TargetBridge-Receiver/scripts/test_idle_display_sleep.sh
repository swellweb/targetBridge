#!/bin/bash
# Run in a logged-in GUI session with all real Senders disconnected.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/TBReceiverC/tbreceiver"
LOG="$(mktemp -t tb-idle-sleep)"
PID=""

cleanup() {
    if [[ -n "$PID" ]]; then
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if lsof -nP -iTCP:54321 -sTCP:LISTEN >/dev/null 2>&1; then
    echo "Port 54321 is already in use; leaving the existing Receiver untouched." >&2
    exit 2
fi
if [[ ! -x "$BIN" ]]; then
    echo "Build the Receiver with make before running this GUI-session test." >&2
    exit 2
fi

TB_LANG=en "$BIN" --windowed >"$LOG" 2>&1 &
PID=$!
for ((i=0; i<50; i++)); do
    kill -0 "$PID"
    if grep -q 'display sleep enabled while receiver is idle' "$LOG"; then break; fi
    sleep 0.1
done
grep -q 'display sleep enabled while receiver is idle' "$LOG"
sleep 1
if grep -q 'client connected' "$LOG"; then
    echo "INCONCLUSIVE: another Sender connected before the idle check. Disconnect it and retry." >&2
    exit 2
fi

check_idle() {
    local assertions
    assertions="$(pmset -g assertions)"
    if grep -E "pid ${PID}\\([^)]*\\):.*PreventUserIdleDisplaySleep" <<<"$assertions"; then
        echo "FAIL: Receiver owns a display-sleep assertion while idle ($1)." >&2
        exit 1
    fi
    kill -0 "$PID"
    echo "PASS: Receiver permits idle display sleep ($1)."
}

check_idle 'before first connection'
python3 "$ROOT/TBReceiverC/tests/mock_sender.py" --mode handshake --duration 1
for ((i=0; i<50; i++)); do
    if grep -q 'client disconnected' "$LOG"; then break; fi
    sleep 0.1
done
grep -q 'client disconnected' "$LOG"
sleep 1
if [[ "$(grep -c 'client connected' "$LOG")" != 1 ]]; then
    echo "INCONCLUSIVE: another Sender connected during the test." >&2
    exit 2
fi
check_idle 'after session teardown'
echo "Receiver log: $LOG"
