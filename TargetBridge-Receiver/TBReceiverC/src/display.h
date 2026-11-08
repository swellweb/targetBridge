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
    TB_DISP_ACTION_CYCLE_LANGUAGE = 1 << 1,
    TB_DISP_ACTION_HIDE_WINDOW = 1 << 2
};

/* Video renderer (Receiver menu > Expert settings, applies at start). */
enum tb_disp_renderer {
    TB_DISP_RENDERER_TARGETBRIDGE = 0, /* SDL Metal window, our Metal video view */
    TB_DISP_RENDERER_SDL_METAL    = 1, /* SDL draws everything with Metal */
    TB_DISP_RENDERER_SDL_OPENGL   = 2  /* SDL draws everything with OpenGL */
};

struct tb_display *tb_disp_create(int fullscreen, int start_hidden, int renderer);
void               tb_disp_destroy(struct tb_display *d);
void               tb_disp_set_connection_state(struct tb_display *d, int connected);
void               tb_disp_set_input_capture_active(struct tb_display *d, int active);

/* Background mode: the window can hide, and closing it hides it instead of quitting. */
void               tb_disp_set_window_visible(struct tb_display *d, int visible);
void               tb_disp_set_close_hides(struct tb_display *d, int close_hides);
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

/* Upload only rows [first_row, end_row) of a tightly packed NV12 picture
 * (stride = w), then render. A newly created texture gets the whole picture. */
void tb_disp_render_nv12_rows(struct tb_display *d,
                              const uint8_t *y, size_t y_capacity,
                              const uint8_t *uv, size_t uv_capacity,
                              int w, int h, int first_row, int end_row);

/* A notice shown at the bottom of the picture (e.g. a version mismatch);
 * NULL or "" removes it. */
void tb_disp_set_notice_text(struct tb_display *d, const char *text);

/* Same for 10-bit RGB (32-bit little-endian ARGB2101010, stride = w * 4).
 * With the Metal renderer `pixels` is read by the GPU in place, so it must
 * be 16 KiB aligned with `pixels_capacity` a multiple of 16 KiB (see
 * tb_raw_frame); the picture is then shown in 10 bits. */
void tb_disp_render_rgb10_rows(struct tb_display *d, const uint8_t *pixels, size_t pixels_capacity,
                               int w, int h, int first_row, int end_row);

/* Forgets the picture of the Metal video view, e.g. at the end of a session. */
void tb_disp_reset_video(struct tb_display *d);

/* Uncompressed modes on the TargetBridge Metal renderer: 1 = present in step
 * with the display's refresh (no tearing, but the Receiver waits for it). */
void tb_disp_set_display_sync(struct tb_display *d, int on);

/* Whether the renderer keeps 10-bit RGB textures (otherwise SDL converts
 * them to 8 bit on upload). */
int  tb_disp_native_rgb10(struct tb_display *d);

/* Update low-latency local cursor overlay in source-frame coordinates. */
void tb_disp_set_cursor(struct tb_display *d,
                        int x, int y,
                        int source_w, int source_h,
                        int visible,
                        int type,
                        int large);

void tb_disp_set_brightness(struct tb_display *d, double level);

/* Performance overlay drawn over the video. NULL or "" removes it. */
void        tb_disp_set_stats_text(struct tb_display *d, const char *text);
const char *tb_disp_renderer_name(struct tb_display *d);

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
