# Testing TargetBridge Without Hardware

Everything on this page runs on one Mac with **no Thunderbolt cable, no
second machine, and no Apple Silicon requirement** (except where noted).
The CI workflow defines the first two suites. It only runs when GitHub Actions
is enabled for the repository and the target branch is included in its triggers.

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
The suite also checks idle-dashboard geometry from 640 x 480 to 5K, including
the 980 x 620 launcher window, without SDL or a GUI session.

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

For the Receiver idle-sleep report (#132), build the Receiver and run
`bash TargetBridge-Receiver/scripts/test_idle_display_sleep.sh` from the repo
root in a GUI session. Disconnect real Senders first: automatic discovery can
otherwise establish a session during the check. The test checks only its own
Receiver process in `pmset -g assertions`, before a connection and after mock
session teardown. Exit 2 means the test could not run in isolation, not a
confirmed sleep regression. It does not change system sleep settings.

The sender logs its connection lifecycle (dial target, interface, waiting/
failed states, timeouts) to unified logging:

```bash
log stream --predicate 'subsystem == "com.targetbridge.sender"'
```

The receiver logs to stderr; under the LaunchAgent that lands in
`~/Library/Logs/TargetBridgeReceiver.launchd.err.log`.

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

## Retina 16:10 Receiver profiles

For an exact 16:10 Receiver panel, select **Extended Desktop**, enable
**Render Matching Stream Resolution**, and choose one of these stream profiles:

| Profile | Encoded frame | Logical HiDPI desktop | On a 3072 x 1920 panel |
| --- | --- | --- | --- |
| Retina 16:10 | 3072 x 1920 | 1536 x 960 | Pixel-matched backing |
| Retina 16:10 More Space | 3584 x 2240 | 1792 x 1120 | Downsampled to the physical panel |

The second profile requests a larger virtual framebuffer while retaining the
Receiver's physical panel geometry. It processes about 36% more pixels than the
first profile. Both request 60 fps; sustained frame rate depends on the encoder,
decoder and link. Codec selection and hardware fallback follow the existing
policies. These choices do not change the defaults or the existing 16:9 profiles.

The larger-backing exception requires an explicit HiDPI render override and an
exact 16:10 panel. It is bounded to 3584 x 2240. Other aspect ratios and existing
profiles retain the previous panel limit. On smaller 16:10 panels, both profiles
can involve downsampling. With render matching disabled, the receiver-advertised
desktop mode is retained; the logical desktop sizes above are not forced.

This targets the geometry/scaling part of #207. It does not establish that every
reported black border has the same cause. A physical 16:10 end-to-end check is
still required before claiming that report fully resolved. Mirror mode continues
to follow the source display's aspect ratio and is not guaranteed to fill a
different-shaped Receiver.

The normal Sender XCTest suite includes profile, HiDPI geometry, bounded
supersampling, 16:9 preservation, codec choice, localization and automation tests.
To run the focused check without starting the app or creating a display:

```bash
python3 TargetBridge-Sender/scripts/test_retina_16x10.py . /tmp/tb-retina-check
```

For a negative control, run the same script against the unmodified source with
`--presets-only`; it reports both missing 16:10 profiles. The script compiles the
production declarations, not a parallel implementation of the geometry rules.

Hardware validation should cover both profiles on a 16:10 Receiver: reported
logical/pixel sizes, full-screen edge coverage, text sharpness, cursor and input
at all corners, reconnect and saved profile selection. Recheck Full HD, Retina
4K and 5K on 16:9 Receivers. Do not run the normal app-hosted tests alongside a
live Sender; use an isolated command-line test host or a separate test machine.
