/* Direct macOS Metal presentation for VideoToolbox NV12 pixel buffers. */

#ifndef TB_NATIVE_METAL_RENDERER_H
#define TB_NATIVE_METAL_RENDERER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct tb_native_metal_stats {
    uint64_t submitted_frames;
    uint64_t completed_frames;
    uint64_t dropped_frames;
    double   gpu_time_ms_total;
    double   gpu_time_ms_max;
};

void *tb_native_metal_create(void);
void  tb_native_metal_destroy(void *renderer);
void  tb_native_metal_set_visible(void *renderer, int visible);

/* Returns 1 when submitted, 0 for a temporary queue/drawable drop and -1
 * when the native renderer cannot handle the frame. */
int tb_native_metal_render_nv12(void *renderer,
                                void *pixel_buffer,
                                int cursor_x,
                                int cursor_y,
                                int cursor_source_w,
                                int cursor_source_h,
                                int cursor_visible,
                                int cursor_type,
                                int cursor_large);

int tb_native_metal_render_cursor(void *renderer,
                                  int cursor_x,
                                  int cursor_y,
                                  int cursor_source_w,
                                  int cursor_source_h,
                                  int cursor_visible,
                                  int cursor_type,
                                  int cursor_large);

void tb_native_metal_get_stats(void *renderer,
                               struct tb_native_metal_stats *stats);

#ifdef __cplusplus
}
#endif

#endif
