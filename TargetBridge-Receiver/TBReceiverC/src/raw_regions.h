/* raw_regions.h — changed-rows raw NV12 frames (packet type 0x24).
 *
 * The sender only sends the rows of the screen that changed since the last
 * frame it sent, optionally compressed losslessly with LZ4. The receiver keeps
 * the whole picture in a persistent NV12 buffer and patches the received rows
 * into it, so a mostly static desktop costs almost no bandwidth.
 *
 * Payload (all integers big endian):
 *   [1 byte format: 1=NV12][1 byte flags: bit0 = full frame]
 *   [4 width][4 height][2 band count][2 reserved]
 *   band table, count entries of 13 bytes:
 *     [4 first row][4 row count][4 encoded length][1 encoding: 0=raw, 1=LZ4]
 *   band data, in table order.
 *
 * A decoded band holds its Y rows (width bytes each) followed by its CbCr rows
 * (width bytes each, row count / 2 of them). First row and row count are even.
 *
 * Pure C with no SDL or system codec dependency, so it is unit tested in CI.
 * LZ4 decoding is passed in as a function pointer. */

#ifndef TB_RAW_REGIONS_H
#define TB_RAW_REGIONS_H

#include <stddef.h>
#include <stdint.h>

#define TB_RAW_REGIONS_HEADER_BYTES   14
#define TB_RAW_REGIONS_BAND_BYTES     13
#define TB_RAW_REGIONS_MAX_BANDS      4096
#define TB_RAW_REGIONS_MAX_DIMENSION  8192

#define TB_RAW_REGIONS_FLAG_FULL      0x01

#define TB_RAW_REGIONS_ENCODING_RAW   0
#define TB_RAW_REGIONS_ENCODING_LZ4   1

/* The receiver's copy of the picture: tightly packed NV12 (stride = width). */
struct tb_raw_frame {
    uint8_t *y;
    uint8_t *uv;
    uint32_t w;
    uint32_t h;
};

/* Decodes src into exactly dst_len bytes. Returns 0 on success. */
typedef int (*tb_raw_decode_fn)(uint8_t *dst, size_t dst_len,
                                const uint8_t *src, size_t src_len);

struct tb_raw_regions_result {
    uint32_t w;
    uint32_t h;
    uint32_t first_row;     /* changed rows: [first_row, end_row) */
    uint32_t end_row;
    uint32_t bands;
    uint32_t rows;          /* rows carried by the packet */
    int      full;          /* sender marked it as a whole frame */
    int      compressed;    /* at least one band used LZ4 */
};

/* Validates the whole payload first, then patches it into the frame. Nothing
 * is written if any part is malformed. The frame is (re)allocated when the
 * size changes; new memory starts black. Returns 0 on success, -1 on
 * malformed input or allocation failure, -2 if an LZ4 band could not be
 * decoded (the frame may then be partly updated). */
int  tb_raw_regions_apply(struct tb_raw_frame *frame,
                          const uint8_t *payload, size_t len,
                          tb_raw_decode_fn decode,
                          struct tb_raw_regions_result *out);

void tb_raw_frame_free(struct tb_raw_frame *frame);

#endif
