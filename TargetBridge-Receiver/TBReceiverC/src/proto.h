/* proto.h — TBDisplay monitor-emulation wire protocol constants.
 *
 * Wire format on the TCP stream:
 *   [4 bytes BE uint32 length][1 byte type][payload (length-1 bytes)]
 *
 * type 0x10 = hello receiver (JSON)
 * type 0x11 = display profile (JSON)
 * type 0x12 = create session ack (JSON)
 * type 0x13 = ui language update (JSON)
 * type 0x20 = parameter sets (H.264: SPS/PPS; HEVC: VPS/SPS/PPS)
 *   payload = [1 byte codec marker: 1=H.264, 2=HEVC][1 byte count]
 *             then for each set: [4 bytes BE uint32 size][size bytes]
 *   (see build_extradata in decoder.c)
 *
 * type 0x21 = video frame
 *   payload = AVCC-formatted NAL units, 4-byte BE length prefixes (no start codes)
 *
 * type 0x22 = raw video frame (uncompressed NV12, "raw passthrough" mode)
 *   payload = [1 byte format: 1=NV12][4 BE uint32 width][4 BE uint32 height]
 *             [4 BE uint32 yStride][4 BE uint32 uvStride]
 *             [Y plane: yStride*height][CbCr plane: uvStride*(height/2)]
 *   (see handle_raw_frame in main.c; sender-side sendRawFrame)
 *
 * type 0x30 = heartbeat (JSON)
 * type 0x31 = teardown (JSON)
 * type 0x32 = cursor position (JSON)
 * type 0x33 = input relay event (JSON)
 * type 0x34 = input control mode update (JSON)
 * type 0x35 = brightness update (JSON)
 * type 0x36 = clipboard update (JSON)
 * type 0x37 = volume update (JSON)
 *
 * Compatible with the new TBDisplaySender Swift app.
 */

#ifndef TB_PROTO_H
#define TB_PROTO_H

#include <stdint.h>

#define TB_PORT             54321
#define TB_PKT_HELLO_RECEIVER   0x10
#define TB_PKT_DISPLAY_PROFILE  0x11
#define TB_PKT_CREATE_SESSION_ACK 0x12
#define TB_PKT_UI_LANGUAGE      0x13
#define TB_PKT_PARAM_SETS       0x20
#define TB_PKT_FRAME            0x21
#define TB_PKT_RAW_FRAME        0x22  /* uncompressed NV12 planes (raw passthrough) */
#define TB_PKT_AUDIO_FRAME      0x23
/* Damage update: only the rectangles that changed since the previous frame.
 * ScreenCaptureKit hands the sender the WindowServer's own dirty rects, so
 * detection is free; this just avoids resending the ~98% of a 5K desktop that
 * is usually identical frame to frame.
 *   [1] format (2 = BGRA8888, 3 = ARGB2101010 — packed 32bpp only)
 *   [4] frame width   [4] frame height
 *   [2] rect count
 *   per rect: [4] x  [4] y  [4] w  [4] h  then w*h*4 bytes, rows packed tight
 * A full TB_PKT_RAW_FRAME must arrive first (and periodically after) so the
 * receiver has a complete base image to patch into. */
#define TB_PKT_RAW_DAMAGE       0x24
/* Full frame, losslessly compressed with tile-DPCM (TBD1; see tb_dpcm.h). The
 * payload is one TBD1 blob and nothing else — its own header carries the
 * dimensions, so none are repeated here.
 *
 * This exists for the case damage rectangles cannot help: fullscreen video and
 * fast scrolling, where most of the screen really is new every frame and the
 * sender falls back to whole frames. Measured 2.96x on near-worst-case
 * photographic content and 4.5-14x on desktop content, which turns a 23.4 ms
 * receive into ~8 ms.
 *
 * Only sent to a receiver that advertised "supportsDPCM" in its display
 * profile, which is conditional on a working Metal decoder: decoding costs
 * ~44 million bit extractions per 5K frame, which this receiver's CPU cannot
 * afford (measured 166 ms single-threaded on the target iMac, against 6.5 ms on
 * its GPU). A silent peer is an old peer and keeps getting TB_PKT_RAW_FRAME. */
#define TB_PKT_RAW_DPCM         0x25
/* One horizontal BAND of a TBD2 frame. Payload is a 28-byte header, big-endian
 * like the rest of the protocol, followed by a TBD2 blob covering rows
 * [y0, y0+height) of the frame:
 *
 *   [8] capture_time  sender host clock, nanoseconds, at frame acquisition
 *   [4] frame_id      monotonic; a change means a new frame started
 *   [4] frame_w       full surface width  (bands are always full width)
 *   [4] frame_h       full surface height
 *   [4] y0            first row of this band, a multiple of the 8-row tile
 *   [2] slice_index
 *   [2] slice_count
 *
 * Slicing exists so the stages stop running end to end: band k decodes while
 * band k+1 is still crossing the wire. Measured, that roughly halves frame
 * latency — 23.6 ms to ~12 at 8-bit — because the wire is the slowest stage and
 * everything else can hide behind it.
 *
 * It costs nothing in bytes. Tiles were already independent 8x8 units with
 * byte-aligned group bases, so a band is just a shorter frame: measured
 * byte-for-byte identical to a whole-frame encode at every slice count tried,
 * both depths, and the reassembled pixels are bit-identical.
 *
 * Sent only to a receiver advertising "supportsDPCMSlices". A receiver that
 * understands 0x25 but not this keeps getting whole frames. */
#define TB_PKT_RAW_DPCM_SLICE   0x26
#define TB_DPCM_SLICE_HEADER    28

#define TB_PKT_HEARTBEAT        0x30
#define TB_PKT_TEARDOWN         0x31
#define TB_PKT_CURSOR           0x32
#define TB_PKT_INPUT_EVENT      0x33
#define TB_PKT_INPUT_CONTROL    0x34
#define TB_PKT_BRIGHTNESS       0x35
#define TB_PKT_CLIPBOARD        0x36
#define TB_PKT_VOLUME           0x37
/* Display tweaks on the receiver's panel: JSON {"nightShift":bool,"trueTone":bool}.
 * Both are private CoreBrightness features, so the receiver reports whether it
 * can honour them in its display profile. */
#define TB_PKT_DISPLAY_TWEAKS   0x38
/* Receiver's microphone, flowing receiver -> sender: raw 48 kHz stereo Int16,
 * no JSON wrapper. The sender feeds it into the virtual audio device's input
 * stream so the receiver's mic appears as an input on the sender Mac. */
#define TB_PKT_MIC_FRAME        0x39
#define TB_PKT_TEST_DATA        0x40
/* The receiver's stderr, flowing receiver -> sender: raw UTF-8 text, no JSON
 * wrapper and no line framing — a packet is whatever bytes were pending, which
 * may split a line or carry several. The sender appends them to a file so both
 * sides' logs can be read from one machine. Diagnostic only: a sender that does
 * not know this type ignores it, and a receiver whose sender never asks simply
 * keeps writing to its own console. */
#define TB_PKT_LOG              0x41

/* One tile-aligned RECTANGLE of a TBD2 frame: a 32-byte header then the blob.
 *
 * The same idea as a band (0x26) in both axes. A band is a full-width strip at a
 * row offset; a rect adds a column offset and a width, and the codec needs
 * nothing for either — an encoder handed (base + y*stride + x*4, stride, w, h)
 * produces a blob that decodes losslessly on its own, verified against the
 * reference encoder.
 *
 * Why it exists: with the pipeline fixed, the wire is the largest term left, and
 * a desktop changes a few percent of its pixels per frame while we send all of
 * them. It also deletes most of the host-side plan work, which is O(tiles).
 *
 *   [0]  capture_time  sender host clock, nanoseconds, at frame acquisition
 *   [8]  frame_id      increments per frame; all rects of a frame share it
 *   [12] frame_w       full surface, for validation
 *   [16] frame_h
 *   [20] x0            destination column, multiple of TB_DPCM_TILE
 *   [24] y0            destination row, multiple of TB_DPCM_TILE
 *   [28] index         which rect of this frame
 *   [30] count         how many rects the frame has; the last one presents
 *
 * Only sent to a receiver that advertised `supportsDPCMRects`; one that did not
 * keeps getting whole frames or bands, so an older receiver is unaffected. */
#define TB_PKT_RAW_DPCM_RECT    0x27
#define TB_DPCM_RECT_HEADER     32

#define TB_HDR_BYTES        5   /* 4 length + 1 type */


/* ---- Audio wire format -------------------------------------------------
 *
 * 48 kHz, stereo, 32-bit float, interleaved, native endian — CoreAudio's
 * canonical format, matched end to end so nothing quantises along the way.
 * Senders older than this negotiate down to Int16; see "audioFormat" in the
 * hello and "supportsFloat32Audio" in the display profile.
 *
 * Sizes are derived, never written out: a literal byte count silently changes
 * meaning when the sample size does, which is how a 150 ms backlog cap became
 * 75 ms when this path moved from Int16 to Float32.
 *
 * Must agree with TBAudioWireFormat.swift and TargetBridge-AudioDriver/Driver.cpp.
 */
#define AUDIO_SAMPLE_RATE      48000
#define AUDIO_CHANNELS         2
#define AUDIO_BYTES_PER_SAMPLE ((int)sizeof(float))
#define AUDIO_BYTES_PER_FRAME  (AUDIO_CHANNELS * AUDIO_BYTES_PER_SAMPLE)
#define AUDIO_BYTES_PER_MS     (AUDIO_SAMPLE_RATE * AUDIO_BYTES_PER_FRAME / 1000)

/* Int16 fallback scaling. Asymmetric on purpose: two's-complement Int16 runs
 * -32768..+32767, so widening divides by 32768 to map the full negative rail to
 * -1.0, and narrowing multiplies by 32767 so +1.0 cannot wrap. */
#define AUDIO_INT16_TO_FLOAT   32768.0f

#endif