/* test_dpcm.c — hardware-free unit tests for the TBD2 tile-DPCM codec.
 *
 * Build & run:  make test
 *
 * Only needs tb_dpcm.c + libc — no ffmpeg, no SDL, no GPU. The point of these is
 * that the C codec is the correctness oracle for two shaders: the receiver's
 * decoder and the sender's encoder. If this is wrong, both are verified against
 * the wrong answer. So the tests lean on round-tripping real-shaped content at
 * both sample depths, and on rejecting malformed blobs, since tb_dpcm_parse is
 * what lets the decode shader skip bounds checks entirely.
 */

#include "tb_dpcm.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg) do {                                              \
    g_checks++;                                                            \
    if (!(cond)) {                                                         \
        g_failures++;                                                      \
        fprintf(stderr, "FAIL %s:%d — %s\n", __FILE__, __LINE__, (msg));   \
    }                                                                      \
} while (0)

/* ---- helpers ----------------------------------------------------------- */

static uint32_t rng_state = 0xC0FFEEu;
static uint32_t rng(void) {
    uint32_t x = rng_state;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return rng_state = x;
}

/* A pixel is 4 bytes at either depth; channels sit at bit c*depth. */
static inline uint32_t pack_px(uint32_t c0, uint32_t c1, uint32_t c2, int ten_bit) {
    return ten_bit ? ((3u << 30) | (c2 << 20) | (c1 << 10) | c0)
                   : ((0xFFu << 24) | (c2 << 16) | (c1 << 8) | c0);
}

static uint8_t *frame_alloc(int w, int h, int ten_bit) {
    uint8_t *p = calloc((size_t)h, (size_t)w * 4);
    if (!p) return NULL;
    const uint32_t opaque = ten_bit ? (3u << 30) : (0xFFu << 24);
    for (size_t i = 0; i < (size_t)w * h; ++i) memcpy(p + i * 4, &opaque, 4);
    return p;
}

static inline void put_px(uint8_t *f, int w, int x, int y, uint32_t v) {
    memcpy(f + ((size_t)y * w + x) * 4, &v, 4);
}

/* Round-trip a frame and require it back byte for byte. Alpha is not carried, so
 * the source is built opaque and the comparison includes the alpha field — that
 * way a decoder that forgets to write alpha fails here rather than showing up as
 * a transparent window much later. */
static void roundtrip(const char *what, const uint8_t *src, int w, int h,
                      int ten_bit, double *out_ratio) {
    const int stride = w * 4;
    size_t cap = tb_dpcm_max_size(w, h);
    uint8_t *blob = malloc(cap);
    uint8_t *back = calloc((size_t)h, stride);
    CHECK(blob != NULL && back != NULL, "allocation");
    if (!blob || !back) { free(blob); free(back); return; }

    size_t len = tb_dpcm_encode(src, stride, w, h, ten_bit, blob, cap);
    CHECK(len > 0, what);
    CHECK(len <= cap, "encoder respects its own size bound");

    struct tb_dpcm_info in;
    CHECK(tb_dpcm_parse(blob, len, &in) == 0, "parse accepts what encode produced");
    CHECK(in.width == w && in.height == h, "dimensions survive");
    CHECK(in.alpha_omitted == 1, "alpha is declared omitted");
    CHECK(in.ten_bit == (ten_bit ? 1 : 0), "sample depth survives");

    /* Every group's payload must start on a byte boundary: that is what lets the
     * encoder write groups concurrently without two threads sharing a byte. */
    for (uint32_t gi = 0; gi < in.group_count; ++gi) {
        uint32_t base;
        memcpy(&base, blob + in.group_table_off + (size_t)gi * 4, 4);
        if (base % 8u != 0u) { CHECK(0, "group base is byte-aligned"); break; }
    }
    g_checks++;   /* the loop above counts as one check when it passes */

    CHECK(tb_dpcm_decode(blob, len, back, stride) == 0, "decode succeeds");
    CHECK(memcmp(src, back, (size_t)h * stride) == 0, what);

    if (out_ratio) {
        *out_ratio = (double)((size_t)h * stride) / (double)len;
        /* Printed, not just asserted: a silent drift in ratio is the kind of
         * regression a pass/fail bound will not surface until it is large. */
        printf("  %-34s %6.2fx  %2d-bit  (%d x %d)\n",
               what, *out_ratio, ten_bit ? 10 : 8, w, h);
    }
    free(blob);
    free(back);
}

/* ---- tests ------------------------------------------------------------- */

/* A single flat colour is where the format should be at its very best: every
 * residual is zero, so a tile costs only its header and seed. */
static void test_flat(int ten_bit) {
    const int w = 256, h = 128;
    uint8_t *f = frame_alloc(w, h, ten_bit);
    const uint32_t v = pack_px(ten_bit ? 0x081 : 0x20,
                               ten_bit ? 0x102 : 0x40,
                               ten_bit ? 0x203 : 0x60, ten_bit);
    for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) put_px(f, w, x, y, v);
    double ratio = 0;
    roundtrip("flat frame round-trips", f, w, h, ten_bit, &ratio);
    /* 4 bytes/px in; 5.5 bytes per 64-px tile out. */
    CHECK(ratio > 30.0, "flat frame compresses hard");
    free(f);
}

/* Pure noise is the adversarial case: residuals span the full range, so every
 * tile-channel lands at the sample depth and the payload equals the raw
 * three-channel size. The format must not EXPAND here — that is what the modular
 * re-centring buys, and why no escape hatch to raw is needed. At 8-bit the win is
 * the dropped alpha byte; at 10-bit there is only the 2-bit alpha field to save,
 * so the floor is much closer to 1. */
static void test_noise_does_not_expand(int ten_bit) {
    const int w = 128, h = 64;
    uint8_t *f = frame_alloc(w, h, ten_bit);
    const uint32_t mask = ten_bit ? 0x3FFu : 0xFFu;
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x) {
            uint32_t r = rng();
            put_px(f, w, x, y, pack_px(r & mask, (r >> 11) & mask, (r >> 21) & mask, ten_bit));
        }
    double ratio = 0;
    roundtrip("noise round-trips", f, w, h, ten_bit, &ratio);
    CHECK(ratio > (ten_bit ? 1.02 : 1.30), "noise still does not expand");
    free(f);
}

/* Gradients are what the format exists for, and also where an off-by-one in the
 * predictor hides: a wrong predictor still round-trips if encoder and decoder
 * share the mistake, but the ratio collapses. So this asserts on the ratio, not
 * just on correctness. */
static void test_gradient(int ten_bit) {
    const int w = 512, h = 256;
    uint8_t *f = frame_alloc(w, h, ten_bit);
    const uint32_t top = ten_bit ? 1023u : 255u;
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x)
            put_px(f, w, x, y, pack_px((uint32_t)x * top / (uint32_t)(w - 1),
                                       (uint32_t)y * top / (uint32_t)(h - 1),
                                       (uint32_t)(x + y) * top / (uint32_t)(w + h - 2),
                                       ten_bit));
    double ratio = 0;
    roundtrip("gradient round-trips", f, w, h, ten_bit, &ratio);
    /* 256 levels across 512 px means a step every other pixel, so residuals need
     * 2 bits; the 5K gradient that measured 14.7x steps every 20 px. At 10-bit
     * the same ramp climbs four times as fast, so its residuals are wider. */
    CHECK(ratio > (ten_bit ? 3.0 : 4.5), "a smooth gradient compresses well");
    free(f);
}

/* Wrapping is the sharp edge of the modular residual: 0 next to full-scale is a
 * distance of 1, not full-scale, and only survives if encoder and decoder agree
 * that reconstruction wraps. A frame of alternating extremes exercises nothing
 * else. */
static void test_wraparound(int ten_bit) {
    const int w = 64, h = 64;
    uint8_t *f = frame_alloc(w, h, ten_bit);
    const uint32_t top = ten_bit ? 1023u : 255u;
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x) {
            uint32_t v = ((x + y) & 1) ? top : 0u;
            put_px(f, w, x, y, pack_px(v, v, v, ten_bit));
        }
    roundtrip("alternating min/max round-trips", f, w, h, ten_bit, NULL);
    free(f);
}

/* Sizes that are not multiples of 8 leave partial tiles along the right and
 * bottom edges, whose coded-sample counts differ from a full tile's. Those counts
 * feed the group offsets, so an error here corrupts every tile after the first
 * short row rather than just the edge. */
static void test_partial_tiles(int ten_bit) {
    const int sizes[][2] = { {1,1}, {1,8}, {8,1}, {7,7}, {9,9}, {13,5}, {65,33}, {5121,17} };
    const uint32_t mask = ten_bit ? 0x3FFu : 0xFFu;
    for (size_t i = 0; i < sizeof(sizes) / sizeof(sizes[0]); ++i) {
        const int w = sizes[i][0], h = sizes[i][1];
        uint8_t *f = frame_alloc(w, h, ten_bit);
        if (!f) { CHECK(0, "allocation"); continue; }
        for (int y = 0; y < h; ++y)
            for (int x = 0; x < w; ++x) {
                uint32_t r = rng();
                put_px(f, w, x, y, pack_px(r & mask, (r >> 7) & mask, (r >> 13) & mask, ten_bit));
            }
        char msg[64];
        snprintf(msg, sizeof(msg), "%dx%d round-trips", w, h);
        roundtrip(msg, f, w, h, ten_bit, NULL);
        free(f);
    }
}

/* A frame where each tile lands at a different bit width, including zero, so the
 * group offsets have to be right for tiles that contribute nothing. */
static void test_mixed_widths(int ten_bit) {
    const int w = 8 * 40, h = 8 * 12;
    const int depth = ten_bit ? 10 : 8;
    const uint32_t mid = ten_bit ? 512u : 128u;
    uint8_t *f = frame_alloc(w, h, ten_bit);
    int t = 0;
    for (int ty = 0; ty < h; ty += 8) {
        for (int tx = 0; tx < w; tx += 8, ++t) {
            int n = t % (depth + 1);                 /* 0..depth, every width */
            int span = (n == 0) ? 1 : (1 << n);
            for (int y = 0; y < 8; ++y)
                for (int x = 0; x < 8; ++x) {
                    uint32_t s[3];
                    for (int c = 0; c < 3; ++c)
                        s[c] = (mid + (rng() % (uint32_t)span) - (uint32_t)(span / 2))
                             & (ten_bit ? 0x3FFu : 0xFFu);
                    put_px(f, w, tx + x, ty + y, pack_px(s[0], s[1], s[2], ten_bit));
                }
        }
    }
    roundtrip("mixed per-tile bit widths", f, w, h, ten_bit, NULL);
    free(f);
}

/* The two depths must produce different blobs from the same bytes — otherwise
 * the flag is decorative and a 10-bit frame would be decoded as 8-bit garbage. */
static void test_depths_are_distinct(void) {
    const int w = 64, h = 64;
    uint8_t *f = frame_alloc(w, h, 1);
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x) {
            uint32_t r = rng();
            put_px(f, w, x, y, pack_px(r & 0x3FF, (r >> 11) & 0x3FF, (r >> 21) & 0x3FF, 1));
        }
    size_t cap = tb_dpcm_max_size(w, h);
    uint8_t *a = malloc(cap), *b = malloc(cap);
    size_t la = tb_dpcm_encode(f, w * 4, w, h, 0, a, cap);
    size_t lb = tb_dpcm_encode(f, w * 4, w, h, 1, b, cap);
    CHECK(la > 0 && lb > 0, "both depths encode");
    CHECK(la != lb || memcmp(a, b, la) != 0, "the depth flag changes the blob");

    /* And a blob decoded at the wrong depth must not silently look plausible:
     * the flag is inside the blob, so this is really a check that the decoder
     * reads it rather than being told. */
    uint8_t *back = calloc((size_t)h, w * 4);
    CHECK(tb_dpcm_decode(b, lb, back, w * 4) == 0, "10-bit blob decodes");
    CHECK(memcmp(f, back, (size_t)h * w * 4) == 0, "10-bit blob decodes exactly");
    free(back); free(a); free(b); free(f);
}

/* tb_dpcm_parse is the receiver's only defence: it re-derives the whole offset
 * table from the width plane so the GPU decoder can run without a single bounds
 * check. If it ever accepts a blob whose table disagrees, threads read outside
 * the payload. These are the mutations that must be caught. */
static void test_parse_rejects_malformed(void) {
    const int w = 64, h = 64;
    uint8_t *f = frame_alloc(w, h, 0);
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x) {
            uint32_t r = rng();
            put_px(f, w, x, y, pack_px(r & 0xFF, (r >> 8) & 0xFF, (r >> 16) & 0xFF, 0));
        }
    size_t cap = tb_dpcm_max_size(w, h);
    uint8_t *good = malloc(cap);
    size_t len = tb_dpcm_encode(f, w * 4, w, h, 0, good, cap);
    CHECK(len > 0, "encode for malformed-input tests");

    struct tb_dpcm_info in;
    CHECK(tb_dpcm_parse(good, len, &in) == 0, "the unmodified blob parses");

    uint8_t *bad = malloc(len);

    CHECK(tb_dpcm_parse(good, TB_DPCM_HEADER - 1, &in) != 0, "truncated header rejected");
    CHECK(tb_dpcm_parse(good, len - 1, &in) != 0, "truncated blob rejected");
    CHECK(tb_dpcm_parse(good, len + 1, &in) != 0, "over-long blob rejected");

    memcpy(bad, good, len); bad[0] ^= 0xFF;
    CHECK(tb_dpcm_parse(bad, len, &in) != 0, "bad magic rejected");

    memcpy(bad, good, len); bad[12] = 4;
    CHECK(tb_dpcm_parse(bad, len, &in) != 0, "unsupported tile size rejected");

    memcpy(bad, good, len); bad[13] = 4;
    CHECK(tb_dpcm_parse(bad, len, &in) != 0, "unsupported channel count rejected");

    /* Flipping the depth flag is NOT detectable, and that is worth pinning down
     * rather than wishing otherwise: bit widths and every declared length are
     * independent of depth, so there is nothing to cross-check against. The blob
     * decodes to wrong colours.
     *
     * What matters is that it stays a fidelity bug and never becomes a safety
     * one — the offsets a thread computes must be unchanged, since the decode
     * shader runs with no bounds checks on the strength of this function. An
     * 8-bit blob only survives the flip because widths <= 8 are legal at 10-bit
     * too; the reverse direction IS caught, by the width-range test below. */
    {
        struct tb_dpcm_info flipped;
        memcpy(bad, good, len); bad[14] |= TB_DPCM_FLAG_TEN_BIT;
        CHECK(tb_dpcm_parse(bad, len, &flipped) == 0, "flipped depth flag parses");
        CHECK(flipped.ten_bit == 1, "flipped flag is reported");
        CHECK(flipped.payload_bytes == in.payload_bytes &&
              flipped.group_count == in.group_count &&
              flipped.payload_off == in.payload_off,
              "a flipped depth flag cannot move any offset");
    }

    /* Width plane edited without the group table following: the declared offsets
     * no longer match the widths, which is exactly the shape of an attack that
     * would push a thread past the end of the payload. */
    memcpy(bad, good, len);
    bad[in.width_plane_off] ^= 0x0F;
    CHECK(tb_dpcm_parse(bad, len, &in) != 0, "width/offset-table disagreement rejected");

    /* A group base pointing somewhere else entirely. */
    memcpy(bad, good, len);
    bad[in.group_table_off + 4] ^= 0x40;
    CHECK(tb_dpcm_parse(bad, len, &in) != 0, "tampered group base rejected");

    /* A nibble claiming a width no encoder emits at this depth. */
    memcpy(bad, good, len);
    bad[in.width_plane_off] |= 0x0F;
    CHECK(tb_dpcm_parse(bad, len, &in) != 0, "out-of-range bit width rejected");

    memcpy(bad, good, len);
    bad[4] = 0; bad[5] = 0; bad[6] = 0; bad[7] = 0;
    CHECK(tb_dpcm_parse(bad, len, &in) != 0, "zero width rejected");

    free(bad); free(good); free(f);
}

/* The encoder must refuse rather than overrun when handed a buffer even one byte
 * short of what it promised it would need. */
static void test_encode_respects_capacity(void) {
    const int w = 64, h = 64;
    uint8_t *f = frame_alloc(w, h, 0);
    size_t cap = tb_dpcm_max_size(w, h);
    uint8_t *dst = malloc(cap);
    CHECK(tb_dpcm_encode(f, w * 4, w, h, 0, dst, cap - 1) == 0, "short buffer refused");
    CHECK(tb_dpcm_encode(f, w * 4, w, h, 0, dst, cap) > 0, "exact buffer accepted");
    CHECK(tb_dpcm_encode(f, w * 4, w, h, 1, dst, cap) > 0, "10-bit fits the same bound");
    CHECK(tb_dpcm_encode(f, w * 4 - 1, w, h, 0, dst, cap) == 0, "stride below the row width refused");
    CHECK(tb_dpcm_encode(f, w * 4, 0, h, 0, dst, cap) == 0, "zero width refused");
    free(dst); free(f);
}

int main(void) {
    for (int ten_bit = 0; ten_bit <= 1; ++ten_bit) {
        printf("--- %d-bit ---\n", ten_bit ? 10 : 8);
        test_flat(ten_bit);
        test_noise_does_not_expand(ten_bit);
        test_gradient(ten_bit);
        test_wraparound(ten_bit);
        test_partial_tiles(ten_bit);
        test_mixed_widths(ten_bit);
    }
    test_depths_are_distinct();
    test_parse_rejects_malformed();
    test_encode_respects_capacity();

    if (g_failures == 0) {
        printf("dpcm codec tests: %d checks passed\n", g_checks);
        return 0;
    }
    fprintf(stderr, "dpcm codec tests: %d/%d checks FAILED\n", g_failures, g_checks);
    return 1;
}
