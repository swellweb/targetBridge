/* display.c — SDL2 NV12 renderer.
 *
 * SDL2 on macOS uses Metal renderer by default (SDL_RENDERER_ACCELERATED).
 * SDL_PIXELFORMAT_NV12 + SDL_UpdateNVTexture lets us upload YUV planes
 * directly to GPU; the shader does YUV→RGB conversion on the GPU.
 */

#include "display.h"
#include "i18n.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <SDL.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef TB_RECEIVER_VERSION
#define TB_RECEIVER_VERSION "0.1.0-rc1"
#endif

#ifndef TB_RECEIVER_BUILD
#define TB_RECEIVER_BUILD "dev"
#endif

struct tb_display {
    SDL_Window   *win;
    SDL_Renderer *ren;
    SDL_Texture  *tex;
    SDL_Texture  *status_tex;
    int           tex_w, tex_h;
    int           quit;
    int           preferred_fullscreen;
    int           is_connected;
    int           cursor_x, cursor_y;
    int           cursor_source_w, cursor_source_h;
    int           cursor_visible;
    int           cursor_type;
    uint32_t      last_video_frame_time;

    char          last_ip[64];
    char          last_status[128];
    char          last_sender[128];
    char          last_panel[128];
    char          last_mode[128];
    int           last_drawable_w;
    int           last_drawable_h;
};

static void tb_disp_destroy_status_texture(struct tb_display *d) {
    if (d->status_tex) {
        SDL_DestroyTexture(d->status_tex);
        d->status_tex = NULL;
    }
}

static void tb_disp_draw_text(CGContextRef ctx,
                              const char *text,
                              const char *font_name,
                              CGFloat font_size,
                              CGFloat x,
                              CGFloat y,
                              CGFloat r,
                              CGFloat g,
                              CGFloat b) {
    if (!text || !*text) return;

    CFStringRef cf_text = CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
    if (!cf_text) return;

    CFStringRef cf_font_name = CFStringCreateWithCString(NULL, font_name, kCFStringEncodingUTF8);
    if (!cf_font_name) {
        CFRelease(cf_text);
        return;
    }

    CTFontRef font = CTFontCreateWithName(cf_font_name, font_size, NULL);
    CFRelease(cf_font_name);
    if (!font) {
        CFRelease(cf_text);
        return;
    }

    CGFloat components[4] = { r, g, b, 1.0 };
    CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
    CGColorRef color = CGColorCreate(color_space, components);
    CGColorSpaceRelease(color_space);
    if (!color) {
        CFRelease(font);
        CFRelease(cf_text);
        return;
    }

    const void *keys[] = { kCTFontAttributeName, kCTForegroundColorAttributeName };
    const void *values[] = { font, color };
    CFDictionaryRef attrs = CFDictionaryCreate(
        NULL,
        keys,
        values,
        2,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    CFAttributedStringRef attributed = CFAttributedStringCreate(NULL, cf_text, attrs);
    CTLineRef line = attributed ? CTLineCreateWithAttributedString(attributed) : NULL;

    if (line) {
        CGContextSaveGState(ctx);
        /* The whole status canvas is flipped to get a top-left origin.
         * CoreText glyph rasterization does not follow that transform the
         * way the filled rects do, so we locally flip again just for text. */
        CGContextSetTextMatrix(ctx, CGAffineTransformIdentity);
        CGContextTranslateCTM(ctx, 0.0, 2.0 * y);
        CGContextScaleCTM(ctx, 1.0, -1.0);
        CGContextSetTextPosition(ctx, x, y);
        CTLineDraw(line, ctx);
        CGContextRestoreGState(ctx);
        CFRelease(line);
    }

    if (attributed) CFRelease(attributed);
    if (attrs) CFRelease(attrs);
    CGColorRelease(color);
    CFRelease(font);
    CFRelease(cf_text);
}

static void tb_disp_fill_rect(CGContextRef ctx,
                              CGFloat x,
                              CGFloat y,
                              CGFloat w,
                              CGFloat h,
                              CGFloat r,
                              CGFloat g,
                              CGFloat b,
                              CGFloat a) {
    CGContextSetRGBFillColor(ctx, r, g, b, a);
    CGContextFillRect(ctx, CGRectMake(x, y, w, h));
}

static void tb_disp_rebuild_status_texture(struct tb_display *d,
                                           const char *ip,
                                           const char *status,
                                           const char *sender,
                                           const char *panel,
                                           const char *mode,
                                           int drawable_w,
                                           int drawable_h) {
    if (!d || drawable_w <= 0 || drawable_h <= 0) return;

    tb_disp_destroy_status_texture(d);

    const size_t bytes_per_row = (size_t)drawable_w * 4u;
    uint32_t *pixels = (uint32_t *)calloc((size_t)drawable_w * (size_t)drawable_h, sizeof(uint32_t));
    if (!pixels) return;

    CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        pixels,
        (size_t)drawable_w,
        (size_t)drawable_h,
        8,
        bytes_per_row,
        color_space,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little
    );
    CGColorSpaceRelease(color_space);
    if (!ctx) {
        free(pixels);
        return;
    }

    CGContextTranslateCTM(ctx, 0, (CGFloat)drawable_h);
    CGContextScaleCTM(ctx, 1.0, -1.0);

    tb_disp_fill_rect(ctx, 0, 0, (CGFloat)drawable_w, (CGFloat)drawable_h, 0.06, 0.07, 0.09, 1.0);
    tb_disp_fill_rect(ctx, 48, 52, (CGFloat)drawable_w - 96, (CGFloat)drawable_h - 104, 0.12, 0.13, 0.16, 1.0);
    tb_disp_fill_rect(ctx, 48, (CGFloat)drawable_h - 152, (CGFloat)drawable_w - 96, 2, 0.23, 0.25, 0.30, 1.0);

    /* Pick fonts based on locale. CoreText cannot render CJK glyphs with
     * Helvetica / Menlo, so when Chinese is active we fall back to
     * PingFang SC (Semibold) and PingFang SC (Regular) which ship with
     * macOS. ASCII fields (IP address, version) keep Menlo for the
     * monospaced look since they only contain digits / latin letters. */
    const int zh = tb_locale_is_chinese();
    const char *title_font     = zh ? "PingFangSC-Semibold" : "Helvetica-Bold";
    const char *body_font      = zh ? "PingFangSC-Regular"  : "Helvetica";
    const char *section_font   = zh ? "PingFangSC-Semibold" : "Helvetica-Bold";
    const char *value_font     = zh ? "PingFangSC-Regular"  : "Helvetica";
    /* IP / mode strings are mostly ASCII numerics; keep monospaced look. */
    const char *mono_font      = "Menlo";
    const char *mono_bold_font = "Menlo-Bold";

    tb_disp_draw_text(ctx, tb_tr("TARGETBRIDGE RECEIVER", "TARGETBRIDGE 接收端"),
                      title_font, 30, 72, (CGFloat)drawable_h - 76, 0.95, 0.97, 1.0);
    tb_disp_draw_text(ctx, tb_tr("5K / HiDPI receiver ready for sender", "5K / HiDPI 接收端，等待发送端连接"),
                      body_font, 18, 72, (CGFloat)drawable_h - 118, 0.72, 0.76, 0.84);
    tb_disp_draw_text(ctx, TB_RECEIVER_VERSION, mono_bold_font, 18, (CGFloat)drawable_w - 220, (CGFloat)drawable_h - 78, 0.64, 0.69, 0.78);
    tb_disp_draw_text(ctx, TB_RECEIVER_BUILD, mono_font, 14, (CGFloat)drawable_w - 220, (CGFloat)drawable_h - 120, 0.53, 0.57, 0.66);

    tb_disp_draw_text(ctx, tb_tr("IP THUNDERBOLT BRIDGE", "Thunderbolt Bridge IP"),
                      section_font, 16, 72, (CGFloat)drawable_h - 190, 0.54, 0.62, 0.76);
    tb_disp_draw_text(ctx, ip, mono_bold_font, 36, 72, (CGFloat)drawable_h - 235, 0.43, 0.93, 0.60);

    tb_disp_draw_text(ctx, tb_tr("STATUS", "状态"),
                      section_font, 16, 72, (CGFloat)drawable_h - 300, 0.54, 0.62, 0.76);
    tb_disp_draw_text(ctx, status, value_font, 24, 72, (CGFloat)drawable_h - 338, 0.94, 0.96, 0.99);

    tb_disp_draw_text(ctx, tb_tr("SENDER", "发送端"),
                      section_font, 16, 72, (CGFloat)drawable_h - 400, 0.54, 0.62, 0.76);
    tb_disp_draw_text(ctx, sender, value_font, 22, 72, (CGFloat)drawable_h - 436, 0.94, 0.96, 0.99);

    tb_disp_draw_text(ctx, tb_tr("DISPLAY", "显示器"),
                      section_font, 16, 72, (CGFloat)drawable_h - 498, 0.54, 0.62, 0.76);
    tb_disp_draw_text(ctx, panel, zh ? value_font : mono_font, 22, 72, (CGFloat)drawable_h - 534, 0.94, 0.96, 0.99);

    tb_disp_draw_text(ctx, tb_tr("STREAM PROFILE", "码流配置"),
                      section_font, 16, 72, (CGFloat)drawable_h - 596, 0.54, 0.62, 0.76);
    tb_disp_draw_text(ctx, mode, zh ? value_font : mono_font, 22, 72, (CGFloat)drawable_h - 632, 0.94, 0.96, 0.99);

    tb_disp_draw_text(ctx, tb_tr("Start the sender on your MacBook and enter this IP address.",
                                 "在 MacBook 上启动发送端，并填入上方的 IP 地址。"),
                      body_font, 18, 72, 146, 0.76, 0.80, 0.88);
    tb_disp_draw_text(ctx, tb_tr("When the first frame arrives, the receiver switches to fullscreen automatically.",
                                 "收到第一帧画面后，接收端会自动切换到全屏。"),
                      body_font, 18, 72, 116, 0.76, 0.80, 0.88);
    tb_disp_draw_text(ctx, tb_tr("If the sender stops, the receiver returns here ready for a new session.",
                                 "发送端停止后，接收端会返回此界面，等待下一次会话。"),
                      body_font, 18, 72, 86, 0.76, 0.80, 0.88);

    CGContextRelease(ctx);

    d->status_tex = SDL_CreateTexture(
        d->ren,
        SDL_PIXELFORMAT_ARGB8888,
        SDL_TEXTUREACCESS_STATIC,
        drawable_w,
        drawable_h
    );
    if (d->status_tex) {
        SDL_UpdateTexture(d->status_tex, NULL, pixels, (int)bytes_per_row);
        SDL_SetTextureBlendMode(d->status_tex, SDL_BLENDMODE_NONE);
    }
    free(pixels);
}

static void tb_disp_refresh_window_mode(struct tb_display *d) {
    if (!d || !d->win) return;

    if (d->is_connected && d->preferred_fullscreen) {
        SDL_SetWindowFullscreen(d->win, SDL_WINDOW_FULLSCREEN_DESKTOP);
        SDL_ShowCursor(SDL_DISABLE);
    } else {
        SDL_SetWindowFullscreen(d->win, 0);
        SDL_SetWindowSize(d->win, 980, 620);
        SDL_SetWindowPosition(d->win, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED);
        SDL_ShowCursor(SDL_ENABLE);
    }
}

struct tb_display *tb_disp_create(int fullscreen) {
    /* Force OpenGL renderer driver to avoid Metal's HDR/swapchain flickering on macOS Tahoe. */
    SDL_SetHint(SDL_HINT_RENDER_DRIVER, "opengl");

    /* Best-quality scaling (linear filter; Metal backend uses bilinear
     * regardless but this sets the hint correctly). "best" enables
     * anisotropic where supported. Must be set BEFORE renderer creation. */
    SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "best");

    if (SDL_Init(SDL_INIT_VIDEO) < 0) {
        fprintf(stderr, "[disp] SDL_Init: %s\n", SDL_GetError());
        return NULL;
    }
    SDL_DisableScreenSaver();

    struct tb_display *d = (struct tb_display *)calloc(1, sizeof(*d));
    if (!d) return NULL;

    Uint32 flags = SDL_WINDOW_HIDDEN | SDL_WINDOW_ALLOW_HIGHDPI | SDL_WINDOW_RESIZABLE;

    d->win = SDL_CreateWindow("TargetBridge Receiver",
                              SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                              980, 620, flags);
    if (!d->win) {
        fprintf(stderr, "[disp] CreateWindow: %s\n", SDL_GetError());
        free(d); return NULL;
    }

    /* No VSYNC: lets us present as fast as decode produces frames.
     * On Intel iMac with Radeon Pro 570 + 5K display, VSYNC at 60Hz combined
     * with GPU→CPU NV12 transfer was stalling the pipeline to ~4 fps. */
    d->ren = SDL_CreateRenderer(d->win, -1, SDL_RENDERER_ACCELERATED);
    if (!d->ren) {
        fprintf(stderr, "[disp] CreateRenderer: %s\n", SDL_GetError());
        SDL_DestroyWindow(d->win); free(d); return NULL;
    }
    SDL_SetYUVConversionMode(SDL_YUV_CONVERSION_BT709);
    SDL_RenderSetLogicalSize(d->ren, 0, 0);

    /* report which backend SDL picked */
    SDL_RendererInfo info;
    if (SDL_GetRendererInfo(d->ren, &info) == 0) {
        fprintf(stderr, "[disp] renderer = %s\n", info.name);
    }

    int win_w = 0, win_h = 0, out_w = 0, out_h = 0;
    SDL_GetWindowSize(d->win, &win_w, &win_h);
    if (SDL_GetRendererOutputSize(d->ren, &out_w, &out_h) == 0) {
        fprintf(stderr, "[disp] window %dx%d -> drawable %dx%d\n",
                win_w, win_h, out_w, out_h);
    }

    d->preferred_fullscreen = fullscreen;
    d->is_connected = 0;
    d->last_ip[0] = '\0';
    d->last_status[0] = '\0';
    d->last_sender[0] = '\0';
    d->last_panel[0] = '\0';
    d->last_mode[0] = '\0';
    d->last_drawable_w = 0;
    d->last_drawable_h = 0;
    d->cursor_x = 0;
    d->cursor_y = 0;
    d->cursor_source_w = 1;
    d->cursor_source_h = 1;
    d->cursor_visible = 0;
    d->cursor_type = 0;
    d->last_video_frame_time = 0;

    tb_disp_refresh_window_mode(d);
    SDL_ShowWindow(d->win);
    return d;
}

void tb_disp_destroy(struct tb_display *d) {
    if (!d) return;
    tb_disp_destroy_status_texture(d);
    if (d->tex) SDL_DestroyTexture(d->tex);
    if (d->ren) SDL_DestroyRenderer(d->ren);
    if (d->win) SDL_DestroyWindow(d->win);
    SDL_EnableScreenSaver();
    SDL_Quit();
    free(d);
}

int tb_disp_ensure_texture(struct tb_display *d, int w, int h) {
    if (d->tex && d->tex_w == w && d->tex_h == h) return 0;
    if (d->tex) { SDL_DestroyTexture(d->tex); d->tex = NULL; }

    d->tex = SDL_CreateTexture(d->ren, SDL_PIXELFORMAT_NV12,
                               SDL_TEXTUREACCESS_STREAMING, w, h);
    if (!d->tex) {
        fprintf(stderr, "[disp] CreateTexture(NV12): %s\n", SDL_GetError());
        return -1;
    }
    d->tex_w = w;
    d->tex_h = h;
    fprintf(stderr, "[disp] texture %dx%d NV12\n", w, h);
    return 0;
}

static void tb_disp_draw_poly_outline(SDL_Renderer *ren, const SDL_Point *pts, int count) {
    if (!ren || !pts || count < 2) return;
    for (int i = 0; i < count; ++i) {
        const SDL_Point a = pts[i];
        const SDL_Point b = pts[(i + 1) % count];
        SDL_RenderDrawLine(ren, a.x, a.y, b.x, b.y);
    }
}

static void tb_disp_fill_poly(SDL_Renderer *ren, const SDL_Point *pts, int count) {
    if (!ren || !pts || count < 3) return;

    int min_y = pts[0].y;
    int max_y = pts[0].y;
    for (int i = 1; i < count; ++i) {
        if (pts[i].y < min_y) min_y = pts[i].y;
        if (pts[i].y > max_y) max_y = pts[i].y;
    }

    for (int y = min_y; y <= max_y; ++y) {
        int nodes[16];
        int node_count = 0;

        for (int i = 0, j = count - 1; i < count; j = i++) {
            const int yi = pts[i].y;
            const int yj = pts[j].y;
            if ((yi < y && yj >= y) || (yj < y && yi >= y)) {
                const int xi = pts[i].x;
                const int xj = pts[j].x;
                if (node_count < (int)(sizeof(nodes) / sizeof(nodes[0]))) {
                    nodes[node_count++] = xi + ((y - yi) * (xj - xi)) / (yj - yi);
                }
            }
        }

        for (int i = 1; i < node_count; ++i) {
            int v = nodes[i];
            int k = i - 1;
            while (k >= 0 && nodes[k] > v) {
                nodes[k + 1] = nodes[k];
                --k;
            }
            nodes[k + 1] = v;
        }

        for (int i = 0; i + 1 < node_count; i += 2) {
            SDL_RenderDrawLine(ren, nodes[i], y, nodes[i + 1], y);
        }
    }
}

static int tb_disp_cursor_scale(int size, int value) {
    return (size * value + 16) / 32;
}

static SDL_Point tb_disp_cursor_point(int x, int y, int size, int px, int py) {
    SDL_Point p = {
        x + tb_disp_cursor_scale(size, px),
        y + tb_disp_cursor_scale(size, py)
    };
    return p;
}

static void draw_scaled_rect(SDL_Renderer *ren, int cx, int cy, int size, int rx1, int ry1, int rx2, int ry2) {
    SDL_Rect r;
    int x1 = cx + tb_disp_cursor_scale(size, rx1);
    int y1 = cy + tb_disp_cursor_scale(size, ry1);
    int x2 = cx + tb_disp_cursor_scale(size, rx2);
    int y2 = cy + tb_disp_cursor_scale(size, ry2);
    r.x = x1 < x2 ? x1 : x2;
    r.y = y1 < y2 ? y1 : y2;
    r.w = x2 > x1 ? (x2 - x1) : (x1 - x2);
    r.h = y2 > y1 ? (y2 - y1) : (y1 - y2);
    if (r.w == 0) r.w = 1;
    if (r.h == 0) r.h = 1;
    SDL_RenderFillRect(ren, &r);
}

static void tb_disp_draw_cursor(struct tb_display *d) {
    if (!d || !d->cursor_visible || d->cursor_source_w <= 0 || d->cursor_source_h <= 0) return;

    int out_w = 0, out_h = 0;
    if (SDL_GetRendererOutputSize(d->ren, &out_w, &out_h) < 0 || out_w <= 0 || out_h <= 0) {
        return;
    }

    const double sx = (double)out_w / (double)d->cursor_source_w;
    const double sy = (double)out_h / (double)d->cursor_source_h;
    const int x = (int)((double)d->cursor_x * sx);
    const int y = (int)((double)d->cursor_y * sy);
    const int size = out_w >= 5000 ? 58 : 44;
    SDL_BlendMode old_blend = SDL_BLENDMODE_NONE;
    (void)SDL_GetRenderDrawBlendMode(d->ren, &old_blend);

    SDL_SetRenderDrawBlendMode(d->ren, SDL_BLENDMODE_BLEND);

    if (d->cursor_type == 1) {
        /* I-Beam (Text Cursor) */
        /* Draw Shadow */
        SDL_SetRenderDrawColor(d->ren, 0, 0, 0, 70);
        int sx_off = 1, sy_off = 2;
        draw_scaled_rect(d->ren, x + sx_off, y + sy_off, size, -8, -14, 8, -10);
        draw_scaled_rect(d->ren, x + sx_off, y + sy_off, size, -8, 10, 8, 14);
        draw_scaled_rect(d->ren, x + sx_off, y + sy_off, size, -2, -12, 2, 12);
        
        /* Draw Outline (White) */
        SDL_SetRenderDrawColor(d->ren, 255, 255, 255, 255);
        draw_scaled_rect(d->ren, x, y, size, -8, -14, 8, -10);
        draw_scaled_rect(d->ren, x, y, size, -8, 10, 8, 14);
        draw_scaled_rect(d->ren, x, y, size, -2, -12, 2, 12);
        
        /* Draw Body (Black) */
        SDL_SetRenderDrawColor(d->ren, 0, 0, 0, 255);
        draw_scaled_rect(d->ren, x, y, size, -7, -13, 7, -11);
        draw_scaled_rect(d->ren, x, y, size, -7, 11, 7, 13);
        draw_scaled_rect(d->ren, x, y, size, -1, -11, 1, 11);
    }
    else if (d->cursor_type == 2) {
        /* Pointing Hand */
        const int cx = x - tb_disp_cursor_scale(size, 10);
        const int cy = y;
        SDL_Point shadow[] = {
            tb_disp_cursor_point(cx + 2, cy + 3, size, 10, 0),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 13, 2),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 13, 11),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 17, 11),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 17, 15),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 16, 17),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 16, 20),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 14, 22),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 14, 24),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 11, 27),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 5, 27),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 1, 20),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 0, 16),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 3, 13),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 7, 11),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 7, 2)
        };
        SDL_SetRenderDrawColor(d->ren, 0, 0, 0, 70);
        tb_disp_fill_poly(d->ren, shadow, (int)(sizeof(shadow) / sizeof(shadow[0])));

        SDL_Point outline[] = {
            tb_disp_cursor_point(cx, cy, size, 10, 0),
            tb_disp_cursor_point(cx, cy, size, 13, 2),
            tb_disp_cursor_point(cx, cy, size, 13, 11),
            tb_disp_cursor_point(cx, cy, size, 17, 11),
            tb_disp_cursor_point(cx, cy, size, 17, 15),
            tb_disp_cursor_point(cx, cy, size, 16, 17),
            tb_disp_cursor_point(cx, cy, size, 16, 20),
            tb_disp_cursor_point(cx, cy, size, 14, 22),
            tb_disp_cursor_point(cx, cy, size, 14, 24),
            tb_disp_cursor_point(cx, cy, size, 11, 27),
            tb_disp_cursor_point(cx, cy, size, 5, 27),
            tb_disp_cursor_point(cx, cy, size, 1, 20),
            tb_disp_cursor_point(cx, cy, size, 0, 16),
            tb_disp_cursor_point(cx, cy, size, 3, 13),
            tb_disp_cursor_point(cx, cy, size, 7, 11),
            tb_disp_cursor_point(cx, cy, size, 7, 2)
        };
        SDL_SetRenderDrawColor(d->ren, 255, 255, 255, 255);
        tb_disp_fill_poly(d->ren, outline, (int)(sizeof(outline) / sizeof(outline[0])));
        tb_disp_draw_poly_outline(d->ren, outline, (int)(sizeof(outline) / sizeof(outline[0])));

        SDL_Point body[] = {
            tb_disp_cursor_point(cx, cy, size, 10, 2),
            tb_disp_cursor_point(cx, cy, size, 12, 3),
            tb_disp_cursor_point(cx, cy, size, 12, 11),
            tb_disp_cursor_point(cx, cy, size, 15, 12),
            tb_disp_cursor_point(cx, cy, size, 15, 14),
            tb_disp_cursor_point(cx, cy, size, 14, 17),
            tb_disp_cursor_point(cx, cy, size, 14, 19),
            tb_disp_cursor_point(cx, cy, size, 12, 21),
            tb_disp_cursor_point(cx, cy, size, 12, 23),
            tb_disp_cursor_point(cx, cy, size, 10, 25),
            tb_disp_cursor_point(cx, cy, size, 6, 25),
            tb_disp_cursor_point(cx, cy, size, 3, 19),
            tb_disp_cursor_point(cx, cy, size, 2, 16),
            tb_disp_cursor_point(cx, cy, size, 4, 14),
            tb_disp_cursor_point(cx, cy, size, 8, 12),
            tb_disp_cursor_point(cx, cy, size, 8, 3)
        };
        SDL_SetRenderDrawColor(d->ren, 0, 0, 0, 255);
        tb_disp_fill_poly(d->ren, body, (int)(sizeof(body) / sizeof(body[0])));
        tb_disp_draw_poly_outline(d->ren, body, (int)(sizeof(body) / sizeof(body[0])));
    }
    else if (d->cursor_type == 3) {
        /* Resize Horizontal */
        const int cx = x - tb_disp_cursor_scale(size, 16);
        const int cy = y - tb_disp_cursor_scale(size, 16);
        SDL_Point shadow[] = {
            tb_disp_cursor_point(cx + 2, cy + 3, size, 2, 16),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 8, 10),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 8, 13),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 24, 13),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 24, 10),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 30, 16),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 24, 22),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 24, 19),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 8, 19),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 8, 22)
        };
        SDL_SetRenderDrawColor(d->ren, 0, 0, 0, 70);
        tb_disp_fill_poly(d->ren, shadow, (int)(sizeof(shadow) / sizeof(shadow[0])));

        SDL_Point outline[] = {
            tb_disp_cursor_point(cx, cy, size, 2, 16),
            tb_disp_cursor_point(cx, cy, size, 8, 10),
            tb_disp_cursor_point(cx, cy, size, 8, 13),
            tb_disp_cursor_point(cx, cy, size, 24, 13),
            tb_disp_cursor_point(cx, cy, size, 24, 10),
            tb_disp_cursor_point(cx, cy, size, 30, 16),
            tb_disp_cursor_point(cx, cy, size, 24, 22),
            tb_disp_cursor_point(cx, cy, size, 24, 19),
            tb_disp_cursor_point(cx, cy, size, 8, 19),
            tb_disp_cursor_point(cx, cy, size, 8, 22)
        };
        SDL_SetRenderDrawColor(d->ren, 255, 255, 255, 255);
        tb_disp_fill_poly(d->ren, outline, (int)(sizeof(outline) / sizeof(outline[0])));
        tb_disp_draw_poly_outline(d->ren, outline, (int)(sizeof(outline) / sizeof(outline[0])));

        SDL_Point body[] = {
            tb_disp_cursor_point(cx, cy, size, 5, 16),
            tb_disp_cursor_point(cx, cy, size, 8, 12),
            tb_disp_cursor_point(cx, cy, size, 8, 15),
            tb_disp_cursor_point(cx, cy, size, 24, 15),
            tb_disp_cursor_point(cx, cy, size, 24, 12),
            tb_disp_cursor_point(cx, cy, size, 27, 16),
            tb_disp_cursor_point(cx, cy, size, 24, 20),
            tb_disp_cursor_point(cx, cy, size, 24, 17),
            tb_disp_cursor_point(cx, cy, size, 8, 17),
            tb_disp_cursor_point(cx, cy, size, 8, 20)
        };
        SDL_SetRenderDrawColor(d->ren, 0, 0, 0, 255);
        tb_disp_fill_poly(d->ren, body, (int)(sizeof(body) / sizeof(body[0])));
        tb_disp_draw_poly_outline(d->ren, body, (int)(sizeof(body) / sizeof(body[0])));
    }
    else if (d->cursor_type == 4) {
        /* Resize Vertical */
        const int cx = x - tb_disp_cursor_scale(size, 16);
        const int cy = y - tb_disp_cursor_scale(size, 16);
        SDL_Point shadow[] = {
            tb_disp_cursor_point(cx + 2, cy + 3, size, 16, 2),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 22, 8),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 19, 8),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 19, 24),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 22, 24),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 16, 30),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 10, 24),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 13, 24),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 13, 8),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 10, 8)
        };
        SDL_SetRenderDrawColor(d->ren, 0, 0, 0, 70);
        tb_disp_fill_poly(d->ren, shadow, (int)(sizeof(shadow) / sizeof(shadow[0])));

        SDL_Point outline[] = {
            tb_disp_cursor_point(cx, cy, size, 16, 2),
            tb_disp_cursor_point(cx, cy, size, 22, 8),
            tb_disp_cursor_point(cx, cy, size, 19, 8),
            tb_disp_cursor_point(cx, cy, size, 19, 24),
            tb_disp_cursor_point(cx, cy, size, 22, 24),
            tb_disp_cursor_point(cx, cy, size, 16, 30),
            tb_disp_cursor_point(cx, cy, size, 10, 24),
            tb_disp_cursor_point(cx, cy, size, 13, 24),
            tb_disp_cursor_point(cx, cy, size, 13, 8),
            tb_disp_cursor_point(cx, cy, size, 10, 8)
        };
        SDL_SetRenderDrawColor(d->ren, 255, 255, 255, 255);
        tb_disp_fill_poly(d->ren, outline, (int)(sizeof(outline) / sizeof(outline[0])));
        tb_disp_draw_poly_outline(d->ren, outline, (int)(sizeof(outline) / sizeof(outline[0])));

        SDL_Point body[] = {
            tb_disp_cursor_point(cx, cy, size, 16, 5),
            tb_disp_cursor_point(cx, cy, size, 20, 8),
            tb_disp_cursor_point(cx, cy, size, 17, 8),
            tb_disp_cursor_point(cx, cy, size, 17, 24),
            tb_disp_cursor_point(cx, cy, size, 20, 24),
            tb_disp_cursor_point(cx, cy, size, 16, 27),
            tb_disp_cursor_point(cx, cy, size, 12, 24),
            tb_disp_cursor_point(cx, cy, size, 15, 24),
            tb_disp_cursor_point(cx, cy, size, 15, 8),
            tb_disp_cursor_point(cx, cy, size, 12, 8)
        };
        SDL_SetRenderDrawColor(d->ren, 0, 0, 0, 255);
        tb_disp_fill_poly(d->ren, body, (int)(sizeof(body) / sizeof(body[0])));
        tb_disp_draw_poly_outline(d->ren, body, (int)(sizeof(body) / sizeof(body[0])));
    }
    else if (d->cursor_type == 6) {
        /* Crosshair */
        /* Draw Shadow */
        SDL_SetRenderDrawColor(d->ren, 0, 0, 0, 70);
        int sx_off = 1, sy_off = 2;
        draw_scaled_rect(d->ren, x + sx_off, y + sy_off, size, -15, -2, -2, 2);
        draw_scaled_rect(d->ren, x + sx_off, y + sy_off, size, 2, -2, 15, 2);
        draw_scaled_rect(d->ren, x + sx_off, y + sy_off, size, -2, -15, 2, -2);
        draw_scaled_rect(d->ren, x + sx_off, y + sy_off, size, -2, 2, 2, 15);
        
        /* Draw Outline (White) */
        SDL_SetRenderDrawColor(d->ren, 255, 255, 255, 255);
        draw_scaled_rect(d->ren, x, y, size, -15, -2, -2, 2);
        draw_scaled_rect(d->ren, x, y, size, 2, -2, 15, 2);
        draw_scaled_rect(d->ren, x, y, size, -2, -15, 2, -2);
        draw_scaled_rect(d->ren, x, y, size, -2, 2, 2, 15);
        
        /* Draw Body (Black) */
        SDL_SetRenderDrawColor(d->ren, 0, 0, 0, 255);
        draw_scaled_rect(d->ren, x, y, size, -14, -1, -3, 1);
        draw_scaled_rect(d->ren, x, y, size, 3, -1, 14, 1);
        draw_scaled_rect(d->ren, x, y, size, -1, -14, 1, -3);
        draw_scaled_rect(d->ren, x, y, size, -1, 3, 1, 14);
    }
    else if (d->cursor_type == 7) {
        /* Northwest-Southeast diagonal resize cursor (NWSE) */
        const int cx = x - tb_disp_cursor_scale(size, 16);
        const int cy = y - tb_disp_cursor_scale(size, 16);
        SDL_Point shadow[] = {
            tb_disp_cursor_point(cx + 2, cy + 3, size, 4, 4),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 12, 4),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 10, 7),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 22, 19),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 28, 20),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 28, 28),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 20, 28),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 22, 25),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 10, 13),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 4, 12)
        };
        SDL_SetRenderDrawColor(d->ren, 0, 0, 0, 70);
        tb_disp_fill_poly(d->ren, shadow, (int)(sizeof(shadow) / sizeof(shadow[0])));

        SDL_Point outline[] = {
            tb_disp_cursor_point(cx, cy, size, 4, 4),
            tb_disp_cursor_point(cx, cy, size, 12, 4),
            tb_disp_cursor_point(cx, cy, size, 10, 7),
            tb_disp_cursor_point(cx, cy, size, 22, 19),
            tb_disp_cursor_point(cx, cy, size, 28, 20),
            tb_disp_cursor_point(cx, cy, size, 28, 28),
            tb_disp_cursor_point(cx, cy, size, 20, 28),
            tb_disp_cursor_point(cx, cy, size, 22, 25),
            tb_disp_cursor_point(cx, cy, size, 10, 13),
            tb_disp_cursor_point(cx, cy, size, 4, 12)
        };
        SDL_SetRenderDrawColor(d->ren, 255, 255, 255, 255);
        tb_disp_fill_poly(d->ren, outline, (int)(sizeof(outline) / sizeof(outline[0])));
        tb_disp_draw_poly_outline(d->ren, outline, (int)(sizeof(outline) / sizeof(outline[0])));

        SDL_Point body[] = {
            tb_disp_cursor_point(cx, cy, size, 7, 7),
            tb_disp_cursor_point(cx, cy, size, 12, 7),
            tb_disp_cursor_point(cx, cy, size, 10, 9),
            tb_disp_cursor_point(cx, cy, size, 21, 20),
            tb_disp_cursor_point(cx, cy, size, 25, 20),
            tb_disp_cursor_point(cx, cy, size, 25, 25),
            tb_disp_cursor_point(cx, cy, size, 20, 25),
            tb_disp_cursor_point(cx, cy, size, 22, 23),
            tb_disp_cursor_point(cx, cy, size, 11, 12),
            tb_disp_cursor_point(cx, cy, size, 7, 12)
        };
        SDL_SetRenderDrawColor(d->ren, 0, 0, 0, 255);
        tb_disp_fill_poly(d->ren, body, (int)(sizeof(body) / sizeof(body[0])));
        tb_disp_draw_poly_outline(d->ren, body, (int)(sizeof(body) / sizeof(body[0])));
    }
    else if (d->cursor_type == 8) {
        /* Northeast-Southwest diagonal resize cursor (NESW) */
        const int cx = x - tb_disp_cursor_scale(size, 16);
        const int cy = y - tb_disp_cursor_scale(size, 16);
        SDL_Point shadow[] = {
            tb_disp_cursor_point(cx + 2, cy + 3, size, 28, 4),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 20, 4),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 22, 7),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 10, 19),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 4, 20),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 4, 28),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 12, 28),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 10, 25),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 22, 13),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 28, 12)
        };
        SDL_SetRenderDrawColor(d->ren, 0, 0, 0, 70);
        tb_disp_fill_poly(d->ren, shadow, (int)(sizeof(shadow) / sizeof(shadow[0])));

        SDL_Point outline[] = {
            tb_disp_cursor_point(cx, cy, size, 28, 4),
            tb_disp_cursor_point(cx, cy, size, 20, 4),
            tb_disp_cursor_point(cx, cy, size, 22, 7),
            tb_disp_cursor_point(cx, cy, size, 10, 19),
            tb_disp_cursor_point(cx, cy, size, 4, 20),
            tb_disp_cursor_point(cx, cy, size, 4, 28),
            tb_disp_cursor_point(cx, cy, size, 12, 28),
            tb_disp_cursor_point(cx, cy, size, 10, 25),
            tb_disp_cursor_point(cx, cy, size, 22, 13),
            tb_disp_cursor_point(cx, cy, size, 28, 12)
        };
        SDL_SetRenderDrawColor(d->ren, 255, 255, 255, 255);
        tb_disp_fill_poly(d->ren, outline, (int)(sizeof(outline) / sizeof(outline[0])));
        tb_disp_draw_poly_outline(d->ren, outline, (int)(sizeof(outline) / sizeof(outline[0])));

        SDL_Point body[] = {
            tb_disp_cursor_point(cx, cy, size, 25, 7),
            tb_disp_cursor_point(cx, cy, size, 20, 7),
            tb_disp_cursor_point(cx, cy, size, 22, 9),
            tb_disp_cursor_point(cx, cy, size, 11, 20),
            tb_disp_cursor_point(cx, cy, size, 7, 20),
            tb_disp_cursor_point(cx, cy, size, 7, 25),
            tb_disp_cursor_point(cx, cy, size, 12, 25),
            tb_disp_cursor_point(cx, cy, size, 10, 23),
            tb_disp_cursor_point(cx, cy, size, 21, 12),
            tb_disp_cursor_point(cx, cy, size, 25, 12)
        };
        SDL_SetRenderDrawColor(d->ren, 0, 0, 0, 255);
        tb_disp_fill_poly(d->ren, body, (int)(sizeof(body) / sizeof(body[0])));
        tb_disp_draw_poly_outline(d->ren, body, (int)(sizeof(body) / sizeof(body[0])));
    }
    else {
        /* Default: Arrow (Type 0, 5, or fallback) */
        SDL_Point shadow[] = {
            tb_disp_cursor_point(x + 2, y + 3, size, 0, 0),
            tb_disp_cursor_point(x + 2, y + 3, size, 0, 33),
            tb_disp_cursor_point(x + 2, y + 3, size, 7, 25),
            tb_disp_cursor_point(x + 2, y + 3, size, 13, 38),
            tb_disp_cursor_point(x + 2, y + 3, size, 20, 35),
            tb_disp_cursor_point(x + 2, y + 3, size, 14, 22),
            tb_disp_cursor_point(x + 2, y + 3, size, 24, 22)
        };
        SDL_SetRenderDrawColor(d->ren, 0, 0, 0, 70);
        tb_disp_fill_poly(d->ren, shadow, (int)(sizeof(shadow) / sizeof(shadow[0])));

        SDL_Point outline[] = {
            tb_disp_cursor_point(x, y, size, 0, 0),
            tb_disp_cursor_point(x, y, size, 0, 33),
            tb_disp_cursor_point(x, y, size, 7, 25),
            tb_disp_cursor_point(x, y, size, 13, 38),
            tb_disp_cursor_point(x, y, size, 20, 35),
            tb_disp_cursor_point(x, y, size, 14, 22),
            tb_disp_cursor_point(x, y, size, 24, 22)
        };
        SDL_SetRenderDrawColor(d->ren, 255, 255, 255, 255);
        tb_disp_fill_poly(d->ren, outline, (int)(sizeof(outline) / sizeof(outline[0])));
        tb_disp_draw_poly_outline(d->ren, outline, (int)(sizeof(outline) / sizeof(outline[0])));

        SDL_Point body[] = {
            tb_disp_cursor_point(x, y, size, 3, 5),
            tb_disp_cursor_point(x, y, size, 3, 27),
            tb_disp_cursor_point(x, y, size, 8, 21),
            tb_disp_cursor_point(x, y, size, 14, 34),
            tb_disp_cursor_point(x, y, size, 16, 33),
            tb_disp_cursor_point(x, y, size, 11, 20),
            tb_disp_cursor_point(x, y, size, 19, 20)
        };
        SDL_SetRenderDrawColor(d->ren, 0, 0, 0, 255);
        tb_disp_fill_poly(d->ren, body, (int)(sizeof(body) / sizeof(body[0])));
        tb_disp_draw_poly_outline(d->ren, body, (int)(sizeof(body) / sizeof(body[0])));
    }

    SDL_SetRenderDrawBlendMode(d->ren, old_blend);
}

static void tb_disp_render_current(struct tb_display *d) {
    if (!d || !d->tex) return;
    SDL_RenderClear(d->ren);
    SDL_RenderCopy(d->ren, d->tex, NULL, NULL);
    tb_disp_draw_cursor(d);
    SDL_RenderPresent(d->ren);
}

void tb_disp_render_nv12(struct tb_display *d,
                         const uint8_t *y, int y_stride,
                         const uint8_t *uv, int uv_stride,
                         int w, int h) {
    if (tb_disp_ensure_texture(d, w, h) < 0) return;
    tb_disp_set_connection_state(d, 1);

    if (SDL_UpdateNVTexture(d->tex, NULL,
                            y,  y_stride,
                            uv, uv_stride) < 0) {
        fprintf(stderr, "[disp] UpdateNVTexture: %s\n", SDL_GetError());
        return;
    }
    d->last_video_frame_time = SDL_GetTicks();
    tb_disp_render_current(d);
}

void tb_disp_set_cursor(struct tb_display *d,
                        int x, int y,
                        int source_w, int source_h,
                        int visible,
                        int type) {
    if (!d) return;
    d->cursor_x = x;
    d->cursor_y = y;
    d->cursor_source_w = source_w > 0 ? source_w : 1;
    d->cursor_source_h = source_h > 0 ? source_h : 1;
    d->cursor_visible = visible;
    d->cursor_type = type;

    uint32_t now = SDL_GetTicks();
    if (now - d->last_video_frame_time > 40) {
        if (d->is_connected && d->tex) {
            tb_disp_render_current(d);
        }
    }
}

int tb_disp_poll_quit(struct tb_display *d) {
    SDL_Event ev;
    while (SDL_PollEvent(&ev)) {
        if (ev.type == SDL_QUIT) d->quit = 1;
        else if (ev.type == SDL_KEYDOWN &&
                 ev.key.keysym.sym == SDLK_ESCAPE) d->quit = 1;
    }
    return d->quit;
}

int tb_disp_get_info(struct tb_display *d, struct tb_display_info *info) {
    if (!d || !info || !d->win || !d->ren) return -1;

    memset(info, 0, sizeof(*info));

    int display_index = SDL_GetWindowDisplayIndex(d->win);
    if (display_index < 0) display_index = 0;

    SDL_DisplayMode mode;
    if (SDL_GetCurrentDisplayMode(display_index, &mode) == 0) {
        info->active_w = (uint32_t)mode.w;
        info->active_h = (uint32_t)mode.h;
    }

    int window_w = 0, window_h = 0;
    int drawable_w = 0, drawable_h = 0;
    SDL_GetWindowSize(d->win, &window_w, &window_h);
    if (SDL_GetRendererOutputSize(d->ren, &drawable_w, &drawable_h) == 0) {
        info->drawable_w = (uint32_t)drawable_w;
        info->drawable_h = (uint32_t)drawable_h;
    }

    /* On Retina/5K macOS displays SDL_GetCurrentDisplayMode may report the
     * logical desktop size (for example 2560x1440) while the renderer
     * drawable exposes the true backing pixel size (for example 5120x2880).
     * For the TB stream UI we want the actual panel pixel size. */
    if (info->drawable_w > info->active_w) info->active_w = info->drawable_w;
    if (info->drawable_h > info->active_h) info->active_h = info->drawable_h;

    info->window_w = (uint32_t)window_w;
    info->window_h = (uint32_t)window_h;

    const char *name = SDL_GetDisplayName(display_index);
    if (!name) name = "Receiver Display";
    snprintf(info->name, sizeof(info->name), "%s", name);
    return 0;
}

void tb_disp_set_connection_state(struct tb_display *d, int connected) {
    if (!d) return;
    if (d->is_connected == connected) return;
    d->is_connected = connected;
    tb_disp_refresh_window_mode(d);
}

void tb_disp_render_status(struct tb_display *d,
                           const char *ip,
                           const char *status,
                           const char *sender,
                           const char *panel,
                           const char *mode) {
    if (!d || !d->ren || !d->win) return;

    tb_disp_set_connection_state(d, 0);

    if (!ip) ip = "not detected";
    if (!status) status = "waiting for sender";
    if (!sender) sender = "waiting";
    if (!panel) panel = "unknown display";
    if (!mode) mode = "2560 x 1440 HiDPI on 5K display";

    int drawable_w = 0, drawable_h = 0;
    if (SDL_GetRendererOutputSize(d->ren, &drawable_w, &drawable_h) < 0 ||
        drawable_w <= 0 || drawable_h <= 0) {
        drawable_w = 980;
        drawable_h = 620;
    }

    if (strcmp(d->last_ip, ip) != 0 ||
        strcmp(d->last_status, status) != 0 ||
        strcmp(d->last_sender, sender) != 0 ||
        strcmp(d->last_panel, panel) != 0 ||
        strcmp(d->last_mode, mode) != 0 ||
        d->last_drawable_w != drawable_w ||
        d->last_drawable_h != drawable_h ||
        d->status_tex == NULL) {
        snprintf(d->last_ip, sizeof(d->last_ip), "%s", ip);
        snprintf(d->last_status, sizeof(d->last_status), "%s", status);
        snprintf(d->last_sender, sizeof(d->last_sender), "%s", sender);
        snprintf(d->last_panel, sizeof(d->last_panel), "%s", panel);
        snprintf(d->last_mode, sizeof(d->last_mode), "%s", mode);
        d->last_drawable_w = drawable_w;
        d->last_drawable_h = drawable_h;
        tb_disp_rebuild_status_texture(d, ip, status, sender, panel, mode, drawable_w, drawable_h);
    }

    char title[256];
    snprintf(title, sizeof(title), "TBDisplayReceiverC %s — IP %s — %s", TB_RECEIVER_VERSION, ip, status);
    SDL_SetWindowTitle(d->win, title);

    SDL_RenderClear(d->ren);
    if (d->status_tex) SDL_RenderCopy(d->ren, d->status_tex, NULL, NULL);
    SDL_RenderPresent(d->ren);
}
