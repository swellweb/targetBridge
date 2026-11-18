/* test_keyframe_nal.c — keyframe NAL unit types for H.264 and HEVC. */

#include "keyframe_nal.h"

#include <stdio.h>

static int checks;
static int failures;

#define CHECK(condition) do { \
    checks++; \
    if (!(condition)) { \
        failures++; \
        fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition); \
    } \
} while (0)

/* First header byte for an HEVC NAL unit of this type (layer 0, F bit clear). */
static uint8_t hevc(int type) { return (uint8_t)(type << 1); }

int main(void) {
    /* H.264: only IDR slices (5), whatever nal_ref_idc says. */
    CHECK(tb_nal_is_keyframe(0, 0x65) == 1);   /* IDR, nal_ref_idc 3 */
    CHECK(tb_nal_is_keyframe(0, 0x25) == 1);   /* IDR, nal_ref_idc 1 */
    CHECK(tb_nal_is_keyframe(0, 0x41) == 0);   /* non-IDR slice */
    CHECK(tb_nal_is_keyframe(0, 0x06) == 0);   /* SEI */
    CHECK(tb_nal_is_keyframe(0, 0x67) == 0);   /* SPS */
    CHECK(tb_nal_is_keyframe(0, 0x68) == 0);   /* PPS */
    CHECK(tb_nal_is_keyframe(0, 0x09) == 0);   /* access unit delimiter */

    /* HEVC: BLA_W_LP .. CRA_NUT (16-21) are keyframes; nothing else is. */
    for (int type = 0; type < 64; type++) {
        CHECK(tb_nal_is_keyframe(1, hevc(type)) == (type >= 16 && type <= 21));
    }
    CHECK(tb_nal_is_keyframe(1, 0x26) == 1);   /* IDR_W_RADL as VideoToolbox writes it */
    CHECK(tb_nal_is_keyframe(1, 0x02) == 0);   /* TRAIL_R */
    CHECK(tb_nal_is_keyframe(1, 0x40) == 0);   /* VPS */
    CHECK(tb_nal_is_keyframe(1, 0x4E) == 0);   /* prefix SEI */

    if (failures) {
        fprintf(stderr, "keyframe NAL tests: %d of %d checks failed\n", failures, checks);
        return 1;
    }
    printf("keyframe NAL tests: %d checks passed\n", checks);
    return 0;
}
