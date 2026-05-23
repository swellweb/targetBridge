# Audio Streaming Architecture & Synchronization

TargetBridge implements raw, high-fidelity system audio streaming from a sender Mac to a receiver Mac in **Mirror Mode (Duplicate Desktop)**. The stream is designed for ultra-low latency, real-time synchronization with H.264/HEVC video decoding, and robust scheduling jitter tolerance.

This document describes the technical architecture, dynamic format conversion pipeline, and the synchronization breakthroughs that eliminated playout lag without sacrificing audio quality.

---

## 🗺️ High-Level Pipeline

```mermaid
flowchart LR
    subgraph Sender (Swift)
        A[ScreenCaptureKit] -->|Float32 Non-Interleaved| B[SBAudioConverter]
        B -->|AVAudioConverter| C[S16 Interleaved PCM]
        C -->|TCP Socket| D[NWConnection]
    end

    subgraph Receiver (C)
        D -->|TB_PKT_AUDIO_FRAME| E[TCP Parser]
        E -->|Locked Resync Check| F[Circular Ring Buffer]
        G[SDL Sound Card Thread] -->|audio_callback| F
    end
```

---

## 🎙️ Sender-Side Architecture (Swift)

### 1. Capture via ScreenCaptureKit
System audio is captured before the master hardware volume or mute is applied. This allows the user to manually mute their MacBook speakers while high-fidelity audio streams to the receiver.
* **`capturesAudio = true`**: Enables audio capture on the `SCStream`.
* **`excludesCurrentProcessAudio = true`**: Prevents the sender from capturing its own system sounds, avoiding feedback loops.
* **QoS Queue**: The capture stream delegates callbacks onto a high-priority `.userInteractive` dispatch queue (`fd.tbmonitor.sender.audio`).

### 2. Format Conversion (`SBAudioConverter`)
ScreenCaptureKit outputs audio as **Float32 non-interleaved PCM** (separate buffers for left and right channels). 
To make it compatible with low-overhead C playback systems (such as SDL2), the Swift sender converts it to standard **16-bit signed interleaved PCM at 48000Hz Stereo** (4 bytes per sample frame).

The `SBAudioConverter` class executes this:
1. **Pointer Extraction**: Safely extracts the non-interleaved channel buffers using `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer`.
2. **Hardware-Accelerated Conversion**: Feeds the float pointers to an `AVAudioConverter` configured to transcode into a packed 16-bit signed integer interleaved `AudioStreamBasicDescription` (ASBD).
3. **Low-Allocation Copying**: Performs conversion frame-by-frame with zero persistent copies, preserving thread safety using Swift concurrency locks.

---

## 🔊 Receiver-Side Architecture (C)

The receiver utilizes the cross-platform **SDL2 Audio Subsystem** configured for raw PCM playback:
* **Audio Format**: `AUDIO_S16LSB` (16-bit signed little-endian PCM).
* **Sample Rate**: `48000 Hz`.
* **Channels**: `2` (Stereo).
* **Device Buffering**: Requested at **1024 samples (approx. 21.3ms)**.

### The Evolution: Why `SDL_QueueAudio` Failed
Initially, the receiver used SDL2's queuing API (`SDL_QueueAudio`) and capped the backlog using `SDL_GetQueuedAudioSize() < 13440` (70ms). This failed due to two factors:
1. **OS-Level Hardware Buffering**: SDL2 immediately drains the external queued buffer into its internal OS/CoreAudio device playback ring buffers. Once the data leaves the SDL queue, `SDL_GetQueuedAudioSize` reports `0` for it, bypassing the backlog threshold and causing up to **1 second of hidden playback buffering**.
2. **Socket Congestion**: During temporary network slow-downs or high H.264 keyframe activity, audio packets accumulate in the TCP transmit/receive socket buffers (configured up to 4MB). When the network clears, the socket drains in a massive burst. Sequencing all these backlogged packets directly into playout caused a permanent, lagging delay.

---

## ⚡ The Synchronization Breakthroughs

To resolve the delay without degrading audio quality, the pipeline was rewritten using a **circular ring buffer, a dedicated SDL callback, and a smooth-discard sliding-window resynchronization**.

### 1. Dedicated Audio Callback (`audio_callback`)
Instead of pushing bytes, we configure SDL2 to pull bytes via an explicit callback:
* The sound card thread requests `len` bytes from the circular buffer.
* If the buffer does not have enough samples (underflow), it fills the remainder with silence (`memset(..., 0)`). This prevents the device from looping old samples, which would cause horrible static/buzzing.

### 2. Circular Ring Buffer & Thread-Safe Locking
A 1-second circular buffer (`audio_buf`) is added to the receiver's main `app` context:
* The callback reads from the buffer (updating `audio_buf_tail`).
* The TCP socket thread writes incoming network frames to the buffer (updating `audio_buf_head`).
* Since the callback runs on an independent SDL system thread, any modifications to the buffer indexes on the main TCP socket thread are wrapped inside **`SDL_LockAudioDevice`** and **`SDL_UnlockAudioDevice`** to prevent data races.

### 3. Smooth-Discard (Sliding-Window Resync)
Rather than aggressively clearing/wiping the entire audio buffer when it gets backlogged (which causes silent gaps, sudden dropouts, and loud popping noises), we implement a **smooth-discard sliding window**:

* We set a strict maximum latency ceiling of **80ms** (equivalent to `80 * 192 = 15360` bytes).
* In `on_packet`'s `TB_PKT_AUDIO_FRAME` handler, we check the total queued size:
  ```c
  const int cap_bytes = 15360; // 80ms
  if (a->audio_buf_size + len > cap_bytes) {
      int excess = (a->audio_buf_size + len) - cap_bytes;
      a->audio_buf_tail = (a->audio_buf_tail + excess) % AUDIO_BUF_CAP;
      a->audio_buf_size -= excess;
  }
  ```
* **How it works**: If a burst of socket-backlogged packets arrives, the check immediately triggers. Instead of deleting all data, it **advances the read tail pointer by the exact excess byte count**.
* **The Result**: The oldest, lagging samples are skipped instantly. The circular buffer is left holding exactly **80ms of the newest, most up-to-date audio samples**.
* **Acoustics**: Truncating just the oldest samples in this manner is perceived by the ear as a seamless micro-skip, maintaining crystal-clear playout fidelity, while guaranteeing that audio latency stays perfectly locked to the video stream.

---

## 🛠️ Diagnostics & Tweaking

Developers can tweak the following properties in `main.c` depending on hardware limits:

1. **`spec.samples` (Hardware Buffer Size)**:
   - Configured at `1024` samples. If run on modern Apple Silicon, this can be safely reduced to `512` (10.6ms) or `256` (5.3ms) for even lower latency.
   - For older Intel Macs or high CPU scheduling jitter, keep this at `1024` to prevent scheduling underflows (which cause crackling/static).
2. **`cap_bytes` (Latency Threshold)**:
   - Configured at `15360` bytes (80ms).
   - If H.264 video decoding takes longer on a specific system, this can be adjusted (e.g., `19200` for 100ms) to match video latency.
