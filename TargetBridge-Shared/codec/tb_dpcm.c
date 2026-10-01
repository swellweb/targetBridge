/* tb_dpcm.c — reference encoder/decoder for TBD2. See tb_dpcm.h for the format
 * and the reasoning behind its shape.
 *
 * Both directions here are correctness oracles, not production paths. The
 * decoder performs ~44 million bit extractions per 5K frame, which the
 * receiver's i5 cannot afford on top of a TCP stack that already saturates a
 * core (166 ms measured, against 6.5 ms on its GPU). The encoder is a
 * straightforward two-pass implementation — it computes bit widths, then
 * re-derives the residuals to emit them — which costs double the prediction work
 * in exchange for not holding a 44 MB residual buffer. At ~95 ms/frame it exists
 * to verify the GPU encoder, not to replace it: the sender's CPU belongs to the
 * person using the machine.
 */

#include "tb_dpcm.h"

#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------- little-endian */

/* Written out by hand rather than memcpy'd from a struct: the header must have
 * exactly this layout on every compiler, with no padding surprises. */
static inline void put_u32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v      );
    p[1] = (uint8_t)(v >>  8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

static inline uint32_t get_u32(const uint8_t *p) {
    return (uint32_t)p[0]
         | ((uint32_t)p[1] <<  8)
         | ((uint32_t)p[2] << 16)
         | ((uint32_t)p[3] << 24);
}

static inline size_t round4(size_t n) { return (n + 3u) & ~(size_t)3u; }

/* ------------------------------------------------------------------ bit twiddling */

/* Write the low `n` bits of `v` at bit position `p`. The buffer must be zeroed:
 * this ORs rather than masking, which keeps it to at most three byte writes.
 * n <= 10 and the bit offset within a byte is <= 7, so a value spans at most
 * 17 bits, i.e. three bytes. */
static inline void bw_put(uint8_t *buf, size_t p, uint32_t v, int n) {
    if (n == 0) return;
    size_t   byte = p >> 3;
    int      sh   = (int)(p & 7);
    uint32_t x    = (v & ((1u << n) - 1u)) << sh;
    buf[byte] |= (uint8_t)(x & 0xFF);
    if (sh + n >  8) buf[byte + 1] |= (uint8_t)((x >>  8) & 0xFF);
    if (sh + n > 16) buf[byte + 2] |= (uint8_t)((x >> 16) & 0xFF);
}

static inline uint32_t br_get(const uint8_t *buf, size_t p, int n) {
    if (n == 0) return 0;
    size_t   byte = p >> 3;
    int      sh   = (int)(p & 7);
    uint32_t x    = (uint32_t)buf[byte];
    if (sh + n >  8) x |= (uint32_t)buf[byte + 1] <<  8;
    if (sh + n > 16) x |= (uint32_t)buf[byte + 2] << 16;
    return (x >> sh) & ((1u << n) - 1u);
}

static inline int bits_for(uint32_t v) {
    int n = 0;
    while (v) { ++n; v >>= 1; }
    return n;
}

/* Nibble-packed bit widths: (tile, channel) -> 4 bits, tile-major. A width can
 * reach 10 at 10-bit depth, which still fits a nibble. */
static inline void width_put(uint8_t *plane, uint32_t idx, int n) {
    if (idx & 1u) plane[idx >> 1] |= (uint8_t)((n & 0xF) << 4);
    else          plane[idx >> 1] |= (uint8_t)( n & 0xF);
}

static inline int width_get(const uint8_t *plane, uint32_t idx) {
    uint8_t b = plane[idx >> 1];
    return (idx & 1u) ? (b >> 4) : (b & 0xF);
}

/* ------------------------------------------------------------------ samples */

/* One pixel is 4 bytes at either depth. Channel c sits at bit c*depth, so the
 * same index means blue, green, red in both formats:
 *   8-bit  BGRA8888        : B,G,R at bits 0,8,16   alpha at 24
 *   10-bit ARGB2101010LE   : B,G,R at bits 0,10,20  alpha at 30
 * Read and written whole, via memcpy, so nothing depends on the destination
 * stride happening to be 4-byte aligned. */
struct depth {
    int      bits;      /* 8 or 10 */
    uint32_t mask;      /* (1 << bits) - 1 */
    uint32_t half;      /* 1 << (bits - 1) */
    uint32_t alpha;     /* opaque alpha, already shifted into place */
};

static inline struct depth depth_of(int ten_bit) {
    struct depth d;
    d.bits  = ten_bit ? 10 : 8;
    d.mask  = ten_bit ? 0x3FFu : 0xFFu;
    d.half  = ten_bit ? 0x200u : 0x80u;
    d.alpha = ten_bit ? (3u << 30) : (0xFFu << 24);
    return d;
}

static inline uint32_t px_load(const uint8_t *p) {
    uint32_t v;
    memcpy(&v, p, 4);
    return v;
}

static inline void px_store(uint8_t *p, uint32_t v) {
    memcpy(p, &v, 4);
}

static inline uint32_t sample_of(uint32_t px, int c, const struct depth *d) {
    return (px >> (c * d->bits)) & d->mask;
}

/* Residual as stored: the modular difference re-centred and zigzagged so small
 * magnitudes of either sign need few bits. Reconstruction wraps, so no clamping
 * is needed anywhere and the round trip is exact. */
static inline uint32_t resid_encode(uint32_t cur, uint32_t pred, const struct depth *d) {
    int32_t diff = (int32_t)((cur - pred + d->half) & d->mask) - (int32_t)d->half;
    return (uint32_t)((diff << 1) ^ (diff >> 31));
}

static inline uint32_t resid_decode(uint32_t z, uint32_t pred, const struct depth *d) {
    int32_t diff = (int32_t)((z >> 1) ^ (~(z & 1u) + 1u));
    return ((uint32_t)((int32_t)pred + diff)) & d->mask;
}

/* ------------------------------------------------------------------- geometry */

struct geom {
    int      tiles_x, tiles_y;
    uint32_t tile_count, group_count;
    size_t   width_plane_bytes, seed_plane_bytes;
    size_t   group_table_off, width_plane_off, seed_plane_off, payload_off;
};

static void geom_of(int w, int h, struct geom *g) {
    g->tiles_x = (w + TB_DPCM_TILE - 1) / TB_DPCM_TILE;
    g->tiles_y = (h + TB_DPCM_TILE - 1) / TB_DPCM_TILE;
    g->tile_count  = (uint32_t)g->tiles_x * (uint32_t)g->tiles_y;
    g->group_count = (g->tile_count + TB_DPCM_GROUP - 1) / TB_DPCM_GROUP;

    /* Padded to word multiples so a GPU can bind every plane at an offset it is
     * allowed to address as uint32. */
    uint32_t nibbles = g->tile_count * TB_DPCM_CHANNELS;
    g->width_plane_bytes = round4((nibbles + 1) / 2);
    g->seed_plane_bytes  = (size_t)g->tile_count * 4;

    g->group_table_off = TB_DPCM_HEADER;
    g->width_plane_off = g->group_table_off + (size_t)g->group_count * 4;
    g->seed_plane_off  = g->width_plane_off + g->width_plane_bytes;
    g->payload_off     = g->seed_plane_off  + g->seed_plane_bytes;
}

/* Every bit offset in the format — the group table, and every position a shader
 * computes — is 32 bits. The worst-case payload is 30 bits per pixel, so total
 * pixels must stay below 2^32/30; 2^27 (134M, four 5K frames) keeps the widest
 * blob under 2^32 with margin. Without this cap the parser's offset
 * cross-check would compare truncated values and could bless a blob whose
 * offsets wrap in the shader. */
static inline int dims_ok(int w, int h) {
    return w > 0 && h > 0 && w <= 16384 && h <= 16384 &&
           (uint64_t)w * (uint64_t)h <= (uint64_t)1 << 27;
}

size_t tb_dpcm_max_size(int w, int h) {
    if (!dims_ok(w, h)) return 0;
    struct geom g;
    geom_of(w, h, &g);
    /* Worst case is the deeper format at its widest: 10 bits per coded sample,
     * i.e. exactly the tile's raw size, plus up to 7 bits of alignment padding
     * per group. Bounding by the padded tile grid rather than by w*h covers the
     * partial tiles along the right and bottom edges. */
    size_t coded_bits = (size_t)g.tile_count *
                        (TB_DPCM_TILE * TB_DPCM_TILE - 1) * TB_DPCM_CHANNELS * 10;
    size_t pad_bits   = (size_t)g.group_count * 7;
    return g.payload_off + (coded_bits + pad_bits + 7) / 8 + 16;
}

/* ------------------------------------------------------------------- encoding */

/* Walk one tile-channel, visiting every coded sample in order. Both passes of
 * the encoder and the decoder must agree exactly on this traversal, so it lives
 * in one place.
 *
 * Prediction: the left neighbour, except the first column, which predicts from
 * above. Pixel (0,0) is the seed and is not coded. Reconstructed values equal
 * the originals because the coding is lossless, so the encoder may read either. */
#define TB_TILE_WALK(tw, th, BODY)                                              \
    do {                                                                        \
        for (int _y = 0; _y < (th); ++_y) {                                     \
            for (int _x = 0; _x < (tw); ++_x) {                                 \
                if (_x == 0 && _y == 0) continue;                               \
                const int _px = (_x > 0) ? (_x - 1) : 0;                        \
                const int _py = (_x > 0) ? _y       : (_y - 1);                 \
                BODY                                                            \
            }                                                                   \
        }                                                                       \
    } while (0)

/* Tile geometry from its raster index. */
static inline void tile_rect(const struct geom *g, uint32_t t, int w, int h,
                            int *tx, int *ty, int *tw, int *th) {
    const int txi = (int)(t % (uint32_t)g->tiles_x);
    const int tyi = (int)(t / (uint32_t)g->tiles_x);
    *tx = txi * TB_DPCM_TILE;
    *ty = tyi * TB_DPCM_TILE;
    *tw = (*tx + TB_DPCM_TILE <= w) ? TB_DPCM_TILE : (w - *tx);
    *th = (*ty + TB_DPCM_TILE <= h) ? TB_DPCM_TILE : (h - *ty);
}

/* Advance `bitpos` to where tile `t` begins, applying the group byte-alignment.
 * Encoder, parser and decoder all call this so the rule cannot drift between
 * them — it is the one piece of arithmetic that has to be identical in three
 * places here, and in a fourth in the shaders. */
static inline size_t group_align(size_t bitpos, uint32_t t) {
    if (t % TB_DPCM_GROUP == 0) return (bitpos + 7u) & ~(size_t)7u;
    return bitpos;
}

size_t tb_dpcm_encode(const uint8_t *src, int stride, int w, int h,
                      int ten_bit, uint8_t *dst, size_t dst_cap) {
    if (!src || !dst || !dims_ok(w, h) || stride < w * 4) return 0;

    struct geom g;
    geom_of(w, h, &g);
    if (dst_cap < tb_dpcm_max_size(w, h)) return 0;
    const struct depth d = depth_of(ten_bit);

    uint8_t *widths = calloc(g.tile_count, TB_DPCM_CHANNELS);
    if (!widths) return 0;

    /* Pass 1: the widest residual in each tile-channel decides its bit width. */
    for (uint32_t t = 0; t < g.tile_count; ++t) {
        int tx, ty, tw, th;
        tile_rect(&g, t, w, h, &tx, &ty, &tw, &th);
        const uint8_t *tile = src + (size_t)ty * stride + (size_t)tx * 4;

        for (int c = 0; c < TB_DPCM_CHANNELS; ++c) {
            uint32_t widest = 0;
            TB_TILE_WALK(tw, th, {
                uint32_t cur  = sample_of(px_load(tile + (size_t)_y  * stride + (size_t)_x  * 4), c, &d);
                uint32_t pred = sample_of(px_load(tile + (size_t)_py * stride + (size_t)_px * 4), c, &d);
                uint32_t z = resid_encode(cur, pred, &d);
                if (z > widest) widest = z;
            });
            widths[t * TB_DPCM_CHANNELS + c] = (uint8_t)bits_for(widest);
        }
    }

    /* Group bases, in bits, each rounded up to a byte. One per 64 tiles; threads
     * recover their own offset from a scan within the group, so no per-tile
     * offset goes on the wire. */
    memset(dst, 0, g.payload_off);
    size_t bitpos = 0;
    for (uint32_t t = 0; t < g.tile_count; ++t) {
        bitpos = group_align(bitpos, t);
        if (t % TB_DPCM_GROUP == 0)
            put_u32(dst + g.group_table_off + (size_t)(t / TB_DPCM_GROUP) * 4,
                    (uint32_t)bitpos);

        int tx, ty, tw, th;
        tile_rect(&g, t, w, h, &tx, &ty, &tw, &th);
        const int coded = tw * th - 1;
        for (int c = 0; c < TB_DPCM_CHANNELS; ++c) {
            width_put(dst + g.width_plane_off, t * TB_DPCM_CHANNELS + c,
                      widths[t * TB_DPCM_CHANNELS + c]);
            bitpos += (size_t)widths[t * TB_DPCM_CHANNELS + c] * coded;
        }
    }
    const size_t payload_bytes = (bitpos + 7) / 8;
    memset(dst + g.payload_off, 0, payload_bytes);

    /* Pass 2: seeds and residuals. The running bit position is recomputed with
     * the same alignment rule rather than stored, which keeps the encoder's
     * memory flat; the two loops visit tiles in the same order so they cannot
     * disagree. */
    bitpos = 0;
    for (uint32_t t = 0; t < g.tile_count; ++t) {
        bitpos = group_align(bitpos, t);

        int tx, ty, tw, th;
        tile_rect(&g, t, w, h, &tx, &ty, &tw, &th);
        const uint8_t *tile = src + (size_t)ty * stride + (size_t)tx * 4;

        /* The seed is the tile's top-left pixel, stored raw with alpha dropped. */
        put_u32(dst + g.seed_plane_off + (size_t)t * 4, px_load(tile) & ~d.alpha);

        for (int c = 0; c < TB_DPCM_CHANNELS; ++c) {
            const int n = widths[t * TB_DPCM_CHANNELS + c];
            if (n == 0) continue;   /* flat: every residual is zero */
            TB_TILE_WALK(tw, th, {
                uint32_t cur  = sample_of(px_load(tile + (size_t)_y  * stride + (size_t)_x  * 4), c, &d);
                uint32_t pred = sample_of(px_load(tile + (size_t)_py * stride + (size_t)_px * 4), c, &d);
                bw_put(dst + g.payload_off, bitpos, resid_encode(cur, pred, &d), n);
                bitpos += n;
            });
        }
    }
    free(widths);

    put_u32(dst +  0, TB_DPCM_MAGIC);
    put_u32(dst +  4, (uint32_t)w);
    put_u32(dst +  8, (uint32_t)h);
    dst[12] = 3;                                  /* log2(8) */
    dst[13] = TB_DPCM_CHANNELS;
    dst[14] = (uint8_t)(TB_DPCM_FLAG_ALPHA_OMITTED |
                        (ten_bit ? TB_DPCM_FLAG_TEN_BIT : 0u));
    dst[15] = 0;
    put_u32(dst + 16, g.group_count);
    put_u32(dst + 20, (uint32_t)g.width_plane_bytes);
    put_u32(dst + 24, (uint32_t)g.seed_plane_bytes);
    put_u32(dst + 28, (uint32_t)payload_bytes);

    return g.payload_off + payload_bytes;
}

/* -------------------------------------------------------------------- parsing */

int tb_dpcm_parse(const uint8_t *src, size_t len, struct tb_dpcm_info *out) {
    if (!src || !out || len < TB_DPCM_HEADER) return -1;
    if (get_u32(src) != TB_DPCM_MAGIC) return -1;

    const uint32_t w = get_u32(src + 4);
    const uint32_t h = get_u32(src + 8);
    if (!dims_ok((int)w, (int)h)) return -1;
    if (src[12] != 3 || src[13] != TB_DPCM_CHANNELS) return -1;

    const uint8_t flags = src[14];
    const int ten_bit = (flags & TB_DPCM_FLAG_TEN_BIT) ? 1 : 0;
    const int max_width = ten_bit ? 10 : 8;

    struct geom g;
    geom_of((int)w, (int)h, &g);

    if (get_u32(src + 16) != g.group_count)                      return -1;
    if (get_u32(src + 20) != (uint32_t)g.width_plane_bytes)       return -1;
    if (get_u32(src + 24) != (uint32_t)g.seed_plane_bytes)        return -1;
    const uint32_t payload_bytes = get_u32(src + 28);
    if (g.payload_off + payload_bytes != len)                     return -1;

    /* Re-derive every group base from the width plane and require the blob's own
     * table to agree. This is the one check that lets the GPU decoder run
     * without bounds tests: once the table is known to be exactly the aligned
     * prefix sum of the declared widths, and the total matches the payload
     * length, no thread can compute an offset outside the payload. Costs one
     * pass over the width plane (~690 KB at 5K), which is cheap next to what it
     * buys. */
    const uint8_t *wp = src + g.width_plane_off;
    const uint8_t *gt = src + g.group_table_off;
    size_t bitpos = 0;
    for (uint32_t t = 0; t < g.tile_count; ++t) {
        bitpos = group_align(bitpos, t);
        if (t % TB_DPCM_GROUP == 0) {
            if (get_u32(gt + (size_t)(t / TB_DPCM_GROUP) * 4) != (uint32_t)bitpos)
                return -1;
        }
        int tx, ty, tw, th;
        tile_rect(&g, t, (int)w, (int)h, &tx, &ty, &tw, &th);
        for (int c = 0; c < TB_DPCM_CHANNELS; ++c) {
            int n = width_get(wp, t * TB_DPCM_CHANNELS + c);
            if (n > max_width) return -1;
            bitpos += (size_t)n * (tw * th - 1);
        }
    }
    if ((bitpos + 7) / 8 != payload_bytes) return -1;

    out->width         = (int)w;
    out->height        = (int)h;
    out->tile          = TB_DPCM_TILE;
    out->channels      = TB_DPCM_CHANNELS;
    out->alpha_omitted = (flags & TB_DPCM_FLAG_ALPHA_OMITTED) ? 1 : 0;
    out->ten_bit       = ten_bit;
    out->tiles_x       = g.tiles_x;
    out->tiles_y       = g.tiles_y;
    out->tile_count    = g.tile_count;
    out->group_count   = g.group_count;
    out->group_table_off = g.group_table_off;
    out->width_plane_off = g.width_plane_off;
    out->seed_plane_off  = g.seed_plane_off;
    out->payload_off     = g.payload_off;
    out->payload_bytes   = payload_bytes;
    out->total_bytes     = len;
    return 0;
}

/* ------------------------------------------------------------------- decoding */

int tb_dpcm_decode(const uint8_t *src, size_t len, uint8_t *dst, int stride) {
    struct tb_dpcm_info in;
    if (tb_dpcm_parse(src, len, &in) != 0) return -1;
    if (!dst || stride < in.width * 4) return -1;

    struct geom g;
    geom_of(in.width, in.height, &g);
    const struct depth d = depth_of(in.ten_bit);

    const uint8_t *wp = src + in.width_plane_off;
    const uint8_t *sp = src + in.seed_plane_off;
    const uint8_t *pl = src + in.payload_off;

    size_t bitpos = 0;
    for (uint32_t t = 0; t < in.tile_count; ++t) {
        bitpos = group_align(bitpos, t);

        int tx, ty, tw, th;
        tile_rect(&g, t, in.width, in.height, &tx, &ty, &tw, &th);
        uint8_t *tile = dst + (size_t)ty * stride + (size_t)tx * 4;

        /* Every pixel starts opaque, because alpha is not carried and the
         * receiver's drawable is opaque — anything else would be a lie the
         * compositor might act on. Writing it here also gives the per-channel
         * merges below something well defined to merge into. */
        const uint32_t seed = get_u32(sp + (size_t)t * 4);
        for (int y = 0; y < th; ++y)
            for (int x = 0; x < tw; ++x)
                px_store(tile + (size_t)y * stride + (size_t)x * 4, d.alpha);
        px_store(tile, seed | d.alpha);

        for (int c = 0; c < TB_DPCM_CHANNELS; ++c) {
            const int shift = c * d.bits;
            const uint32_t keep = ~(d.mask << shift);
            const int n = width_get(wp, t * TB_DPCM_CHANNELS + c);
            if (n == 0) {
                /* Flat tile-channel: every sample takes the seed's value. A
                 * plain loop rather than TB_TILE_WALK, which exists to supply
                 * predictor coordinates there is nothing here to predict from. */
                const uint32_t v = sample_of(seed, c, &d) << shift;
                for (int y = 0; y < th; ++y)
                    for (int x = 0; x < tw; ++x) {
                        uint8_t *p = tile + (size_t)y * stride + (size_t)x * 4;
                        px_store(p, (px_load(p) & keep) | v);
                    }
                continue;
            }
            TB_TILE_WALK(tw, th, {
                uint8_t *cp = tile + (size_t)_y  * stride + (size_t)_x  * 4;
                uint32_t pred = sample_of(px_load(tile + (size_t)_py * stride + (size_t)_px * 4), c, &d);
                uint32_t v = resid_decode(br_get(pl, bitpos, n), pred, &d);
                bitpos += n;
                px_store(cp, (px_load(cp) & keep) | (v << shift));
            });
        }
    }
    return 0;
}
