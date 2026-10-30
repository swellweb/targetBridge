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

## 6. Monitor shield lifecycle (macOS GUI session)

```bash
cd TargetBridge-Receiver/TBReceiverC
make test-monitor-shield
```

Opens a small test window and checks repeated activation, delayed window-level
restoration, backing-property notifications, observer cleanup, and cancellation
of pending retries after stopping. Requires AppKit and a logged-in GUI session,
but no screen recording or input permissions. This is separate from `make test`
so the portable test suite remains usable without a GUI. It does not replace
live verification of notification suppression during a real stream.

## Debugging a live connection

The sender logs its connection lifecycle (dial target, interface, waiting/
failed states, timeouts) to unified logging:

```bash
log stream --predicate 'subsystem == "com.targetbridge.sender"'
```

The receiver logs to stderr; under the LaunchAgent that lands in
`~/Library/Logs/TargetBridgeReceiver.launchd.err.log`.

For a slow live stream, run the read-only collector **on the receiver Mac**
while keeping the same video playing:

```bash
bash TargetBridge-Receiver/scripts/sample_receiver_performance.sh
```

It uses built-in macOS tools: ten seconds of per-process TCP counters and
socket queues, followed by ten seconds of thread sampling. The resulting ZIP
is saved on the Desktop; `--output-dir DIRECTORY` selects another parent
directory, and `--pid PID` selects one receiver if several are running. No
rebuild or restart is needed. It does not change settings, generate test
traffic, capture screen/video payloads, or upload the report. It records
process paths, model/OS information, TCP endpoint addresses and stack traces.

Check `status.txt` for collection failures. Throughput is measured before the
more intrusive thread sample, so sampling stalls must not be reported as
normal playback performance. `Recv-Q` counts bytes waiting for the app to
read; it is not the advertised TCP window. Sender `localContentProcessed`
measures local Network completion, not receiver presentation. Neither a
single queue snapshot nor a syscall stack alone establishes the bottleneck.

## Experimental 5K at 60 FPS

`native5k60Experimental` is an opt-in HEVC profile for testing recent Apple
Silicon encoders at 5120 x 2880 and 60 FPS. It does not alter the stable 5K
profile, which remains at 48 FPS and is the recommended choice for daily work.

Real-world M4 testing has reached 56-57 FPS but also showed temporary drops
under mixed workloads and added heat when Input Dockstation is active. Treat
this profile as a benchmark and feedback tool, not a guaranteed 60 FPS mode.

Use it only for a test session, either from the Sender's stream-profile picker
or with the automation alias:

```bash
targetbridge connect --receiver <receiver-ip> --mode extended --preset 5k60
```

After at least one minute of normal desktop use, note the Sender FPS shown in
the session card, whether input remains responsive, and any capture or decoder
errors. For a two-receiver experiment, start one session per receiver and
record the FPS for each session separately. Include the sender model, macOS
version, receiver model, cable type, and selected transport with the report.

## RAW RGB10 transport

Sender tests verify capability gating, actual `l10r`/Display P3 capture settings,
three-slot ownership through final DispatchData destruction, CPU fallback and
GPU blit readback. Hardware-free Receiver checks use production functions:

```bash
python3 TargetBridge-Receiver/TBReceiverC/tests/test_rgb10_display.py
python3 TargetBridge-Receiver/TBReceiverC/tests/test_raw_rgb10.py
python3 TargetBridge-Receiver/TBReceiverC/tests/test_socket_drain.py
python3 TargetBridge-Receiver/TBReceiverC/tests/test_video_diagnostics.py
```

`make test` includes parser, address discovery and lifecycle state tests. The
optional Metal test uses synthetic pixels in a small window, without capture or
network traffic:

```bash
cd TargetBridge-Receiver/TBReceiverC
make test-rgb10-metal
./test_rgb10_metal --presentation-only
```

The full suite checks owned 4.5K uploads, cursor fallback, first-frame visibility,
teardown and resource bounds. Presentation-only checks the production render
target against complete 1024-level ramps, one-pixel checkerboards and isolated
pixels. Render-target equality does not validate Core Animation color management,
physical panel depth, screen capture or sustained remote frame rate. Validate the
actual Apple Silicon and Intel receivers separately; see [RAW RGB10](Raw-RGB10.md).

### Receiver stream-profile display

Run `python3 TargetBridge-Receiver/TBReceiverC/tests/test_stream_mode.py` to
exercise the production handshake, language changes, frame metadata and
connection reset with real translations and synthetic frames. Before a sender
provides dimensions, the status page shows a waiting message. Requested
resolution remains visible across language changes until a valid frame arrives;
then received pixel dimensions take priority. Disconnect clears the previous
session's dimensions. A fixed HiDPI desktop size is never used as stream metadata.
