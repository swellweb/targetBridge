/* keyframe_nal.h — does a NAL unit start a picture a decoder can begin from?
 *
 * H.264: an IDR slice (nal_unit_type 5, low five bits of the header byte).
 * HEVC: an IRAP picture (BLA, IDR or CRA: nal_unit_type 16-21, bits 1-6 of
 * the first header byte). Header only, so the portable tests need no FFmpeg.
 */

#ifndef TB_KEYFRAME_NAL_H
#define TB_KEYFRAME_NAL_H

#include <stdint.h>

static inline int tb_nal_is_keyframe(int is_hevc, uint8_t header) {
    if (is_hevc) {
        const int type = (header >> 1) & 0x3F;
        return type >= 16 && type <= 21;
    }
    return (header & 0x1F) == 5;
}

#endif
