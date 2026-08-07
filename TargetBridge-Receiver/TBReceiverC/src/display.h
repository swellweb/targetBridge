/* display.h — SDL2 fullscreen window + NV12 GPU texture renderer. */

#ifndef TB_DISPLAY_H
#define TB_DISPLAY_H

#include <stdint.h>
#include <stddef.h>

struct tb_display;

struct tb_display_info {
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

enum tb_input_event_kind {
    TB_INPUT_EVENT_NONE = 0,
    TB_INPUT_EVENT_MOVE,
    TB_INPUT_EVENT_LEFT_DRAG,
    TB_INPUT_EVENT_RIGHT_DRAG,
    TB_INPUT_EVENT_OTHER_DRAG,
    TB_INPUT_EVENT_SCROLL,
    TB_INPUT_EVENT_LEFT_DOWN,
    TB_INPUT_EVENT_LEFT_UP,
    TB_INPUT_EVENT_RIGHT_DOWN,
    TB_INPUT_EVENT_RIGHT_UP,
    TB_INPUT_EVENT_OTHER_DOWN,
    TB_INPUT_EVENT_OTHER_UP,
    TB_INPUT_EVENT_KEY_DOWN,
    TB_INPUT_EVENT_KEY_UP,
    TB_INPUT_EVENT_SWITCH_PREV_TARGET,
    TB_INPUT_EVENT_SWITCH_NEXT_TARGET,
    TB_INPUT_EVENT_SWITCH_PREV_SPACE,
    TB_INPUT_EVENT_SWITCH_NEXT_SPACE,
    TB_INPUT_EVENT_DEACTIVATE_CONTROL
};

struct tb_input_event {
    enum tb_input_event_kind kind;
    int dx;
    int dy;
    int scroll_x;
    int scroll_y;
    uint16_t key_code;
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

/* Render a packed 4:4:4 frame — full chroma, no subsampling. `ten_bit` selects
 * ARGB2101010 over 8-bit BGRA; both are 4 bytes/pixel. */
void tb_disp_render_packed32(struct tb_display *d,
                             const uint8_t *rgba, int stride,
                             int w, int h, int ten_bit);

/* Decode and render one TBD1 blob (tb_dpcm.h) on the GPU. Returns 0 on success;
 * non-zero means the frame was not displayed and the caller should count it as
 * dropped rather than assume the screen is current. */
int  tb_disp_render_dpcm(struct tb_display *d, const uint8_t *blob, size_t len);

/* Decode one region of a TBD2 frame; present when it is the last of its frame.
 * `blob`/`len` are the TBD2 payload with the packet header already stripped.
 *
 * `x0`/`y0` place it, both multiples of the tile size. A full-width band passes
 * x0 = 0; a damage rect passes both. */
int  tb_disp_render_dpcm_slice(struct tb_display *d, const uint8_t *blob, size_t len,
                               int frame_w, int frame_h, int x0, int y0, int is_last);

/* Whether this receiver can decode TBD1 at all, i.e. whether it should advertise
 * "supportsDPCM" to the sender. False on any Mac without a working compute
 * pipeline, which must keep receiving uncompressed frames. */
int  tb_disp_supports_dpcm(void);

/* Update low-latency local cursor overlay in source-frame coordinates. */
void tb_disp_set_cursor(struct tb_display *d,
                        int x, int y,
                        int source_w, int source_h,
                        int visible,
                        int type);

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
