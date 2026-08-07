# Audio Streaming Architecture & Synchronization

TargetBridge implements raw, high-fidelity system audio streaming from a sender Mac to a receiver Mac in **Mirror Mode** and **Extended Desktop Mode**. The stream is designed for ultra-low latency, real-time synchronization with H.264/HEVC video decoding, and robust scheduling jitter tolerance.

This document describes the technical architecture, dynamic format conversion pipeline, and the synchronization breakthroughs that eliminated playout lag without sacrificing audio quality.

---

## 🗺️ High-Level Pipeline

```mermaid
flowchart LR
    subgraph Sender (Swift)
        A[ScreenCaptureKit] -->|Float32 Non-Interleaved| B[SBAudioConverter]
        B -->|AVAudioConverter| C[Float32 Interleaved PCM]
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
The sender interleaves it, keeping **32-bit float at 48000 Hz stereo** (8 bytes per sample frame) — CoreAudio's canonical format at both ends, so nothing quantises along the way. Receivers older than this negotiate down to Int16; see [Format negotiation](#format-negotiation).

The `SBAudioConverter` class executes this:
1. **Pointer Extraction**: Safely extracts the non-interleaved channel buffers using `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer`.
2. **Hardware-Accelerated Conversion**: Feeds the float pointers to an `AVAudioConverter` configured for a packed interleaved `AudioStreamBasicDescription` (ASBD) — 32-bit float, or 16-bit signed integer when the receiver is too old for float.
3. **Low-Allocation Copying**: Performs conversion frame-by-frame with zero persistent copies, preserving thread safety using Swift concurrency locks.

### 3. Extended Display Mode Capture (Unified SCStream)
To support audio in Extended Display Mode, the capture strategy was unified:
* **The Legacy Approach**: Previously, Extended Display Mode captured the virtual display using the video-only `CGDisplayStream` API. However, `CGDisplayStream` has no audio capture capability.
* **The Modern Solution**: The virtual display capture was migrated to modern **ScreenCaptureKit (`SCStream`)**.
  - Since the macOS WindowServer exposes the virtual extended desktop as a standard `SCDisplay` object inside `SCShareableContent.displays`, we can resolve and capture it using `SCStream`.
  - By setting `capturesAudio = true` on the virtual display stream, ScreenCaptureKit captures system audio and delivers it alongside the virtual display's H.264 video frames.
  - This unifies the entire sender-side pipeline, unlocking high-fidelity, low-latency audio for both Mirror and Extended Display sessions without needing separate capture loops.

### 4. Per-Session Audio Toggles (Live Muting)
When broadcasting to multiple receivers, audio can be controlled on a per-session basis:
* **Decoupled State**: Each `TBDisplaySenderSession` manages its own `@Published var audioEnabled: Bool` state, initialized using the global preference as a default.
* **On-the-Fly Toggle**: Toggles inside each session card bind directly to that session's state and remain interactive at all times.
* **Instant Playout Cutoff**: The `processAudio` callback verifies `audioEnabled` before every frame conversion. Disabling the toggle stops packet transmission instantly, providing seamless real-time muting for individual targets during active streaming.

---

## 🔊 Receiver-Side Architecture (C)

The receiver utilizes the cross-platform **SDL2 Audio Subsystem** configured for raw PCM playback:
* **Audio Format**: `AUDIO_F32SYS` (32-bit float, native endian) — what CoreAudio itself uses, so the output device takes it without conversion.
* **Sample Rate**: `48000 Hz`.
* **Channels**: `2` (Stereo).
* **Device Buffering**: Requested at **1024 samples (approx. 21.3ms)**.

### The Evolution: Why `SDL_QueueAudio` Failed
Initially, the receiver used SDL2's queuing API (`SDL_QueueAudio`) and capped the backlog using `SDL_GetQueuedAudioSize() < 13440` (70ms). This failed due to three factors:
1. **OS-Level Hardware Buffering**: SDL2 immediately drains the external queued buffer into its internal OS/CoreAudio device playback ring buffers. Once the data leaves the SDL queue, `SDL_GetQueuedAudioSize` reports `0` for it, bypassing the backlog threshold and causing up to **1 second of hidden playback buffering**.
2. **Socket Congestion**: During temporary network slow-downs or high H.264 keyframe activity, audio packets accumulate in the TCP transmit/receive socket buffers (configured up to 4MB). When the network clears, the socket drains in a massive burst. Sequencing all these backlogged packets directly into playout caused a permanent, lagging delay.
3. **CPU Busy-Spinning & Thread Starvation**: Initially, the receiver's event loop checked non-blocking network socket events without yielding. This resulted in 100% CPU busy-spinning during active streaming, which created thread-scheduling contention and starved the real-time SDL audio thread. Starving this thread caused sporadic playout underflows and stuttering. Yielding for 1ms via `SDL_Delay(1)` in the main loop when the network socket is idle (0 bytes read) completely resolves this CPU starvation.

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

* We set a strict maximum latency ceiling of **150 ms**, expressed as `AUDIO_BACKLOG_MAX_MS * AUDIO_BYTES_PER_MS`. Deriving it matters: written out as a byte count it silently became 75 ms when the wire moved from Int16 to Float32.
* In `on_packet`'s `TB_PKT_AUDIO_FRAME` handler, we check the total queued size:
  ```c
  const int cap_bytes = AUDIO_BACKLOG_MAX_MS * AUDIO_BYTES_PER_MS;
  if (a->audio_buf_size + len > cap_bytes) {
      int excess = (a->audio_buf_size + len) - cap_bytes;
      a->audio_buf_tail = (a->audio_buf_tail + excess) % AUDIO_BUF_CAP;
      a->audio_buf_size -= excess;
  }
  ```
* **How it works**: If a burst of socket-backlogged packets arrives, the check immediately triggers. Instead of deleting all data, it **advances the read tail pointer by the exact excess byte count**.
* **The Result**: The oldest, lagging samples are skipped instantly. The circular buffer is left holding exactly **150ms of the newest, most up-to-date audio samples**.
* **Acoustics**: Truncating just the oldest samples in this manner is perceived by the ear as a seamless micro-skip, maintaining crystal-clear playout fidelity, while guaranteeing that audio latency stays perfectly locked to the video stream.

---

## 🛠️ Diagnostics & Tweaking

Developers can tweak the following properties in `main.c` depending on hardware limits:

1. **`spec.samples` (Hardware Buffer Size)**:
   - Configured at `1024` samples. If run on modern Apple Silicon, this can be safely reduced to `512` (10.6ms) or `256` (5.3ms) for even lower latency.
   - For older Intel Macs or high CPU scheduling jitter, keep this at `1024` to prevent scheduling underflows (which cause crackling/static).
2. **`cap_bytes` (Latency Threshold)**:
   - Configured at `AUDIO_BACKLOG_MAX_MS` (150 ms) to cushion against ScreenCaptureKit's variable delivery chunks and socket congestion.
   - If H.264 video decoding takes longer on a specific system, this can be adjusted to match video latency.

---

## Format negotiation

Sender and receiver ship as separate binaries and are updated independently, so
neither may assume the other's version. Both directions therefore announce what
they can take, and **both default to the older Int16 format when the peer says
nothing** — a silent peer is an old peer.

| Direction | Announced in | Field | Absent means |
|---|---|---|---|
| Receiver → sender | display profile | `supportsFloat32Audio` | old receiver; sender sends Int16 |
| Sender → receiver | hello | `audioFormat` (`"f32"` / `"s16"`) | old sender; receiver widens Int16 to float |

The receiver's output device is always opened as float and an older sender's
Int16 is widened on ingest, rather than reopening the device mid-session.

Int16 conversion is asymmetric, by convention: two's-complement Int16 spans
−32768…+32767, so widening divides by 32768 to map the full negative rail to
−1.0, while narrowing multiplies by 32767 and clamps so +1.0 cannot wrap.

---

## Virtual audio device (Audio Driver addon)

Optional, off by default, and gated by the `audio-driver` addon capability. It
presents the receiver's speakers and microphone as ordinary macOS devices so any
app can pick them from the Sound menu. See
[TargetBridge-AudioDriver/README.md](../TargetBridge-AudioDriver/README.md).

Two loopback UDP ports carry it, both in IANA's dynamic/private range
(49152–65535):

| Port | Direction | Carries |
|---|---|---|
| 51710 | driver → sender | output audio |
| 51711 | sender → driver | microphone audio |

**Liveness is detected by probing, not by listening.** The plug-in runs inside a
host process we do not control, where a leftover instance can hold a fixed port
for minutes and `bind()` then fails with `EADDRINUSE` without recovering.
Sending has no such failure mode: a connected UDP socket reports ICMP
port-unreachable as `ECONNREFUSED`, so an unanswered probe is the signal that
the sender is gone. Three consecutive failures withdraw the device — removed
outright rather than marked not-alive, because macOS moves the user to another
output when a device *disappears*, the way real hardware does when unplugged.

**Microphone buffering targets a latency, not a size.** The two ends run on
independent 48 kHz clocks with no shared reference, so drift accumulates in one
direction and a merely-large buffer eventually runs full and stays full. The
backlog is held near 30 ms and trimmed oldest-first past 60 ms. This is the
cheap tier of standard practice — PulseAudio and PipeWire resample toward a
target latency, WebRTC's NetEq tracks a target delay and time-stretches — all of
which share the same principle: pick a target and correct toward it.
