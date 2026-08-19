/* display.h — SDL2 fullscreen window + NV12 GPU texture renderer. */

#ifndef TB_DISPLAY_H
#define TB_DISPLAY_H

#include <stdint.h>
#include <stddef.h>

#include "input_queue.h"

struct tb_display;

struct tb_display_info {
    uint32_t logical_w;
    uint32_t logical_h;
    uint32_t active_w;
    uint32_t active_h;
    uint32_t window_w;
    uint32_t window_h;
    uint32_t drawable_w;
    uint32_t drawable_h;
    char     name[128];
};

enum tb_display_action {
    TB_DISP_ACTION_NONE = 0,
    TB_DISP_ACTION_QUIT = 1 << 0,
    TB_DISP_ACTION_CYCLE_LANGUAGE = 1 << 1
};

struct tb_display *tb_disp_create(int fullscreen);
void               tb_disp_destroy(struct tb_display *d);
void               tb_disp_set_connection_state(struct tb_display *d, int connected);
void               tb_disp_set_input_capture_active(struct tb_display *d, int active);
void               tb_disp_set_input_intercept_active(struct tb_display *d, int active);

/* Whether the receiver display window is on the active macOS Space. Used to
 * gate receiverMaster global-tap forwarding so input on other receiver Spaces
 * does not leak to the sender. */
int                tb_disp_window_on_active_space(struct tb_display *d);

/* Resize/recreate texture when frame dimensions change. */
int  tb_disp_ensure_texture(struct tb_display *d, int w, int h);

/* Upload NV12 planes + render. Called once per decoded frame. */
void tb_disp_render_nv12(struct tb_display *d,
                         const uint8_t *y, int y_stride,
                         const uint8_t *uv, int uv_stride,
                         int w, int h);

/* Present a VideoToolbox CVPixelBuffer through the optional native Metal
 * path. Returns non-zero when the frame was handled; portable callers keep
 * using tb_disp_render_nv12. */
int tb_disp_render_native_nv12(struct tb_display *d,
                               void *pixel_buffer,
                               int w, int h);

/* Update low-latency local cursor overlay in source-frame coordinates. */
void tb_disp_set_cursor(struct tb_display *d,
                        int x, int y,
                        int source_w, int source_h,
                        int visible,
                        int type,
                        int large);

void tb_disp_set_brightness(struct tb_display *d, double level);

/* Poll input actions while idle/connected. */
unsigned int tb_disp_poll_actions(struct tb_display *d);
int          tb_disp_pop_input_event(struct tb_display *d, struct tb_input_event *out);

/* Query active display/window/drawable information for UI/debug metadata. */
int  tb_disp_get_info(struct tb_display *d, struct tb_display_info *info);

/* Render a simple launcher/status UI before the video stream starts. */
void tb_disp_render_status(struct tb_display *d,
                           const char *ip,
                           const char *status,
                           const char *sender,
                           const char *panel,
                           const char *mode,
                           const char *language,
                           const char *permissions);
void tb_disp_render_connecting(struct tb_display *d);

#endif
