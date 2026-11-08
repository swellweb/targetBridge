/* tb_metal_view.h — full 10-bit colour on SDL's Metal renderer.
 *
 * SDL2 has no 10-bit texture format: an ARGB2101010 texture is converted to
 * 8 bits on the CPU for every frame, and the window's drawable is 8-bit. With
 * the Metal renderer this module instead
 *   - switches the window's Metal layer to a 10-bit (BGR10A2) drawable,
 *   - keeps the picture in a 10-bit Metal texture, filled from the
 *     Receiver's copy of the frame by a GPU blit of the changed rows only,
 *     without a CPU copy or conversion, and
 *   - draws that texture into SDL's own render pass, so SDL then draws the
 *     cursor, stats and notices on top as usual.
 * It also lets the Metal layer present in step with the display's refresh,
 * which avoids tearing.
 *
 * All functions are no-ops returning -1 when the renderer is not Metal. */

#ifndef TB_METAL_VIEW_H
#define TB_METAL_VIEW_H

#include <SDL.h>
#include <stddef.h>
#include <stdint.h>

struct tb_metal_view;

/* NULL unless `ren` is SDL's Metal renderer and the GPU setup works. */
struct tb_metal_view *tb_metal_view_create(SDL_Renderer *ren);
void tb_metal_view_destroy(struct tb_metal_view *v);

/* Copies rows [first_row, end_row) of `pixels` (ARGB2101010 little endian,
 * stride w * 4) into the 10-bit texture. `pixels` must be page aligned and
 * `pixels_capacity` a multiple of 16 KiB, so the GPU can read it in place.
 * A new texture is filled completely. Waits until the GPU is done, so the
 * caller may change `pixels` right after. Returns 0 on success. */
int  tb_metal_view_upload_rgb10(struct tb_metal_view *v,
                                const uint8_t *pixels, size_t pixels_capacity,
                                int w, int h, int first_row, int end_row);

/* Draws the 10-bit texture over the whole output. Call between
 * SDL_RenderClear and the SDL draws that should appear on top. */
int  tb_metal_view_draw(struct tb_metal_view *v, SDL_Renderer *ren);

/* 1: 10-bit drawable, 0: SDL's default 8-bit drawable. Call only between
 * frames (after SDL_RenderPresent). */
void tb_metal_view_set_10bit_drawable(struct tb_metal_view *v, int on);

/* 1: present in step with the display's refresh (no tearing). */
void tb_metal_view_set_display_sync(struct tb_metal_view *v, int on);

/* Forgets the texture, e.g. at the end of a session. */
void tb_metal_view_reset(struct tb_metal_view *v);

#endif
