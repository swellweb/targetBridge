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

/* The current transport sends whole frames and waits for each decode before
 * presenting. Keep at most three presentation surfaces and one additional
 * decode/upload slot; the former eight-slot ring was sized for sliced frames
 * and retained eight full-frame buffers even though that wire path is unused. */
#define TB_FRAME_RING 3
#define TB_UPLOAD_RING (TB_FRAME_RING + 1)

/* Mirrors DpcmParams in the shader. */
struct tb_dpcm_gpu_params {
    uint32_t width, height;
    uint32_t tilesX, tilesY;
    uint32_t tileCount;
    uint32_t outStridePx;
    uint32_t widthOff, seedOff, payOff;
    uint32_t bits;      /* 8 or 10; channel c sits at bit c*bits */
    uint32_t alpha;     /* opaque alpha, pre-shifted for this depth */
    uint32_t adaptiveColor; /* seed bit 31 may select reversible B-G/R-G */
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
    int                   cur_x, cur_y, cur_sw, cur_sh, cur_visible, cur_type, cur_large;
    float                 cur_hot_x, cur_hot_y;

    int                   shown;
    /* Default on: tearing should be opted into, never inherited. */
    int                   vsync;
    int                   vsync_initialised;
} g;

void tb_metal_plane_set_vsync(int enabled) {
    const int want = enabled ? 1 : 0;
    if (g.vsync == want) return;
    g.vsync = want;
    /* Applies immediately when a layer exists, and is re-applied at init, so the
     * choice survives the plane being torn down and rebuilt. */
    if (g.layer) g.layer.displaySyncEnabled = want ? YES : NO;
    fprintf(stderr, "[metal] vsync %s\n", want ? "on" : "off (lower latency, may tear)");
}

/* Set by set_cursor, cleared when the main loop updates the layer. */
static atomic_int g_cursor_dirty = 0;

static void tb_cursor_layer_attach(void);
static void tb_cursor_layer_ensure(void);
static void tb_cursor_layer_place(void);

static pthread_mutex_t g_cursor_state_lock = PTHREAD_MUTEX_INITIALIZER;
/* Snapshot a complete cursor position for placement. */
static struct { int x, y, sw, sh, visible; double arrival_ms; } g_cur_pending;


void tb_metal_plane_set_cursor(int x, int y, int source_w, int source_h,
                               int visible, int type, int large) {
    /* Keep the render-pass fallback in sync when the separate cursor layer is
     * disabled with TB_CURSOR_PLANE=0. */
    g.cur_x = x;
    g.cur_y = y;
    g.cur_sw = source_w > 0 ? source_w : 1;
    g.cur_sh = source_h > 0 ? source_h : 1;
    g.cur_visible = visible;
    if (g.cur_type != type || g.cur_large != (large != 0)) {
        g.cur_tex_scale = g.cur_layer_scale = -1.f;
    }
    g.cur_type = type;
    g.cur_large = large != 0;

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

/* Match the existing cursor type values sent by TBDisplaySender. */
static NSCursor *tb_cursor_for_type(int type) {
    switch (type) {
        case 1: return NSCursor.IBeamCursor;
        case 2: return NSCursor.pointingHandCursor;
        case 3: return NSCursor.resizeLeftRightCursor;
        case 4: return NSCursor.resizeUpDownCursor;
        case 5: return NSCursor.openHandCursor;
        case 6: return NSCursor.crosshairCursor;
        case 7:
        case 8:
            if (@available(macOS 15.0, *)) {
                return [NSCursor frameResizeCursorFromPosition:
                    type == 7 ? NSCursorFrameResizePositionTopLeft : NSCursorFrameResizePositionTopRight
                    inDirections:NSCursorFrameResizeDirectionsAll];
            } else {
                /* The sender uses these same selectors on older macOS. */
                SEL selector = NSSelectorFromString(type == 7
                    ? @"_windowResizeNorthWestSouthEastCursor"
                    : @"_windowResizeNorthEastSouthWestCursor");
                if ([NSCursor respondsToSelector:selector]) {
                    NSCursor *(*get_cursor)(id, SEL) = (void *)[NSCursor methodForSelector:selector];
                    NSCursor *cursor = get_cursor(NSCursor.class, selector);
                    if (cursor) return cursor;
                }
                return NSCursor.crosshairCursor;
            }
        default: return NSCursor.arrowCursor;
    }
}

static float tb_cursor_scale(void) {
    const int size = g.cur_large ? (g.frame_w >= 5000 ? 58 : 44)
                                 : (g.frame_w >= 5000 ? 32 : 24);
    return (float)size / 24.f;
}

/* Both presentation paths use the same premultiplied BGRA raster and hotspot.
 * NSCursor supplies the shape and its hotspot; large scales both together. */
static uint32_t *tb_cursor_raster(float scale, int *out_w, int *out_h) {
    NSCursor *cursor = tb_cursor_for_type(g.cur_type);
    NSImage *image = cursor.image;
    NSSize size = g.cursorImage ? NSMakeSize(g.cur_img_w, g.cur_img_h) : image.size;
    NSPoint hot = g.cursorImage ? NSMakePoint(g.cur_img_hot_x, g.cur_img_hot_y) : cursor.hotSpot;
    CGImageRef source = g.cursorImage ?: [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (!source || size.width <= 0 || size.height <= 0) return NULL;
    const int w = (int)ceil(size.width * scale), h = (int)ceil(size.height * scale);
    uint32_t *px = calloc((size_t)w * h, 4);
    if (!px) return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(px, w, h, 8, (size_t)w * 4, cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!context) { free(px); return NULL; }
    CGContextDrawImage(context, CGRectMake(0, 0, w, h), source);
    CGContextRelease(context);
    g.cur_hot_x = (float)(hot.x * w / size.width);
    g.cur_hot_y = (float)(hot.y * h / size.height);
    *out_w = w; *out_h = h;
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
    td.storageMode = g.dev.hasUnifiedMemory ? MTLStorageModeShared : MTLStorageModeManaged;
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

/* Cursor placement follows the receiver's main loop. There is no detached
 * worker that could still touch a layer while a fallback tears it down. */
void tb_metal_plane_flush_cursor(void) {
    tb_cursor_layer_ensure();
    if (atomic_exchange(&g_cursor_dirty, 0)) tb_cursor_layer_place();
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
        g.cur_layer_scale = g.cur_tex_scale = -1.f;
        tb_metal_plane_flush_cursor();
    }
    if (ctx) CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
}

static void tb_cursor_layer_sync_image(float scale) {
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
        tb_cursor_layer_sync_image(tb_cursor_scale());
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
    /* Both the layer and render-pass path use the same scaled image hotspot. */
    const double offx = g.cur_hot_x;
    const double offy = g.cur_hot_y;
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
    "  VOut o; o.pos = float4(c, 0, 1); o.uv = uv;\n"
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
    "  uint bits, alpha, adaptiveColor, rowOffset, colOffset;\n"
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
    "  uint3 v = uint3(seed + acc) & mask;\n"
    /* In adaptive blobs the seed marker selects the tile's coding space.
     * Restore RGB only after reconstructing all three transformed channels. */
    "  if (P.adaptiveColor != 0u && (sraw & 0x80000000u) != 0u) {\n"
    "    v.x = (v.x + v.y) & mask;\n"
    "    v.z = (v.z + v.y) & mask;\n"
    "  }\n"
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
    if (!g.layer) {
        fprintf(stderr, "[metal] no CAMetalLayer\n");
        tb_metal_plane_shutdown();
        return -1;
    }

    g.layer.hidden = YES;
    [(__bridge NSView *)g.view setHidden:YES];
    g.layer.device = g.dev;
    g.layer.pixelFormat = MTLPixelFormatBGR10A2Unorm;
    g.layer.framebufferOnly = NO;
    g.layer.opaque = YES;
    g.layer.maximumDrawableCount = TB_METAL_RING;
    g.layer.displaySyncEnabled = g.vsync ? YES : NO;
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
        tb_metal_plane_shutdown();
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
        tb_metal_plane_shutdown();
        return -1;
    }

    MTLRenderPipelineDescriptor *cd = [MTLRenderPipelineDescriptor new];
    cd.vertexFunction   = [lib newFunctionWithName:@"tb_cursor_vs"];
    cd.fragmentFunction = [lib newFunctionWithName:@"tb_cursor_fs"];
    cd.colorAttachments[0].pixelFormat = MTLPixelFormatBGR10A2Unorm;
    cd.colorAttachments[0].blendingEnabled = YES;
    cd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
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
    if (!g.queue) { tb_metal_plane_shutdown(); return -1; }
    g.inflight = dispatch_semaphore_create(TB_UPLOAD_RING);
    /* This protocol sends complete frames. Present synchronously so each frame
     * owns its surface until submission; a shared async "latest frame" slot
     * loses ownership when another decode completes before presentation. */
    g.frames_free = dispatch_semaphore_create(TB_FRAME_RING);
    g.frame_widx = 0;
    g.frame_open = 0;
    g.ring_idx = 0;
    g.ready = 1;
    g.shown = 0;

    fprintf(stderr, "[metal] plane ready on %s (dpcm=%s)\n",
            [[g.dev name] UTF8String], g.dpcmPipe ? "yes" : "no");
    return 0;
}

void tb_metal_plane_shutdown(void) {
    if (!g.ready && !g.view && !g.dev) return;
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
    if (!hidden) {
        if (g.ready && !g.shown) {
            g.layer.hidden = NO;
            [(__bridge NSView *)g.view setHidden:NO];
            g.shown = 1;
            tb_cursor_layer_attach();
        }
        return;
    }
    /* Fully remove the view: hiding the layer is not enough to reveal the
     * OpenGL content underneath. Only fires on an actual transition. */
    if (g.ready) {
        tb_metal_plane_shutdown();
        fprintf(stderr, "[metal] plane released; SDL owns the window\n");
    }
}

/* ---------------------------------------------------------------- geometry */

/* The transport currently offers at most 5K. The generic codec accepts larger
 * images, but a small flat blob must not allocate multi-gigabyte GPU rings. */
static int tb_metal_frame_dimensions_valid(int w, int h) {
    return w > 0 && h > 0 && w <= 5120 && h <= 2880;
}

int tb_metal_plane_accepts_dpcm(const uint8_t *blob, size_t len) {
    struct tb_dpcm_info info;
    return tb_dpcm_parse(blob, len, &info) == 0 &&
           tb_metal_frame_dimensions_valid(info.width, info.height);
}

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

/* Take an upload slot without advancing past it. The caller advances only after
 * submission, or returns `inflight` on failure so retries reuse the same free
 * slot instead of wrapping into buffers still owned by earlier GPU work. */
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
                      MTLStorageMode mode, int ten_bit, dispatch_semaphore_t frames) {
    if (!cb) { dispatch_semaphore_signal(g.inflight); return -1; }
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
        /* No commands were submitted: the caller releases its frame slot.
         * ARC releases this drawable back to the pool when we return. */
        dispatch_semaphore_signal(g.inflight);
        fprintf(stderr, "[metal] no source texture\n");
        return -1;
    }

    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture     = drawable.texture;
    rp.colorAttachments[0].loadAction  = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    if (!enc) { dispatch_semaphore_signal(g.inflight); return -1; }
    [enc setRenderPipelineState:g.pipe];
    [enc setFragmentTexture:srcTex atIndex:0];
    /* Eight-bit samples may be dithered into the deeper drawable. Do not add
     * noise to ten-bit samples, whose low bits the codec already preserves.
     * The drawable format alone does not establish the panel's output depth. */
    const float dither = ten_bit ? 0.0f : g.dither;
    [enc setFragmentBytes:&dither length:sizeof(dither) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];

    /* Only composite the cursor into the frame when it has no plane of its own.
     * With the plane attached this would be a second, staler arrow drawn on top
     * of the live one. */
    if (g.cur_visible && g.cursorPipe && !g.cursorLayer) {
        tb_cursor_build(tb_cursor_scale());
        if (g.curTex) {
            /* Cursor coordinates arrive in the sender's source-frame space, which
             * is not necessarily the frame we are showing. */
            const float sx = (float)g.frame_w / (float)g.cur_sw;
            const float sy = (float)g.frame_h / (float)g.cur_sh;
            const float px = (float)g.cur_x * sx - g.cur_hot_x;
            const float py = (float)g.cur_y * sy - g.cur_hot_y;
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
        if (frames) dispatch_semaphore_signal(frames);
    }];
    [cb commit];
    return 0;
}

/* -------------------------------------------------------------- entry points */

int tb_metal_plane_render_packed(const uint8_t *px, int stride, int w, int h,
                                 int ten_bit) {
    if (!g.ready || !px || !tb_metal_frame_dimensions_valid(w, h)) return -1;

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
        const int rc = tb_present(cb, up, MTLStorageModeShared, ten_bit, nil);
        if (rc == 0) g.ring_idx = (g.ring_idx + 1) % TB_UPLOAD_RING;
        return rc;
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
    if (!tb_metal_frame_dimensions_valid(frame_w, frame_h)) {
        tb_health_note_submit(tb_mp_now_ms() - tb_submit_t0);
        return -1;
    }
    if (x0 != 0) { tb_health_note_submit(tb_mp_now_ms() - tb_submit_t0); return -1; }
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
        if (!up) {
            dispatch_semaphore_signal(g.frames_free);
            g.frame_open = 0;
            tb_health_note_submit(tb_mp_now_ms() - tb_submit_t0);
            return -1;
        }
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
            in.adaptive_color ? 1u : 0u,
            (uint32_t)y0, (uint32_t)x0
        };

        id<MTLCommandBuffer> cb = [g.queue commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        if (!cb || !ce) {
            dispatch_semaphore_signal(g.inflight);
            dispatch_semaphore_signal(g.frames_free);
            g.frame_open = 0;
            tb_health_note_submit(tb_mp_now_ms() - tb_submit_t0);
            return -1;
        }
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
        [cb addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull done) {
            (void)done;
            dispatch_semaphore_signal(sem);
        }];
        [cb commit];
        g.ring_idx = (g.ring_idx + 1) % TB_UPLOAD_RING;

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
        if (cb.status != MTLCommandBufferStatusCompleted) {
            dispatch_semaphore_signal(g.frames_free);
            g.frame_open = 0;
            tb_health_note_submit(tb_mp_now_ms() - tb_submit_t0);
            return -1;
        }

        const int presented_idx = g.frame_widx;
        g.frame_open = 0;

        dispatch_semaphore_t frames = g.frames_free;

        /* Match the texture view to the transmitted depth. Ten-bit samples
         * are presented without dithering so their low bits remain intact. */
        id<MTLCommandBuffer> pcb = [g.queue commandBuffer];
        /* tb_present registers the frame release only after all fallible setup.
         * Metal can invoke a handler when an uncommitted command is destroyed;
         * registering here would then double-release the failure path's slot. */

        /* tb_present releases an inflight count on completion, so take one —
         * bounded, like every other wait on this thread. */
        if (dispatch_semaphore_wait(g.inflight,
                                    dispatch_time(DISPATCH_TIME_NOW,
                                                  100 * NSEC_PER_MSEC)) != 0) {
            dispatch_semaphore_signal(frames);
            { tb_health_note_submit(tb_mp_now_ms() - tb_submit_t0); return -1; }
        }
        const int rc = tb_present(pcb, g.frame[presented_idx], MTLStorageModePrivate, in.ten_bit, frames);
        if (rc != 0) {
            /* No presentation was committed and no frame-release handler was
             * registered. Return the slot while keeping it next in the ring. */
            dispatch_semaphore_signal(frames);
        } else {
            /* Only a submitted presentation owns this slot. A failed attempt
             * must retry it, not skip toward an older surface still in use. */
            g.frame_widx = (g.frame_widx + 1) % TB_FRAME_RING;
        }
        { tb_health_note_submit(tb_mp_now_ms() - tb_submit_t0); return rc; }
    }
}
