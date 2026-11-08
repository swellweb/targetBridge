/* tb_metal_view.m — see tb_metal_view.h. */

#import "tb_metal_view.h"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <stdio.h>

static NSString *const kTBMetalViewShaders =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct TBVertexOut { float4 position [[position]]; float2 uv; };\n"
     "vertex TBVertexOut tb_fullscreen_vertex(uint vid [[vertex_id]]) {\n"
     "    // Triangle strip covering the viewport.\n"
     "    float2 uv = float2(float(vid & 1u), float(vid >> 1u));\n"
     "    TBVertexOut out;\n"
     "    out.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);\n"
     "    out.uv = uv;\n"
     "    return out;\n"
     "}\n"
     "fragment float4 tb_texture_fragment(TBVertexOut in [[stage_in]],\n"
     "                                    texture2d<float> tex [[texture(0)]],\n"
     "                                    sampler s [[sampler(0)]]) {\n"
     "    return float4(tex.sample(s, in.uv).rgb, 1.0);\n"
     "}\n";

@interface TBMetalView : NSObject
@property (nonatomic, strong) CAMetalLayer *layer;
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> queue;
@property (nonatomic, strong) id<MTLLibrary> library;
@property (nonatomic, strong) id<MTLSamplerState> sampler;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property (nonatomic) MTLPixelFormat pipelineFormat;
@property (nonatomic, strong) id<MTLTexture> texture;
@property (nonatomic) BOOL textureFilled;
@property (nonatomic, strong) id<MTLBuffer> source;
@property (nonatomic) const void *sourcePointer;
@property (nonatomic) size_t sourceLength;
@property (nonatomic) MTLPixelFormat defaultFormat;
@end

@implementation TBMetalView
@end

struct tb_metal_view {
    void *object; /* TBMetalView, retained */
};

static TBMetalView *tb_view(struct tb_metal_view *v) {
    return v ? (__bridge TBMetalView *)v->object : nil;
}

struct tb_metal_view *tb_metal_view_create(SDL_Renderer *ren) {
    if (!ren) return NULL;
    @autoreleasepool {
        CAMetalLayer *layer = (__bridge CAMetalLayer *)SDL_RenderGetMetalLayer(ren);
        if (!layer || !layer.device) return NULL;

        TBMetalView *view = [TBMetalView new];
        view.layer = layer;
        view.device = layer.device;
        view.defaultFormat = layer.pixelFormat;
        view.queue = [view.device newCommandQueue];
        NSError *error = nil;
        view.library = [view.device newLibraryWithSource:kTBMetalViewShaders options:nil error:&error];
        if (!view.queue || !view.library) {
            fprintf(stderr, "[metal] 10-bit view setup failed: %s\n",
                    error ? error.localizedDescription.UTF8String : "no command queue");
            return NULL;
        }
        MTLSamplerDescriptor *sampler = [MTLSamplerDescriptor new];
        sampler.minFilter = MTLSamplerMinMagFilterLinear;
        sampler.magFilter = MTLSamplerMinMagFilterLinear;
        sampler.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sampler.tAddressMode = MTLSamplerAddressModeClampToEdge;
        view.sampler = [view.device newSamplerStateWithDescriptor:sampler];
        if (!view.sampler) return NULL;

        struct tb_metal_view *v = (struct tb_metal_view *)calloc(1, sizeof(*v));
        if (!v) return NULL;
        v->object = (__bridge_retained void *)view;
        fprintf(stderr, "[metal] 10-bit view ready on %s\n", view.device.name.UTF8String);
        return v;
    }
}

void tb_metal_view_destroy(struct tb_metal_view *v) {
    if (!v) return;
    TBMetalView *view = (__bridge_transfer TBMetalView *)v->object;
    view.layer.pixelFormat = view.defaultFormat;
    view = nil;
    free(v);
}

void tb_metal_view_reset(struct tb_metal_view *v) {
    TBMetalView *view = tb_view(v);
    if (!view) return;
    view.texture = nil;
    view.textureFilled = NO;
    view.source = nil;
    view.sourcePointer = NULL;
    view.sourceLength = 0;
}

void tb_metal_view_set_10bit_drawable(struct tb_metal_view *v, int on) {
    TBMetalView *view = tb_view(v);
    if (!view) return;
    const MTLPixelFormat format = on ? MTLPixelFormatBGR10A2Unorm : view.defaultFormat;
    if (view.layer.pixelFormat != format) {
        view.layer.pixelFormat = format;
        fprintf(stderr, "[metal] drawable %s\n", on ? "BGR10A2 (10-bit)" : "8-bit");
    }
}

void tb_metal_view_set_display_sync(struct tb_metal_view *v, int on) {
    TBMetalView *view = tb_view(v);
    if (!view) return;
    if (@available(macOS 10.13, *)) {
        if (view.layer.displaySyncEnabled != (BOOL)on) {
            view.layer.displaySyncEnabled = on ? YES : NO;
            fprintf(stderr, "[metal] display sync %s\n", on ? "on" : "off");
        }
    }
}

static id<MTLTexture> tb_metal_view_texture(TBMetalView *view, int w, int h) {
    if (view.texture && (int)view.texture.width == w && (int)view.texture.height == h) {
        return view.texture;
    }
    MTLTextureDescriptor *desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGR10A2Unorm
                                                           width:(NSUInteger)w
                                                          height:(NSUInteger)h
                                                       mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModePrivate;
    view.texture = [view.device newTextureWithDescriptor:desc];
    view.textureFilled = NO;
    if (view.texture) {
        fprintf(stderr, "[metal] texture %dx%d BGR10A2 (10-bit, GPU blit upload)\n", w, h);
    }
    return view.texture;
}

/* The Receiver's frame memory, wrapped so the GPU reads it in place. */
static id<MTLBuffer> tb_metal_view_source(TBMetalView *view, const uint8_t *pixels, size_t capacity) {
    if (view.source && view.sourcePointer == pixels && view.sourceLength == capacity) {
        return view.source;
    }
    view.source = [view.device newBufferWithBytesNoCopy:(void *)pixels
                                                 length:capacity
                                                options:MTLResourceStorageModeShared
                                            deallocator:nil];
    view.sourcePointer = view.source ? pixels : NULL;
    view.sourceLength = view.source ? capacity : 0;
    if (!view.source) fprintf(stderr, "[metal] could not wrap the frame memory\n");
    return view.source;
}

int tb_metal_view_upload_rgb10(struct tb_metal_view *v,
                               const uint8_t *pixels, size_t pixels_capacity,
                               int w, int h, int first_row, int end_row) {
    TBMetalView *view = tb_view(v);
    if (!view || !pixels || w <= 0 || h <= 0) return -1;
    const size_t pitch = (size_t)w * 4u;
    if (pixels_capacity < pitch * (size_t)h) return -1;
    @autoreleasepool {
        id<MTLTexture> texture = tb_metal_view_texture(view, w, h);
        id<MTLBuffer> source = tb_metal_view_source(view, pixels, pixels_capacity);
        if (!texture || !source) return -1;
        if (!view.textureFilled) {
            first_row = 0;
            end_row = h;
        }
        if (first_row < 0) first_row = 0;
        if (end_row > h) end_row = h;
        if (end_row <= first_row) return 0;

        id<MTLCommandBuffer> commands = [view.queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
        const NSUInteger rows = (NSUInteger)(end_row - first_row);
        [blit copyFromBuffer:source
                sourceOffset:pitch * (size_t)first_row
           sourceBytesPerRow:pitch
         sourceBytesPerImage:pitch * rows
                  sourceSize:MTLSizeMake((NSUInteger)w, rows, 1)
                   toTexture:texture
            destinationSlice:0
            destinationLevel:0
           destinationOrigin:MTLOriginMake(0, (NSUInteger)first_row, 0)];
        [blit endEncoding];
        [commands commit];
        [commands waitUntilCompleted];
        if (commands.status != MTLCommandBufferStatusCompleted) {
            fprintf(stderr, "[metal] upload failed: %s\n",
                    commands.error ? commands.error.localizedDescription.UTF8String : "unknown");
            return -1;
        }
        view.textureFilled = YES;
        return 0;
    }
}

static id<MTLRenderPipelineState> tb_metal_view_pipeline(TBMetalView *view, MTLPixelFormat format) {
    if (view.pipeline && view.pipelineFormat == format) return view.pipeline;
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = [view.library newFunctionWithName:@"tb_fullscreen_vertex"];
    desc.fragmentFunction = [view.library newFunctionWithName:@"tb_texture_fragment"];
    desc.colorAttachments[0].pixelFormat = format;
    NSError *error = nil;
    view.pipeline = [view.device newRenderPipelineStateWithDescriptor:desc error:&error];
    view.pipelineFormat = format;
    if (!view.pipeline) {
        fprintf(stderr, "[metal] pipeline failed: %s\n",
                error ? error.localizedDescription.UTF8String : "unknown");
    }
    return view.pipeline;
}

int tb_metal_view_draw(struct tb_metal_view *v, SDL_Renderer *ren) {
    TBMetalView *view = tb_view(v);
    if (!view || !view.texture || !view.textureFilled) return -1;
    @autoreleasepool {
        /* Flushes SDL's queued clear and returns its render encoder for this
         * frame's drawable. SDL sets its own state again for later draws. */
        id<MTLRenderCommandEncoder> encoder =
            (__bridge id<MTLRenderCommandEncoder>)SDL_RenderGetMetalCommandEncoder(ren);
        if (!encoder) return -1;
        id<MTLRenderPipelineState> pipeline = tb_metal_view_pipeline(view, view.layer.pixelFormat);
        if (!pipeline) return -1;
        /* The encoder starts with the scissor covering the whole drawable,
         * as only a clear ran before; the viewport is SDL's output size. */
        int out_w = 0, out_h = 0;
        if (SDL_GetRendererOutputSize(ren, &out_w, &out_h) != 0 || out_w <= 0 || out_h <= 0) return -1;
        [encoder setViewport:(MTLViewport){ 0.0, 0.0, (double)out_w, (double)out_h, 0.0, 1.0 }];
        [encoder setRenderPipelineState:pipeline];
        [encoder setFragmentTexture:view.texture atIndex:0];
        [encoder setFragmentSamplerState:view.sampler atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        return 0;
    }
}
