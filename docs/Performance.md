Receiver Performance Switches
=============================

The Receiver's menu bar icon has a **Performance** submenu for comparing latency changes on real hardware. Each switch is stored and applies immediately unless noted.

- **Draw only the newest frame** (on by default): every frame is still decoded, because later frames depend on it, but only the latest decoded frame is drawn when several arrive in one loop. This avoids drawing frames that are already out of date.
- **Wake on incoming data** (on by default): while waiting, the Receiver wakes as soon as data arrives instead of always sleeping 1 ms.
- **Use Metal renderer** (off by default): SDL renders with Metal instead of OpenGL. It applies after restarting the Receiver. The `TB_RECEIVER_RENDER_DRIVER` environment variable still overrides it.
- **Show performance stats**: an overlay with frames per second, skipped frames, draw time per frame (average and maximum), received data rate and the renderer. The same line is written to the Receiver log once per second.

"Draw time" covers uploading a frame to the GPU and presenting it, which is the step the planned zero-copy work targets.

Uncompressed Video: Changed Rows Only
=====================================

With **Uncompressed** or **Uncompressed, LZ4 (lossless)** as the video compression, the Sender no longer sends every frame in full. ScreenCaptureKit reports which areas of the screen changed in each frame, and the Sender sends only those rows of the 4:2:0 picture. The Receiver keeps the whole picture in memory, patches the received rows into it and uploads only those rows to the GPU.

- **Bandwidth**: a still desktop costs almost nothing; typing or a moving window costs a fraction of a full frame. Full-screen video and scrolling still need up to about 10.6 Gb/s at 5K and 60 Hz.
- **LZ4 (lossless)**: the changed rows are compressed with LZ4 before sending, in parallel chunks of 64 rows on both Macs. The picture stays bit-identical. Chunks that LZ4 can't shrink are sent as they are.
- **Rows from skipped frames**: when the frame rate limit or a saturated link skips a frame, its changed rows are kept and sent with the next frame, so nothing is lost.
- **Safety net**: the first frame, a size change, a frame without dirty-rect information and one frame every 5 seconds are sent in full.
- **Compatibility**: the Receiver advertises `supportsRawRegions` and `supportsRawLZ4`. Older Receivers keep getting full frames (packet type 0x22), and LZ4 is only used when the Receiver supports it. The wire format of packet type 0x24 is described in `TargetBridge-Receiver/TBReceiverC/src/raw_regions.h`.
- **Comparing**: start the Sender with the environment variable `RAW_REGIONS=0` to send full frames again. With **Show performance stats** on, the Receiver's overlay shows `changed N%`, the share of the screen's rows that had to be sent.
