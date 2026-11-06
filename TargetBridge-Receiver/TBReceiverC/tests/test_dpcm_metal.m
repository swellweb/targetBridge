/* Optional GUI/Metal smoke test. Synthetic pixels only: no capture, network,
 * fullscreen, input hooks, or display-setting changes. Like test_monitor_shield,
 * include the implementation to inspect the private output surface directly. */
#import "../src/tb_metal_plane.m"
#include <assert.h>

static void pump(void) {
    SDL_PumpEvents();
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:0.02];
    [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:end];
}

static uint32_t get_le32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 |
           (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static void test_decode_variant(int width, int height, int ten_bit,
                                int adaptive, int mixed_tiles) {
    size_t pixel_bytes = (size_t)width * height * 4;
    uint32_t *pixels = malloc(pixel_bytes);
    uint32_t mask = ten_bit ? 1023u : 255u;
    int bits = ten_bit ? 10 : 8;
    uint32_t alpha = ten_bit ? 3u << 30 : 255u << 24;
    assert(pixels);
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            uint32_t b = (uint32_t)(x + y) & mask;
            uint32_t green = (uint32_t)(x * 17 + y * 29) & mask;
            uint32_t red = (uint32_t)(x * 31 + y * 7) & mask;
            if (adaptive) {
                green = (uint32_t)(x + y * 29) & mask;
                b = (green + 31) & mask;
                red = (green + mask - 7) & mask;
                if (mixed_tiles && ((x / TB_DPCM_TILE + y / TB_DPCM_TILE) & 1)) {
                    /* Here RGB residuals need fewer bits than B-G/R-G, so
                     * these tiles must retain the original coding space. */
                    b = (uint32_t)((x % TB_DPCM_TILE) + (y % TB_DPCM_TILE) * TB_DPCM_TILE);
                    green = mask - b;
                    red = b;
                }
            }
            pixels[(size_t)y * width + x] = alpha | b | (green << bits) | (red << (2 * bits));
        }
    }
    size_t capacity = tb_dpcm_max_size(width, height);
    uint8_t *blob = malloc(capacity);
    uint8_t *reference = malloc(pixel_bytes);
    assert(blob && reference);
    size_t length = adaptive
        ? tb_dpcm_encode_adaptive((const uint8_t *)pixels, width * 4,
                                  width, height, ten_bit, blob, capacity)
        : tb_dpcm_encode((const uint8_t *)pixels, width * 4,
                         width, height, ten_bit, blob, capacity);
    struct tb_dpcm_info info;
    assert(length && tb_dpcm_parse(blob, length, &info) == 0);
    assert(info.adaptive_color == adaptive);
    if (adaptive) {
        unsigned transformed = 0;
        for (uint32_t tile = 0; tile < info.tile_count; ++tile) {
            if (get_le32(blob + info.seed_plane_off + (size_t)tile * 4) &
                TB_DPCM_SEED_ADAPTIVE_COLOR) ++transformed;
        }
        assert(transformed > 0);
        if (mixed_tiles) assert(transformed < info.tile_count);
    }
    assert(tb_metal_plane_accepts_dpcm(blob, length));
    assert(length && tb_dpcm_decode(blob, length, reference, width * 4) == 0);
    assert(memcmp(pixels, reference, pixel_bytes) == 0);
    assert(tb_metal_plane_render_dpcm(blob, length) == 0);

    int rendered = (g.frame_widx + TB_FRAME_RING - 1) % TB_FRAME_RING;
    size_t bytes = g.frame_bpr * (size_t)height;
    id<MTLBuffer> readback = [g.dev newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    assert(readback);
    id<MTLCommandBuffer> cb = [g.queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromBuffer:g.frame[rendered] sourceOffset:0
               toBuffer:readback destinationOffset:0 size:bytes];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    assert(cb.status == MTLCommandBufferStatusCompleted);
    for (int y = 0; y < height; ++y) {
        assert(memcmp((uint8_t *)readback.contents + (size_t)y * g.frame_bpr,
                      reference + (size_t)y * width * 4, (size_t)width * 4) == 0);
    }
    assert(g.layer.pixelFormat == MTLPixelFormatBGR10A2Unorm);
    free(reference);
    free(blob);
    free(pixels);
}

static void test_decode(int width, int height, int ten_bit) {
    test_decode_variant(width, height, ten_bit, 0, 0);
}

static void put_le32(uint8_t *p, uint32_t value) {
    p[0] = value; p[1] = value >> 8; p[2] = value >> 16; p[3] = value >> 24;
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

/* Reserve permits to model older GPU submissions still owning their slots.
 * Only failure boundaries are substituted; upload, decode and recovery use
 * real Metal buffers and the production rendering entry points. */
@interface TBRingFailDevice : NSObject
@property(nonatomic) int attempts;
@end
@implementation TBRingFailDevice
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options {
    (void)length; (void)options; ++_attempts; return nil;
}
@end

@interface TBRingFailBuffer : NSObject
@property(nonatomic, strong) id<MTLBuffer> real;
@end
@implementation TBRingFailBuffer
- (id)forwardingTargetForSelector:(SEL)selector { return self.real; }
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor
                                  offset:(NSUInteger)offset bytesPerRow:(NSUInteger)stride {
    (void)descriptor; (void)offset; (void)stride; return nil;
}
@end

@interface TBRingFailCommand : NSObject
@property(nonatomic, strong) id<MTLCommandBuffer> real;
@property(nonatomic) int failure;
@end
@implementation TBRingFailCommand
- (id)forwardingTargetForSelector:(SEL)selector { return self.real; }
- (void)addCompletedHandler:(MTLCommandBufferHandler)handler {
    const int failure = self.failure;
    [self.real addCompletedHandler:^(id<MTLCommandBuffer> command) {
        fprintf(stderr, "injected command completion fault=%d status=%lu\n", failure, (unsigned long)command.status);
        handler(command);
    }];
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoder {
    return self.failure == 2 ? nil : [self.real computeCommandEncoder];
}
- (id<MTLRenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)descriptor {
    return self.failure == 3 ? nil : [self.real renderCommandEncoderWithDescriptor:descriptor];
}
@end

@interface TBRingFailQueue : NSObject
@property(nonatomic, strong) id<MTLCommandQueue> real;
@property(nonatomic) int calls, failAt, failure, drained;
@end
@implementation TBRingFailQueue
- (id<MTLCommandBuffer>)commandBuffer {
    if (++_calls != self.failAt) return [self.real commandBuffer];
    if (self.failure == 1) return nil;
    if (self.failure == 4) {
        while (dispatch_semaphore_wait(g.inflight, DISPATCH_TIME_NOW) == 0) ++_drained;
    }
    TBRingFailCommand *command = [TBRingFailCommand new];
    command.real = [self.real commandBuffer];
    command.failure = self.failure;
    return (id<MTLCommandBuffer>)command;
}
@end

static void ring_fence(id<MTLCommandQueue> queue) {
    id<MTLCommandBuffer> command = [queue commandBuffer];
    assert(command); [command commit]; [command waitUntilCompleted];
    assert(command.status == MTLCommandBufferStatusCompleted);
}

static void assert_one_permit(dispatch_semaphore_t sem) {
    assert(dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    assert(dispatch_semaphore_wait(sem, DISPATCH_TIME_NOW) != 0);
    dispatch_semaphore_signal(sem);
}

static void assert_held_uploads(size_t bytes) {
    for (int slot = 0; slot < TB_UPLOAD_RING - 1; ++slot) {
        const uint8_t *held = g.ring[slot].contents;
        for (size_t i = 0; i < bytes; ++i) assert(held[i] == 0x7f);
    }
}

static void test_failed_upload_keeps_free_slot(void) {
    id<MTLCommandQueue> queue = g.queue;
    id<MTLDevice> device = g.dev;
    CAMetalLayer *layer = g.layer;
    ring_fence(queue);
    tb_geometry_set(64, 4);
    const size_t bytes = g.frame_bpr * 4;
    for (int slot = 0; slot < TB_UPLOAD_RING - 1; ++slot) {
        g.ring[slot] = [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
        assert(g.ring[slot]); g.ring_cap[slot] = bytes;
        memset(g.ring[slot].contents, 0x7f, bytes);
    }
    dispatch_semaphore_t permits = g.inflight;
    g.inflight = dispatch_semaphore_create(1);
    const int free_slot = TB_UPLOAD_RING - 1;
    g.ring_idx = free_slot;
    g.ring[free_slot] = nil; g.ring_cap[free_slot] = 0;
    uint32_t pixels[64 * 4]; memset(pixels, 0x31, sizeof pixels);
    TBRingFailDevice *missing = [TBRingFailDevice new];
    g.dev = (id<MTLDevice>)missing;
    for (int retry = 0; retry < 4; ++retry) {
        assert(tb_metal_plane_render_packed((uint8_t *)pixels, 256, 64, 4, 1) == -1);
        assert(g.ring_idx == free_slot); assert_held_uploads(bytes); assert_one_permit(g.inflight);
    }
    assert(missing.attempts == 4); g.dev = device;
    for (int failure = 0; failure < 4; ++failure) {
        id<MTLBuffer> original = nil;
        TBRingFailQueue *failed_queue = [TBRingFailQueue new];
        failed_queue.real = queue; failed_queue.failAt = 1; failed_queue.failure = 3;
        if (failure == 0) g.queue = nil;
        if (failure == 1) g.layer = nil;
        if (failure == 2) {
            original = g.ring[free_slot];
            TBRingFailBuffer *failed_buffer = [TBRingFailBuffer new]; failed_buffer.real = original;
            g.ring[free_slot] = (id<MTLBuffer>)failed_buffer;
        }
        if (failure == 3) g.queue = (id<MTLCommandQueue>)failed_queue;
        for (int retry = 0; retry < 8; ++retry) {
            failed_queue.calls = 0;
            assert(tb_metal_plane_render_packed((uint8_t *)pixels, 256, 64, 4, 1) == -1);
            assert(g.ring_idx == free_slot); assert_held_uploads(bytes); assert_one_permit(g.inflight);
        }
        if (original) g.ring[free_slot] = original;
        g.queue = queue; g.layer = layer;
    }
    assert(tb_metal_plane_render_packed((uint8_t *)pixels, 256, 64, 4, 1) == 0);
    assert(g.ring_idx == 0);
    ring_fence(queue); assert_one_permit(g.inflight); assert_held_uploads(bytes);
    assert(memcmp(g.ring[free_slot].contents, pixels, sizeof pixels) == 0);
    g.inflight = permits;
    puts("Metal upload ring: allocation/command/drawable/texture/encoder failures preserve busy slots; recovery passed");
}

static void assert_held_frames(id<MTLCommandQueue> queue, size_t bytes) {
    id<MTLBuffer> readback = [g.dev newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    assert(readback);
    for (int slot = 0; slot < TB_FRAME_RING - 1; ++slot) {
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
        [blit copyFromBuffer:g.frame[slot] sourceOffset:0 toBuffer:readback destinationOffset:0 size:bytes];
        [blit endEncoding]; [command commit]; [command waitUntilCompleted];
        assert(command.status == MTLCommandBufferStatusCompleted);
        const uint8_t *held = readback.contents;
        for (size_t i = 0; i < bytes; ++i) assert(held[i] == 0x7f);
    }
}

static void test_failed_frame_present_keeps_free_slot(void) {
    id<MTLCommandQueue> queue = g.queue;
    ring_fence(queue); tb_geometry_set(64, 4);
    const size_t bytes = g.frame_bpr * 4;
    id<MTLCommandBuffer> setup = [queue commandBuffer];
    id<MTLBlitCommandEncoder> fill = [setup blitCommandEncoder];
    for (int slot = 0; slot < TB_FRAME_RING; ++slot) {
        g.frame[slot] = [g.dev newBufferWithLength:bytes options:MTLResourceStorageModePrivate];
        assert(g.frame[slot]); g.frame_cap[slot] = bytes;
        [fill fillBuffer:g.frame[slot] range:NSMakeRange(0, bytes) value:0x7f];
    }
    [fill endEncoding]; [setup commit]; [setup waitUntilCompleted];
    assert(setup.status == MTLCommandBufferStatusCompleted);
    dispatch_semaphore_t frames = g.frames_free;
    g.frames_free = dispatch_semaphore_create(1);
    const int free_slot = TB_FRAME_RING - 1;
    g.frame_widx = free_slot;
    uint32_t pixels[64 * 4]; for (int i = 0; i < 64 * 4; ++i) pixels[i] = 0xc0100803u;
    size_t capacity = tb_dpcm_max_size(64, 4);
    uint8_t *blob = malloc(capacity); assert(blob);
    size_t length = tb_dpcm_encode((uint8_t *)pixels, 256, 64, 4, 1, blob, capacity); assert(length);
    /* Failure 1: decode command missing; 2: compute encoder missing;
     * 3: present command missing; 4: render encoder missing;
     * 5: no permit for presentation after a successful decode. */
    for (int failure = 1; failure <= 5; ++failure) {
        fprintf(stderr, "frame ring fault %d\n", failure);
        TBRingFailQueue *failed = [TBRingFailQueue new]; failed.real = queue;
        failed.failAt = failure <= 2 ? 1 : 2;
        failed.failure = failure == 1 || failure == 3 ? 1 : failure == 2 ? 2 : failure == 4 ? 3 : 4;
        g.queue = (id<MTLCommandQueue>)failed;
        for (int retry = 0; retry < 6; ++retry) {
            failed.calls = 0; failed.drained = 0;
            const int upload = g.ring_idx;
            assert(tb_metal_plane_render_dpcm(blob, length) == -1);
            for (int i = 0; i < failed.drained; ++i) dispatch_semaphore_signal(g.inflight);
            assert(g.frame_widx == free_slot && !g.frame_open);
            assert(g.ring_idx == (failure <= 2 ? upload : (upload + 1) % TB_UPLOAD_RING));
            assert_one_permit(g.frames_free); assert_held_frames(queue, bytes);
        }
    }
    g.queue = queue;
    fprintf(stderr, "frame ring recovery\n");
    assert(tb_metal_plane_render_dpcm(blob, length) == 0);
    assert(g.frame_widx == 0 && !g.frame_open);
    ring_fence(queue); assert_one_permit(g.frames_free); assert_held_frames(queue, bytes);
    id<MTLBuffer> recovered = [g.dev newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> readback = [queue commandBuffer];
    id<MTLBlitCommandEncoder> copy = [readback blitCommandEncoder];
    assert(recovered && copy);
    [copy copyFromBuffer:g.frame[free_slot] sourceOffset:0 toBuffer:recovered destinationOffset:0 size:bytes];
    [copy endEncoding]; [readback commit]; [readback waitUntilCompleted];
    assert(readback.status == MTLCommandBufferStatusCompleted);
    assert(memcmp(recovered.contents, pixels, sizeof pixels) == 0);
    for (int i = 0; i < TB_UPLOAD_RING; ++i)
        assert(dispatch_semaphore_wait(g.inflight, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    assert(dispatch_semaphore_wait(g.inflight, DISPATCH_TIME_NOW) != 0);
    for (int i = 0; i < TB_UPLOAD_RING; ++i) dispatch_semaphore_signal(g.inflight);
    g.frames_free = frames;
    free(blob);
    puts("Metal frame ring: decode/present failures and exhausted presentation permits preserve busy surfaces; recovery passed");
}

static void test_resource_limit(void) {
    /* A valid flat 16K x 8K blob is only ~12 MB, but its decoded surface would
     * be 512 MiB. Reject it before geometry or either GPU ring is allocated. */
    const int width = 16384, height = 8192;
    uint32_t tiles = (uint32_t)(width / 8) * (height / 8);
    uint32_t groups = (tiles + 63) / 64;
    uint32_t widths = ((tiles * 3 + 1) / 2 + 3) & ~3u;
    uint32_t seeds = tiles * 4;
    size_t length = TB_DPCM_HEADER + (size_t)groups * 4 + widths + seeds;
    uint8_t *blob = calloc(1, length);
    assert(blob);
    put_le32(blob, TB_DPCM_MAGIC);
    put_le32(blob + 4, width); put_le32(blob + 8, height);
    blob[12] = 3; blob[13] = TB_DPCM_CHANNELS;
    blob[14] = TB_DPCM_FLAG_ALPHA_OMITTED | TB_DPCM_FLAG_TEN_BIT;
    put_le32(blob + 16, groups); put_le32(blob + 20, widths); put_le32(blob + 24, seeds);
    struct tb_dpcm_info info;
    assert(tb_dpcm_parse(blob, length, &info) == 0);
    assert(!tb_metal_plane_accepts_dpcm(blob, length));
    assert(tb_metal_plane_render_dpcm(blob, length) == -1);
    assert(g.frame_w == 0 && g.frame_h == 0);
    for (int i = 0; i < TB_FRAME_RING; ++i) assert(!g.frame[i]);
    for (int i = 0; i < TB_UPLOAD_RING; ++i) assert(!g.ring[i]);
    free(blob);
}

int main(int argc, char **argv) {
    const int ring_only = argc == 2 && strcmp(argv[1], "--ring-upload-only") == 0 ? 1
                        : argc == 2 && strcmp(argv[1], "--ring-frame-only") == 0 ? 2 : 0;
    assert(argc == 1 || ring_only);
    @autoreleasepool {
        [NSApplication sharedApplication];
        uint8_t invalid[TB_DPCM_HEADER] = {0};
        assert(!tb_metal_plane_accepts_dpcm(NULL, 0));
        assert(!tb_metal_plane_accepts_dpcm(invalid, 1));
        assert(!tb_metal_plane_accepts_dpcm(invalid, sizeof invalid));
        assert(!tb_metal_plane_available());
        tb_metal_plane_set_cursor(12, 34, 1024, 768, 1, 0, 0);
        assert(g.cur_visible && g.cur_x == 12 && g.cur_y == 34);
        assert(g.cur_sw == 1024 && g.cur_sh == 768);
        tb_metal_plane_set_cursor(0, 0, 0, -1, 0, 0, 0);
        assert(!g.cur_visible && g.cur_sw == 1 && g.cur_sh == 1);
        assert(SDL_Init(SDL_INIT_VIDEO) == 0);
        SDL_SetHint(SDL_HINT_RENDER_DRIVER, "opengl");
        SDL_Window *window = SDL_CreateWindow("TargetBridge synthetic DPCM test",
            SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, 320, 180,
            SDL_WINDOW_ALLOW_HIGHDPI);
        assert(window);
        SDL_Renderer *renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED);
        assert(renderer);
        assert(tb_metal_plane_supports_dpcm());
        assert(!tb_metal_plane_available());
        for (int cycle = 0; cycle < 2; ++cycle) {
            assert(tb_metal_plane_init(window) == 0);
            assert(!g.shown && g.layer.hidden && [(__bridge NSView *)g.view isHidden]);
            test_resource_limit();
            if (ring_only) {
                if (ring_only == 1) test_failed_upload_keeps_free_slot();
                else test_failed_frame_present_keeps_free_slot();
                tb_metal_plane_shutdown();
                break;
            }
            test_failed_upload_keeps_free_slot();
            test_failed_frame_present_keeps_free_slot();
            test_cursor_orientation();
            tb_metal_plane_set_cursor(32, 2, 1024, 4, 1, 0, 0);
            /* All 1024 values, including the low two bits, in every channel. */
            test_decode(1024, 4, 1);
            assert(g.curTex); /* The first frame uses the render-pass cursor. */
            tb_metal_plane_set_hidden(0);
            assert(g.shown && !g.layer.hidden && ![(__bridge NSView *)g.view isHidden]);
            const char *cursor_plane = getenv("TB_CURSOR_PLANE");
            if (cursor_plane && cursor_plane[0] == '0') assert(!g.cursorLayer);
            pump();
            test_decode(65, 65, 0);
            test_decode(65, 65, 1);
            /* Restore all 1024 values, including the low two bits, after the
             * modulo color transform. Then mix transformed/raw tiles and
             * exercise partial tiles at both sample depths. */
            test_decode_variant(1024, 4, 1, 1, 0);
            test_decode_variant(65, 65, 0, 1, 0);
            test_decode_variant(65, 65, 1, 1, 0);
            test_decode_variant(65, 65, 0, 1, 1);
            test_decode_variant(65, 65, 1, 1, 1);
            test_cursor_shapes();
            /* Full 4.5K frame, including the final partial group of 16 tiles. */
            test_decode(4480, 2520, 1);
            test_decode_variant(4480, 2520, 1, 1, 1);
            test_decode(65, 65, 1);
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
        if (ring_only) puts("Metal selected ring failure/recovery regression passed");
        else puts("Metal DPCM: legacy/adaptive 8/10-bit CPU parity, mixed color tiles, all 1024 levels, partial tiles, 4.5K frames, hidden first frame, fallback/teardown, cursor shapes/size/hotspots and resource limits passed");
    }
    return 0;
}
