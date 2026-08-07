/* tb_dpcm.h — TBD2, a lossless tile-DPCM wire format for 4:4:4 frames.
 *
 * WHY THIS EXISTS
 *
 * The receiver spends 23.4 ms of a 36 ms frame just pulling bytes off the wire
 * (single-core cost inside the TCP stack, measured), and another 12.9 ms pushing
 * the same bytes across PCIe to the GPU. Both costs are proportional to frame
 * size, so the cheapest way to raise the frame rate is to send fewer bytes.
 * Damage rectangles already handle the case where little changed; this handles
 * the case they cannot — fullscreen video and fast scrolling, where most of the
 * screen genuinely is new every frame and the sender falls back to full frames.
 *
 * Measured on real content (see the ratio probe): 2.96x on a 36-megapixel photo,
 * which is close to worst case, 4.5x on text-heavy UI, 13.8x on ordinary window
 * chrome. LZFSE on the same photo gets 3.48x, so this captures 85% of what a
 * real entropy coder finds, at a small fraction of the cost. It is LOSSLESS —
 * every output sample is bit-identical to the input.
 *
 * THE SHAPE OF THE FORMAT, AND WHY
 *
 * DPCM is inherently serial: each residual is relative to the pixel before it,
 * so a decoder cannot start pixel N before finishing pixel N-1. That is fatal on
 * a GPU, and the receiver's GPU is the only spare compute it has (its CPU cores
 * are already the bottleneck). So the frame is cut into 8x8 tiles that are
 * FULLY INDEPENDENT: each carries its own seed pixel and its own bit widths, and
 * needs nothing from any neighbour. One GPU threadgroup per tile, 230400 of them
 * at 5K, which is the shape a GPU wants.
 *
 * 8x8 was measured, not guessed. 4x4 wins marginally on dense text (4.71x vs
 * 4.46x) but loses badly on flat content (9.7x vs 13.8x) because it pays four
 * times the per-tile overhead where there is nothing to code. 16x16 loses
 * everywhere: one high-contrast edge sets the bit width for 256 pixels.
 *
 * The predictor is the left neighbour, with the first column predicting from
 * above. JPEG-LS's median-edge predictor was measured too and ties it to within
 * 1% on every frame tested, including the photo — inside an 8x8 tile there is
 * not enough vertical run for it to earn its three extra loads and a clamp.
 *
 * Residuals are taken modulo the sample range (256 or 1024) and re-centred, so
 * reconstruction wraps and stays exact. Zigzagged, the widest possible residual
 * needs exactly the sample depth — the same as a raw sample — so a tile can
 * never expand beyond its header, and no escape hatch is needed for
 * pathological content.
 *
 * TWO SAMPLE DEPTHS
 *
 * 8-bit codes the three bytes of a BGRA8888 pixel; 10-bit codes the three
 * fields of an ARGB2101010LE ('l10r') pixel. 10-bit exists because of a
 * measured artefact of the capture path: the virtual display's framebuffer is
 * 8-bit, but the capture-side conversion to Display P3 manufactures sub-8-bit
 * detail on its way into the 10-bit container, and on the panel that detail is
 * the difference between a smooth gradient and a banded one. A codec that only
 * carried 8 bits would permanently trade that quality away for speed.
 *
 * Payload lengths vary per tile, so a decoder needs to know where its tile
 * starts. Shipping an offset per tile would cost 4 bytes x 230400 = 921 KB, which
 * would wreck the ratio on the flat frames where the win is largest. Instead
 * tiles are grouped 64 at a time with one base offset per group, and each
 * threadgroup recovers its members' offsets with a 64-element scan in
 * threadgroup memory. The group table costs 14 KB at 5K, and the wire carries no
 * per-tile offsets at all.
 *
 * Each group's payload starts on a BYTE boundary (the base offsets in the table
 * are still expressed in bits, but are always multiples of 8). This costs at
 * most 7 bits per group — ~3 KB a frame — and is what makes the ENCODER
 * parallel: two threads packing adjacent groups never share a byte, so groups
 * can be written concurrently. Within a group, residuals are packed with no
 * padding and concurrent writers must merge (the GPU encoder uses atomic OR).
 * The width and seed planes are padded to 4-byte multiples for the same reason:
 * every section a GPU touches starts at an offset it can address as words.
 *
 * BYTE ORDER
 *
 * Everything inside a blob is LITTLE-endian, unlike the enclosing TB packet
 * header, which stays big-endian as it always was. This is deliberate: the blob
 * is produced and consumed by GPUs on little-endian machines, and byte-swapping
 * the group table (or swizzling in the shaders) would be pure waste. The blob
 * is opaque to the packet layer.
 */

#ifndef TB_DPCM_H
#define TB_DPCM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 'TBD2' as little-endian bytes T,B,D,2. TBD1 lacked 10-bit and the group
 * byte-alignment; the magic changed with the layout so a version mismatch is a
 * clean "wrong magic" rejection rather than a subtle mis-parse. */
#define TB_DPCM_MAGIC       0x32444254u
#define TB_DPCM_TILE        8
#define TB_DPCM_CHANNELS    3             /* alpha is not carried; see flags */
#define TB_DPCM_GROUP       64            /* tiles per group == threadgroup size */
#define TB_DPCM_HEADER      32            /* bytes before the group table */

/* flags */
#define TB_DPCM_FLAG_ALPHA_OMITTED  0x01u
#define TB_DPCM_FLAG_TEN_BIT        0x02u /* samples are 10-bit ('l10r') */

/* Fixed-size prologue. All fields little-endian. Immediately followed by:
 *   group_count * uint32   group base offsets, in BITS into the payload
 *                          (always multiples of 8; see alignment note above)
 *   width_plane_bytes      4 bits per (tile, channel), tile-major; padded to
 *                          a 4-byte multiple
 *   seed_plane_bytes       per tile, one LE uint32 holding the seed pixel
 *                          (three 8-bit or three 10-bit samples)
 *   payload_bytes          bit-packed residuals
 */
struct tb_dpcm_header {
    uint32_t magic;
    uint32_t width;
    uint32_t height;
    uint8_t  log2_tile;          /* 3 => 8x8 */
    uint8_t  channels;           /* 3 */
    uint8_t  flags;
    uint8_t  reserved;
    uint32_t group_count;
    uint32_t width_plane_bytes;
    uint32_t seed_plane_bytes;
    uint32_t payload_bytes;
};

/* Everything a decoder needs after parsing, including where each plane starts.
 * Offsets are byte offsets from the start of the blob. */
struct tb_dpcm_info {
    int      width, height;
    int      tile;               /* 8 */
    int      channels;           /* 3 */
    int      alpha_omitted;
    int      ten_bit;
    int      tiles_x, tiles_y;
    uint32_t tile_count;
    uint32_t group_count;
    size_t   group_table_off;
    size_t   width_plane_off;
    size_t   seed_plane_off;
    size_t   payload_off;
    size_t   payload_bytes;
    size_t   total_bytes;
};

/* Upper bound on the encoded size of a w x h frame at either depth, so callers
 * can allocate once and never check again. Every tile's payload is capped at
 * the raw sample depth per coded sample, so the bound is raw + fixed overhead. */
size_t tb_dpcm_max_size(int w, int h);

/* Encode one packed 32-bit frame into `dst`. `stride` is bytes per row of
 * `src`. `ten_bit` selects ARGB2101010LE samples over BGRA8888; the pixel size
 * is 4 bytes either way. Returns bytes written, or 0 if `dst_cap` is too small
 * or the inputs are bad. Alpha is dropped; decoders reconstruct it as opaque.
 *
 * This is the REFERENCE encoder — the correctness oracle for the Metal encoder
 * on the sender, and far too slow to run per-frame at 5K (~95 ms single-
 * threaded). Production encoding happens on the GPU precisely so the sender's
 * CPU stays free for the person using the machine. */
size_t tb_dpcm_encode(const uint8_t *src, int stride, int w, int h,
                      int ten_bit, uint8_t *dst, size_t dst_cap);

/* Validate a blob and fill in `out`. Returns 0 on success, non-zero if the blob
 * is malformed or inconsistent — this runs on untrusted network data, so every
 * declared length is checked against the actual one. */
int tb_dpcm_parse(const uint8_t *src, size_t len, struct tb_dpcm_info *out);

/* Reference decode into a packed 32-bit frame, alpha forced opaque. `stride` is
 * bytes per row of `dst`. Returns 0 on success.
 *
 * The correctness oracle for the receiver's GPU decoder, and too slow to stand
 * in for it (166 ms/frame measured on the target iMac's i5, against 6.5 ms on
 * its GPU). */
int tb_dpcm_decode(const uint8_t *src, size_t len, uint8_t *dst, int stride);

#ifdef __cplusplus
}
#endif

#endif
