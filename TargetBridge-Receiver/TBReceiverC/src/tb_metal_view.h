/* tb_metal_view.h — the Receiver's own Metal video drawing.
 *
 * With the "TargetBridge Metal" renderer (the default), SDL still owns the
 * window, its Metal layer, the waiting screen and the overlays, but every
 * video picture is drawn by this module:
 *   - NV12 (H.264/HEVC, the 8-bit and dithered uncompressed modes): a Y and a
 *     CbCr texture, converted to RGB (BT.709, video range) in a shader.
 *   - 10-bit RGB (full colour): a 10-bit (BGR10A2) texture on a 10-bit
 *     drawable, so it is shown in 10 bits; SDL2 has no 10-bit textures.
 * Changed rows of the uncompressed modes are copied by the GPU straight from
 * the Receiver's page-aligned frame memory (no CPU copy or conversion).
 * The picture is drawn into SDL's own render pass, so SDL then draws the
 * cursor, stats and notices on top as usual. The Metal layer can also present
 * in step with the display's refresh, which avoids tearing.
 *
 * Every function returns -1 / does nothing when the view is NULL. */

#ifndef TB_METAL_VIEW_H
#define TB_METAL_VIEW_H

#include <SDL.h>
#include <stddef.h>
#include <stdint.h>

struct tb_metal_view;

/* NULL unless `ren` is SDL's Metal renderer and the GPU setup works. */
struct tb_metal_view *tb_metal_view_create(SDL_Renderer *ren);
void tb_metal_view_destroy(struct tb_metal_view *v);

/* A whole NV12 picture from any CPU memory (decoded video, full raw frames). */
int  tb_metal_view_upload_nv12(struct tb_metal_view *v,
                               const uint8_t *y, int y_stride,
                               const uint8_t *uv, int uv_stride,
                               int w, int h);

/* Rows [first_row, end_row) of the Receiver's NV12 frame (stride w for both
 * planes). Both planes must be 16 KiB aligned with capacities that are
 * multiples of 16 KiB, so the GPU can read them in place. A new texture is
 * filled completely. Waits until the GPU is done, so the caller may change
 * the memory right after. */
int  tb_metal_view_upload_nv12_rows(struct tb_metal_view *v,
                                    const uint8_t *y, size_t y_capacity,
                                    const uint8_t *uv, size_t uv_capacity,
                                    int w, int h, int first_row, int end_row);

/* Same for 10-bit RGB (ARGB2101010 little endian, stride w * 4). */
int  tb_metal_view_upload_rgb10(struct tb_metal_view *v,
                                const uint8_t *pixels, size_t pixels_capacity,
                                int w, int h, int first_row, int end_row);

/* Draws the last uploaded picture over the whole output. Call between
 * SDL_RenderClear and the SDL draws that should appear on top. */
int  tb_metal_view_draw(struct tb_metal_view *v, SDL_Renderer *ren);

/* 1: 10-bit drawable, 0: SDL's default 8-bit drawable. Call only between
 * frames (after SDL_RenderPresent). */
void tb_metal_view_set_10bit_drawable(struct tb_metal_view *v, int on);

/* 1: present in step with the display's refresh (no tearing). */
void tb_metal_view_set_display_sync(struct tb_metal_view *v, int on);

/* Forgets the picture, e.g. at the end of a session. */
void tb_metal_view_reset(struct tb_metal_view *v);

#endif
