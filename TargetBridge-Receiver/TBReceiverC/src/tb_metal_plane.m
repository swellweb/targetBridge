/* tb_metal_plane.m — the video plane, and the frame surface behind it.
 *
 * WHY THIS BYPASSES SDL AT ALL
 *
 * SDL2's 2D renderer has no 10-bit texture format on any macOS backend, so
 * asking it for ARGB2101010 silently lands on a scalar CPU converter that both
 * costs ~100 ms/frame at 5K and truncates to 8 bits. Measured on the target
 * iMac: 8-bit BGRA 12 ms/frame, the same frame as "10-bit" 102 ms/frame. SDL
 * keeps the window, input and status UI; this owns a sibling layer shown only
 * while video frames are arriving.
 *
 * TWO WAYS A FRAME ARRIVES
 *
 * An uncompressed frame is staged in a shared buffer and presented straight from
 * there, as it always was. A TBD2 frame (tb_dpcm.h) is uploaded compressed and
 * expanded by a compute kernel into a private buffer that lives in VRAM — at 5K
 * that is ~20 MB instead of 59 at 8-bit depth, ~32 MB at 10-bit.
 *
 * That the decoded frame lands in VRAM rather than in CPU-visible memory was
 * measured, not assumed: decoding into shared memory costs 17.2 ms/frame on the
 * target GPU against 7.5 ms into VRAM, and 17.2 ms alone exceeds the 16.67 ms
 * budget at 60 Hz.
 *
 * A compressed full frame therefore fits 60 Hz by itself, which is why damage
 * rectangles are not part of the TBD2 path at all — no base image, no patching,
 * no keyframe bookkeeping. Receivers that cannot decode TBD2 still get damage
 * packets, patched on the CPU and presented through the uncompressed path, since
 * for them it is the only thing that makes 5K viable.
 *
 * The cursor is composited by the render pass, NOT drawn into the frame. A
 * compressed frame never exists in CPU-visible memory, so there is nothing to
 * stamp it into.
 */

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
/* Not pulled in by CAMetalLayer.h: the cursor plane needs CALayer and, above
 * all, CATransaction — every geometry change it makes has to disable implicit
 * animation. */
#import <QuartzCore/QuartzCore.h>
#import <Cocoa/Cocoa.h>

#include "tb_metal_plane.h"
#include "tb_dpcm.h"
#include "tb_health.h"
#include <pthread.h>
#include <stdatomic.h>

#include <sys/time.h>
/* MUST be CLOCK_MONOTONIC, and must stay the same clock main.c's now_ms_f uses.
 * This was gettimeofday, whose epoch differs by decades from a monotonic one, so
 * subtracting a timestamp taken in main.c produced a cursor "latency" of
 * 1786464339519 ms. Monotonic is also the right choice on its own merits: a
 * wall-clock adjustment cannot make a duration negative. */
static double tb_mp_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
}

#include <SDL.h>
#include <stdio.h>
#include <string.h>

/* Drawables the layer may hand out. Only 2 or 3 are legal — CAMetalLayer clamps,
 * and double buffering is the floor for a compositor: one buffer is scanned out
 * while the other is drawn.
 *
 * THREE. Two was tried, measured, and reverted — the note is here so it is not
 * tried again on the strength of the latency number alone.
 *
 * Two looked excellent on paper. With vsync on, `drawable` (time blocked in
 * nextDrawable) fell from 11.7ms mean to ~0.1ms, and cursor latency improved
 * with it, from ~2.0ms to ~1.0ms: the pool had been exhausted at every present,
 * so all three buffers sat queued ahead of the panel.
 *
 * What it cost was slack. Late frames went from ~0.3% to ~1% of a 240-frame
 * window, worst-case gaps grew from ~22-31ms to ~26-33ms, and in use the CURSOR
 * began skipping — which it should not care about at all, being on its own
 * layer. The mechanism is the synchronous present path further down, which calls
 * tb_present on the calling thread rather than presentQ: with one buffer fewer,
 * nextDrawable blocks there often enough to stall the main loop, and the main
 * loop is what delivers cursor positions. The stall then persisted until a vsync
 * toggle rebuilt the drawable queue.
 *
 * So: ~11ms of latency is not worth a visible stutter, and the real fix is to
 * remove that synchronous present path, not to starve the pool. */
#define TB_METAL_RING 3

/* Upload staging slots.
 *
 * Sized for SLICES, not frames. This was 3, from when a frame was a single
 * upload — but a sliced frame takes one slot per band, so at 18 bands the
 * thread doing the uploading blocked on slot recycling eighteen times a frame.
 * That thread also services the window and the socket, so the receiver stopped
 * responding while the GPU caught up: not a deadlock, just the main thread used
 * as the throttle.
 *
 * A slice slot is a fraction of a frame (~1.7 MB at 18 bands against ~30 MB
 * whole), so depth is cheap where it used to be expensive. */
/* Eight, not thirty-two. Sized for bands at ~1.7 MB, thirty-two forgot that the
 * same ring carries WHOLE frames on the unsliced path, and every slot grows to
 * the largest request it has ever seen: 32 x ~30 MB is a gigabyte of staging
 * buffers. Measured 4.4 GB peak footprint on the receiver, which put the machine
 * into swap and stalled the stream to zero with none of the drop paths firing —
 * nothing was broken, it was just thrashing.
 *
 * Eight is comfortably above the 4-band working set and bounds the ring at
 * ~240 MB in the worst case. */
#define TB_UPLOAD_RING 8

/* Frames in flight. One surface is not enough once a frame arrives as bands:
 * the next frame's first band starts decoding while the current frame is still
 * being presented, and with a single buffer the screen shows bands from two
 * frames at once. Three is what the source spec called for and what the cost
 * justifies — 59 MB each against 4 GB of VRAM. */
#define TB_FRAME_RING 3

/* Mirrors DpcmParams in the shader. */
struct tb_dpcm_gpu_params {
    uint32_t width, height;
    uint32_t tilesX, tilesY;
    uint32_t tileCount;
    uint32_t outStridePx;
    uint32_t widthOff, seedOff, payOff;
    uint32_t bits;      /* 8 or 10; channel c sits at bit c*bits */
    uint32_t alpha;     /* opaque alpha, pre-shifted for this depth */
    /* Where in the destination this blob belongs. A slice is simply a shorter
     * frame written further down the surface, which is why slicing needed no new
     * codec: the tiles were already independent.
     *
     * A DAMAGE RECT is the same idea in both axes -- a narrower, shorter frame
     * written at a column as well as a row. The codec needs nothing for it
     * either: an encoder given (base + y*stride + x*4, stride, w, h) produces a
     * blob that decodes losslessly, verified against the reference. Both are
     * zero for a whole frame. */
    uint32_t rowOffset;
    uint32_t colOffset;
};

static struct {
    int                   ready;
    SDL_MetalView         view;
    CAMetalLayer         *layer;
    id<MTLDevice>         dev;
    id<MTLCommandQueue>   queue;
    id<MTLRenderPipelineState>  pipe;        /* present + dither */
    id<MTLRenderPipelineState>  cursorPipe;  /* cursor overlay */
    id<MTLComputePipelineState> dpcmPipe;
    size_t                row_align;
    float                 dither;

    id<MTLBuffer>         ring[TB_UPLOAD_RING];
    size_t                ring_cap[TB_UPLOAD_RING];
    int                   ring_idx;
    dispatch_semaphore_t  inflight;

    /* Destinations for decoded frames, in VRAM. 4 bytes per pixel, rows padded
     * so a texture can be viewed over them. */
    id<MTLBuffer>         frame[TB_FRAME_RING];
    size_t                frame_cap[TB_FRAME_RING];
    int                   frame_widx;      /* being decoded into */
    int                   frame_open;      /* a frame holds a ring slot */
    dispatch_semaphore_t  frames_free;

    /* Present without blocking the render thread — TB_ASYNC_PRESENT=1.
     *
     * Presenting has to wait for every band's decode, and the simple way to do
     * that is to block on the last one, which is what the synchronous path
     * does. It costs the render thread roughly 4 ms a frame sitting idle, and
     * during that time it cannot start on the next frame's early bands.
     *
     * Waiting is unavoidable; doing it on the render thread is not. Each band
     * counts itself in before commit and out on completion, and whoever takes
     * the count to zero performs the present. That needs no assumption about
     * completion order — which matters, because the two claims in this file
     * disagree about whether one queue guarantees it, and the comment written
     * after the N>1 glitches says it does not. Counting is true either way.
     *
     * Off by default: this is the code that has glitched before. */
    int                   async_present;
    dispatch_queue_t      presentQ;
    _Atomic int           bands_inflight;  /* committed, not yet completed */
    int                   present_armed;   /* guarded by g_present_lock */
    int                   present_idx;
    int                   present_ten_bit;
    size_t                frame_bpr;
    int                   frame_w, frame_h;


    id<MTLTexture>        curTex;
    int                   cur_tex_w, cur_tex_h;
    /* The cursor's own compositing plane — see the cursor-plane section. */
    CALayer              *cursorLayer;
    int                   cur_layer_w, cur_layer_h;
    float                 cur_layer_scale;
    /* Arrival time of the cursor packet being applied, 0 when unknown. */
    double                cur_arrival_ms;
    /* The sender's real cursor bitmap, once it has sent one. */
    CGImageRef            cursorImage;
    int                   cur_img_w, cur_img_h, cur_img_hot_x, cur_img_hot_y;
    int                   cursor_layer_flipped;
    float                 cur_tex_scale;      /* what curTex was built for */
    int                   cur_x, cur_y, cur_sw, cur_sh, cur_visible, cur_type;

    int                   shown;
    /* Default on: tearing should be opted into, never inherited. */
    int                   vsync;
    int                   vsync_initialised;
} g;

/* Guards g.present_idx / present_ten_bit / present_armed.
 *
 * File scope with a static initialiser on purpose: `g` is zero-initialised, and
 * an all-zero pthread_mutex_t is not a valid mutex on macOS — the initialiser
 * carries a signature. Keeping it out of the struct also means no ordering
 * question about when it becomes usable.
 *
 * A mutex rather than serialising on presentQ, because presentQ blocks inside
 * nextDrawable waiting for a vblank and the arming thread must never wait for
 * that. See the arming site for what it cost. */
static pthread_mutex_t g_present_lock = PTHREAD_MUTEX_INITIALIZER;

void tb_metal_plane_set_vsync(int enabled) {
    const int want = enabled ? 1 : 0;
    if (g.vsync == want) return;
    g.vsync = want;
    /* Applies immediately when a layer exists, and is re-applied at init, so the
     * choice survives the plane being torn down and rebuilt. */
    if (g.layer) g.layer.displaySyncEnabled = want ? YES : NO;
    fprintf(stderr, "[metal] vsync %s\n", want ? "on" : "off (lower latency, may tear)");
}

/* Set by set_cursor, cleared by the cursor thread. */
static atomic_int g_cursor_dirty = 0;

static void tb_cursor_layer_attach(void);
static void tb_cursor_layer_ensure(void);
static void tb_cursor_layer_place(void);

/* The cursor's own thread.
 *
 * WHY IT HAS ONE
 *
 * Placement used to run on the receiver's main loop. That loop blocks for up to
 * 100ms in dispatch_semaphore_wait(g.inflight) when the GPU is backed up — and
 * when presentQ is sitting in nextDrawable waiting for a vblank, inflight is
 * exactly what stops being signalled. Measured: `submit 100%`, `drawable 11.6ms`
 * and cursor latency going from 1.6ms to 23.9ms mean / 95ms worst, all in the
 * same five-second window. The cursor was never the faulty part; it was starved
 * by render backpressure, which is why three fixes aimed at the cursor missed.
 *
 * Only PROPERTY writes happen here — position, size, hidden — inside an explicit
 * CATransaction, which is what Core Animation supports off the main thread. The
 * structural work (creating the layer, re-parenting it, building its image) stays
 * on the main thread via tb_metal_plane_flush_cursor, because mutating a layer
 * TREE off-main while AppKit may also be touching it is a different and much
 * worse risk. */
static pthread_t      g_cursor_thread;
static atomic_int     g_cursor_thread_run = 0;
static pthread_mutex_t g_cursor_state_lock = PTHREAD_MUTEX_INITIALIZER;
/* Written by the packet thread, read by the cursor thread. Snapshotted together
 * so a placement can never mix a new x with an old y. */
static struct { int x, y, sw, sh, visible; double arrival_ms; } g_cur_pending;


void tb_metal_plane_set_cursor(int x, int y, int source_w, int source_h,
                               int visible, int type) {
    g.cur_type = type;

    pthread_mutex_lock(&g_cursor_state_lock);
    g_cur_pending.x       = x;
    g_cur_pending.y       = y;
    g_cur_pending.sw      = source_w > 0 ? source_w : 1;
    g_cur_pending.sh      = source_h > 0 ? source_h : 1;
    g_cur_pending.visible = visible;
    g_cur_pending.arrival_ms = g.cur_arrival_ms;
    pthread_mutex_unlock(&g_cursor_state_lock);

    /* Only mark it dirty. Placement happens once per run-loop pass via
     * tb_metal_plane_flush_cursor().
     *
     * This used to place inline, to save a queue hop. That put CATransaction —
     * and therefore a window-server round trip — directly in the packet handler,
     * up to 120 times a second, on the same thread that drains video. Under load
     * the loop stalled behind AppKit, the socket stopped being read, and the
     * sender's send queue grew to megabytes: the receiver appeared frozen.
     *
     * Coalescing costs at most one pass of latency and keeps the cursor entirely
     * off the frame pipeline, which was the point. */
    atomic_store(&g_cursor_dirty, 1);
}

/* ------------------------------------------------------------- cursor sprite */

/* Even-odd scanline fill; the arrow is non-convex so a simple span fill will
 * not do. Coordinates are floats in sprite space. */
static void tb_fill_poly(uint32_t *px, int w, int h, int stride,
                         const float *xs, const float *ys, int n,
                         uint32_t colour) {
    float miny = ys[0], maxy = ys[0];
    for (int i = 1; i < n; ++i) { if (ys[i] < miny) miny = ys[i]; if (ys[i] > maxy) maxy = ys[i]; }
    int y0 = (int)miny; if (y0 < 0) y0 = 0;
    int y1 = (int)maxy + 1; if (y1 > h) y1 = h;

    for (int y = y0; y < y1; ++y) {
        float cy = (float)y + 0.5f;
        float xi[16];
        int   cnt = 0;
        for (int i = 0, j = n - 1; i < n && cnt < 16; j = i++) {
            if ((ys[i] > cy) != (ys[j] > cy)) {
                float t = (cy - ys[i]) / (ys[j] - ys[i]);
                xi[cnt++] = xs[i] + t * (xs[j] - xs[i]);
            }
        }
        for (int a = 0; a < cnt - 1; ++a)          /* insertion sort, tiny n */
            for (int b = a + 1; b < cnt; ++b)
                if (xi[b] < xi[a]) { float t = xi[a]; xi[a] = xi[b]; xi[b] = t; }
        for (int s = 0; s + 1 < cnt; s += 2) {
            int xa = (int)xi[s], xb = (int)xi[s + 1];
            if (xa < 0) xa = 0;
            if (xb > w) xb = w;
            uint32_t *row = px + (size_t)y * stride;
            for (int x = xa; x < xb; ++x) row[x] = colour;
        }
    }
}

/* The arrow, in units later multiplied by `scale`. */
static const float kArrowX[7] = { 0.f, 0.f,  4.5f, 7.5f, 10.5f, 7.5f, 12.f };
static const float kArrowY[7] = { 0.f, 17.f, 13.f, 20.f, 19.f,  12.f, 12.f };
#define TB_CUR_PAD 2   /* the black outline reaches this far from the shape */

/* Build the cursor into a small texture, once per scale. Drawn black-offset-then
 * white so it stays legible on any background — the same reason the SDL path
 * outlines it. Alpha is zero everywhere the arrow is not, so the render pass can
 * blend it over the video without touching the frame. */
/* Rasterise the arrow into a fresh BGRA buffer. Shared by the Metal texture and
 * the CALayer overlay so the two can never draw a different cursor. Caller
 * frees. */
static uint32_t *tb_cursor_raster(float scale, int *out_w, int *out_h) {
    const int w = (int)(12.f * scale) + 2 * TB_CUR_PAD + 2;
    const int h = (int)(20.f * scale) + 2 * TB_CUR_PAD + 2;
    uint32_t *px = calloc((size_t)w * h, 4);
    if (!px) return NULL;

    float bx[7], by[7];
    const int off[8][2] = {{-2,0},{2,0},{0,-2},{0,2},{-2,-2},{2,-2},{-2,2},{2,2}};
    for (int k = 0; k < 8; ++k) {
        for (int i = 0; i < 7; ++i) {
            bx[i] = TB_CUR_PAD + kArrowX[i] * scale + (float)off[k][0];
            by[i] = TB_CUR_PAD + kArrowY[i] * scale + (float)off[k][1];
        }
        tb_fill_poly(px, w, h, w, bx, by, 7, 0xFF000000u);
    }
    for (int i = 0; i < 7; ++i) {
        bx[i] = TB_CUR_PAD + kArrowX[i] * scale;
        by[i] = TB_CUR_PAD + kArrowY[i] * scale;
    }
    tb_fill_poly(px, w, h, w, bx, by, 7, 0xFFFFFFFFu);

    *out_w = w;
    *out_h = h;
    return px;
}

static void tb_cursor_build(float scale) {
    if (g.curTex && g.cur_tex_scale == scale) return;

    int w = 0, h = 0;
    uint32_t *px = tb_cursor_raster(scale, &w, &h);
    if (!px) return;

    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                          width:(NSUInteger)w
                                                         height:(NSUInteger)h
                                                      mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeManaged;
    g.curTex = [g.dev newTextureWithDescriptor:td];
    if (g.curTex) {
        [g.curTex replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)w, (NSUInteger)h)
                    mipmapLevel:0
                      withBytes:px
                    bytesPerRow:(NSUInteger)w * 4];
        g.cur_tex_w = w;
        g.cur_tex_h = h;
        g.cur_tex_scale = scale;
    }
    free(px);
}

/* ------------------------------------------------- cursor as a separate plane
 *
 * WHY THIS EXISTS
 *
 * The cursor already travels on its own channel — a tiny 0x32 packet, not baked
 * into the video — but until now it had no independent path to the panel: the
 * sprite was composited into the same Metal drawable as the frame, so it only
 * appeared when a frame did. That made cursor latency inherit the whole present
 * cadence, including displaySyncEnabled. Moving the mouse over a still screen
 * moved nothing until something else caused a frame.
 *
 * A sibling CALayer above the CAMetalLayer is composited by WindowServer, not by
 * us. Setting its position is a compositor-level move that reaches the screen on
 * the next refresh regardless of whether a video frame ever arrives — which is
 * exactly how the local cursor on any Mac behaves, and why it feels instant.
 *
 * THE ANIMATION TRAP
 *
 * Every position change MUST be inside a transaction with actions disabled.
 * Implicit animation is the default for CALayer geometry, so without this each
 * move would spawn an animation, sixty or more a second would overlap, and the
 * cursor would both lag and smear. This project has already lost a day to the
 * NSWindow flavour of the same mistake (see TBKeepWarm) — that one released an
 * animation twice and segfaulted. Disabling actions twice over, in the layer's
 * own action dictionary AND per update, is deliberate belt-and-braces.
 */

/* The cursor's placement loop. Wakes often enough to keep up with a 120 Hz
 * sender and does nothing at all when no position has arrived. */
static void *tb_cursor_thread_main(void *unused) {
    (void)unused;
    pthread_setname_np("tb.cursor");
    while (atomic_load(&g_cursor_thread_run)) {
        if (atomic_exchange(&g_cursor_dirty, 0)) {
            @autoreleasepool { tb_cursor_layer_place(); }
        }
        /* ~240 Hz: half the sender's sample interval, so a position never waits
         * for a whole one. Idle cost is a sleep and an atomic load. */
        usleep(4000);
    }
    return NULL;
}

/* Called from the receiver's main loop. Structural work ONLY — the loop can block
 * for up to 100ms on GPU backpressure, and that is precisely why placement no
 * longer happens here. */
void tb_metal_plane_flush_cursor(void) {
    tb_cursor_layer_ensure();

    if (!atomic_load(&g_cursor_thread_run) && g.cursorLayer) {
        atomic_store(&g_cursor_thread_run, 1);
        if (pthread_create(&g_cursor_thread, NULL, tb_cursor_thread_main, NULL) != 0) {
            atomic_store(&g_cursor_thread_run, 0);
            fprintf(stderr, "[cursor] no thread; placing on the main loop instead\n");
        } else {
            pthread_detach(g_cursor_thread);
            fprintf(stderr, "[cursor] placement moved to its own thread\n");
        }
    }

    /* Fallback: without a thread, keep the old behaviour rather than freezing. */
    if (!atomic_load(&g_cursor_thread_run) && atomic_exchange(&g_cursor_dirty, 0)) {
        tb_cursor_layer_place();
    }
}

void tb_metal_plane_note_cursor_arrival(double recv_ms) {
    g.cur_arrival_ms = recv_ms;
}

void tb_metal_plane_set_cursor_image(const uint8_t *rgba, int w, int h,
                                     int hot_x, int hot_y) {
    if (!rgba || w <= 0 || h <= 0 || w > 512 || h > 512) return;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    /* The sender writes premultipliedLast (RGBA); saying so here rather than
     * swizzling keeps the two ends describing the same bytes. */
    CGContextRef ctx = CGBitmapContextCreate((void *)rgba, (size_t)w, (size_t)h, 8,
                                             (size_t)w * 4, cs,
                                             kCGImageAlphaPremultipliedLast |
                                             kCGBitmapByteOrder32Big);
    CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    if (img) {
        if (g.cursorImage) CGImageRelease(g.cursorImage);
        g.cursorImage = img;            /* retained; released on replace/detach */
        g.cur_img_w = w;
        g.cur_img_h = h;
        g.cur_img_hot_x = hot_x;
        g.cur_img_hot_y = hot_y;

        if (g.cursorLayer) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            g.cursorLayer.contents = (__bridge id)img;
            [CATransaction commit];
        }
        /* Force the next placement to recompute size from the new bitmap. */
        g.cur_layer_w = w;
        g.cur_layer_h = h;
        g.cur_layer_scale = -1.f;
        tb_cursor_layer_place();
    }
    if (ctx) CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
}

static void tb_cursor_layer_sync_image(float scale) {
    /* A real cursor bitmap from the sender always wins over the drawn arrow. */
    if (g.cursorImage) return;
    if (!g.cursorLayer || g.cur_layer_scale == scale) return;

    int w = 0, h = 0;
    uint32_t *px = tb_cursor_raster(scale, &w, &h);
    if (!px) return;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, (size_t)w, (size_t)h, 8, (size_t)w * 4, cs,
                                             kCGImageAlphaPremultipliedFirst |
                                             kCGBitmapByteOrder32Little);
    CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    if (img) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        g.cursorLayer.contents = (__bridge id)img;
        [CATransaction commit];
        CGImageRelease(img);
        g.cur_layer_w = w;
        g.cur_layer_h = h;
        g.cur_layer_scale = scale;
    }
    if (ctx) CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    free(px);
}

/* Place the sprite from the last known cursor state. Cheap enough to call on
 * every packet: it is two float assignments and a compositor notification, with
 * no drawing and no frame involved. */

/* The layer our cursor must be parented to. Computed the same way attach() does,
 * so place() can notice when they have diverged. */
static CALayer *tb_cursor_host(void) {
    if (!g.layer) return nil;
    return g.layer.superlayer ?: g.layer;
}

/* Say why a placement did nothing — once per change of reason, so a permanent
 * stall names itself instead of just going quiet.
 *
 * Every early return here used to be silent. When the layer lost its parent the
 * cursor froze for good and the only clue was the absence of `cursor gap` in the
 * health line, which is indistinguishable from the pointer being on the other
 * Mac. Two wrong diagnoses came out of that ambiguity. */
static void tb_cursor_note_skip(const char *why) {
    static const char *last = NULL;
    if (last == why) return;
    last = why;
    if (why) fprintf(stderr, "[cursor] placement skipped: %s\n", why);
    else     fprintf(stderr, "[cursor] placement resumed\n");
}

/* Main thread only: make sure the layer exists and hangs off the current metal
 * layer. Cheap — a pointer comparison in the common case. */
static void tb_cursor_layer_ensure(void) {
    CALayer *host = tb_cursor_host();
    if (!host) return;
    if (!g.cursorLayer || g.cursorLayer.superlayer != host) {
        tb_cursor_layer_attach();
        if (!g.cursorLayer) return;
        if (g.cursorLayer.superlayer != host) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [g.cursorLayer removeFromSuperlayer];
            [host addSublayer:g.cursorLayer];
            [CATransaction commit];
            fprintf(stderr, "[cursor] plane re-parented to the current metal layer\n");
        }
    }
    /* The sprite is built here too: it allocates and makes a CGImage, which has
     * no business happening on the hot path. */
    if (g.cursorLayer && g.frame_w > 0) {
        tb_cursor_layer_sync_image(((g.frame_w >= 5000) ? 58.f : 44.f) / 24.f);
    }
}

static void tb_cursor_layer_place(void) {
    CALayer *host = g.cursorLayer.superlayer;
    if (!host) { tb_cursor_note_skip("no metal layer"); return; }

    CGRect b = host.bounds;
    if (b.size.width <= 0 || b.size.height <= 0) b = g.layer.bounds;
    if (b.size.width <= 0 || b.size.height <= 0) { tb_cursor_note_skip("host has no bounds"); return; }

    pthread_mutex_lock(&g_cursor_state_lock);
    const int cx = g_cur_pending.x, cy = g_cur_pending.y;
    const int csw = g_cur_pending.sw, csh = g_cur_pending.sh;
    const int cvis = g_cur_pending.visible;
    const double carr = g_cur_pending.arrival_ms;
    pthread_mutex_unlock(&g_cursor_state_lock);

    if (!cvis || csw <= 0 || csh <= 0) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        g.cursorLayer.hidden = YES;
        [CATransaction commit];
        return;   /* pointer is on the sending Mac; not a fault, not a commit */
    }

    /* The sprite is prepared by tb_cursor_layer_ensure on the main thread; here we
     * only place what already exists. */
    if (g.cur_layer_w <= 0 || g.frame_w <= 0 || g.frame_h <= 0) {
        tb_cursor_note_skip("no sprite or frame size yet");
        return;
    }

    /* Cursor arrives in the sender's source-frame space; express everything as a
     * fraction of the frame, then multiply by the layer's size in points. That
     * keeps it correct whatever the window size is. */
    /* The drawn arrow is offset by its padding; a real bitmap is offset by its
     * own hot spot, which is the pixel the user is actually pointing with. */
    const double offx = g.cursorImage ? (double)g.cur_img_hot_x : (double)TB_CUR_PAD;
    const double offy = g.cursorImage ? (double)g.cur_img_hot_y : (double)TB_CUR_PAD;
    const double fx = ((double)cx / (double)csw)
                    - (offx / (double)g.frame_w);
    const double fy = ((double)cy / (double)csh)
                    - (offy / (double)g.frame_h);
    const double wPts = (double)g.cur_layer_w / (double)g.frame_w * b.size.width;
    const double hPts = (double)g.cur_layer_h / (double)g.frame_h * b.size.height;
    const double xPts = fx * b.size.width;
    const double yTop = fy * b.size.height;

    /* AppKit layers are bottom-left origin unless the view says otherwise, and
     * SDL's view has been both over the years — so ask rather than assume. */
    const double yPts = g.cursor_layer_flipped ? yTop
                                               : (b.size.height - yTop - hPts);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    g.cursorLayer.hidden = NO;
    g.cursorLayer.frame = CGRectMake(xPts, yPts, wPts, hPts);
    [CATransaction commit];
    /* Cadence, not latency — the sender's 120 Hz clock is on another machine.
     * ~8ms between commits means positions flow; ~17ms means something is
     * gating them to the display refresh. */
    tb_cursor_note_skip(NULL);   /* placements are flowing again */
    tb_health_note_cursor_commit();
    if (carr > 0.0) {
        tb_health_note_cursor_latency(tb_mp_now_ms() - carr);
        pthread_mutex_lock(&g_cursor_state_lock);
        if (g_cur_pending.arrival_ms == carr) g_cur_pending.arrival_ms = 0.0;
        pthread_mutex_unlock(&g_cursor_state_lock);
    }
}

static void tb_cursor_layer_attach(void) {
    if (g.cursorLayer || !g.layer) return;

    /* Escape hatch. If the plane ever misbehaves — wrong place, wrong size, a
     * compositor quirk on some macOS version — TB_CURSOR_PLANE=0 falls straight
     * back to compositing the cursor into the frame, which is what shipped
     * before and is known to be correct if slower.
     *
     * Decided once. place() now calls attach() on every flush to self-heal a
     * mis-parented layer, so re-reading the environment here would re-log this
     * line up to 120 times a second. */
    static int disabled = -1;
    if (disabled < 0) {
        const char *env = getenv("TB_CURSOR_PLANE");
        disabled = (env && env[0] == '0') ? 1 : 0;
        if (disabled) {
            fprintf(stderr, "[metal] cursor plane disabled by TB_CURSOR_PLANE=0; "
                            "cursor will ride the video frames again\n");
        }
    }
    if (disabled) return;
    CALayer *host = g.layer.superlayer ?: g.layer;

    CALayer *cur = [CALayer layer];
    cur.contentsScale = g.layer.contentsScale > 0 ? g.layer.contentsScale : 2.0;
    cur.zPosition = 1000;              /* above the video, always */
    cur.hidden = YES;
    /* Belt: kill implicit animation at the source as well as per update. */
    cur.actions = @{ @"position": [NSNull null], @"bounds": [NSNull null],
                     @"frame":    [NSNull null], @"contents": [NSNull null],
                     @"hidden":   [NSNull null] };

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [host addSublayer:cur];
    /* Re-apply a bitmap we already hold: the plane is torn down and rebuilt on
     * resolution changes, and the sender only resends on a SHAPE change, so
     * without this the pointer would revert to the drawn arrow until the user
     * happened to move over something with a different cursor. */
    if (g.cursorImage) cur.contents = (__bridge id)g.cursorImage;
    [CATransaction commit];

    g.cursorLayer = cur;
    /* SDL_MetalView is an opaque void*; it is the NSView underneath. Asking it
     * rather than assuming, because a flipped view would put the cursor exactly
     * as far wrong as it is from the top of the screen. */
    NSView *nsView = (__bridge NSView *)g.view;
    g.cursor_layer_flipped = [nsView isKindOfClass:[NSView class]] && nsView.isFlipped ? 1 : 0;
    fprintf(stderr, "[metal] cursor plane attached (flipped=%d) — cursor no longer waits for a frame\n",
            g.cursor_layer_flipped);
}

static void tb_cursor_layer_detach(void) {
    /* Stop the placement thread before the layer goes, so it cannot touch a
     * released layer. Detached, so a short wait is enough for it to notice. */
    if (atomic_exchange(&g_cursor_thread_run, 0)) usleep(12000);
    if (!g.cursorLayer) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [g.cursorLayer removeFromSuperlayer];
    [CATransaction commit];
    g.cursorLayer = nil;
    g.cur_layer_scale = 0.f;
    g.cur_layer_w = g.cur_layer_h = 0;
    if (g.cursorImage) { CGImageRelease(g.cursorImage); g.cursorImage = NULL; }
}

/* ------------------------------------------------------------------- shaders */

static NSString *tb_shader_source(void) {
    return
    @"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "\n"
    "struct VOut { float4 pos [[position]]; float2 uv; };\n"
    "\n"
    "vertex VOut tb_vs(uint vid [[vertex_id]]) {\n"
    "  float2 p = float2((vid << 1) & 2, vid & 2);\n"
    "  VOut o; o.pos = float4(p * 2.0 - 1.0, 0, 1); o.uv = float2(p.x, 1.0 - p.y);\n"
    "  return o;\n"
    "}\n"
    /* Dither on presentation.
     *
     * macOS adds sub-LSB noise on the way to the panel, which is why 8-bit
     * gradients look smooth everywhere else in the OS. A CAMetalLayer writing
     * straight to a 10-bit drawable never picks that up, so quantisation the
     * rest of the system hides is plainly visible in our window — measured with
     * a synthetic ramp: an 8-bit half banded here while the same data was
     * smooth in any ordinary window.
     *
     * An 8x8 ordered matrix, not random noise. White noise of the same
     * amplitude reads as canvas texture across the whole image, because its
     * energy sits at all spatial frequencies including the low ones the eye is
     * most sensitive to. An ordered pattern puts its energy where the eye does
     * not resolve it, which is why GPUs dither this way. */
    "constant float bayer[64] = {\n"
    "  0,32,8,40,2,34,10,42, 48,16,56,24,50,18,58,26,\n"
    " 12,44,4,36,14,46,6,38, 60,28,52,20,62,30,54,22,\n"
    "  3,35,11,43,1,33,9,41, 51,19,59,27,49,17,57,25,\n"
    " 15,47,7,39,13,45,5,37, 63,31,55,23,61,29,53,21 };\n"
    "fragment float4 tb_fs(VOut in [[stage_in]],\n"
    "                      texture2d<float> tex [[texture(0)]],\n"
    "                      constant float &amp [[buffer(0)]]) {\n"
    "  constexpr sampler s(filter::nearest, address::clamp_to_edge);\n"
    "  float4 c = tex.sample(s, in.uv);\n"
    "  uint2 q = uint2(in.pos.xy);\n"
    "  float t = (bayer[(q.y & 7) * 8 + (q.x & 7)] + 0.5) / 64.0 - 0.5;\n"
    "  c.rgb += t * amp;\n"
    "  return c;\n"
    "}\n"
    "\n"
    /* Cursor overlay: a blended quad, positioned in normalised device
     * coordinates by the host so the sprite needs no scaling here. */
    "vertex VOut tb_cursor_vs(uint vid [[vertex_id]],\n"
    "                         constant float4 &r [[buffer(0)]]) {\n"
    "  float2 c = float2((vid == 1 || vid == 2 || vid == 4) ? r.z : r.x,\n"
    "                    (vid == 2 || vid == 4 || vid == 5) ? r.w : r.y);\n"
    "  float2 uv = float2((c.x - r.x) / (r.z - r.x), (c.y - r.y) / (r.w - r.y));\n"
    "  VOut o; o.pos = float4(c, 0, 1); o.uv = float2(uv.x, 1.0 - uv.y);\n"
    "  return o;\n"
    "}\n"
    "fragment float4 tb_cursor_fs(VOut in [[stage_in]],\n"
    "                             texture2d<float> tex [[texture(0)]]) {\n"
    "  constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
    "  return tex.sample(s, in.uv);\n"
    "}\n"
    "\n"
    /* ---- TBD1 decode ----
     *
     * One threadgroup per 8x8 tile, one thread per pixel. Tile size, and this
     * mapping, are both measured choices:
     *
     * One thread per TILE — the obvious mapping, since DPCM is serial along the
     * prediction direction — measured 100 ms/frame on the target GPU against
     * 7.5 ms for this one. The reason is memory, not arithmetic: with a thread
     * per tile, the 64 lanes of a wave each read a different scattered byte and
     * each pulls its own cache line to extract a few bits from it. With a thread
     * per pixel, adjacent lanes read adjacent bit ranges, so a whole
     * tile-channel's residuals fall inside one or two lines.
     *
     * The serial dependency is not a problem because DPCM along a row is a
     * prefix sum, and a prefix sum is parallel. Each thread reads only its own
     * residual, then two short prefixes resolve out of threadgroup memory: down
     * column 0 for the row starts, and along the row for everything else.
     *
     * The tile's own payload offset is derived here rather than transmitted. The
     * blob carries one base offset per group of 64 tiles, and this threadgroup's
     * 64 threads each price one earlier tile in their group and reduce. Shipping
     * an offset per tile would cost 921 KB a frame and wreck the ratio on
     * exactly the flat content where it is largest.
     *
     * There are no bounds checks: tb_dpcm_parse has already re-derived the whole
     * offset table from the width plane and rejected the blob unless it agrees,
     * so every offset computed here is inside the payload by construction. */
    "struct DpcmParams {\n"
    "  uint width, height, tilesX, tilesY, tileCount, outStridePx;\n"
    "  uint widthOff, seedOff, payOff;\n"
    "  uint bits, alpha, rowOffset, colOffset;\n"
    "};\n"
    "static inline uint tb_width_get(device const uchar *plane, uint idx) {\n"
    "  uchar b = plane[idx >> 1];\n"
    "  return (idx & 1u) ? uint(b >> 4) : uint(b & 0xF);\n"
    "}\n"
    /* n reaches 10 at 10-bit depth and the offset within a byte reaches 7, so a
     * value can span three bytes. */
    "static inline uint tb_bits_at(device const uchar *buf, uint p, uint n) {\n"
    "  if (n == 0u) return 0u;\n"
    "  uint byte = p >> 3, sh = p & 7u;\n"
    "  uint x = uint(buf[byte]);\n"
    "  if (sh + n >  8u) x |= uint(buf[byte + 1]) << 8;\n"
    "  if (sh + n > 16u) x |= uint(buf[byte + 2]) << 16;\n"
    "  return (x >> sh) & ((1u << n) - 1u);\n"
    "}\n"
    "static inline int tb_unzig(uint z) { return int((z >> 1) ^ (~(z & 1u) + 1u)); }\n"
    "\n"
    "kernel void tb_dpcm_decode(device const uchar *blob  [[buffer(0)]],\n"
    "                           device const uint  *gtab  [[buffer(1)]],\n"
    "                           device       uint  *out   [[buffer(2)]],\n"
    "                           constant DpcmParams &P    [[buffer(3)]],\n"
    "                           uint tile [[threadgroup_position_in_grid]],\n"
    "                           uint lane [[thread_position_in_threadgroup]]) {\n"
    "  device const uchar *wp = blob + P.widthOff;\n"
    "  device const uint  *seeds = (device const uint *)(blob + P.seedOff);\n"
    "  device const uchar *pay = blob + P.payOff;\n"
    "  const uint grp = tile / 64u, idx = tile % 64u;\n"
    "\n"
    "  uint jcost = 0u;\n"
    "  {\n"
    "    const uint jt = grp * 64u + lane;\n"
    "    if (lane < idx && jt < P.tileCount) {\n"
    "      const uint jx = jt % P.tilesX, jy = jt / P.tilesX;\n"
    "      const uint jw = min(8u, P.width  - jx * 8u);\n"
    "      const uint jh = min(8u, P.height - jy * 8u);\n"
    "      const uint jn = tb_width_get(wp, jt * 3u + 0u)\n"
    "                    + tb_width_get(wp, jt * 3u + 1u)\n"
    "                    + tb_width_get(wp, jt * 3u + 2u);\n"
    "      jcost = jn * (jw * jh - 1u);\n"
    "    }\n"
    "  }\n"
    "  threadgroup uint red[64];\n"
    "  red[lane] = jcost;\n"
    "  threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "  for (uint off = 32u; off > 0u; off >>= 1) {\n"
    "    if (lane < off) red[lane] += red[lane + off];\n"
    "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "  }\n"
    "\n"
    "  const uint x = lane & 7u, y = lane >> 3;\n"
    "  const uint txi = tile % P.tilesX, tyi = tile / P.tilesX;\n"
    "  const uint tw = min(8u, P.width  - txi * 8u);\n"
    "  const uint th = min(8u, P.height - tyi * 8u);\n"
    "  const uint coded = tw * th - 1u;\n"
    "  const bool live = (x < tw && y < th);\n"
    "\n"
    "  const uint n0 = tb_width_get(wp, tile * 3u + 0u);\n"
    "  const uint n1 = tb_width_get(wp, tile * 3u + 1u);\n"
    "  const uint n2 = tb_width_get(wp, tile * 3u + 2u);\n"
    /* The group base the wire carries is already byte-aligned; within a group
     * residuals are packed with no padding, so the scan is an exact bit sum. */
    "  const uint b0 = gtab[grp] + red[0];\n"
    "  const uint b1 = b0 + n0 * coded;\n"
    "  const uint b2 = b1 + n1 * coded;\n"
    "\n"
    "  int3 d = int3(0);\n"
    "  if (live && !(x == 0u && y == 0u)) {\n"
    "    const uint k = y * tw + x - 1u;\n"
    "    d.x = tb_unzig(tb_bits_at(pay, b0 + k * n0, n0));\n"
    "    d.y = tb_unzig(tb_bits_at(pay, b1 + k * n1, n1));\n"
    "    d.z = tb_unzig(tb_bits_at(pay, b2 + k * n2, n2));\n"
    "  }\n"
    "\n"
    "  threadgroup int3 rowd[64];\n"
    "  threadgroup int3 cold[8];\n"
    "  rowd[lane] = (x == 0u) ? int3(0) : d;\n"
    "  if (x == 0u) cold[y] = (y == 0u) ? int3(0) : d;\n"
    "  threadgroup_barrier(mem_flags::mem_threadgroup);\n"
    "  if (!live) return;\n"
    "\n"
    "  int3 acc = int3(0);\n"
    "  for (uint j = 1u; j <= y; ++j) acc += cold[j];\n"
    "  for (uint i = 1u; i <= x; ++i) acc += rowd[y * 8u + i];\n"
    "\n"
    /* One LE uint32 per tile holds the seed pixel at either depth. */
    "  const uint mask = (1u << P.bits) - 1u;\n"
    "  const uint sraw = seeds[tile];\n"
    "  const int3 seed = int3(int((sraw >> (0u * P.bits)) & mask),\n"
    "                         int((sraw >> (1u * P.bits)) & mask),\n"
    "                         int((sraw >> (2u * P.bits)) & mask));\n"
    "  const uint3 v = uint3(seed + acc) & mask;\n"
    "  out[(P.rowOffset + tyi * 8u + y) * P.outStridePx + (P.colOffset + txi * 8u + x)] =\n"
    "      P.alpha | v.x | (v.y << P.bits) | (v.z << (2u * P.bits));\n"
    "}\n";
}

/* ---------------------------------------------------------------------- setup */

int tb_metal_plane_init(SDL_Window *win) {
    if (g.ready) return 0;
    if (!win) return -1;
    /* `g` is zero-initialised, so without this the first plane would come up
     * with vsync off — the opposite of the intended default. */
    if (!g.vsync_initialised) { g.vsync_initialised = 1; g.vsync = 1; }

    g.dev = MTLCreateSystemDefaultDevice();
    if (!g.dev) { fprintf(stderr, "[metal] no Metal device\n"); return -1; }

    g.view = SDL_Metal_CreateView(win);
    if (!g.view) {
        fprintf(stderr, "[metal] SDL_Metal_CreateView: %s\n", SDL_GetError());
        g.dev = nil;
        return -1;
    }

    g.layer = (__bridge CAMetalLayer *)SDL_Metal_GetLayer(g.view);
    if (!g.layer) { fprintf(stderr, "[metal] no CAMetalLayer\n"); return -1; }

    g.layer.device = g.dev;
    g.layer.pixelFormat = MTLPixelFormatBGR10A2Unorm;
    g.layer.framebufferOnly = NO;
    g.layer.opaque = YES;
    g.layer.maximumDrawableCount = TB_METAL_RING;
    g.layer.displaySyncEnabled = g.vsync ? YES : NO;
    tb_cursor_layer_attach();
    tb_cursor_layer_place();
    /* Tag the layer with the space the pixels are actually in, which is what
     * the sender captures: Display P3.
     *
     * This used to be the *panel's* profile, chosen to avoid a per-frame
     * conversion. That was wrong: it tells the compositor the values are
     * already in display space, so the conversion P3 data needs is skipped.
     * On a panel using its own calibrated profile that shows up as banding in
     * dark gradients and a colour shift — and setting the display profile to
     * P3 by hand "fixed" it only by making the mislabel accidentally true.
     * Labelling correctly lets the compositor convert, in its own higher
     * precision, on the GPU. */
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
    if (cs) { g.layer.colorspace = cs; CGColorSpaceRelease(cs); }

    /* What the panel is actually capable of receiving. A 10-bit drawable still
     * gets quantised at scanout if the display is running an 8-bit mode, and
     * that looks exactly like a pipeline that never carried 10 bits. */
    {
        NSScreen *scr = [NSScreen mainScreen];
        CGColorSpaceRef dcs = CGDisplayCopyColorSpace(CGMainDisplayID());
        CFStringRef name = dcs ? CGColorSpaceCopyName(dcs) : NULL;
        fprintf(stderr,
                /* NSBitsPerSampleFromDepth is a legacy WINDOW depth: it reports
                 * 8 on essentially every Mac, including 10-bit panels, and
                 * reading it as the panel's capability sent us down a wrong
                 * path. Reported as `windowDepth` so nobody mistakes it for the
                 * panel again. What actually establishes depth is the drawable
                 * format, the colorspace, and the sender's own probe. */
                "[metal] drawable=BGR10A2Unorm  windowDepth(legacy)=%ld  P3=%d  maxEDR=%.2f  colorspace=%s\n",
                (long)NSBitsPerSampleFromDepth(scr.depth),
                (int)[scr canRepresentDisplayGamut:NSDisplayGamutP3],
                (double)scr.maximumExtendedDynamicRangeColorComponentValue,
                name ? [(__bridge NSString *)name UTF8String] : "?");
        if (name) CFRelease(name);
        if (dcs) CGColorSpaceRelease(dcs);
    }

    NSError *err = nil;
    id<MTLLibrary> lib = [g.dev newLibraryWithSource:tb_shader_source() options:nil error:&err];
    if (!lib) {
        fprintf(stderr, "[metal] shader compile failed: %s\n",
                err.localizedDescription.UTF8String ?: "?");
        return -1;
    }

    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction   = [lib newFunctionWithName:@"tb_vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"tb_fs"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGR10A2Unorm;
    g.pipe = [g.dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!g.pipe) {
        fprintf(stderr, "[metal] pipeline failed: %s\n",
                err.localizedDescription.UTF8String ?: "?");
        return -1;
    }

    MTLRenderPipelineDescriptor *cd = [MTLRenderPipelineDescriptor new];
    cd.vertexFunction   = [lib newFunctionWithName:@"tb_cursor_vs"];
    cd.fragmentFunction = [lib newFunctionWithName:@"tb_cursor_fs"];
    cd.colorAttachments[0].pixelFormat = MTLPixelFormatBGR10A2Unorm;
    cd.colorAttachments[0].blendingEnabled = YES;
    cd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    cd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    cd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    cd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    g.cursorPipe = [g.dev newRenderPipelineStateWithDescriptor:cd error:&err];
    if (!g.cursorPipe)
        fprintf(stderr, "[metal] cursor pipeline failed: %s\n",
                err.localizedDescription.UTF8String ?: "?");

    /* The decode pipeline is optional: without it the plane still presents
     * uncompressed frames, and the receiver simply does not advertise
     * "supportsDPCM", so the sender keeps sending them. */
    g.dpcmPipe = [g.dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"tb_dpcm_decode"]
                                                     error:&err];
    if (!g.dpcmPipe)
        fprintf(stderr, "[metal] dpcm pipeline failed: %s\n",
                err.localizedDescription.UTF8String ?: "?");

    g.dither = 0.5f / 255.0f;   /* half an 8-bit step = ~2 levels at 10-bit */
    const char *denv = getenv("TB_DITHER");
    if (denv) {
        float scale = (float)atof(denv);
        if (scale >= 0.0f && scale <= 8.0f) g.dither = scale / 255.0f;
    }
    fprintf(stderr, "[metal] dither %.2f of an 8-bit step (%.1f levels at 10-bit)\n",
            g.dither * 255.0f, g.dither * 1023.0f);

    /* Buffer-backed textures need their rows aligned; the frame surface pads to
     * this rather than to the frame width. */
    g.row_align = [g.dev minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatBGR10A2Unorm];
    if (g.row_align == 0) g.row_align = 256;

    g.queue = [g.dev newCommandQueue];
    g.inflight = dispatch_semaphore_create(TB_UPLOAD_RING);
    {
        /* On by default since 2026-08-07. Shipped opt-in first because this is
         * the code that glitched at every slice count above one, and that
         * failure was content-dependent — it needed real use to trust, not a
         * clean minute. It got that: sustained video, scrolling and window
         * dragging with no artefact, `submit` down from 24% to 15% of wall
         * time, and every frame counter clean throughout.
         *
         * TB_ASYNC_PRESENT=0 falls back, because the failure mode here is
         * visible-only — no counter we have goes red when it happens — so the
         * escape hatch is for eyes, not for logs. */
        const char *ap = getenv("TB_ASYNC_PRESENT");
        g.async_present = !(ap && ap[0] == '0');
        if (g.async_present) {
            g.presentQ = dispatch_queue_create("tb.present", DISPATCH_QUEUE_SERIAL);
            if (!g.presentQ) g.async_present = 0;
        }
        fprintf(stderr, "[metal] present %s\n",
                g.async_present ? "async (TB_ASYNC_PRESENT=0 reverts)"
                                : "synchronous");
    }
    g.frames_free = dispatch_semaphore_create(TB_FRAME_RING);
    g.frame_widx = 0;
    g.frame_open = 0;
    g.ring_idx = 0;
    g.ready = 1;
    g.shown = 1;

    fprintf(stderr, "[metal] plane ready on %s (dpcm=%s)\n",
            [[g.dev name] UTF8String], g.dpcmPipe ? "yes" : "no");
    return 0;
}

void tb_metal_plane_shutdown(void) {
    if (!g.ready) return;
    g.shown = 0;
    g.frame_w = g.frame_h = 0;

    /* A frame caught mid-assembly holds a surface slot that only its LAST band
     * releases, and that band is never going to arrive. Hand it back before the
     * drain below, which would otherwise wait for it forever — teardown runs on
     * the thread servicing the window, so that wait froze the whole receiver the
     * moment a stream paused partway through a frame. Invisible at one band per
     * frame, where every frame is also its own last band. */
    if (g.frame_open && g.frames_free) {
        dispatch_semaphore_signal(g.frames_free);
        g.frame_open = 0;
    }

    /* Drain: reclaim every ring slot so no command buffer is still reading a
     * buffer (or the layer) when we release them. */
    if (g.inflight) {
        dispatch_semaphore_t sem = g.inflight;
        /* Bounded. Metal retains the resources a command buffer references, so
         * proceeding after a timeout releases our references and nothing more —
         * the drain is tidiness, not a safety requirement. A teardown that hangs
         * is far worse than one that gives up early. */
        int got = 0;
        for (int i = 0; i < TB_UPLOAD_RING; ++i) {
            if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
                                                           500 * NSEC_PER_MSEC)) != 0) break;
            ++got;
        }
        if (got < TB_UPLOAD_RING)
            fprintf(stderr, "[metal] teardown: %d upload slots never returned\n",
                    TB_UPLOAD_RING - got);
        /* Signal the FULL count, not just what was taken. libdispatch raises
         * SIGILL ("semaphore deallocated while in use") when a semaphore is
         * disposed below its creation value, and any slot still held by an
         * in-flight command buffer is never coming back to us. Over-signalling
         * is harmless; under-signalling crashes, which is how this crashed on
         * every teardown once before. */
        for (int i = 0; i < TB_UPLOAD_RING; ++i) dispatch_semaphore_signal(sem);
        g.inflight = nil;
    }
    if (g.frames_free) {
        dispatch_semaphore_t fs = g.frames_free;
        int got = 0;
        for (int i = 0; i < TB_FRAME_RING; ++i) {
            if (dispatch_semaphore_wait(fs, dispatch_time(DISPATCH_TIME_NOW,
                                                          500 * NSEC_PER_MSEC)) != 0) break;
            ++got;
        }
        if (got < TB_FRAME_RING)
            fprintf(stderr, "[metal] teardown: %d frame surfaces never returned\n",
                    TB_FRAME_RING - got);
        for (int i = 0; i < TB_FRAME_RING; ++i) dispatch_semaphore_signal(fs);
        g.frames_free = nil;
    }
    for (int i = 0; i < TB_UPLOAD_RING; ++i) { g.ring[i] = nil; g.ring_cap[i] = 0; }
    for (int i = 0; i < TB_FRAME_RING; ++i) { g.frame[i] = nil; g.frame_cap[i] = 0; }
    g.frame_open = 0; g.frame_widx = 0;
    tb_cursor_layer_detach();
    g.curTex = nil; g.cur_tex_scale = 0.f;
    g.pipe = nil; g.cursorPipe = nil; g.dpcmPipe = nil;
    g.queue = nil;
    g.dev = nil;
    g.layer = nil;
    if (g.view) { SDL_Metal_DestroyView(g.view); g.view = NULL; }
    g.ready = 0;
}

int tb_metal_plane_available(void) { return g.ready; }

int tb_metal_plane_supports_dpcm(void) {
    if (g.ready) return g.dpcmPipe != nil;

    /* The answer is needed at connect time, in the display profile, but the plane
     * is not created until the first frame arrives — it sits over SDL's window
     * and would hide the status UI. So probe standalone: make a device, compile
     * the library, build the pipeline. Nothing short of that is evidence, and
     * claiming the capability we cannot deliver would leave the sender
     * transmitting frames this receiver has no way to display.
     *
     * Cached because it costs a shader compile, and answered once per process. */
    static int cached = -1;
    if (cached >= 0) return cached;
    cached = 0;
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) return cached;
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:tb_shader_source() options:nil error:&err];
        if (!lib) {
            fprintf(stderr, "[metal] dpcm probe: shader failed: %s\n",
                    err.localizedDescription.UTF8String ?: "?");
            return cached;
        }
        id<MTLComputePipelineState> p =
            [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"tb_dpcm_decode"]
                                              error:&err];
        cached = p != nil;
        fprintf(stderr, "[metal] dpcm decode %s on %s\n",
                cached ? "available" : "unavailable", [[dev name] UTF8String]);
    }
    return cached;
}

void tb_metal_plane_set_hidden(int hidden) {
    if (!hidden) return;
    /* Fully remove the view: hiding the layer is not enough to reveal the
     * OpenGL content underneath. Only fires on an actual transition. */
    if (g.ready && g.shown) {
        g.shown = 0;
        tb_metal_plane_shutdown();
        fprintf(stderr, "[metal] plane released; SDL owns the window\n");
    }
}

/* ---------------------------------------------------------------- geometry */

/* Drive the layer at the frame's own resolution and let Core Animation scale it
 * to the window. On this 5K panel fullscreen they match, so scaling is free;
 * when they don't, the compositor handles it. */
static size_t tb_row_bytes(int w) {
    const size_t tight = (size_t)w * 4;
    return ((tight + g.row_align - 1) / g.row_align) * g.row_align;
}

static void tb_geometry_set(int w, int h) {
    if (g.frame_w == w && g.frame_h == h) return;
    g.frame_w = w; g.frame_h = h;
    g.frame_bpr = tb_row_bytes(w);
    g.layer.drawableSize = CGSizeMake(w, h);
    fprintf(stderr, "[metal] drawable %dx%d\n", w, h);
}

/* Take an upload slot. The caller must signal `inflight` if it does not go on to
 * submit a command buffer that signals it on completion. */
static id<MTLBuffer> tb_upload_take(size_t bytes) {
    /* Bounded for the same reason the frame-surface wait is: this runs on the
     * thread that services the window. Returning nil drops a band, which costs
     * one stale strip for a frame; blocking costs the whole session. */
    const dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC);
    if (dispatch_semaphore_wait(g.inflight, deadline) != 0) {
        static int warned = 0;
        if (!warned) {
            warned = 1;
            fprintf(stderr, "[metal] upload ring exhausted; dropping bands\n");
        }
        return nil;
    }
    int slot = g.ring_idx;
    g.ring_idx = (g.ring_idx + 1) % TB_UPLOAD_RING;
    if (g.ring_cap[slot] < bytes) {
        g.ring[slot] = [g.dev newBufferWithLength:bytes options:MTLResourceStorageModeShared];
        g.ring_cap[slot] = g.ring[slot] ? bytes : 0;
    }
    if (!g.ring[slot]) { dispatch_semaphore_signal(g.inflight); return nil; }
    return g.ring[slot];
}

/* Draw `src` into the next drawable, dither it, and blend the cursor on top.
 * Consumes the `inflight` count that the caller took.
 *
 * `src` is a texture VIEW over a buffer, not a copy — for an uncompressed frame
 * that is the staging buffer the CPU just filled, and for a TBD1 frame it is the
 * VRAM buffer the decode kernel just wrote. Either way the shader samples those
 * bytes in place. */
static int tb_present(id<MTLCommandBuffer> cb, id<MTLBuffer> src,
                      MTLStorageMode mode, int ten_bit) {
    /* Timed because this is where vsync actually costs us: with
     * displaySyncEnabled the call blocks until a drawable frees. The mean tells
     * us whether maximumDrawableCount is worth lowering, or whether doing so
     * would trade throughput for nothing. */
    const double draw_t0 = tb_mp_now_ms();
    id<CAMetalDrawable> drawable = [g.layer nextDrawable];
    tb_health_note_drawable_wait(tb_mp_now_ms() - draw_t0);
    if (!drawable) { dispatch_semaphore_signal(g.inflight); return -1; }

    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
             ten_bit ? MTLPixelFormatBGR10A2Unorm : MTLPixelFormatBGRA8Unorm
                                                          width:(NSUInteger)g.frame_w
                                                         height:(NSUInteger)g.frame_h
                                                      mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = mode;
    id<MTLTexture> srcTex = [src newTextureWithDescriptor:td offset:0
                                             bytesPerRow:g.frame_bpr];
    if (!srcTex) {
        /* PRESENT THE DRAWABLE EVEN THOUGH THERE IS NOTHING TO DRAW.
         *
         * A CAMetalLayer reclaims a drawable only when it is presented. Bailing
         * out here after nextDrawable had already handed us one burned it
         * permanently: three failures and the pool of three was gone, so the next
         * nextDrawable blocked forever and the receiver stopped advancing frames
         * while still looking healthy — the "bogging down" that toggling vsync
         * cleared, because reassigning displaySyncEnabled reconfigures the layer
         * and rebuilds the pool.
         *
         * Presenting an undrawn drawable shows one stale or blank frame, which is
         * a far better failure than a permanently wedged pipeline. */
        [cb presentDrawable:drawable];
        [cb commit];
        dispatch_semaphore_signal(g.inflight);
        fprintf(stderr, "[metal] no source texture; drawable returned to the pool\n");
        return -1;
    }

    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture     = drawable.texture;
    rp.colorAttachments[0].loadAction  = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    [enc setRenderPipelineState:g.pipe];
    [enc setFragmentTexture:srcTex atIndex:0];
    /* Dither 8-bit content only.
     *
     * At 8 bits the source sits on a coarser grid than the drawable, the steps
     * are real, and spreading them is measurably better — an 8-bit ramp banded
     * here while the same data was smooth in any ordinary window.
     *
     * At 10 bits there is nothing left to spread and this only adds noise. The
     * amplitude is half an 8-bit step, which is a FULL least-significant bit at
     * 10-bit (0.5/255 against 1/1023), so it was perturbing values the pipeline
     * carries exactly.
     *
     * It ran unconditionally because the panel was believed to be 8-bit, read
     * from NSBitsPerSampleFromDepth — a legacy window depth that reports 8 on
     * essentially every Mac and says nothing about deep colour. This panel is
     * 10-bit (8-bit native plus 2-bit FRC) and the whole chain carries 10:
     * an HDR virtual display gives a 16-bpc framebuffer, capture is packed
     * ARGB2101010, TBD2 is lossless, and the drawable is BGR10A2Unorm.
     * Confirmed by eye — gradients look better with this off at 10 bits, which
     * could only happen if the extra bits reach the panel. */
    const float dither = ten_bit ? 0.0f : g.dither;
    [enc setFragmentBytes:&dither length:sizeof(dither) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];

    /* Only composite the cursor into the frame when it has no plane of its own.
     * With the plane attached this would be a second, staler arrow drawn on top
     * of the live one. */
    if (g.cur_visible && g.cursorPipe && !g.cursorLayer) {
        const float scale = ((g.frame_w >= 5000) ? 58.f : 44.f) / 24.f;
        tb_cursor_build(scale);
        if (g.curTex) {
            /* Cursor coordinates arrive in the sender's source-frame space, which
             * is not necessarily the frame we are showing. */
            const float sx = (float)g.frame_w / (float)g.cur_sw;
            const float sy = (float)g.frame_h / (float)g.cur_sh;
            const float px = (float)g.cur_x * sx - (float)TB_CUR_PAD;
            const float py = (float)g.cur_y * sy - (float)TB_CUR_PAD;
            /* Pixels to normalised device coordinates; y is flipped. */
            const float x0 =  (px / (float)g.frame_w) * 2.f - 1.f;
            const float x1 = ((px + (float)g.cur_tex_w) / (float)g.frame_w) * 2.f - 1.f;
            const float y0 = 1.f -  (py / (float)g.frame_h) * 2.f;
            const float y1 = 1.f - ((py + (float)g.cur_tex_h) / (float)g.frame_h) * 2.f;
            const float rect[4] = { x0, y0, x1, y1 };
            [enc setRenderPipelineState:g.cursorPipe];
            [enc setVertexBytes:rect length:sizeof(rect) atIndex:0];
            [enc setFragmentTexture:g.curTex atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        }
    }
    [enc endEncoding];

    [cb presentDrawable:drawable];
    /* Capture the semaphore itself: reading g.inflight at completion time would
     * signal a *replacement* if the plane was torn down meanwhile. */
    dispatch_semaphore_t sem = g.inflight;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull done) {
        (void)done;
        dispatch_semaphore_signal(sem);
    }];
    [cb commit];
    return 0;
}

/* -------------------------------------------------------------- entry points */

int tb_metal_plane_render_packed(const uint8_t *px, int stride, int w, int h,
                                 int ten_bit) {
    if (!g.ready || !px || w <= 0 || h <= 0) return -1;

    @autoreleasepool {
        tb_geometry_set(w, h);

        const size_t tight = (size_t)w * 4;
        const size_t bytes = g.frame_bpr * (size_t)h;
        id<MTLBuffer> up = tb_upload_take(bytes);
        if (!up) return -1;

        uint8_t *dst = (uint8_t *)[up contents];
        if ((size_t)stride == g.frame_bpr) {
            memcpy(dst, px, bytes);
        } else {
            for (int y = 0; y < h; ++y)
                memcpy(dst + (size_t)y * g.frame_bpr, px + (size_t)y * stride, tight);
        }

        id<MTLCommandBuffer> cb = [g.queue commandBuffer];
        return tb_present(cb, up, MTLStorageModeShared, ten_bit);
    }
}

/* Size the VRAM destination currently being written. Returns 0 on success. */
static int tb_frame_ensure(void) {
    const int i = g.frame_widx;
    const size_t need = g.frame_bpr * (size_t)g.frame_h;
    if (g.frame_cap[i] < need) {
        g.frame[i] = [g.dev newBufferWithLength:need options:MTLResourceStorageModePrivate];
        g.frame_cap[i] = g.frame[i] ? need : 0;
    }
    return g.frame[i] ? 0 : -1;
}

/* Runs on presentQ once every band of the armed frame has completed. Mirrors
 * the tail of the synchronous path exactly — same ring-slot bookkeeping, same
 * failure handling — just off the render thread. */
static void tb_present_armed_frame(void) {
    /* Take the arming state under the lock and RELEASE IT before presenting.
     * Holding it across tb_present would put the render thread back to sleep on
     * a vblank, which is the entire thing this lock exists to avoid. */
    pthread_mutex_lock(&g_present_lock);
    const int armed = g.present_armed;
    const int idx   = g.present_idx;
    const int ten   = g.present_ten_bit;
    g.present_armed = 0;
    pthread_mutex_unlock(&g_present_lock);

    if (!armed) return;

    dispatch_semaphore_t frames = g.frames_free;

    @autoreleasepool {
        id<MTLCommandBuffer> pcb = [g.queue commandBuffer];
        [pcb addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull done) {
            (void)done;
            dispatch_semaphore_signal(frames);
        }];
        if (dispatch_semaphore_wait(g.inflight,
                                    dispatch_time(DISPATCH_TIME_NOW,
                                                  100 * NSEC_PER_MSEC)) != 0) {
            dispatch_semaphore_signal(frames);
            return;
        }
        /* Same rule as the synchronous path: tb_present returns without
         * committing when no drawable is free, so the handler never runs and
         * the ring slot would leak. Three of those and everything blocks. */
        if (tb_present(pcb, g.frame[idx], MTLStorageModePrivate, ten) != 0) {
            dispatch_semaphore_signal(frames);
        }
    }
}

int tb_metal_plane_render_dpcm(const uint8_t *blob, size_t len) {
    /* A whole frame is the single-band case: one band, at row 0, presented
     * immediately.
     *
     * The sliced WIRE format (packet 0x26) was removed on 2026-08-17 after
     * measurement -- N=1 2.98ms vs N=8 5.19ms recv->present, so slicing cost more
     * than it bought on this link. This function is NOT part of that removal: the
     * x0/y0/is_last arguments are how the decoder places any region, and every
     * frame still goes through it. Deleting it deletes the decoder. */
    return tb_metal_plane_render_dpcm_slice(blob, len, 0, 0, 0, 0, 1);
}

int tb_metal_plane_render_dpcm_slice(const uint8_t *blob, size_t len,
                                     int frame_w, int frame_h, int x0, int y0,
                                     int is_last) {
    const double tb_submit_t0 = tb_mp_now_ms();
    if (!g.ready || !g.dpcmPipe || !blob) { tb_health_note_submit(tb_mp_now_ms() - tb_submit_t0); return -1; }

    /* Validate before anything touches the GPU. This is also what lets the
     * shader run without a single bounds check: parse re-derives the entire
     * offset table from the width plane and rejects the blob unless its own
     * table agrees. */
    struct tb_dpcm_info in;
    if (tb_dpcm_parse(blob, len, &in) != 0) {
        fprintf(stderr, "[metal] rejected malformed TBD2 blob (%zu bytes)\n", len);
        { tb_health_note_submit(tb_mp_now_ms() - tb_submit_t0); return -1; }
    }

    /* A slice describes a band of a larger surface; a whole frame describes
     * itself. Passing 0 for the frame size means "this blob is the frame". */
    if (frame_w <= 0 || frame_h <= 0) { frame_w = in.width; frame_h = in.height; }
    if (in.width != frame_w) { tb_health_note_submit(tb_mp_now_ms() - tb_submit_t0); return -1; }                       /* bands are full width */
    if (y0 < 0 || (int64_t)y0 + in.height > frame_h) { tb_health_note_submit(tb_mp_now_ms() - tb_submit_t0); return -1; }
    if (y0 % TB_DPCM_TILE) { tb_health_note_submit(tb_mp_now_ms() - tb_submit_t0); return -1; }                         /* must land on a tile row */

    @autoreleasepool {
        tb_geometry_set(frame_w, frame_h);

        /* Claim a ring slot for this frame. Held until the frame presents, so
         * the next frame's bands cannot land in a surface still on screen. */
        if (!g.frame_open) {
            /* A frame may only begin at its first band. Otherwise a frame whose
             * start was dropped would decode its remaining bands over whatever
             * the slot last held and present a mixture — the failure this ring
             * exists to prevent. */
            if (y0 != 0) { tb_health_note_submit(tb_mp_now_ms() - tb_submit_t0); return -1; }
            /* Bounded, never DISPATCH_TIME_FOREVER: this runs on the thread that
             * also services the window, so an unbounded wait turns a GPU backlog
             * into an unresponsive app. Dropping a frame costs one stale 16.7 ms
             * on a fixed-refresh panel; blocking costs the whole session. */
            const dispatch_time_t deadline =
                dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC);
            if (dispatch_semaphore_wait(g.frames_free, deadline) != 0) {
                static int warned = 0;
                if (!warned) {
                    warned = 1;
                    fprintf(stderr, "[metal] all %d frame surfaces busy; dropping frames\n",
                            TB_FRAME_RING);
                }
                { tb_health_note_submit(tb_mp_now_ms() - tb_submit_t0); return -1; }
            }
            g.frame_open = 1;
        }
        if (tb_frame_ensure() != 0) {
            dispatch_semaphore_signal(g.frames_free);
            g.frame_open = 0;
            { tb_health_note_submit(tb_mp_now_ms() - tb_submit_t0); return -1; }
        }
        id<MTLBuffer> dst = g.frame[g.frame_widx];

        id<MTLBuffer> up = tb_upload_take(len);
        if (!up) { tb_health_note_submit(tb_mp_now_ms() - tb_submit_t0); return -1; }
        double cp0 = tb_mp_now_ms();
        memcpy([up contents], blob, len);
        tb_health_note_upload_copy(tb_mp_now_ms() - cp0);

        /* The blob is bound whole and the planes reached by offset, because
         * Metal wants buffer offsets 4-byte aligned and the seed and payload
         * planes can start anywhere. The group table is the one exception: it
         * always begins at TB_DPCM_HEADER, which is aligned, so it can be bound
         * as uint32 directly. */
        struct tb_dpcm_gpu_params P = {
            (uint32_t)in.width, (uint32_t)in.height,
            (uint32_t)in.tiles_x, (uint32_t)in.tiles_y,
            in.tile_count, (uint32_t)(g.frame_bpr / 4),
            (uint32_t)in.width_plane_off, (uint32_t)in.seed_plane_off,
            (uint32_t)in.payload_off,
            in.ten_bit ? 10u : 8u,
            in.ten_bit ? (3u << 30) : (0xFFu << 24),
            (uint32_t)y0, (uint32_t)x0
        };

        id<MTLCommandBuffer> cb = [g.queue commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:g.dpcmPipe];
        [ce setBuffer:up offset:0 atIndex:0];
        [ce setBuffer:up offset:in.group_table_off atIndex:1];
        [ce setBuffer:dst offset:0 atIndex:2];
        [ce setBytes:&P length:sizeof(P) atIndex:3];
        [ce dispatchThreadgroups:MTLSizeMake(in.tile_count, 1, 1)
           threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [ce endEncoding];

        /* Bands other than the last are pure work: the GPU decodes band k while
         * band k+1 is still arriving, which is the whole point of slicing. Each
         * hands back the upload slot it took, which is only needed until the
         * decode reading it finishes.
         *
         * No explicit ordering between these decodes and the present below.
         * Command buffers on one MTLCommandQueue execute in the order they were
         * committed, so the present — committed last — already runs after every
         * band. An MTLEvent was tried here and is exactly wrong: events
         * synchronise ACROSS queues, and waiting on one within a single queue
         * deadlocks, which is what it did. */
        dispatch_semaphore_t sem = g.inflight;
        const int async_present = g.async_present;

        if (async_present) {
            /* Arm BEFORE committing the last band, or its completion handler
             * could run first and find nothing to do — after which no other
             * band would ever take the count to zero again. */
            if (is_last) {
                /* A mutex, NOT dispatch_sync onto presentQ.
                 *
                 * presentQ is serial and spends most of its life inside
                 * nextDrawable, which blocks until a drawable frees — that is
                 * what vsync is. dispatch_sync onto a busy serial queue waits
                 * for it, so arming here used to park THIS thread on a vblank.
                 * This is the main thread: it also drains the control queue, so
                 * cursor packets stopped being processed for the duration.
                 *
                 * The cursor has its own compositing plane now and still moved
                 * in steps with vsync on, because the plane was never the
                 * problem — nothing was delivering positions to it. A lock held
                 * for three assignments costs nanoseconds and cannot wait on a
                 * display refresh. */
                pthread_mutex_lock(&g_present_lock);
                g.present_idx     = g.frame_widx;
                g.present_ten_bit = in.ten_bit ? 1 : 0;
                g.present_armed   = 1;
                pthread_mutex_unlock(&g_present_lock);
                g.frame_widx = (g.frame_widx + 1) % TB_FRAME_RING;
                g.frame_open = 0;
            }
            atomic_fetch_add(&g.bands_inflight, 1);
        }

        [cb addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull done) {
            (void)done;
            dispatch_semaphore_signal(sem);
            if (async_present) {
                /* Last one out presents. No assumption about the order these
                 * complete in — only about how many are left. */
                if (atomic_fetch_sub(&g.bands_inflight, 1) == 1) {
                    dispatch_async(g.presentQ, ^{ tb_present_armed_frame(); });
                }
            }
        }];
        [cb commit];

        if (async_present) { tb_health_note_submit(tb_mp_now_ms() - tb_submit_t0); return 0; }
        if (!is_last) { tb_health_note_submit(tb_mp_now_ms() - tb_submit_t0); return 0; }

        /* Wait for this frame's decodes before presenting.
         *
         * At one band per frame the decode and the present shared a command
         * buffer and were ordered by construction — which is why N=1 never
         * glitched. At N>1 the earlier bands are in separate command buffers,
         * and commit order on a queue is NOT sufficient: Metal may overlap their
         * execution, so the render pass can sample the surface while a band is
         * still writing it. That produced visible glitches at every slice count
         * above one.
         *
         * An MTLEvent is the wrong instrument here (it synchronises across
         * queues, and waiting on one within a queue deadlocks — it did). Blocking
         * on the last band's completion is coarse but correct, and cheap in the
         * place that matters: bands 0..n-2 have already overlapped the wire,
         * which is where the pipelining win actually comes from. Only the final
         * band's decode is paid for serially. */
        [cb waitUntilCompleted];

        const int presented_idx = g.frame_widx;
        g.frame_widx = (g.frame_widx + 1) % TB_FRAME_RING;
        g.frame_open = 0;

        dispatch_semaphore_t frames = g.frames_free;

        /* The blob says which depth it carries, so the texture view matches it.
         * At 8 bits the shader dithers into the 10-bit drawable — what macOS
         * does with 8-bit content everywhere else. At 10 bits the dither is
         * still applied but has almost nothing left to spread, because the
         * samples already resolve the drawable. */
        id<MTLCommandBuffer> pcb = [g.queue commandBuffer];
        /* Releases the ring slot once the frame has actually been presented. */
        [pcb addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull done) {
            (void)done;
            dispatch_semaphore_signal(frames);
        }];

        /* tb_present releases an inflight count on completion, so take one —
         * bounded, like every other wait on this thread. */
        if (dispatch_semaphore_wait(g.inflight,
                                    dispatch_time(DISPATCH_TIME_NOW,
                                                  100 * NSEC_PER_MSEC)) != 0) {
            dispatch_semaphore_signal(frames);
            { tb_health_note_submit(tb_mp_now_ms() - tb_submit_t0); return -1; }
        }
        const int rc = tb_present(pcb, g.frame[presented_idx], MTLStorageModePrivate, in.ten_bit);
        if (rc != 0) {
            /* tb_present returns without committing when no drawable is free, so
             * the handler above never runs and the ring slot would be lost —
             * three of those and the next frame blocks forever. */
            dispatch_semaphore_signal(frames);
        }
        { tb_health_note_submit(tb_mp_now_ms() - tb_submit_t0); return rc; }
    }
}
