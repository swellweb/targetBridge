# Testing TargetBridge Without Hardware

Everything on this page runs on one Mac with **no Thunderbolt cable, no
second machine, and no Apple Silicon requirement** (except where noted).
CI runs the first two suites on every push/PR.

## 1. Sender unit tests (Swift)

Covers the wire protocol (framing, corrupt-length rejection, unknown-type
skipping, input-event encoder parity with `JSONDecoder`), the discovered-
receiver model (which IP is dialed per transport), connection diagnostics
(link-local interface scoping, failure-detail composition), and the
automation parsers behind `targetbridge://` URLs and `--connect` launch args.

```bash
cd TargetBridge-Sender
xcodegen generate     # only needed after changing project.yml or adding files
xcodebuild test -project TargetBridge.xcodeproj -scheme TBDisplaySender -destination 'platform=macOS'
```

Test sources live in `TargetBridge-Sender/TBDisplaySenderTests/`.

## 2. Receiver parser tests (C)

Unit tests for the streaming packet parser in `net.c` — fragmented and
contiguous feeds, the NUL-sentinel guarantee, corrupt/oversized length
rejection, and multi-megabyte payloads fed in socket-sized chunks.
Pure POSIX: needs **no ffmpeg, SDL, or pkgconf**.

```bash
cd TargetBridge-Receiver/TBReceiverC
make test
```

Test sources live in `TargetBridge-Receiver/TBReceiverC/tests/`.

## 3. Mock sender (protocol-level fault injection)

`TargetBridge-Receiver/TBReceiverC/tests/mock_sender.py` (stdlib-only
Python 3) speaks the full wire protocol against a running receiver:

| Mode        | What it exercises                                              |
|-------------|----------------------------------------------------------------|
| `handshake` | HELLO / heartbeat / TEARDOWN lifecycle                          |
| `stream`    | PARAM_SETS + AVCC H.264 frames (generated via the ffmpeg CLI)   |
| `hang`      | idle watchdog: silent sender is reaped after ~10s               |
| `badlen`    | parser rejects a corrupt `0xFFFFFFFF` length and disconnects    |
| `drop`      | abrupt mid-packet disconnect returns receiver to waiting        |

```bash
# terminal 1
cd TargetBridge-Receiver/TBReceiverC && make && ./tbreceiver --windowed

# terminal 2
python3 TargetBridge-Receiver/TBReceiverC/tests/mock_sender.py --mode stream --duration 5
```

## 4. Loopback smoke test (one command)

Builds the receiver, launches it windowed, and drives all mock-sender
phases with pass/fail assertions on the receiver's log:

```bash
TargetBridge-Receiver/scripts/loopback_smoke.sh            # full run
TargetBridge-Receiver/scripts/loopback_smoke.sh --no-stream  # skip the H.264 phase
```

Needs a GUI session (an SDL window opens briefly) and the receiver build
deps (`brew install ffmpeg sdl2 pkgconf`), so it is a local dev tool rather
than a CI job.

## 5. Real sender ↔ receiver on one Mac (no cable)

The receiver binds `0.0.0.0:54321` and accepts any peer, so an Apple
Silicon Mac can stream to a receiver running on itself over the LAN
interface (the sender refuses `127.0.0.1`, so use the machine's own LAN IP
for both ends):

```bash
open build/TargetBridge.app   # sender: pick the LAN interface, enter the Mac's own LAN IP
./tbreceiver --windowed       # receiver on the same Mac
```

This exercises the true capture → encode → decode → render path minus the
Thunderbolt link itself.

## Debugging a live connection

The sender logs its connection lifecycle (dial target, interface, waiting/
failed states, timeouts) to unified logging:

```bash
log stream --predicate 'subsystem == "com.targetbridge.sender"'
```

The receiver logs to stderr; under the LaunchAgent that lands in
`~/Library/Logs/TargetBridgeReceiver.launchd.err.log`.
