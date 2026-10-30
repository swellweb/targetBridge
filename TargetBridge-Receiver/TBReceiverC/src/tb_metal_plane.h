/* tb_metal_plane.h — the video plane, and the frame surface behind it.
 *
 * SDL2 has no 10-bit texture format on any macOS backend; requesting one lands
 * on a scalar CPU conversion that also truncates to 8 bits. See tb_metal_plane.m
 * for the packed upload and presentation path.
 */

#ifndef TB_METAL_PLANE_H
#define TB_METAL_PLANE_H

#include <stddef.h>
#include <stdint.h>

struct SDL_Window;

/* Create the Metal layer alongside SDL's window. Returns 0 on success; on
 * failure the caller should stay on the SDL render path. Starts hidden. */
int  tb_metal_plane_init(struct SDL_Window *win);
void tb_metal_plane_shutdown(void);

/* Non-zero once init() has succeeded. */
int  tb_metal_plane_available(void);

/* Probe packed RGB presentation without creating a window. Gates the
 * optional supportsRawRGB10 capability. */
int  tb_metal_plane_supports_packed(void);

/* Toggle display synchronization. Disabling it may reduce latency at the cost
 * of tearing. The preference survives plane teardown when SDL takes the window. */
void tb_metal_plane_set_vsync(int enabled);

/* Show a successfully submitted video frame. Hiding releases the Metal view
 * so SDL can render status UI, NV12, or ordinary decoded video again. */
void tb_metal_plane_set_hidden(int hidden);

/* Cursor overlay state in source-frame coordinates. */
void tb_metal_plane_set_cursor(int x, int y, int source_w, int source_h,
                               int visible, int type, int large);

/* Adopt the sender's actual cursor bitmap. Premultiplied RGBA8, `w`*`h` pixels,
 * with the hot spot in the same pixel space. Replaces the drawn arrow for every
 * subsequent placement; the arrow stays as the fallback until the first one
 * arrives, so there is never a moment with no pointer. */
void tb_metal_plane_set_cursor_image(const uint8_t *rgba, int w, int h,
                                     int hot_x, int hot_y);

/* Arrival time (ms, same clock as the receiver's now_ms_f) of the cursor packet
 * about to be applied. Call immediately before set_cursor; the plane reports
 * arrival-to-commit so we can see the queue wait, not just our own work. */
void tb_metal_plane_note_cursor_arrival(double recv_ms);

/* Apply any pending cursor position. Call once per run-loop pass.
 *
 * set_cursor only marks dirty; flush applies the state on the main loop. */
void tb_metal_plane_flush_cursor(void);

/* Present one packed 32-bit frame straight from CPU memory. `ten_bit` selects
 * ARGB2101010 ('l10r') over 8-bit BGRA; both are 4 bytes per pixel. Used for
 * uncompressed frames, including the ones a damage packet has just been patched
 * into. Returns 0 on success. */
int  tb_metal_plane_render_packed(const uint8_t *px, int stride, int w, int h,
                                  int ten_bit);

#endif /* TB_METAL_PLANE_H */
