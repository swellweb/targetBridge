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
     "fragment float4 tb_rgb_fragment(TBVertexOut in [[stage_in]],\n"
     "                                texture2d<float> tex [[texture(0)]],\n"
     "                                sampler s [[sampler(0)]]) {\n"
     "    return float4(tex.sample(s, in.uv).rgb, 1.0);\n"
     "}\n"
     "// NV12, BT.709, video range: the same conversion the Sender and SDL use.\n"
     "fragment float4 tb_nv12_fragment(TBVertexOut in [[stage_in]],\n"
     "                                 texture2d<float> ytex [[texture(0)]],\n"
     "                                 texture2d<float> uvtex [[texture(1)]],\n"
     "                                 sampler s [[sampler(0)]]) {\n"
     "    float y = (ytex.sample(s, in.uv).r * 255.0 - 16.0) / 219.0;\n"
     "    float2 c = (uvtex.sample(s, in.uv).rg * 255.0 - 128.0) / 224.0;\n"
     "    float3 rgb = float3(y + 1.5748 * c.y,\n"
     "                        y - 0.1873 * c.x - 0.4681 * c.y,\n"
     "                        y + 1.8556 * c.x);\n"
     "    return float4(saturate(rgb), 1.0);\n"
     "}\n";

/* What the textures currently hold, and how they are filled. */
enum tb_metal_kind {
    TB_METAL_KIND_NONE = 0,
    TB_METAL_KIND_NV12_CPU,   /* Y + CbCr, written by the CPU */
    TB_METAL_KIND_NV12_GPU,   /* Y + CbCr, blitted from the frame memory */
    TB_METAL_KIND_RGB10       /* BGR10A2, blitted from the frame memory */
};

#define TB_METAL_PLANES 2

@interface TBMetalView : NSObject {
@public
    id<MTLTexture> _textures[TB_METAL_PLANES];
    id<MTLBuffer>  _sources[TB_METAL_PLANES];
    const void    *_sourcePointers[TB_METAL_PLANES];
    size_t         _sourceLengths[TB_METAL_PLANES];
}
@property (nonatomic, strong) CAMetalLayer *layer;
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> queue;
@property (nonatomic, strong) id<MTLLibrary> library;
@property (nonatomic, strong) id<MTLSamplerState> sampler;
@property (nonatomic, strong) id<MTLRenderPipelineState> rgbPipeline;
@property (nonatomic) MTLPixelFormat rgbPipelineFormat;
@property (nonatomic, strong) id<MTLRenderPipelineState> nv12Pipeline;
@property (nonatomic) MTLPixelFormat nv12PipelineFormat;
@property (nonatomic) int kind;
@property (nonatomic) int width;
@property (nonatomic) int height;
@property (nonatomic) BOOL filled;
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
            fprintf(stderr, "[metal] video view setup failed: %s\n",
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
        fprintf(stderr, "[metal] video view ready on %s\n", view.device.name.UTF8String);
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

static void tb_metal_view_forget_sources(TBMetalView *view) {
    for (int i = 0; i < TB_METAL_PLANES; ++i) {
        view->_sources[i] = nil;
        view->_sourcePointers[i] = NULL;
        view->_sourceLengths[i] = 0;
    }
}

void tb_metal_view_reset(struct tb_metal_view *v) {
    TBMetalView *view = tb_view(v);
    if (!view) return;
    for (int i = 0; i < TB_METAL_PLANES; ++i) view->_textures[i] = nil;
    tb_metal_view_forget_sources(view);
    view.kind = TB_METAL_KIND_NONE;
    view.width = 0;
    view.height = 0;
    view.filled = NO;
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

static id<MTLTexture> tb_metal_view_new_texture(TBMetalView *view, MTLPixelFormat format,
                                                int w, int h, MTLStorageMode storage) {
    MTLTextureDescriptor *desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                           width:(NSUInteger)w
                                                          height:(NSUInteger)h
                                                       mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
    desc.storageMode = storage;
    return [view.device newTextureWithDescriptor:desc];
}

/* Makes sure the textures fit `kind` and the picture size. New textures are
 * empty until the next upload fills them completely. */
static BOOL tb_metal_view_prepare(TBMetalView *view, int kind, int w, int h) {
    if (view.kind == kind && view.width == w && view.height == h && view->_textures[0]) return YES;
    for (int i = 0; i < TB_METAL_PLANES; ++i) view->_textures[i] = nil;
    tb_metal_view_forget_sources(view);
    view.filled = NO;

    /* CPU uploads need textures the CPU can write (managed); GPU blits go
     * into private textures, the fastest to sample on a discrete GPU. */
    const MTLStorageMode storage =
        kind == TB_METAL_KIND_NV12_CPU ? MTLStorageModeManaged : MTLStorageModePrivate;
    const char *name = "";
    if (kind == TB_METAL_KIND_RGB10) {
        view->_textures[0] = tb_metal_view_new_texture(view, MTLPixelFormatBGR10A2Unorm, w, h, storage);
        name = "BGR10A2 (10-bit)";
    } else {
        view->_textures[0] = tb_metal_view_new_texture(view, MTLPixelFormatR8Unorm, w, h, storage);
        view->_textures[1] = tb_metal_view_new_texture(view, MTLPixelFormatRG8Unorm, w / 2, h / 2, storage);
        name = "NV12";
    }
    if (!view->_textures[0] || (kind != TB_METAL_KIND_RGB10 && !view->_textures[1])) {
        fprintf(stderr, "[metal] could not create %dx%d %s textures\n", w, h, name);
        view.kind = TB_METAL_KIND_NONE;
        return NO;
    }
    view.kind = kind;
    view.width = w;
    view.height = h;
    fprintf(stderr, "[metal] textures %dx%d %s, %s upload\n", w, h, name,
            kind == TB_METAL_KIND_NV12_CPU ? "CPU" : "GPU blit");
    return YES;
}

/* The Receiver's frame memory, wrapped so the GPU reads it in place. */
static id<MTLBuffer> tb_metal_view_source(TBMetalView *view, int plane,
                                          const uint8_t *memory, size_t capacity) {
    if (view->_sources[plane] && view->_sourcePointers[plane] == memory &&
        view->_sourceLengths[plane] == capacity) {
        return view->_sources[plane];
    }
    id<MTLBuffer> buffer = [view.device newBufferWithBytesNoCopy:(void *)memory
                                                          length:capacity
                                                         options:MTLResourceStorageModeShared
                                                     deallocator:nil];
    view->_sources[plane] = buffer;
    view->_sourcePointers[plane] = buffer ? memory : NULL;
    view->_sourceLengths[plane] = buffer ? capacity : 0;
    if (!buffer) fprintf(stderr, "[metal] could not wrap the frame memory\n");
    return buffer;
}

static void tb_metal_view_blit_rows(id<MTLBlitCommandEncoder> blit, id<MTLBuffer> source,
                                    size_t pitch, NSUInteger first_row, NSUInteger rows,
                                    NSUInteger width, id<MTLTexture> texture) {
    [blit copyFromBuffer:source
            sourceOffset:pitch * first_row
       sourceBytesPerRow:pitch
     sourceBytesPerImage:pitch * rows
              sourceSize:MTLSizeMake(width, rows, 1)
               toTexture:texture
        destinationSlice:0
        destinationLevel:0
       destinationOrigin:MTLOriginMake(0, first_row, 0)];
}

static int tb_metal_view_finish(TBMetalView *view, id<MTLCommandBuffer> commands) {
    [commands commit];
    [commands waitUntilCompleted];
    if (commands.status != MTLCommandBufferStatusCompleted) {
        fprintf(stderr, "[metal] upload failed: %s\n",
                commands.error ? commands.error.localizedDescription.UTF8String : "unknown");
        return -1;
    }
    view.filled = YES;
    return 0;
}

static void tb_metal_view_clamp_rows(TBMetalView *view, int h, int *first_row, int *end_row) {
    if (!view.filled) {
        *first_row = 0;
        *end_row = h;
    }
    *first_row &= ~1;
    *end_row = (*end_row + 1) & ~1;
    if (*first_row < 0) *first_row = 0;
    if (*end_row > h) *end_row = h;
}

int tb_metal_view_upload_nv12(struct tb_metal_view *v,
                              const uint8_t *y, int y_stride,
                              const uint8_t *uv, int uv_stride,
                              int w, int h) {
    TBMetalView *view = tb_view(v);
    if (!view || !y || !uv || w <= 1 || h <= 1 || (w & 1) || (h & 1) ||
        y_stride < w || uv_stride < w) return -1;
    @autoreleasepool {
        if (!tb_metal_view_prepare(view, TB_METAL_KIND_NV12_CPU, w, h)) return -1;
        [view->_textures[0] replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)w, (NSUInteger)h)
                              mipmapLevel:0
                                withBytes:y
                              bytesPerRow:(NSUInteger)y_stride];
        [view->_textures[1] replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)w / 2, (NSUInteger)h / 2)
                              mipmapLevel:0
                                withBytes:uv
                              bytesPerRow:(NSUInteger)uv_stride];
        view.filled = YES;
        return 0;
    }
}

int tb_metal_view_upload_nv12_rows(struct tb_metal_view *v,
                                   const uint8_t *y, size_t y_capacity,
                                   const uint8_t *uv, size_t uv_capacity,
                                   int w, int h, int first_row, int end_row) {
    TBMetalView *view = tb_view(v);
    if (!view || !y || !uv || w <= 1 || h <= 1 || (w & 1) || (h & 1)) return -1;
    if (y_capacity < (size_t)w * (size_t)h || uv_capacity < (size_t)w * (size_t)(h / 2)) return -1;
    @autoreleasepool {
        if (!tb_metal_view_prepare(view, TB_METAL_KIND_NV12_GPU, w, h)) return -1;
        id<MTLBuffer> y_source = tb_metal_view_source(view, 0, y, y_capacity);
        id<MTLBuffer> uv_source = tb_metal_view_source(view, 1, uv, uv_capacity);
        if (!y_source || !uv_source) return -1;
        tb_metal_view_clamp_rows(view, h, &first_row, &end_row);
        if (end_row <= first_row) return 0;

        id<MTLCommandBuffer> commands = [view.queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
        const NSUInteger rows = (NSUInteger)(end_row - first_row);
        tb_metal_view_blit_rows(blit, y_source, (size_t)w, (NSUInteger)first_row, rows,
                                (NSUInteger)w, view->_textures[0]);
        tb_metal_view_blit_rows(blit, uv_source, (size_t)w, (NSUInteger)first_row / 2, rows / 2,
                                (NSUInteger)w / 2, view->_textures[1]);
        [blit endEncoding];
        return tb_metal_view_finish(view, commands);
    }
}

int tb_metal_view_upload_rgb10(struct tb_metal_view *v,
                               const uint8_t *pixels, size_t pixels_capacity,
                               int w, int h, int first_row, int end_row) {
    TBMetalView *view = tb_view(v);
    if (!view || !pixels || w <= 0 || h <= 0) return -1;
    const size_t pitch = (size_t)w * 4u;
    if (pixels_capacity < pitch * (size_t)h) return -1;
    @autoreleasepool {
        if (!tb_metal_view_prepare(view, TB_METAL_KIND_RGB10, w, h)) return -1;
        id<MTLBuffer> source = tb_metal_view_source(view, 0, pixels, pixels_capacity);
        if (!source) return -1;
        tb_metal_view_clamp_rows(view, h, &first_row, &end_row);
        if (end_row <= first_row) return 0;

        id<MTLCommandBuffer> commands = [view.queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
        tb_metal_view_blit_rows(blit, source, pitch, (NSUInteger)first_row,
                                (NSUInteger)(end_row - first_row), (NSUInteger)w, view->_textures[0]);
        [blit endEncoding];
        return tb_metal_view_finish(view, commands);
    }
}

static id<MTLRenderPipelineState> tb_metal_view_make_pipeline(TBMetalView *view, NSString *fragment,
                                                              MTLPixelFormat format) {
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = [view.library newFunctionWithName:@"tb_fullscreen_vertex"];
    desc.fragmentFunction = [view.library newFunctionWithName:fragment];
    desc.colorAttachments[0].pixelFormat = format;
    NSError *error = nil;
    id<MTLRenderPipelineState> pipeline = [view.device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!pipeline) {
        fprintf(stderr, "[metal] pipeline failed: %s\n",
                error ? error.localizedDescription.UTF8String : "unknown");
    }
    return pipeline;
}

static id<MTLRenderPipelineState> tb_metal_view_pipeline(TBMetalView *view, MTLPixelFormat format) {
    if (view.kind == TB_METAL_KIND_RGB10) {
        if (!view.rgbPipeline || view.rgbPipelineFormat != format) {
            view.rgbPipeline = tb_metal_view_make_pipeline(view, @"tb_rgb_fragment", format);
            view.rgbPipelineFormat = format;
        }
        return view.rgbPipeline;
    }
    if (!view.nv12Pipeline || view.nv12PipelineFormat != format) {
        view.nv12Pipeline = tb_metal_view_make_pipeline(view, @"tb_nv12_fragment", format);
        view.nv12PipelineFormat = format;
    }
    return view.nv12Pipeline;
}

int tb_metal_view_draw(struct tb_metal_view *v, SDL_Renderer *ren) {
    TBMetalView *view = tb_view(v);
    if (!view || view.kind == TB_METAL_KIND_NONE || !view.filled) return -1;
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
        [encoder setFragmentTexture:view->_textures[0] atIndex:0];
        if (view.kind != TB_METAL_KIND_RGB10) [encoder setFragmentTexture:view->_textures[1] atIndex:1];
        [encoder setFragmentSamplerState:view.sampler atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        return 0;
    }
}
