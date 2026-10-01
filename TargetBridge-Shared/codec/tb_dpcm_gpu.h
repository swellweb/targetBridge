/* tb_dpcm_gpu.h — TBD2 encoder on the GPU.
 *
 * WHY THIS IS NOT ON THE CPU
 *
 * The reference encoder in tb_dpcm.c costs ~95 ms/frame single-threaded at 5K.
 * Spread over the sender's performance cores it would reach roughly 12 ms, which
 * fits 60 Hz on paper — and is the wrong answer anyway. The sender is the
 * machine somebody is actually using, and spending most of eight cores on video
 * compression to drive a second display is exactly the cost this whole feature
 * exists to avoid. The GPU is idle by comparison.
 *
 * WHY IT IS THREE STEPS
 *
 * No tile's payload position is known until every earlier tile's bit widths are,
 * so the work splits at that dependency:
 *
 *   1. analyze  (GPU)  one threadgroup per tile, one thread per pixel: compute
 *                      every residual, reduce to a bit width per channel, and
 *                      record the tile's seed and its total bit cost.
 *   2. plan     (CPU)  prefix-sum the per-tile costs into the group table and
 *                      each tile's bit offset, and pack the width nibbles. This
 *                      is O(tiles), 1/64th of the per-pixel work, and the host
 *                      has to write the header and read the final length anyway.
 *   3. pack     (GPU)  one thread per (tile, channel), each packing a contiguous
 *                      run of residuals into the payload.
 *
 * Encoding is embarrassingly parallel in a way decoding is not: the encoder
 * predicts from ORIGINAL samples, never reconstructed ones, so no pixel waits on
 * its neighbour. The decoder's prefix-sum trick is unnecessary here.
 *
 * Step 3 needs care about one thing only. Residuals are bit-packed with no
 * padding inside a group, so neighbouring threads share the words at the ends of
 * their runs. Each thread therefore accumulates into a register and writes whole
 * 32-bit words it owns outright, using an atomic OR for just the first and last
 * word of its run — two atomics per thread instead of two per residual, which is
 * 1.4 million rather than 66 million at 5K. Group byte-alignment (see tb_dpcm.h)
 * is what keeps that boundary sharing local to a group.
 */

#ifndef TB_DPCM_GPU_H
#define TB_DPCM_GPU_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct tb_dpcm_gpu tb_dpcm_gpu;

/* Build an encoder: device, pipelines, and buffers that are reused across
 * frames. Returns NULL if there is no Metal device or a shader fails to compile,
 * in which case the caller must not offer DPCM at all. */
tb_dpcm_gpu *tb_dpcm_gpu_create(void);
void         tb_dpcm_gpu_destroy(tb_dpcm_gpu *e);

/* Human-readable device name, for logs. Never NULL. */
const char  *tb_dpcm_gpu_device_name(const tb_dpcm_gpu *e);

/* Encode one packed 32-bit frame. `ten_bit` selects ARGB2101010LE over
 * BGRA8888.
 *
 * `header_reserve` bytes are left free immediately BEFORE the blob, so a caller
 * that has to prepend a packet header can write it in place and send one
 * contiguous buffer. Measured worth doing: two copies of a ~30 MB frame is ~3 ms
 * of the 10.1 ms this stage costs per frame, and the memcpy bandwidth was a
 * visible share of the sender's CPU. `*out_blob` points at the start of the
 * reserved region and the return value includes it.
 *
 * Returns the encoded length and, via `out_blob`, a pointer to it. The blob is
 * owned by the encoder and stays valid until the next call — callers are
 * expected to hand it straight to the socket, which is why it is not copied.
 * Returns 0 on failure, leaving `out_blob` untouched.
 *
 * `src` is read without being copied when it is page-aligned, which is the case
 * for the IOSurface-backed pixel buffers ScreenCaptureKit provides, so the frame
 * never crosses the bus twice and the CPU never reads a pixel. Unaligned input
 * is staged through a copy rather than refused. */
size_t tb_dpcm_gpu_encode(tb_dpcm_gpu *e,
                          const uint8_t *src, int stride, int w, int h,
                          int ten_bit, size_t header_reserve,
                          const uint8_t **out_blob);

/* One encoded band, as returned by tb_dpcm_gpu_encode_bands(). Same ownership
 * rule as the single-frame call: the memory belongs to the encoder and stays
 * valid only until the next encode. */
typedef struct {
    const uint8_t *blob;   /* start of the reserved header run */
    size_t         len;    /* header_reserve + encoded bytes */
} tb_dpcm_gpu_band;

/* Encode `band_count` equal horizontal bands of `band_h` rows each, in TWO GPU
 * round trips for the whole frame instead of two per band.
 *
 * WHY THIS EXISTS
 *
 * tb_dpcm_gpu_encode() blocks twice — once after analyze, once after pack —
 * because step 2 runs on the host between them. Calling it once per band made
 * that 2N blocking waits, and the cost is not the GPU work (which is identical)
 * but the wait itself: each one is a kernel round trip whose latency depends on
 * what else is queued on the device. The sender shares the GPU with WindowServer
 * and with whatever the user is watching, so an unlucky wait can be tens of
 * milliseconds — and with eight chances per frame instead of two, the TAIL
 * compounds even though the mean barely moves.
 *
 * Measured at 4 bands on a 5K frame: `process` (capture callback entry to send)
 * averaged 15 ms against a 16.7 ms budget, and spiked to 48 ms while a video was
 * playing, against 26-30 ms on ordinary desktop content. Those spikes are what
 * bunches two frames onto the wire together and shifts a 25 fps video's 2,3,2,3
 * pulldown into visible judder.
 *
 * Every band shares one geometry — same width, same height, same tile grid — so
 * the per-band regions of every buffer are a fixed stride apart and the whole
 * frame is one dispatch loop inside one command buffer.
 *
 * `src` points at the FULL frame, not at a band; each band reads from its own
 * row offset. That also restores zero-copy for every band: the caller used to
 * advance the pointer per band, and only a band whose byte offset happened to
 * land on a page boundary could be wrapped without a copy.
 *
 * `out` must have room for `band_count` entries. Returns the total encoded
 * length across all bands, or 0 on failure, in which case `out` is untouched.
 * `band_count` is capped at TB_DPCM_GPU_MAX_BANDS. */
#define TB_DPCM_GPU_MAX_BANDS 64

size_t tb_dpcm_gpu_encode_bands(tb_dpcm_gpu *e,
                                const uint8_t *src, int stride, int w, int band_h,
                                int band_count, int ten_bit, size_t header_reserve,
                                tb_dpcm_gpu_band *out);

/* How many frames may be encoding at once. Each in-flight frame needs its own
 * blob, meta and offs buffers, so this is the memory multiplier; three matches
 * the sender's in-flight packet budget. */
#define TB_DPCM_GPU_JOBS 3

/* Called once per band AS IT FINISHES, in submission order, on the encoder's own
 * queue — NOT the caller's.
 *
 * Per band rather than per frame so the wire sees a band the moment it is ready,
 * instead of four packets bursting out together when the last one lands. That
 * burst is visible at the far end: the receiver's presentation cadence is
 * sensitive to emission spacing in a way the sender's own numbers are not.
 *
 * `band` is valid only for the duration of the call. `last` is non-zero on the
 * final band, after which the job slot is recycled — so the caller must release
 * any per-frame ownership exactly then, and not before.
 *
 * `ok` is 0 if that band's encode failed, in which case `band` is meaningless;
 * `last` is still delivered so the caller can clean up. */
typedef void (*tb_dpcm_gpu_done)(void *ctx, int ok,
                                 const tb_dpcm_gpu_band *band,
                                 int index, int last);

/* Encode without blocking the calling thread.
 *
 * WHY
 *
 * tb_dpcm_gpu_encode_bands() waits on the GPU twice, and those waits happen on
 * whatever thread called it — for the sender that is ScreenCaptureKit's capture
 * queue, the one thing that must keep up with the display. Measured there:
 * `process` (callback entry to send) ran 13-15 ms against a 16.7 ms period,
 * because the wait is not for our own work but for a GPU shared with
 * WindowServer and whatever the user is watching. With ~2 ms of headroom any
 * spike pushes a frame into the next period, and then two go out together:
 * capture measured a clean 100% while `send` sat at 85-90% with 7% of packets
 * leaving within 8 ms of the previous one.
 *
 * Batching the bands into two submissions cut the round trips from 2N to 2 and
 * bought about 1 ms, which is all it could: the cost was never the number of
 * waits, it was waiting at all.
 *
 * So this submits and returns. The host-side plan step still has to run between
 * the two GPU passes, but it runs on the encoder's own serial queue rather than
 * the caller's, and `done` fires from there too.
 *
 * OWNERSHIP
 *
 * `src` is read by the GPU AFTER this returns, so the caller must keep those
 * pixels alive and unmodified until `done` runs — for a CVPixelBuffer that
 * means holding the lock and a reference, not just the pointer.
 *
 * Returns 0 if the frame was submitted, -1 if it was rejected: bad geometry, or
 * TB_DPCM_GPU_JOBS frames already in flight. A rejection is ordinary
 * backpressure and the caller should drop the frame; `done` is NOT called.
 *
 * Completion order matches submission order — one command queue, and the plan
 * stage is serial. */
int tb_dpcm_gpu_encode_bands_async(tb_dpcm_gpu *e,
                                   const uint8_t *src, int stride, int w, int band_h,
                                   int band_count, int ten_bit, size_t header_reserve,
                                   tb_dpcm_gpu_done done, void *ctx);

/* Wait for every in-flight frame to finish. Call before destroying the encoder
 * or the pixel buffers it is still reading. */
void tb_dpcm_gpu_drain(tb_dpcm_gpu *e);

/* Whether the last encode could read `src` in place. Reported so the sender can
 * say so once rather than guessing about it. */
int tb_dpcm_gpu_last_was_zero_copy(const tb_dpcm_gpu *e);

#ifdef __cplusplus
}
#endif

#endif
