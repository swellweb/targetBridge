/* raw_regions.c — see raw_regions.h for the wire format. */

#if !defined(__APPLE__) && !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 200112L /* posix_memalign under -std=c11 */
#endif

#include "raw_regions.h"

#include <stdlib.h>
#include <string.h>

#ifdef __APPLE__
#include <dispatch/dispatch.h>
#endif

struct tb_raw_band {
    uint32_t first_row;
    uint32_t rows;
    uint32_t length;
    uint8_t  encoding;
    size_t   offset;    /* of the band data in the payload */
};

struct tb_raw_apply_job {
    struct tb_raw_frame      *frame;
    const struct tb_raw_band *bands;
    const uint8_t            *payload;
    tb_raw_decode_fn          decode;
    uint32_t                  seq;
    volatile int              failed;
};

static uint32_t be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static uint16_t be16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | (uint16_t)p[1]);
}

void tb_raw_frame_free(struct tb_raw_frame *frame) {
    if (!frame) return;
    free(frame->y);
    free(frame->uv);
    free(frame->row_seq);
    frame->y = NULL;
    frame->uv = NULL;
    frame->row_seq = NULL;
    frame->y_capacity = 0;
    frame->format = 0;
    frame->w = 0;
    frame->h = 0;
}

static size_t tb_raw_row_bytes(uint8_t format, size_t w) {
    return format == TB_RAW_REGIONS_FORMAT_RGB10 ? w * 4 : w;
}

static size_t tb_raw_uv_row_bytes(uint8_t format, size_t w) {
    return format == TB_RAW_REGIONS_FORMAT_RGB10 ? 0 : w;
}

static int tb_raw_frame_resize(struct tb_raw_frame *frame, uint8_t format, uint32_t w, uint32_t h) {
    if (frame->y && frame->row_seq && frame->format == format &&
        frame->w == w && frame->h == h) return 0;
    tb_raw_frame_free(frame);
    const size_t y_size = tb_raw_row_bytes(format, w) * h;
    const size_t uv_size = tb_raw_uv_row_bytes(format, w) * (h / 2);
    const size_t y_capacity = (y_size + TB_RAW_REGIONS_Y_ALIGNMENT - 1) &
                              ~(size_t)(TB_RAW_REGIONS_Y_ALIGNMENT - 1);
    void *y = NULL;
    if (posix_memalign(&y, TB_RAW_REGIONS_Y_ALIGNMENT, y_capacity) != 0) y = NULL;
    frame->y = (uint8_t *)y;
    frame->y_capacity = y ? y_capacity : 0;
    frame->uv = uv_size ? (uint8_t *)malloc(uv_size) : NULL;
    frame->row_seq = (uint32_t *)calloc(h / 2, sizeof(uint32_t));
    if (!frame->y || (uv_size && !frame->uv) || !frame->row_seq) {
        tb_raw_frame_free(frame);
        return -1;
    }
    if (format == TB_RAW_REGIONS_FORMAT_RGB10) {
        /* Black, opaque: 0xC0000000 little endian. */
        uint32_t *pixels = (uint32_t *)frame->y;
        for (size_t i = 0; i < (size_t)w * h; ++i) pixels[i] = 0xC0000000u;
    } else {
        /* Video-range black until the first full frame arrives. */
        memset(frame->y, 16, y_size);
        memset(frame->uv, 128, uv_size);
    }
    frame->format = format;
    frame->w = w;
    frame->h = h;
    return 0;
}

/* True if a write with sequence `seq` may replace rows last written by `last`. */
static int tb_raw_seq_newer(uint32_t seq, uint32_t last) {
    return last == 0 || (int32_t)(seq - last) >= 0;
}

/* Copies the decoded band `src` (Y rows, then CbCr rows) into the frame, row
 * pair by row pair, skipping pairs a newer frame already wrote. */
static void tb_raw_copy_band(struct tb_raw_apply_job *job, const struct tb_raw_band *band,
                             const uint8_t *src) {
    struct tb_raw_frame *frame = job->frame;
    const size_t row = tb_raw_row_bytes(frame->format, frame->w);
    const size_t uv_row = tb_raw_uv_row_bytes(frame->format, frame->w);
    const size_t y_bytes = row * band->rows;
    const size_t uv_bytes = uv_row * (band->rows / 2);
    uint8_t *y_dst = frame->y + row * band->first_row;
    uint8_t *uv_dst = frame->uv ? frame->uv + uv_row * (band->first_row / 2) : NULL;

    if (job->seq == 0) {
        memcpy(y_dst, src, y_bytes);
        if (uv_dst) memcpy(uv_dst, src + y_bytes, uv_bytes);
        return;
    }
    const uint32_t first_pair = band->first_row / 2;
    for (uint32_t pair = 0; pair < band->rows / 2; ++pair) {
        uint32_t *last = &frame->row_seq[first_pair + pair];
        if (!tb_raw_seq_newer(job->seq, *last)) continue;
        memcpy(y_dst + 2 * row * pair, src + 2 * row * pair, 2 * row);
        if (uv_dst) memcpy(uv_dst + uv_row * pair, src + y_bytes + uv_row * pair, uv_row);
        *last = job->seq;
    }
}

static void tb_raw_apply_band(struct tb_raw_apply_job *job, size_t index) {
    const struct tb_raw_band *band = &job->bands[index];
    const size_t decoded_size =
        tb_raw_row_bytes(job->frame->format, job->frame->w) * band->rows +
        tb_raw_uv_row_bytes(job->frame->format, job->frame->w) * (band->rows / 2);
    const uint8_t *src = job->payload + band->offset;

    if (band->encoding == TB_RAW_REGIONS_ENCODING_RAW) {
        tb_raw_copy_band(job, band, src);
        return;
    }

    uint8_t *decoded = (uint8_t *)malloc(decoded_size);
    if (!decoded || job->decode(decoded, decoded_size, src, band->length) != 0) {
        free(decoded);
        job->failed = 1;
        return;
    }
    tb_raw_copy_band(job, band, decoded);
    free(decoded);
}

#ifdef __APPLE__
static void tb_raw_apply_band_dispatch(void *context, size_t index) {
    tb_raw_apply_band((struct tb_raw_apply_job *)context, index);
}
#endif

static int tb_raw_regions_apply_seq(struct tb_raw_frame *frame,
                                    const uint8_t *payload, size_t len,
                                    tb_raw_decode_fn decode, uint32_t seq,
                                    struct tb_raw_regions_result *out) {
    if (!frame || !payload || len < TB_RAW_REGIONS_HEADER_BYTES) return -1;
    const uint8_t format = payload[0];
    if (format != TB_RAW_REGIONS_FORMAT_NV12 && format != TB_RAW_REGIONS_FORMAT_RGB10) return -1;

    const uint8_t flags = payload[1];
    const uint32_t w = be32(payload + 2);
    const uint32_t h = be32(payload + 6);
    const uint16_t count = be16(payload + 10);
    if (w == 0 || h == 0 || (w & 1) || (h & 1) ||
        w > TB_RAW_REGIONS_MAX_DIMENSION || h > TB_RAW_REGIONS_MAX_DIMENSION) return -1;
    if (count == 0 || count > TB_RAW_REGIONS_MAX_BANDS) return -1;

    const size_t table_end = TB_RAW_REGIONS_HEADER_BYTES +
                             (size_t)count * TB_RAW_REGIONS_BAND_BYTES;
    if (table_end > len) return -1;

    struct tb_raw_band *bands = (struct tb_raw_band *)calloc(count, sizeof(*bands));
    if (!bands) return -1;

    /* Validate everything before touching the frame. */
    size_t offset = table_end;
    uint32_t first_row = h;
    uint32_t end_row = 0;
    uint32_t rows_total = 0;
    int compressed = 0;
    int ok = 1;
    for (uint16_t i = 0; i < count && ok; ++i) {
        const uint8_t *entry = payload + TB_RAW_REGIONS_HEADER_BYTES +
                               (size_t)i * TB_RAW_REGIONS_BAND_BYTES;
        struct tb_raw_band *band = &bands[i];
        band->first_row = be32(entry);
        band->rows = be32(entry + 4);
        band->length = be32(entry + 8);
        band->encoding = entry[12];
        band->offset = offset;

        const size_t decoded_size = tb_raw_row_bytes(format, w) * band->rows +
                                    tb_raw_uv_row_bytes(format, w) * (band->rows / 2);
        if (band->rows == 0 || (band->first_row & 1) || (band->rows & 1) ||
            band->first_row >= h || band->rows > h - band->first_row) {
            ok = 0;
        } else if (band->encoding == TB_RAW_REGIONS_ENCODING_RAW) {
            if (band->length != decoded_size) ok = 0;
        } else if (band->encoding == TB_RAW_REGIONS_ENCODING_LZ4) {
            if (!decode || band->length == 0) ok = 0;
            compressed = 1;
        } else {
            ok = 0;
        }
        if (ok && band->length > len - offset) ok = 0;
        if (!ok) break;

        offset += band->length;
        rows_total += band->rows;
        if (band->first_row < first_row) first_row = band->first_row;
        if (band->first_row + band->rows > end_row) end_row = band->first_row + band->rows;
    }
    if (!ok || tb_raw_frame_resize(frame, format, w, h) != 0) {
        free(bands);
        return -1;
    }

    struct tb_raw_apply_job job = { frame, bands, payload, decode, seq, 0 };
#ifdef __APPLE__
    if (count > 1) {
        dispatch_apply_f(count, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0),
                         &job, tb_raw_apply_band_dispatch);
    } else {
        tb_raw_apply_band(&job, 0);
    }
#else
    for (uint16_t i = 0; i < count; ++i) tb_raw_apply_band(&job, i);
#endif
    free(bands);

    if (out) {
        out->format = format;
        out->w = w;
        out->h = h;
        out->first_row = first_row;
        out->end_row = end_row;
        out->bands = count;
        out->rows = rows_total;
        out->full = (flags & TB_RAW_REGIONS_FLAG_FULL) != 0;
        out->compressed = compressed;
        out->sequence = seq;
        out->parts = payload[12];
    }
    return job.failed ? -2 : 0;
}

int tb_raw_regions_apply(struct tb_raw_frame *frame,
                         const uint8_t *payload, size_t len,
                         tb_raw_decode_fn decode,
                         struct tb_raw_regions_result *out) {
    return tb_raw_regions_apply_seq(frame, payload, len, decode, 0, out);
}

int tb_raw_regions_apply_part(struct tb_raw_frame *frame,
                              const uint8_t *payload, size_t len,
                              tb_raw_decode_fn decode,
                              struct tb_raw_regions_result *out) {
    if (!payload || len < 4) return -1;
    const uint32_t seq = be32(payload);
    if (seq == 0) return -1;
    return tb_raw_regions_apply_seq(frame, payload + 4, len - 4, decode, seq, out);
}
