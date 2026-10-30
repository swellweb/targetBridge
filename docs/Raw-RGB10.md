# Uncompressed RGB10 streaming

Choose **4480 × 2520 · 60 FPS** under **Resolution and frame rate**, then
**RGB10 uncompressed** under **Video compression**. Resolution and compression are independent: choosing
H.264 or HEVC explicitly uses the encoded path even for the older RAW preset.
Saved Automatic + `native4_5kRGB10Raw60` settings migrate to the ordinary 4.5K
resolution with explicit RGB10 compression. The old preset remains a CLI alias
but is hidden from the resolution menu. Changing only the resolution or
refreshing receiver discovery preserves each session's compression choice.
An explicit RGB10 selection requires the Receiver's `supportsRawRGB10` capability;
a missing capability produces an error rather than silently selecting NV12.

The Sender requests SDR Display P3, packed `l10r` pixels from ScreenCaptureKit.
A reusable pool owns at most three packet buffers. Metal blits into shared owned
storage when supported; the CPU fallback preserves the packed samples. A slot
returns to the pool only when the final DispatchData reference is released.
Local Network completion releases send capacity, not pixel ownership.

The wire keeps packet type `0x22`: format 1 remains legacy NV12, format 2 carries
packed little-endian RGB10 using the existing 17-byte header. The Receiver bounds
frames to 5120 × 2880, validates the exact row layout and presents a
`BGR10A2Unorm` Metal texture. It advertises no DPCM capability; the existing HEVC decode capability is retained.

At 4480 × 2520, a frame is 45,158,400 pixel bytes. Sixty frames per second require
about **21.68 Gbit/s** before TCP and link overhead. Cable-test throughput is a
local transport measurement, not a guarantee of sustained video frame rate.
Capture cadence, OS networking, GPU scheduling and presentation all contribute.

This preserves the delivered packed RGB samples. It does not establish HDR,
physical panel 10-bit output, or lossless reproduction of the original desktop:
capture scaling/color conversion and final compositor output require separate
measurement. The synthetic drawable test verifies the production Metal render
pass before Core Animation, including all 1024 levels and single-pixel detail.
See [Testing](Testing.md) for the synthetic and real-device validation boundaries.

## Shared implementation provenance

The Metal video/cursor plane and receiver health instrumentation derive from
Aykut Alpgiray Ates's [PR #201](https://github.com/swellweb/targetBridge/pull/201).
This independent RAW change retains that shared presentation foundation and its
attribution. The compressed tile codec and compute decoder belong to the separate
DPCM proposal and are not part of this branch.
