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
#define TB_PKT_HEARTBEAT        0x30
#define TB_PKT_TEARDOWN         0x31
#define TB_PKT_CURSOR           0x32
#define TB_PKT_INPUT_EVENT      0x33
#define TB_PKT_INPUT_CONTROL    0x34
#define TB_PKT_BRIGHTNESS       0x35
#define TB_PKT_CLIPBOARD        0x36
#define TB_PKT_VOLUME           0x37
#define TB_PKT_TEST_DATA        0x40

#define TB_HDR_BYTES        5   /* 4 length + 1 type */

/* Receiver's microphone, flowing receiver -> sender: raw PCM in the audio wire
 * format below, no JSON wrapper. The sender feeds it into the virtual audio
 * device's input stream so the receiver's mic appears as an input there. */
#define TB_PKT_MIC_FRAME        0x38

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
