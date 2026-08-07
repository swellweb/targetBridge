/* tb_metal_plane.h — the video plane, and the frame surface behind it.
 *
 * SDL2 has no 10-bit texture format on any macOS backend; requesting one lands
 * on a scalar CPU conversion that also truncates to 8 bits. See tb_metal_plane.m
 * for that, and for why the decoded frame now lives in VRAM.
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

/* Non-zero if this receiver can decode TBD1 frames on the GPU. Gates the
 * "supportsDPCM" capability it advertises to the sender: the CPU reference
 * decoder is far too slow to stand in at 5K (166 ms/frame measured on the
 * target iMac's i5, against 6.5 ms on its GPU), so a receiver without a working
 * compute pipeline must keep receiving uncompressed frames. */
int  tb_metal_plane_supports_dpcm(void);

/* Present without waiting for the display's refresh boundary.
 *
 * Worth up to a full refresh period of latency — ~8 ms on average at 60 Hz, and
 * the largest single addressable term left in the end-to-end budget (capture
 * delivery measured 0.05 ms, encode+send 9.2 ms, decode ~5.5 ms, and scanout is
 * physics). The cost is tearing: a frame can land mid-scanout, so the panel shows
 * part of two frames with a visible seam.
 *
 * Purely a matter of taste, which is why it is a user-facing toggle rather than a
 * decision taken here. Sticky across plane teardown, since the plane is destroyed
 * and rebuilt whenever the SDL status UI takes the window back. */
void tb_metal_plane_set_vsync(int enabled);

/* Show/hide the video plane. Hidden while the SDL status/connecting UI owns
 * the window, shown once frames arrive. */
void tb_metal_plane_set_hidden(int hidden);

/* Cursor overlay state, in source-frame coordinates.
 *
 * Composited by the render pass rather than drawn into the frame. It used to be
 * stamped into the pixel buffer by the CPU, which no longer works for two
 * reasons: a TBD1 frame is never in CPU-visible memory, and once damage
 * rectangles patch the frame in place a stamped cursor would leave a trail
 * everywhere it had been. */
void tb_metal_plane_set_cursor(int x, int y, int source_w, int source_h,
                               int visible, int type);

/* Present one packed 32-bit frame straight from CPU memory. `ten_bit` selects
 * ARGB2101010 ('l10r') over 8-bit BGRA; both are 4 bytes per pixel. Used for
 * uncompressed frames, including the ones a damage packet has just been patched
 * into. Returns 0 on success. */
int  tb_metal_plane_render_packed(const uint8_t *px, int stride, int w, int h,
                                  int ten_bit);

/* Decode one TBD1 blob on the GPU and present it. The blob must already have
 * passed tb_dpcm_parse — that is what makes the shader safe to run without
 * bounds checks. Returns 0 on success.
 *
 * Damage rectangles are deliberately NOT part of this path. A compressed full
 * frame is ~20 MB in the worst case and decodes in ~7.5 ms, which fits 60 Hz on
 * its own, so the sender sends whole frames to a DPCM-capable receiver and the
 * base-image bookkeeping disappears. Receivers that cannot decode TBD1 keep
 * getting damage packets, because on the uncompressed path it is the only thing
 * that makes 5K viable at all. */
int  tb_metal_plane_render_dpcm(const uint8_t *blob, size_t len);

/* Decode one BAND of a frame into the surface and, on the last band, present.
 *
 * Slicing exists to overlap the stages: band k decodes while band k+1 is still
 * crossing the wire. Measured, that is worth roughly halving frame latency —
 * 23.6 ms to ~12 at 8-bit — because the stages stop running end to end.
 *
 * It cost nothing to add to the format. Tiles were already independent 8x8
 * units with byte-aligned group bases, so a band is just a shorter frame written
 * further down the surface: same bytes, same ratio, no seam.
 *
 * `x0`/`y0` place the blob in the surface and must both be multiples of the tile
 * size. A full-width band passes x0 = 0; a DAMAGE RECT passes both, and needs
 * nothing else -- the codec never knew the difference, since an encoder handed
 * (base + y*stride + x*4, stride, w, h) produces a blob that decodes losslessly
 * on its own. Verified against the reference encoder.
 *
 * `frame_w`/`frame_h` describe the whole surface; pass 0 for both when the blob
 * is a whole frame. */
int  tb_metal_plane_render_dpcm_slice(const uint8_t *blob, size_t len,
                                      int frame_w, int frame_h, int x0, int y0,
                                      int is_last);

#endif
