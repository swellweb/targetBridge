#!/usr/bin/env python3
"""Exercise production display routing with isolated SDL/Metal boundaries.

Only the routing functions are compiled, so no GUI, GPU, SDL installation,
receiver process, or network connection is needed. This follows the repository's
source-extraction guard tests while checking behavior rather than source strings.
"""
import argparse
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path,
                    default=Path(__file__).resolve().parents[1] / "src/display.c")
args = parser.parse_args()
src = args.source.read_text()


def function(name, source=None):
    src = source if source is not None else globals()["src"]
    start = re.search(r'^(?:static )?(?:int|void) '+name+r'\(', src, re.M).start()
    body = src.index('{', start)
    depth = 1
    pos = body+1
    while depth:
        depth += (src[pos] == '{') - (src[pos] == '}')
        pos += 1
    return src[start:pos]

prefix = r'''
#include <assert.h>
#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
typedef void SDL_Window;
struct tb_display {
    void *win, *ren, *tex;
    int is_connected, is_connecting, system_cursor_hidden;
    int cursor_x, cursor_y, cursor_source_w, cursor_source_h;
    int cursor_visible, cursor_type, cursor_large;
    uint32_t last_video_frame_time;
};
static int ready, supports, supports_packed, init_rc, render_rc, updates_rc, valid_blob;
static int packed_renders, packed_depth;
static int destroyed_window, last_cursor_type, last_cursor_large;
static void SDL_DestroyTexture(void *p) { (void)p; }
static void SDL_DestroyRenderer(void *p) { (void)p; assert(!ready); }
static void SDL_DestroyWindow(void *p) { (void)p; assert(!ready); ++destroyed_window; }
static void SDL_EnableScreenSaver(void) { }
static void SDL_Quit(void) { }
static int CGMainDisplayID(void) { return 0; }
static void CGDisplayShowCursor(int id) { (void)id; }
static void tb_disp_destroy_status_texture(struct tb_display *d) { (void)d; }
static int init_calls, shutdown_calls, shown, draws, renders, flushes;
static int tb_metal_plane_available(void) { return ready; }
static int tb_metal_plane_supports_packed(void) { return supports_packed; }
static int tb_metal_plane_init(void *w) { (void)w; ++init_calls; ready = !init_rc; return init_rc; }
static void tb_metal_plane_shutdown(void) { ++shutdown_calls; ready = shown = 0; }
static void tb_metal_plane_set_hidden(int hidden) { if(hidden) tb_metal_plane_shutdown(); else shown = 1; }
static int tb_metal_plane_render_packed(const uint8_t *pixels,int stride,int w,int h,int ten_bit) {
    assert(pixels && stride == w * 4 && w > 0 && h > 0);
    ++packed_renders; packed_depth = ten_bit; return render_rc;
}
static void tb_metal_plane_set_cursor(int x,int y,int sw,int sh,int v,int t,int large) { (void)x;(void)y;(void)sw;(void)sh;(void)v;last_cursor_type=t;last_cursor_large=large; }
static void tb_metal_plane_flush_cursor(void) { ++flushes; }
static void tb_disp_refresh_window_mode(struct tb_display *d) { (void)d; }
static int tb_disp_ensure_texture(struct tb_display *d,int w,int h) { (void)d;(void)w;(void)h;return 0; }
static int SDL_UpdateNVTexture(void *tex,void *rect,const uint8_t *y,int ys,const uint8_t *uv,int us) { (void)tex;(void)rect;(void)y;(void)ys;(void)uv;(void)us;return updates_rc; }
static const char *SDL_GetError(void) { return "injected failure"; }
static uint32_t SDL_GetTicks(void) { return 100; }
static void tb_disp_render_current(struct tb_display *d) { (void)d; assert(!ready); ++draws; }
static void reset(void) {
    valid_blob = 1;
    ready = supports = init_rc = render_rc = updates_rc = destroyed_window = 0;
    supports_packed = packed_renders = packed_depth = 0;
    init_calls = shutdown_calls = shown = draws = renders = flushes = 0;
}
'''
metal_source = (args.source.parent / 'tb_metal_plane.m').read_text()
body = function('tb_metal_frame_dimensions_valid', metal_source) + '\n' + '\n'.join(function(n) for n in ['tb_disp_set_stream_state', 'tb_disp_set_connection_state', 'tb_disp_render_nv12', 'tb_disp_render_raw_rgb10', 'tb_disp_raw_rgb10_available', 'tb_disp_set_cursor', 'tb_disp_destroy'])
main = r'''
int main(void) {
    assert(tb_metal_frame_dimensions_valid(5120,2880));
    assert(tb_metal_frame_dimensions_valid(1,1));
    assert(!tb_metal_frame_dimensions_valid(5121,2880));
    assert(!tb_metal_frame_dimensions_valid(5120,2881));
    assert(!tb_metal_frame_dimensions_valid(16384,8192));
    assert(!tb_metal_frame_dimensions_valid(0,2880));
    assert(!tb_metal_frame_dimensions_valid(5120,-1));
    struct tb_display d = {0}; uint8_t frame[4] = {0};
    reset(); supports_packed = 1; supports = 0;
    assert(tb_disp_raw_rgb10_available(&d) == 1);
    assert(!init_calls && !ready);  /* Capability probe never covers SDL UI. */
    supports_packed = 0; supports = 1;
    assert(tb_disp_raw_rgb10_available(&d) == 0);
    assert(tb_disp_raw_rgb10_available(NULL) == 0);
    reset();
    assert(tb_disp_render_raw_rgb10(&d,NULL,32,8,8) == -1);
    assert(tb_disp_render_raw_rgb10(&d,frame,28,8,8) == -1);
    assert(tb_disp_render_raw_rgb10(&d,frame,36,8,8) == -1);
    assert(tb_disp_render_raw_rgb10(&d,frame,20484,5121,1) == -1);
    assert(tb_disp_render_raw_rgb10(&d,frame,32,8,2881) == -1);
    assert(tb_disp_render_raw_rgb10(&d,frame,0,0,1) == -1);
    assert(!init_calls && !packed_renders && !shown);
    reset(); init_rc = -1;
    assert(tb_disp_render_raw_rgb10(&d,frame,32,8,8) == -1);
    assert(!packed_renders && !shown);
    reset(); render_rc = -1;
    assert(tb_disp_render_raw_rgb10(&d,frame,32,8,8) == -1);
    assert(!ready && !shown && shutdown_calls == 1 && !draws);
    reset(); supports = 0;
    assert(tb_disp_render_raw_rgb10(&d,frame,32,8,8) == 0);
    assert(ready && shown && d.is_connected && packed_renders == 1 && packed_depth == 1);
    assert(!renders && !draws);  /* No 8-bit fallback. */
    render_rc = -1;
    assert(tb_disp_render_raw_rgb10(&d,frame,32,8,8) == -1);
    assert(ready && shown && !shutdown_calls && !draws);
    tb_disp_render_nv12(&d,frame,2,frame,2,2,2);
    assert(!ready && !shown && draws == 1);

    reset();
    assert(tb_disp_render_raw_rgb10(&d,frame,32,8,8) == 0);
    tb_disp_set_cursor(&d,3,4,100,100,1,0,0);
    assert(flushes == 2 && draws == 0);
    tb_disp_set_cursor(&d,3,4,100,100,1,1,1);
    assert(last_cursor_type == 1 && last_cursor_large == 1 && draws == 0);
    render_rc = -1;
    assert(tb_disp_render_raw_rgb10(&d,frame,32,8,8) == -1);
    assert(ready && shown && shutdown_calls == 0);
    tb_disp_render_nv12(&d,frame,2,frame,2,2,2);
    assert(!ready && !shown && draws == 1);

    reset(); ready = shown = 1; d.is_connected = 1;
    tb_disp_set_connection_state(&d,0);
    assert(!ready && !shown && !d.is_connected);
    reset(); ready = shown = 1; d.is_connected = 0;
    tb_disp_set_connection_state(&d,0);
    assert(!ready && !shown);
    reset(); ready = shown = 1;
    struct tb_display *owned = calloc(1, sizeof(*owned));
    assert(owned);
    owned->win = owned->ren = (void *)1;
    tb_disp_destroy(owned);
    assert(shutdown_calls == 1 && destroyed_window == 1);
    puts("RAW RGB10 display capability/failure/fallback/cursor/disconnect/teardown checks passed");
}
'''
with tempfile.TemporaryDirectory(prefix="targetbridge-display-test-") as temporary:
    out = Path(temporary) / "display_test.c"
    out.write_text(prefix + body + main)
    executable = out.with_suffix("")
    subprocess.run(shlex.split(os.environ.get("CC", "cc")) + [
        "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function",
        str(out), "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable)], check=True)
