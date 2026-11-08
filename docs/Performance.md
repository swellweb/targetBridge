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

With any of the **Uncompressed** options as the video compression, the Sender no longer sends every frame in full. ScreenCaptureKit reports which areas of the screen changed in each frame, and the Sender sends only those rows of the 4:2:0 picture. The Receiver keeps the whole picture in memory, patches the received rows into it and uploads only those rows to the GPU.

- **Bandwidth**: a still desktop costs almost nothing; typing or a moving window costs a fraction of a full frame. Full-screen video and scrolling still need up to about 10.6 Gb/s at 5K and 60 Hz.
- **LZ4 (lossless)**: the changed rows are compressed with LZ4 before sending, in parallel chunks of 64 rows on both Macs. The picture stays bit-identical. Chunks that LZ4 can't shrink are sent as they are.
- **Rows from skipped frames**: when the frame rate limit or a saturated link skips a frame, its changed rows are kept and sent with the next frame, so nothing is lost.
- **Safety net**: the first frame, a size change, a frame without dirty-rect information and one frame every 5 seconds are sent in full.
- **Compatibility**: the Receiver advertises `supportsRawRegions` and `supportsRawLZ4`. Older Receivers keep getting full frames (packet type 0x22), and LZ4 is only used when the Receiver supports it. The wire format of packet type 0x24 is described in `TargetBridge-Receiver/TBReceiverC/src/raw_regions.h`.
- **Comparing**: start the Sender with the environment variable `RAW_REGIONS=0` to send full frames again. With **Show performance stats** on, the Receiver's overlay shows `changed N%`, the share of the screen's rows that had to be sent.

Uncompressed, 10-bit Modes (Experimental)
=========================================

Two further options build on **Uncompressed, LZ4, lossless (8-bit)**: both capture the screen in 10-bit and send raw frames over up to 4 parallel data connections.

| Option | Captured | Sent and shown | Data at 5K | Frame rate at 5K |
|---|---|---|---|---|
| **Uncompressed (8-bit)** | 8-bit 4:2:0 | 8-bit 4:2:0 | up to ~10.6 Gb/s | 60 Hz |
| **Uncompressed, LZ4, lossless (8-bit)** | 8-bit 4:2:0 | 8-bit 4:2:0, LZ4 | less, depends on content | 60 Hz |
| **Uncompressed, enhanced (10-bit dithered)** | 10-bit RGB | 8-bit 4:2:0, dithered, LZ4, parallel | like the 8-bit modes | 60 Hz |
| **Uncompressed, full colour (10-bit)** | 10-bit RGB | 10-bit RGB 4:4:4, LZ4, parallel | ~2.7 times as much | ~30 fps for video and scrolling |

- **Enhanced (10-bit dithered)**: captured in 10-bit, displayed in 8-bit. Before sending, a GPU shader converts only the changed rows to 8-bit 4:2:0 (BT.709, video range) and adds a fixed, position-based triangular dither of ±1 code value. Gradients stay smooth without visible steps, and a still picture stays bit-identical from frame to frame, so it still compresses well. Without a usable Metal GPU the Sender captures 8-bit directly.
- **Full colour (10-bit)**: the captured pixels are sent unchanged, 4 bytes per pixel. Whether the iMac really shows 10 bits depends on the Receiver's renderer: if SDL cannot create 10-bit textures it converts them to 8-bit on upload, and you still get full 4:4:4 colour resolution. The stats overlay shows `10-bit RGB` or `10-bit RGB shown as 8-bit`. If the Receiver cannot show 10-bit RGB at all, the Sender uses Enhanced instead.
- **Stream profiles**: *5K 60 Uncompressed (8-bit)*, *5K 60 LZ4, lossless (8-bit)*, *5K 60 10-bit dithered* and *5K 60 Full 10-bit* select 5K at 60 Hz and the matching mode in one step. While one is selected, the video compression setting is locked to it.
- **Parallel data streams**: one TCP connection over Thunderbolt Bridge tends to hit a CPU-core limit before the cable is full. The Receiver advertises up to 4 extra connections and a per-session token; the Sender opens them, splits each frame's changed rows into parts of similar size and sends one part per connection (packet type 0x26). Parts can arrive out of order, so the Receiver remembers for every pair of rows which frame wrote it last, and an older part never overwrites newer rows. If no extra connection comes up, frames go over the session connection as before.
