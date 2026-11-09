Receiver Performance Switches
=============================

The Receiver's menu bar icon has a **Performance** submenu for comparing latency changes on real hardware. Each switch is stored and applies immediately unless noted.

- **Draw only the newest frame** (on by default): every frame is still decoded, because later frames depend on it, but only the latest decoded frame is drawn when several arrive in one loop. This avoids drawing frames that are already out of date.
- **Wake on incoming data** (on by default): while waiting, the Receiver wakes as soon as data arrives instead of always sleeping 1 ms.
- **Show performance stats**: an overlay with frames per second, skipped frames, draw time per frame (average and maximum), received data rate and the renderer. The same line is written to the Receiver log once per second.
- **Renderer (Expert Settings)**, for developers:
  - **Renderer** (applies after restarting the Receiver):
    - **TargetBridge Metal** (default, recommended): the Receiver draws all video, H.264/HEVC and every uncompressed mode, with its own Metal code, like DisplayBridge. SDL, the library the Receiver uses for its window, still draws the waiting screen, cursor and overlays. Changed rows of the uncompressed modes are copied by the GPU straight from the Receiver's memory, and full 10-bit colour is shown in 10 bits.
    - **SDL Metal** and **SDL OpenGL**: SDL draws everything, as in earlier versions (OpenGL was the default before 4.0). SDL's Metal mode can flash on some systems, and neither shows full 10-bit colour, so the Sender then uses 10-bit dithered instead.
    - The `TB_RECEIVER_RENDER_DRIVER` environment variable still overrides SDL's choice of driver.
  - **Wait for display refresh in uncompressed modes** (off by default, TargetBridge Metal only): presents in step with the iMac's refresh, which avoids tearing. The Receiver then waits for each refresh, which can lower the frame rate.

"Draw time" covers uploading a frame to the GPU and presenting it. With display refresh waiting on, it includes that wait.

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
| **Uncompressed, full colour (10-bit)** | 10-bit RGB | 10-bit RGB 4:4:4, parallel, LZ4 while it pays off | ~2.7 times as much | ~30 fps for video and scrolling |

- **Enhanced (10-bit dithered)**: captured in 10-bit, displayed in 8-bit. Before sending, a GPU shader converts only the changed rows to 8-bit 4:2:0 (BT.709, video range) with an ordered 4×4 (Bayer) dither. Gradients stay smooth without visible steps. The pattern depends only on the pixel position and repeats every 4 pixels and rows, so a still picture stays bit-identical from frame to frame and flat areas still compress well with LZ4. Without a usable Metal GPU the Sender captures 8-bit directly.
- **Full colour (10-bit)**: the captured pixels are sent unchanged, 4 bytes per pixel, compressed with LZ4 while that pays off. Desktop content (moving windows, text, scrolling pages) shrinks several times. Video barely does, so after a frame that LZ4 shrank by less than 20 %, the next 30 frames go out raw before LZ4 is tried again, much like DisplayBridge sends video raw.
  - **Shown in 10 bits by the TargetBridge Metal renderer** (the default): the window switches to a 10-bit (BGR10A2) drawable, and the GPU copies only the changed rows from the Receiver's memory into a 10-bit texture without any CPU conversion. The stats overlay shows `10-bit RGB`.
  - With an SDL renderer the Receiver doesn't offer full colour, and the Sender uses Enhanced instead.
- **Receive buffers**: the Receiver asks for receive buffers of up to 16 MiB per connection (macOS allows 8 MiB by default), so a whole 5K frame keeps arriving over the data streams while the previous one is drawn.
- **Complete frames only**: each part of a frame carries the number of parts, and the Receiver draws a frame only once all of its parts have arrived (or after 100 ms, if one never does). A frame that is replaced by a newer one before it was drawn counts as skipped in the stats.
- **Display refresh**: frames are presented as soon as they are complete. Waiting for the iMac's refresh (no tearing) is in Renderer (Expert Settings), off by default; hardware-decoded H.264/HEVC never waits.
- **Stream profiles**: *5K 60 Uncompressed (8-bit)*, *5K 60 LZ4, lossless (8-bit)*, *5K 60 10-bit dithered* and *5K 60 Full 10-bit* select 5K at 60 Hz and the matching mode in one step. While one is selected, the video compression setting is locked to it.
- **Parallel data streams**: one TCP connection over Thunderbolt Bridge tends to hit a CPU-core limit before the cable is full. The Receiver advertises up to 4 extra connections and a per-session token; the Sender opens them, splits each frame's changed rows into parts of similar size and sends one part per connection (packet type 0x26, with the part count in byte 12 of the header). Parts can arrive out of order, so the Receiver remembers for every pair of rows which frame wrote it last, and an older part never overwrites newer rows. If no extra connection comes up, frames go over the session connection as before.
