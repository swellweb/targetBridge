# Experimental 10-bit RGB DPCM transport

Select **4480 × 2520 · 60 FPS** (`retina4_5k60`) under **Resolution and frame rate**,
and **DPCM RGB 10-bit (lossless)** under **Video compression** to capture 4480 × 2520 packed 10-bit
RGB. This matches the [24-inch M1 iMac's native resolution](https://support.apple.com/en-gb/111895),
but the profile is not limited to that model. DPCM can be selected with any
stream profile; compression does not change its resolution or frame-rate limit.
The selection is remembered for the session and used as a default when choosing
that receiver again. Refreshing a discovered receiver does not overwrite an
existing session choice.

Resolution choices contain only dimensions and frame rates. The legacy
`native4_5kRaw60` and `native5kRaw60` identifiers remain supported for saved
settings and command-line aliases, but no longer appear as duplicate DPCM
resolution entries. Old Automatic+DPCM settings retain their compatibility
fallback as **Automatic (DPCM preferred)** in Video compression; changing only the resolution keeps that
choice. Explicit H.264 or HEVC overrides are preserved. Ordinary profiles with
**Automatic** keep the existing hardware-codec selection.

A negotiated DPCM session requests packed 10-bit RGB (`l10r`, ARGB2101010
little endian) from ScreenCaptureKit and losslessly transmits the captured RGB
samples using TBD2 tile-DPCM. This is an experimental transport, not a guarantee
of sustained 4.5K60 or 5K60, HDR, native 10-bit source content, or 10-bit panel scanout.

For 1:1 capture, enable render matching in Extended Desktop: the 4.5K profile
uses a 2240 × 1260 HiDPI desktop, and the 5K profile uses 2560 × 1440.

This integration is based on the 3.6.0 `main` release. It retains the mainline
codec preferences, native-scale 1080p profiles, receiver identity migration and
headless capture behavior. Render matching waits for the requested backing
pixels and verifies the active mode, instead of accepting a 2240 × 1260 1x
mode when a 4480 × 2520 HiDPI backing store is required.

## Capture and color contract

The DPCM session explicitly requests `kCVPixelFormatType_ARGB2101010LEPacked`
and `CGColorSpace.displayP3`. The receiver labels its `BGR10A2Unorm`
CAMetalLayer as Display P3 too. ScreenCaptureKit documents `l10r` as a
supported [output pixel format](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/pixelformat).

Capture startup and delayed callbacks are tied to the current connection and
capture attempt. A stop/reconnect during an asynchronous start discards the old
stream instead of publishing it into the new session.

The sender checks the delivered CVPixelBuffer format and layout before reading
any samples. NV12 and BGRA are rejected rather than interpreted as packed
10-bit RGB. The encoder preserves all 1024 values per RGB channel, including
the low two bits. Alpha is omitted and reconstructed as opaque.

This contract begins **after capture and color conversion**. Choosing a 10-bit
buffer does not create source precision that an application, source display,
or virtual framebuffer did not have. This change does not modify the private
virtual-display transfer-function API. Color conversion, scaling and final
panel scanout are outside the codec's bit-exact guarantee. Capture remains SDR.

## Negotiation and fallback

| Receiver / selected mode | Capture and wire format |
|---|---|
| DPCM selected, receiver advertises a working Metal DPCM decoder | Display P3 10-bit RGB, TBD2 (`0x25`) |
| Negotiated DPCM receiver also advertises `supportsDPCMAdaptiveColor` | 10-bit TBD2 with reversible per-tile colour decorrelation |
| Explicit DPCM, receiver lacks DPCM support | Error before capture; no silent NV12 or hardware-codec fallback |
| Migrated automatic DPCM compatibility mode, old receiver supports raw NV12 | 8-bit NV12, existing raw packet (`0x22`) |
| Migrated automatic DPCM compatibility mode, receiver supports neither DPCM nor raw NV12 | Existing HEVC/H.264 path, subject to encoder availability |
| Automatic + ordinary profile | Existing encoded path, or explicitly enabled `RAW=1` NV12 |
| Explicit H.264 or HEVC with any profile | Hardware-codec path; overrides the profile default and `RAW=1` |

Absent capability fields mean unsupported. Selection happens before capture
starts, so a packed RGB frame never reaches the planar NV12 sender. The active
codec label distinguishes DPCM RGB 10-bit, NV12 RAW 8-bit and encoded transport.
A receiver without usable Metal continues advertising the legacy formats.
The receive loop yields after a byte/time budget so a continuously readable
video stream cannot starve window events or input; teardown stops dispatching
further packets from the same batch.
Capability probing does not create a visible Metal layer over the status UI.

If GPU encoding cannot be created or fails in a negotiated DPCM session, the
CPU reference encoder emits the same 10-bit TBD2 format. It may be much slower;
backpressure and the existing frame-rate ceiling still apply. There is no
silent conversion to 8-bit NV12. Invalid capture frames are rejected and logged.
The direct CGDisplayStream mirror fallback is used only for encoded sessions;
it does not silently substitute its 8-bit buffers into a DPCM session.

The receiver creates the Metal layer only for incoming DPCM frames, shows it
after a successful frame, and releases it on NV12/encoded fallback, disconnect
or window destruction. The currently integrated whole-frame decoder uses
ordered presentation, avoiding the unfinished asynchronous band-present path.

## Codec

TBD2 splits frames into independent 8 × 8 tiles. Each tile stores its first
pixel and per-channel residual widths. Remaining pixels predict from the left,
except the first column which predicts from above. Modular residuals and zigzag
coding preserve samples exactly at either supported codec depth (8 or 10 bits).
The current Sender DPCM transport accepts only 10-bit capture.

When the receiver advertises `supportsDPCMAdaptiveColor`, each tile compares
RGB coding with `(B-G, G, R-G)` modulo 1024 (256 in the 8-bit codec tests).
It chooses the latter only when the sum of residual widths is smaller. This
removes repeated residuals in correlated RGB content such as grayscale text,
preserves every captured bit, and never enlarges a tile's payload. The GPU
performs the comparison and transform within its existing analysis/packing
passes; there is no additional CPU pass over the captured frame.

The extension uses header flag `0x04` and bit 31 of each seed to identify a
transformed tile. The decoder adds green back to blue and red after residual
reconstruction. Layout, packet type and maximum frame size stay the same.
Old receivers get the original format with this flag clear; old senders work
with the extended decoder. Both apps must be updated to obtain the improvement.

This is spatial, lossless compression, not a fixed bitrate video codec. Dense
edges and independent RGB noise can still make residuals wide. At 4480 × 2520,
the largest legacy 10-bit payload is about 42.66 MB: approximately 10.24 Gbps
at 30 frames/s or 20.47 Gbps at 60 frames/s, before network overhead. Adaptive
colour cannot compress independent noise further. Historical ratios for other
images or 8-bit input are not guarantees for captured 10-bit desktops.

Groups of 64 tiles share an offset table. The CPU parser checks dimensions,
widths, payload sizes and group offsets before the Metal decoder accesses the
blob. Display allocations are additionally limited to 5120 × 2880, matching
the current Sender transport, even when a small valid blob describes a much
larger flat image. GPU encoding is compared byte-for-byte with the reference C encoder in
the optional synthetic-pixel test.

| Component | Source |
|---|---|
| Wire format and CPU reference | `TargetBridge-Shared/codec/tb_dpcm.h`, `tb_dpcm.c` |
| GPU encoder | `TargetBridge-Shared/codec/tb_dpcm_gpu.h`, `tb_dpcm_gpu.m` |
| Capture negotiation and buffer validation | `TBVideoTransport`, `TBDPCMFrameEncoder` in `TBDisplaySenderService.swift` |
| Receiver GPU decode and display | `TargetBridge-Receiver/TBReceiverC/src/tb_metal_plane.m` |

## Compatibility and verification

Both Apple Silicon receivers (including M1 iMac) and Intel receivers remain
supported targets. A capability probe, not the CPU model, controls DPCM
availability. Existing CI builds both `arm64` and `x86_64`. No new OS minimum is
introduced. The initial proposal's measurements came from a separate fork on
a 2020 Intel 5K iMac; they do not establish performance on M1 iMac or on this
integration. A 40 Gb/s cable rating is not application throughput.

Hardware-free checks:

```sh
cd TargetBridge-Receiver/TBReceiverC
make test
```

This includes the C codec tests, with complete 0–1023 RGB ramps and malformed
packet coverage. For the GPU encoder, using synthetic pixels only:

```sh
make test-dpcm-gpu
```

The GPU test compares 8-bit and 10-bit GPU output with the CPU reference, injects GPU creation/submission failures, then
checks decoded pixels, padded rows, partial tiles and full 4480 × 2520 frames.
It requires a usable
Metal device; exit 77 means unavailable, not a passing GPU test.

For receiver decode and presentation with synthetic pixels, run
`make test-dpcm-metal`. This requires SDL2 and a logged-in GUI session, opens a
small test window, compares GPU decoded buffers with the CPU reference, and
checks first-frame visibility, teardown, oversized-frame rejection and native
4.5K decode readback (including its final partial group). It does
not capture the screen or change display settings.

Sender XCTest coverage checks explicit-choice priority, capability rejection,
automatic compatibility fallback, saved codec preferences and idle previews. It
also checks the actual SCStream configuration, rejection of incompatible pixel
buffers and CPU fallback round-trips of all 1024 channel values. See [Testing](Testing.md) for commands.

For a stream stuck before its first HEVC frame, the Sender logs encoder creation,
optional-property rejection, preparation and the first encoded packet. Receiver
logs use `[video] stage=param_sets_received`, `param_sets_ready`, `encoded_packet`
and `decoded_first_frame`, with bounded errors and a `session_end` summary.
`make test-hevc-startup` exercises the real hardware encoder and FFmpeg decoder
using synthetic 4.5K NV12/BGRA frames without capture or network access. Passing
this on one GPU does not establish that a different receiver can decode the
actual stream. The hardware-free diagnostic regression is
`python3 tests/test_video_diagnostics.py` from `TargetBridge-Receiver/TBReceiverC`.

DPCM reports mean encode-plus-packet time, synchronous send-call time
(`meanSendCallMS`) and packet size every 120 sent frames,
alongside cumulative capture, pacing and pre-encode drop counters. The latter
includes rejected frames as well as a full queue; correlate it with error logs. Use those
to distinguish capture cadence, encoding work and a full send queue; a cable
speed or FPS number alone does not identify the bottleneck. Packet construction
copies the encoded bytes once into owned `DispatchData`; subsequent GPU frames
cannot overwrite packets still being sent. The public Network `DataProtocol`
send overload accepts that storage directly, avoiding the extra full-frame copy
observed when passing Swift `Data`. Encode-plus-packet timing alone does not
include the send call or establish end-to-end latency.

The three-packet budget is released directly by Network completion under a
separate lock. Deferring that update onto the capture queue could falsely drop
queued frames after Network had already processed the preceding submissions.
The budget still rejects new frames when transport processing is actually
pending; it does not imply receiver presentation or TCP acknowledgement.

The Sender's monitor details show actual DPCM dimensions, submitted video Gbps,
average MB/frame, compression relative to packed 32-bit capture, encoding time,
and GPU/CPU backend. FPS and bitrate use the same elapsed-time window. These
are application video submissions, excluding TCP overhead/retransmissions and
other sessions, and do not measure receiver presentation FPS. Activity Monitor
can include other traffic; check whether its units are bytes/s or bits/s before
comparing (1 GB/s = 8 Gbps). No diagnostic launcher is needed for these details.

Before calling the path ready for general use, run real two-machine sessions
on Apple Silicon and Intel receivers. Record source and receiver model, macOS
version, selected display mode, actual capture format, transport, sustained FPS,
queue drops, CPU/GPU cost, color gradients/text, cursor, disconnect/reconnect
and fallback behavior. M1 iMac is one test target, not the sole supported setup.
Synthetic codec tests do not verify screen capture, GPU presentation, panel
precision or sustained two-machine throughput.
