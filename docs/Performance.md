Receiver Performance Switches
=============================

The Receiver's menu bar icon has a **Performance** submenu for comparing latency changes on real hardware. Each switch is stored and applies immediately unless noted.

- **Draw only the newest frame** (on by default): every frame is still decoded, because later frames depend on it, but only the latest decoded frame is drawn when several arrive in one loop. This avoids drawing frames that are already out of date.
- **Wake on incoming data** (on by default): while waiting, the Receiver wakes as soon as data arrives instead of always sleeping 1 ms.
- **Use Metal renderer** (off by default): SDL renders with Metal instead of OpenGL. It applies after restarting the Receiver. The `TB_RECEIVER_RENDER_DRIVER` environment variable still overrides it.
- **Show performance stats**: an overlay with frames per second, skipped frames, draw time per frame (average and maximum), received data rate and the renderer. The same line is written to the Receiver log once per second.

"Draw time" covers uploading a frame to the GPU and presenting it, which is the step the planned zero-copy work targets.
