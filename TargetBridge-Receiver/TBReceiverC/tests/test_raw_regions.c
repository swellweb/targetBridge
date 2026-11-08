#include "raw_regions.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int checks = 0;
static int failures = 0;

#define CHECK(condition, message) do { \
    checks++; \
    if (!(condition)) { \
        fprintf(stderr, "FAIL: %s\n", message); \
        failures++; \
    } \
} while (0)

/* Test stand-in for LZ4: the "compressed" data is the decoded data with every
 * byte inverted, so a forgotten decode step is caught. */
static int fake_decode(uint8_t *dst, size_t dst_len, const uint8_t *src, size_t src_len) {
    if (src_len != dst_len) return -1;
    for (size_t i = 0; i < dst_len; ++i) dst[i] = (uint8_t)~src[i];
    return 0;
}

struct writer {
    uint8_t buf[4096];
    size_t  len;
};

static void put8(struct writer *w, uint8_t v) { w->buf[w->len++] = v; }
static void put16(struct writer *w, uint16_t v) { put8(w, (uint8_t)(v >> 8)); put8(w, (uint8_t)v); }
static void put32(struct writer *w, uint32_t v) {
    put8(w, (uint8_t)(v >> 24)); put8(w, (uint8_t)(v >> 16));
    put8(w, (uint8_t)(v >> 8)); put8(w, (uint8_t)v);
}

static void header(struct writer *w, uint8_t flags, uint32_t width, uint32_t height, uint16_t count) {
    w->len = 0;
    put8(w, 1);
    put8(w, flags);
    put32(w, width);
    put32(w, height);
    put16(w, count);
    put16(w, 0);
}

static void band_entry(struct writer *w, uint32_t first, uint32_t rows, uint32_t length, uint8_t encoding) {
    put32(w, first);
    put32(w, rows);
    put32(w, length);
    put8(w, encoding);
}

static void band_data(struct writer *w, uint32_t width, uint32_t rows, uint8_t y, uint8_t uv, int invert) {
    for (uint32_t i = 0; i < width * rows; ++i) put8(w, invert ? (uint8_t)~y : y);
    for (uint32_t i = 0; i < width * (rows / 2); ++i) put8(w, invert ? (uint8_t)~uv : uv);
}

int main(void) {
    struct tb_raw_frame frame = {0};
    struct tb_raw_regions_result result;
    struct writer w;
    const uint32_t width = 8;
    const uint32_t height = 8;

    /* Full frame as two raw bands. */
    header(&w, TB_RAW_REGIONS_FLAG_FULL, width, height, 2);
    band_entry(&w, 0, 4, width * 4 + width * 2, TB_RAW_REGIONS_ENCODING_RAW);
    band_entry(&w, 4, 4, width * 4 + width * 2, TB_RAW_REGIONS_ENCODING_RAW);
    band_data(&w, width, 4, 50, 60, 0);
    band_data(&w, width, 4, 70, 80, 0);
    memset(&result, 0, sizeof(result));
    CHECK(tb_raw_regions_apply(&frame, w.buf, w.len, fake_decode, &result) == 0, "full frame applies");
    CHECK(result.full == 1 && result.bands == 2 && result.rows == 8, "full frame result");
    CHECK(result.first_row == 0 && result.end_row == 8, "full frame row span");
    CHECK(frame.w == 8 && frame.h == 8, "frame allocated");
    CHECK(frame.y[0] == 50 && frame.y[width * 4] == 70 && frame.y[width * 8 - 1] == 70, "Y rows patched");
    CHECK(frame.uv[0] == 60 && frame.uv[width * 2] == 80, "CbCr rows patched");

    /* Changed rows 2-3 only, LZ4-encoded. */
    header(&w, 0, width, height, 1);
    band_entry(&w, 2, 2, width * 2 + width, TB_RAW_REGIONS_ENCODING_LZ4);
    band_data(&w, width, 2, 99, 111, 1);
    CHECK(tb_raw_regions_apply(&frame, w.buf, w.len, fake_decode, &result) == 0, "partial LZ4 frame applies");
    CHECK(result.full == 0 && result.compressed == 1, "partial frame flags");
    CHECK(result.first_row == 2 && result.end_row == 4, "partial frame row span");
    CHECK(frame.y[width * 1] == 50 && frame.y[width * 2] == 99 && frame.y[width * 4] == 70,
          "only the changed Y rows change");
    CHECK(frame.uv[0] == 60 && frame.uv[width] == 111 && frame.uv[width * 2] == 80,
          "only the changed CbCr row changes");

    /* Malformed input changes nothing. */
    header(&w, 0, width, height, 1);
    band_entry(&w, 1, 2, width * 2 + width, TB_RAW_REGIONS_ENCODING_RAW);
    band_data(&w, width, 2, 1, 1, 0);
    CHECK(tb_raw_regions_apply(&frame, w.buf, w.len, fake_decode, NULL) == -1, "odd first row rejected");

    header(&w, 0, width, height, 1);
    band_entry(&w, 6, 4, width * 4 + width * 2, TB_RAW_REGIONS_ENCODING_RAW);
    band_data(&w, width, 4, 1, 1, 0);
    CHECK(tb_raw_regions_apply(&frame, w.buf, w.len, fake_decode, NULL) == -1, "band past the bottom rejected");

    header(&w, 0, width, height, 1);
    band_entry(&w, 0, 2, width * 3 + 1, TB_RAW_REGIONS_ENCODING_RAW);
    band_data(&w, width, 2, 1, 1, 0);
    CHECK(tb_raw_regions_apply(&frame, w.buf, w.len, fake_decode, NULL) == -1, "wrong raw length rejected");

    header(&w, 0, width, height, 2);
    band_entry(&w, 0, 2, width * 3, TB_RAW_REGIONS_ENCODING_RAW);
    band_entry(&w, 2, 2, width * 3, TB_RAW_REGIONS_ENCODING_RAW);
    band_data(&w, width, 2, 1, 1, 0);
    CHECK(tb_raw_regions_apply(&frame, w.buf, w.len, fake_decode, NULL) == -1, "truncated payload rejected");
    CHECK(frame.y[0] == 50, "rejected packet left the first band untouched");

    header(&w, 0, width, height, 1);
    band_entry(&w, 0, 2, width * 3, 7);
    band_data(&w, width, 2, 1, 1, 0);
    CHECK(tb_raw_regions_apply(&frame, w.buf, w.len, fake_decode, NULL) == -1, "unknown encoding rejected");

    header(&w, 0, width, height, 1);
    band_entry(&w, 0, 2, 4, TB_RAW_REGIONS_ENCODING_LZ4);
    put32(&w, 0);
    CHECK(tb_raw_regions_apply(&frame, w.buf, w.len, NULL, NULL) == -1, "LZ4 without decoder rejected");
    CHECK(tb_raw_regions_apply(&frame, w.buf, w.len, fake_decode, NULL) == -2, "undecodable LZ4 band reported");

    header(&w, 0, 7, height, 1);
    CHECK(tb_raw_regions_apply(&frame, w.buf, w.len, fake_decode, NULL) == -1, "odd width rejected");

    header(&w, 0, width, height, 0);
    CHECK(tb_raw_regions_apply(&frame, w.buf, w.len, fake_decode, NULL) == -1, "zero bands rejected");

    /* A size change reallocates and starts black outside the sent rows. */
    header(&w, 0, 4, 4, 1);
    band_entry(&w, 0, 2, 4 * 2 + 4, TB_RAW_REGIONS_ENCODING_RAW);
    band_data(&w, 4, 2, 200, 201, 0);
    CHECK(tb_raw_regions_apply(&frame, w.buf, w.len, fake_decode, NULL) == 0, "resized frame applies");
    CHECK(frame.w == 4 && frame.h == 4, "frame resized");
    CHECK(frame.y[0] == 200 && frame.y[4 * 2] == 16 && frame.uv[4] == 128, "unsent rows start black");

    tb_raw_frame_free(&frame);
    CHECK(frame.y == NULL && frame.uv == NULL && frame.w == 0, "frame freed");

    printf("raw regions: %d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
