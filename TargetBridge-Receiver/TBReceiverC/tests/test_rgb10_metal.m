/* Optional GUI/Metal smoke test. Synthetic pixels only: no capture, network,
 * fullscreen, input hooks, or display-setting changes. Like test_monitor_shield,
 * include the implementation to inspect the private output surface directly.
 * --presentation-only runs small RAW drawable checks without the 4.5K upload check. */
#import <Metal/Metal.h>
static void capture_presented_texture(id<MTLCommandBuffer> command, id<MTLTexture> texture);
#define TB_METAL_PLANE_TEST_CAPTURE capture_presented_texture
#import "../src/tb_metal_plane.m"
#undef TB_METAL_PLANE_TEST_CAPTURE
#include <assert.h>

static struct {
    int enabled, captures;
    NSUInteger width, height, row_bytes;
    id<MTLBuffer> pixels;
    id<MTLCommandBuffer> command;
} presentation_readback;

/* Appended after the production render pass, before present, on its actual
 * command buffer. This reads the drawable rather than the input upload buffer.
 * It deliberately cannot observe Core Animation, color management or scanout. */
static void capture_presented_texture(id<MTLCommandBuffer> command, id<MTLTexture> texture) {
    if (!presentation_readback.enabled) return;
    assert(texture.pixelFormat == MTLPixelFormatBGR10A2Unorm);
    assert(!presentation_readback.command && !presentation_readback.pixels);
    presentation_readback.width = texture.width;
    presentation_readback.height = texture.height;
    presentation_readback.row_bytes = (texture.width * 4 + 255) & ~(NSUInteger)255;
    presentation_readback.pixels = [g.dev newBufferWithLength:
        presentation_readback.row_bytes * texture.height options:MTLResourceStorageModeShared];
    assert(presentation_readback.pixels);
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    assert(blit);
    [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0
            sourceOrigin:MTLOriginMake(0, 0, 0)
              sourceSize:MTLSizeMake(texture.width, texture.height, 1)
                toBuffer:presentation_readback.pixels destinationOffset:0
     destinationBytesPerRow:presentation_readback.row_bytes
   destinationBytesPerImage:presentation_readback.row_bytes * texture.height];
    [blit endEncoding];
    presentation_readback.command = command;
    ++presentation_readback.captures;
}

static void test_rgb10_presentation(int width, int height) {
    const int stride = width * 4 + 64;
    uint8_t *source = malloc((size_t)stride * height);
    assert(source);
    const char *names[] = {"1024-level ramps", "one-pixel checkerboard", "isolated pixels"};
    tb_metal_plane_set_cursor(0, 0, width, height, 0, 0, 0);
    for (int pattern = 0; pattern < 3; ++pattern) {
        memset(source, 0xa5, (size_t)stride * height);
        for (int y = 0; y < height; ++y) {
            uint32_t *row = (uint32_t *)(source + (size_t)y * stride);
            for (int x = 0; x < width; ++x) {
                uint32_t rgb = 0;
                if (pattern == 0) {
                    const uint32_t level = (uint32_t)(x + y) & 1023u;
                    rgb = level | (((level * 17u + 7u) & 1023u) << 10) |
                        ((1023u - level) << 20);
                } else if (pattern == 1) {
                    rgb = (x + y) & 1 ? 0x3fffffffu : 0;
                } else if ((x == 0 && y == 0) || (x == width - 1 && y == height - 1) ||
                           (x == width / 2 && y == height / 2)) {
                    rgb = 0x3fffffffu;
                } else if (x == width / 2 + 3 && y == height / 2) {
                    rgb = 1u | (2u << 10) | (3u << 20);
                }
                row[x] = 0xc0000000u | rgb;
            }
        }
        presentation_readback.captures = 0;
        presentation_readback.enabled = 1;
        assert(tb_metal_plane_render_packed(source, stride, width, height, 1) == 0);
        presentation_readback.enabled = 0;
        assert(presentation_readback.captures == 1);
        assert(presentation_readback.width == (NSUInteger)width);
        assert(presentation_readback.height == (NSUInteger)height);
        [presentation_readback.command waitUntilCompleted];
        assert(presentation_readback.command.status == MTLCommandBufferStatusCompleted);
        for (int y = 0; y < height; ++y) {
            const uint32_t *expected = (const uint32_t *)(source + (size_t)y * stride);
            const uint32_t *actual = (const uint32_t *)((const uint8_t *)presentation_readback.pixels.contents +
                (size_t)y * presentation_readback.row_bytes);
            for (int x = 0; x < width; ++x) {
                if (actual[x] != expected[x]) {
                    fprintf(stderr, "RAW drawable %s %dx%d mismatch (%d,%d): expected=%08x actual=%08x\n",
                            names[pattern], width, height, x, y, expected[x], actual[x]);
                    abort();
                }
            }
        }
        printf("RAW drawable %s %dx%d: %d pixels match exactly\n",
               names[pattern], width, height, width * height);
        presentation_readback.command = nil;
        presentation_readback.pixels = nil;
    }
    free(source);
}

static void pump(void) {
    SDL_PumpEvents();
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:0.02];
    [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:end];
}


static void test_packed_rgb10(int width, int height) {
    /* A padded borrowed RAW frame must be copied before the network parser
     * reuses its storage, while preserving every RGB bit and both alpha bits. */
    const int stride = width * 4 + 64;
    uint8_t *pixels = malloc((size_t)stride * height);
    assert(pixels);
    memset(pixels, 0xA5, (size_t)stride * height);
    for (int y = 0; y < height; ++y) {
        uint32_t *row = (uint32_t *)(pixels + (size_t)y * stride);
        for (int x = 0; x < width; ++x) {
            const uint32_t v = (uint32_t)(x + y) & 1023;
            row[x] = ((uint32_t)x & 3u) << 30 | v | ((1023u - v) << 10) |
                     (((v + 29u) & 1023u) << 20);
        }
    }
    assert(tb_metal_plane_render_packed(pixels, stride, width, height, 1) == 0);
    memset(pixels, 0, (size_t)stride * height);
    free(pixels);
    const int slot = (g.ring_idx + TB_UPLOAD_RING - 1) % TB_UPLOAD_RING;
    for (int y = 0; y < height; ++y) {
        const uint32_t *row = (const uint32_t *)((const uint8_t *)g.ring[slot].contents + (size_t)y * g.frame_bpr);
        for (int x = 0; x < width; ++x) {
            const uint32_t v = (uint32_t)(x + y) & 1023;
            const uint32_t expected = ((uint32_t)x & 3u) << 30 | v | ((1023u - v) << 10) |
                                      (((v + 29u) & 1023u) << 20);
            assert(row[x] == expected);
        }
    }
    id<MTLCommandBuffer> fence = [g.queue commandBuffer];
    [fence commit];
    [fence waitUntilCompleted];
    assert(fence.status == MTLCommandBufferStatusCompleted);
    assert(g.layer.pixelFormat == MTLPixelFormatBGR10A2Unorm);
}


static NSData *cursor_pixels(void) {
    tb_cursor_build(tb_cursor_scale());
    assert(g.curTex);
    NSMutableData *pixels = [NSMutableData dataWithLength:(size_t)g.cur_tex_w * g.cur_tex_h * 4];
    [g.curTex getBytes:pixels.mutableBytes bytesPerRow:(size_t)g.cur_tex_w * 4
           fromRegion:MTLRegionMake2D(0, 0, g.cur_tex_w, g.cur_tex_h) mipmapLevel:0];
    if (g.cursorLayer) {
        CGImageRef image = (__bridge CGImageRef)g.cursorLayer.contents;
        assert(image);
        CFDataRef layer_pixels = CGDataProviderCopyData(CGImageGetDataProvider(image));
        assert(CFDataGetLength(layer_pixels) == (CFIndex)pixels.length);
        assert(memcmp(CFDataGetBytePtr(layer_pixels), pixels.bytes, pixels.length) == 0);
        CFRelease(layer_pixels);
    }
    return pixels;
}

static void test_cursor_shapes(void) {
    tb_metal_plane_set_cursor(32, 32, 65, 65, 1, 0, 0);
    tb_metal_plane_flush_cursor();
    NSData *arrow = cursor_pixels();
    float arrow_hot_x = g.cur_hot_x, arrow_hot_y = g.cur_hot_y;
    tb_metal_plane_set_cursor(32, 32, 65, 65, 1, 1, 0);
    tb_metal_plane_flush_cursor();
    NSData *ibeam = cursor_pixels();
    assert(![arrow isEqualToData:ibeam]);
    assert(g.cur_hot_x != arrow_hot_x || g.cur_hot_y != arrow_hot_y);
    NSCursor *native = NSCursor.IBeamCursor;
    assert(fabs(g.cur_hot_x - native.hotSpot.x * g.cur_tex_w / native.image.size.width) < 0.001);
    assert(fabs(g.cur_hot_y - native.hotSpot.y * g.cur_tex_h / native.image.size.height) < 0.001);
    int normal_w = g.cur_tex_w, normal_h = g.cur_tex_h;
    tb_metal_plane_set_cursor(32, 32, 65, 65, 1, 1, 1);
    tb_metal_plane_flush_cursor();
    assert(![ibeam isEqualToData:cursor_pixels()]);
    assert(g.cur_tex_w > normal_w && g.cur_tex_h > normal_h);
    assert(fabs(g.cur_hot_x - native.hotSpot.x * g.cur_tex_w / native.image.size.width) < 0.001);
    assert(fabs(g.cur_hot_y - native.hotSpot.y * g.cur_tex_h / native.image.size.height) < 0.001);
    NSData *diagonal = nil;
    for (int type = 2; type <= 8; ++type) {
        tb_metal_plane_set_cursor(32, 32, 65, 65, 1, type, 0);
        tb_metal_plane_flush_cursor();
        NSData *pixels = cursor_pixels();
        assert(pixels.length > 0);
        if (type == 7) diagonal = pixels;
        if (type == 8) assert(![diagonal isEqualToData:pixels]);
    }
}

static void test_cursor_orientation(void) {
    /* The cursor quad's first vertices are its top edge. Keep image row zero
     * at that edge, matching CALayer contents and NSCursor's top-left hotspot. */
    const uint32_t colors[] = { 0xffff0000u, 0xff00ff00u, 0xff0000ffu, 0xffffffffu };
    MTLTextureDescriptor *input_desc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:2 height:2 mipmapped:NO];
    input_desc.storageMode = g.dev.hasUnifiedMemory ? MTLStorageModeShared : MTLStorageModeManaged;
    input_desc.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> input = [g.dev newTextureWithDescriptor:input_desc];
    assert(input);
    [input replaceRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:0
               withBytes:colors bytesPerRow:8];
    MTLTextureDescriptor *output_desc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:2 height:2 mipmapped:NO];
    output_desc.storageMode = MTLStorageModePrivate;
    output_desc.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> output = [g.dev newTextureWithDescriptor:output_desc];
    assert(output);
    NSError *error = nil;
    id<MTLLibrary> library = [g.dev newLibraryWithSource:tb_shader_source() options:nil error:&error];
    assert(library);
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"tb_cursor_vs"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"tb_cursor_fs"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    id<MTLRenderPipelineState> pipeline = [g.dev newRenderPipelineStateWithDescriptor:descriptor error:&error];
    assert(pipeline);
    id<MTLCommandBuffer> cb = [g.queue commandBuffer];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = output;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> render = [cb renderCommandEncoderWithDescriptor:pass];
    const float rect[] = { -1, 1, 1, -1 };
    [render setRenderPipelineState:pipeline];
    [render setVertexBytes:rect length:sizeof rect atIndex:0];
    [render setFragmentTexture:input atIndex:0];
    [render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [render endEncoding];
    id<MTLBuffer> result = [g.dev newBufferWithLength:512 options:MTLResourceStorageModeShared];
    assert(result);
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:output sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
              sourceSize:MTLSizeMake(2,2,1) toBuffer:result destinationOffset:0
              destinationBytesPerRow:256 destinationBytesPerImage:512];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    assert(cb.status == MTLCommandBufferStatusCompleted);
    assert(memcmp(result.contents, colors, 8) == 0);
    assert(memcmp((uint8_t *)result.contents + 256, colors + 2, 8) == 0);
}

@interface TBFailingUploadDevice : NSObject
@property NSUInteger attempts;
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options;
@end
@implementation TBFailingUploadDevice
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options {
    (void)length; (void)options;
    ++_attempts;
    return nil;
}
@end

/* Model three submitted slots by withholding their permits. A failed command
 * creation must retry the one unused slot, never overwrite a submitted slot.
 * The production upload, copy and failure cleanup execute against real buffers. */
static void test_failed_present_preserves_upload_slots(void) {
    id<MTLCommandBuffer> fence = [g.queue commandBuffer];
    [fence commit];
    [fence waitUntilCompleted];
    assert(fence.status == MTLCommandBufferStatusCompleted);
    tb_geometry_set(64, 4);
    const size_t bytes = g.frame_bpr * 4;
    for (int slot = 0; slot < TB_UPLOAD_RING - 1; ++slot) {
        g.ring[slot] = [g.dev newBufferWithLength:bytes options:MTLResourceStorageModeShared];
        assert(g.ring[slot]);
        g.ring_cap[slot] = bytes;
        memset(g.ring[slot].contents, 0x7f, bytes);
    }
    id<MTLCommandQueue> queue = g.queue;
    dispatch_semaphore_t permits = g.inflight;
    g.inflight = dispatch_semaphore_create(1);
    g.ring_idx = TB_UPLOAD_RING - 1;
    uint32_t pixels[64 * 4];
    memset(pixels, 0x31, sizeof(pixels));
    id<MTLDevice> device = g.dev;
    TBFailingUploadDevice *failed_device = [TBFailingUploadDevice new];
    g.dev = (id<MTLDevice>)failed_device;
    g.ring[TB_UPLOAD_RING - 1] = nil;
    g.ring_cap[TB_UPLOAD_RING - 1] = 0;
    for (int retry = 0; retry < 4; ++retry) {
        assert(tb_metal_plane_render_packed((const uint8_t *)pixels, 64 * 4, 64, 4, 1) == -1);
        assert(g.ring_idx == TB_UPLOAD_RING - 1);
    }
    assert(failed_device.attempts == 4);
    g.dev = device;
    g.queue = nil; /* Deterministic command-buffer creation failure. */
    for (int retry = 0; retry < 8; ++retry) {
        assert(tb_metal_plane_render_packed((const uint8_t *)pixels, 64 * 4, 64, 4, 1) == -1);
        assert(g.ring_idx == TB_UPLOAD_RING - 1);
        for (int slot = 0; slot < TB_UPLOAD_RING - 1; ++slot) {
            const uint8_t *held = g.ring[slot].contents;
            for (size_t i = 0; i < bytes; ++i) assert(held[i] == 0x7f);
        }
    }
    assert(dispatch_semaphore_wait(g.inflight, DISPATCH_TIME_NOW) == 0);
    assert(dispatch_semaphore_wait(g.inflight, DISPATCH_TIME_NOW) != 0);
    dispatch_semaphore_signal(g.inflight);
    g.inflight = permits;
    g.queue = queue;
    g.ring_idx = 0;
    puts("Metal RAW: failed presentation retries preserve occupied upload slots");
}

static void test_resource_limit(void) {
    const uint32_t pixel = 0xffffffffu;
    assert(tb_metal_plane_render_packed((const uint8_t *)&pixel, 16384 * 4, 16384, 8192, 1) == -1);
    assert(tb_metal_plane_render_packed((const uint8_t *)&pixel, 5121 * 4, 5121, 1, 1) == -1);
    assert(g.frame_w == 0 && g.frame_h == 0);
    for (int i = 0; i < TB_UPLOAD_RING; ++i) assert(!g.ring[i]);
}

int main(int argc, char **argv) {
    const int presentation_only = argc == 2 && strcmp(argv[1], "--presentation-only") == 0;
    if (argc != 1 && !presentation_only) {
        fprintf(stderr, "usage: %s [--presentation-only]\n", argv[0]);
        return 2;
    }
    @autoreleasepool {
        [NSApplication sharedApplication];
        assert(!tb_metal_plane_available());
        tb_metal_plane_set_cursor(12, 34, 1024, 768, 1, 0, 0);
        assert(g.cur_visible && g.cur_x == 12 && g.cur_y == 34);
        assert(g.cur_sw == 1024 && g.cur_sh == 768);
        tb_metal_plane_set_cursor(0, 0, 0, -1, 0, 0, 0);
        assert(!g.cur_visible && g.cur_sw == 1 && g.cur_sh == 1);
        assert(SDL_Init(SDL_INIT_VIDEO) == 0);
        SDL_SetHint(SDL_HINT_RENDER_DRIVER, "opengl");
        SDL_Window *window = SDL_CreateWindow("TargetBridge synthetic RAW test",
            SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, 320, 180,
            SDL_WINDOW_ALLOW_HIGHDPI);
        assert(window);
        SDL_Renderer *renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED);
        assert(renderer);
        assert(tb_metal_plane_supports_packed());
        assert(!tb_metal_plane_available());
        for (int cycle = 0; cycle < 2; ++cycle) {
            assert(tb_metal_plane_init(window) == 0);
            assert(!g.shown && g.layer.hidden && [(__bridge NSView *)g.view isHidden]);
            if (presentation_only) {
                test_rgb10_presentation(1024, 16);
                test_rgb10_presentation(65, 65);
                tb_metal_plane_set_hidden(1);
                assert(!tb_metal_plane_available() && !g.view);
                continue;
            }
            const uint32_t pixel = 0xFFFFFFFF;
            assert(tb_metal_plane_render_packed((const uint8_t *)&pixel, 3, 1, 1, 1) == -1);
            test_resource_limit();
            test_failed_present_preserves_upload_slots();
            test_cursor_orientation();
            tb_metal_plane_set_cursor(32, 2, 1024, 4, 1, 0, 0);
            /* All 1024 values, including the low two bits, in every channel. */
            test_packed_rgb10(1024, 4);
            assert(g.curTex); /* The first frame uses the render-pass cursor. */
            tb_metal_plane_set_hidden(0);
            assert(g.shown && !g.layer.hidden && ![(__bridge NSView *)g.view isHidden]);
            const char *cursor_plane = getenv("TB_CURSOR_PLANE");
            if (cursor_plane && cursor_plane[0] == '0') assert(!g.cursorLayer);
            pump();

            test_cursor_shapes();
            /* Full 4.5K packed frame. */
            test_packed_rgb10(1024, 4);
            test_packed_rgb10(4480, 2520);
            test_rgb10_presentation(1024, 16);
            test_rgb10_presentation(65, 65);
            tb_metal_plane_set_hidden(1);
            assert(!tb_metal_plane_available() && !g.view);
            SDL_SetRenderDrawColor(renderer, 24, 48, 96, 255);
            assert(SDL_RenderClear(renderer) == 0);
            SDL_RenderPresent(renderer);
            pump();
        }
        SDL_DestroyRenderer(renderer);
        SDL_DestroyWindow(window);
        SDL_Quit();
        if (presentation_only) {
            puts("Metal RAW presentation: exact 1:1 RGB10 drawable ramps/checkers/isolated pixels passed; Core Animation and panel output not checked");
        } else {
            puts("Metal RAW: packed upload, exact drawable RGB10, cursor and bounded resource lifecycle passed");
        }
    }
    return 0;
}
