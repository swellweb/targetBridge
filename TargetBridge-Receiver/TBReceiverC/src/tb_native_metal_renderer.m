#import "tb_native_metal_renderer.h"

#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <os/lock.h>
#import <simd/simd.h>

#include <stdio.h>
#include <string.h>

@interface TBNativeMetalView : NSView
@end

@implementation TBNativeMetalView

- (CALayer *)makeBackingLayer {
    return [CAMetalLayer layer];
}

- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    /* SDL's content view remains the sole input target. */
    return nil;
}

- (BOOL)acceptsFirstResponder {
    return NO;
}

@end

typedef struct {
    vector_float2 drawableSize;
    vector_float2 cursorPosition;
    vector_float2 cursorSize;
    uint32_t cursorVisible;
    uint32_t cursorType;
    uint32_t fullRange;
    uint32_t cursorLarge;
} TBNativeMetalUniforms;

static const char TBNativeMetalShader[] = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct RasterData {
    float4 position [[position]];
    float2 texCoord;
};

struct Uniforms {
    float2 drawableSize;
    float2 cursorPosition;
    float2 cursorSize;
    uint cursorVisible;
    uint cursorType;
    uint fullRange;
    uint cursorLarge;
};

vertex RasterData tbVideoVertex(uint vertexID [[vertex_id]]) {
    constexpr float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    constexpr float2 texCoords[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };
    RasterData out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

static bool tbArrowMask(float2 p, float expansion) {
    const bool head = p.x >= -expansion &&
                      p.y >= -expansion &&
                      p.y <= 31.0 + expansion &&
                      p.x <= p.y * 0.61 + 2.0 + expansion;
    const bool stem = p.x >= 7.0 - expansion &&
                      p.x <= 14.0 + expansion &&
                      p.y >= 21.0 - expansion &&
                      p.y <= 41.0 + expansion;
    return head || stem;
}

fragment float4 tbVideoFragment(RasterData in [[stage_in]],
                                texture2d<float, access::sample> luma [[texture(0)]],
                                texture2d<float, access::sample> chroma [[texture(1)]],
                                constant Uniforms &uniforms [[buffer(0)]]) {
    constexpr sampler linearSampler(coord::normalized,
                                    address::clamp_to_edge,
                                    filter::linear);
    float y = luma.sample(linearSampler, in.texCoord).r;
    float2 uv = chroma.sample(linearSampler, in.texCoord).rg;

    if (uniforms.fullRange == 0) {
        y = max(0.0, (y - (16.0 / 255.0)) * (255.0 / 219.0));
        uv = (uv - 0.5) * (255.0 / 224.0);
    } else {
        uv -= 0.5;
    }

    float3 rgb;
    rgb.r = y + 1.5748 * uv.y;
    rgb.g = y - 0.1873 * uv.x - 0.4681 * uv.y;
    rgb.b = y + 1.8556 * uv.x;
    rgb = clamp(rgb, 0.0, 1.0);

    if (uniforms.cursorVisible != 0) {
        float2 scale = max(uniforms.cursorSize / float2(24.0, 42.0), float2(0.01));
        float2 cursorPoint = (in.position.xy - uniforms.cursorPosition) / scale;
        /* Match the normal macOS-style overlay used by the OpenGL path:
         * white outline with a dark body. */
        if (tbArrowMask(cursorPoint, 1.7)) rgb = float3(0.98);
        if (tbArrowMask(cursorPoint, 0.0)) rgb = float3(0.03);
    }

    return float4(rgb, 1.0);
}
)METAL";

static BOOL tb_pixel_buffer_uses_display_p3(CVPixelBufferRef pixelBuffer) {
    if (!pixelBuffer) return NO;
    CFTypeRef primaries = CVBufferGetAttachment(
        pixelBuffer, kCVImageBufferColorPrimariesKey, NULL);
    return primaries && CFGetTypeID(primaries) == CFStringGetTypeID() &&
           CFEqual(primaries, kCVImageBufferColorPrimaries_P3_D65);
}

@interface TBNativeMetalRenderer : NSObject
- (instancetype)initRenderer;
- (void)setVisible:(BOOL)visible;
- (int)renderPixelBuffer:(CVPixelBufferRef)pixelBuffer
                 cursorX:(int)cursorX
                 cursorY:(int)cursorY
             cursorWidth:(int)cursorWidth
            cursorHeight:(int)cursorHeight
           cursorVisible:(BOOL)cursorVisible
              cursorType:(int)cursorType
             cursorLarge:(BOOL)cursorLarge
           rememberFrame:(BOOL)rememberFrame;
- (int)renderCursorX:(int)cursorX
             cursorY:(int)cursorY
         cursorWidth:(int)cursorWidth
        cursorHeight:(int)cursorHeight
       cursorVisible:(BOOL)cursorVisible
          cursorType:(int)cursorType
         cursorLarge:(BOOL)cursorLarge;
- (void)copyStats:(struct tb_native_metal_stats *)stats;
- (const char *)colorSpaceName;
- (void)waitUntilIdle;
@end

@implementation TBNativeMetalRenderer {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    id<MTLRenderPipelineState> _pipeline;
    CVMetalTextureCacheRef _textureCache;
    TBNativeMetalView *_view;
    CAMetalLayer *_metalLayer;
    CGColorSpaceRef _layerColorSpace;
    dispatch_semaphore_t _inflightSemaphore;
    CVPixelBufferRef _latestFrame;
    os_unfair_lock _statsLock;
    struct tb_native_metal_stats _stats;
    BOOL _loggedFirstFrame;
    BOOL _displayP3;
}

- (instancetype)initRenderer {
    self = [super init];
    if (!self) return nil;

    _statsLock = OS_UNFAIR_LOCK_INIT;
    _device = MTLCreateSystemDefaultDevice();
    if (!_device) return nil;
    _commandQueue = [_device newCommandQueue];
    if (!_commandQueue) return nil;

    NSError *libraryError = nil;
    NSString *shaderSource = [NSString stringWithUTF8String:TBNativeMetalShader];
    id<MTLLibrary> library = [_device newLibraryWithSource:shaderSource
                                                   options:nil
                                                     error:&libraryError];
    if (!library) {
        fprintf(stderr, "[metal-native] shader compile failed: %s\n",
                libraryError.localizedDescription.UTF8String ?: "unknown error");
        return nil;
    }

    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.label = @"TargetBridge NV12 Pipeline";
    descriptor.vertexFunction = [library newFunctionWithName:@"tbVideoVertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"tbVideoFragment"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

    NSError *pipelineError = nil;
    _pipeline = [_device newRenderPipelineStateWithDescriptor:descriptor error:&pipelineError];
    if (!_pipeline) {
        fprintf(stderr, "[metal-native] pipeline creation failed: %s\n",
                pipelineError.localizedDescription.UTF8String ?: "unknown error");
        return nil;
    }

    CVReturn cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault,
                                                      NULL,
                                                      _device,
                                                      NULL,
                                                      &_textureCache);
    if (cacheStatus != kCVReturnSuccess || !_textureCache) {
        fprintf(stderr, "[metal-native] CVMetalTextureCacheCreate failed: %d\n",
                (int)cacheStatus);
        return nil;
    }

    _inflightSemaphore = dispatch_semaphore_create(3);
    fprintf(stderr, "[metal-native] device=%s\n", _device.name.UTF8String ?: "unknown");
    return self;
}

- (void)dealloc {
    [self setVisible:NO];
    if (_metalLayer) _metalLayer.colorspace = nil;
    if (_layerColorSpace) {
        CGColorSpaceRelease(_layerColorSpace);
        _layerColorSpace = NULL;
    }
    if (_textureCache) {
        CVMetalTextureCacheFlush(_textureCache, 0);
        CFRelease(_textureCache);
        _textureCache = NULL;
    }
}

- (NSWindow *)receiverWindow {
    NSWindow *best = nil;
    CGFloat bestArea = 0.0;
    for (NSWindow *window in NSApp.windows) {
        if (!window.isVisible) continue;
        const CGFloat area = window.frame.size.width * window.frame.size.height;
        if (area > bestArea) {
            bestArea = area;
            best = window;
        }
    }
    return best;
}

- (BOOL)attachViewIfNeeded {
    if (![NSThread isMainThread]) {
        fprintf(stderr, "[metal-native] UI attachment requested off main thread\n");
        return NO;
    }

    NSWindow *window = [self receiverWindow];
    if (!window) return NO;
    NSView *contentView = window.contentView;
    if (!contentView) return NO;
    if (_view.window == window && _view.superview == contentView && _metalLayer) return YES;

    /* SDL may replace its Cocoa window while entering its fullscreen Space.
     * Follow the largest visible receiver window instead of retaining the
     * initial 980x620 window forever. */
    if (_view) {
        if (_metalLayer) _metalLayer.colorspace = nil;
        if (_layerColorSpace) {
            CGColorSpaceRelease(_layerColorSpace);
            _layerColorSpace = NULL;
        }
        [_view removeFromSuperview];
        _view = nil;
        _metalLayer = nil;
    }

    _view = [[TBNativeMetalView alloc] initWithFrame:contentView.bounds];
    _view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _view.wantsLayer = YES;
    _view.hidden = YES;
    [contentView addSubview:_view positioned:NSWindowAbove relativeTo:nil];

    _metalLayer = (CAMetalLayer *)_view.layer;
    if (![_metalLayer isKindOfClass:CAMetalLayer.class]) return NO;
    _metalLayer.device = _device;
    _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (srgb) {
        _metalLayer.colorspace = srgb;
        /* CAMetalLayer's CF-typed property does not declare ownership in the
         * Objective-C header. Retain our own reference until the layer is
         * detached so older macOS releases cannot observe a dangling space. */
        _layerColorSpace = srgb;
    }
    _displayP3 = NO;
    _metalLayer.framebufferOnly = YES;
    _metalLayer.opaque = YES;
    _metalLayer.presentsWithTransaction = NO;
    _metalLayer.allowsNextDrawableTimeout = YES;
    if ([_metalLayer respondsToSelector:@selector(setMaximumDrawableCount:)]) {
        _metalLayer.maximumDrawableCount = 3;
    }
    if ([_metalLayer respondsToSelector:@selector(setDisplaySyncEnabled:)]) {
        _metalLayer.displaySyncEnabled = NO;
    }
    fprintf(stderr,
            "[metal-native] attached window=%ld points=%.0fx%.0f scale=%.1f title=%s\n",
            (long)window.windowNumber,
            contentView.bounds.size.width,
            contentView.bounds.size.height,
            window.backingScaleFactor,
            window.title.UTF8String ?: "");
    return YES;
}

- (void)updateColorSpaceForPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!_metalLayer) return;
    const BOOL displayP3 = tb_pixel_buffer_uses_display_p3(pixelBuffer);
    if (_metalLayer.colorspace && displayP3 == _displayP3) return;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(
        displayP3 ? kCGColorSpaceDisplayP3 : kCGColorSpaceSRGB);
    if (!colorSpace) return;
    CGColorSpaceRef previousColorSpace = _layerColorSpace;
    _layerColorSpace = colorSpace;
    _metalLayer.colorspace = colorSpace;
    if (previousColorSpace) CGColorSpaceRelease(previousColorSpace);
    _displayP3 = displayP3;
    fprintf(stderr, "[metal-native] output color space = %s\n",
            displayP3 ? "Display P3" : "sRGB");
}

- (void)updateDrawableSize {
    if (!_view || !_metalLayer) return;
    NSRect backingBounds = [_view convertRectToBacking:_view.bounds];
    const CGSize size = CGSizeMake(MAX(1.0, backingBounds.size.width),
                                   MAX(1.0, backingBounds.size.height));
    _metalLayer.contentsScale = _view.window.backingScaleFactor;
    if (!CGSizeEqualToSize(_metalLayer.drawableSize, size)) {
        _metalLayer.drawableSize = size;
        fprintf(stderr, "[metal-native] drawable %.0fx%.0f\n", size.width, size.height);
    }
}

- (void)setVisible:(BOOL)visible {
    @autoreleasepool {
        if (visible) {
            if ([self attachViewIfNeeded]) {
                [self updateDrawableSize];
                _view.hidden = NO;
            }
            return;
        }

        if (_view) _view.hidden = YES;
        if (_latestFrame) {
            CVPixelBufferRelease(_latestFrame);
            _latestFrame = NULL;
        }
    }
}

- (void)recordDrop {
    os_unfair_lock_lock(&_statsLock);
    _stats.dropped_frames++;
    os_unfair_lock_unlock(&_statsLock);
}

- (int)renderPixelBuffer:(CVPixelBufferRef)pixelBuffer
                 cursorX:(int)cursorX
                 cursorY:(int)cursorY
             cursorWidth:(int)cursorWidth
            cursorHeight:(int)cursorHeight
           cursorVisible:(BOOL)cursorVisible
              cursorType:(int)cursorType
             cursorLarge:(BOOL)cursorLarge
           rememberFrame:(BOOL)rememberFrame {
    @autoreleasepool {
        if (!pixelBuffer || ![self attachViewIfNeeded]) return -1;
        [self updateDrawableSize];
        [self updateColorSpaceForPixelBuffer:pixelBuffer];
        _view.hidden = NO;

        if (rememberFrame && pixelBuffer != _latestFrame) {
            CVPixelBufferRetain(pixelBuffer);
            if (_latestFrame) CVPixelBufferRelease(_latestFrame);
            _latestFrame = pixelBuffer;
        }

        if (dispatch_semaphore_wait(_inflightSemaphore, DISPATCH_TIME_NOW) != 0) {
            [self recordDrop];
            return 0;
        }

        const size_t width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0);
        const size_t height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0);
        const size_t chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1);
        const size_t chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1);

        CVMetalTextureRef lumaRef = NULL;
        CVMetalTextureRef chromaRef = NULL;
        CVReturn lumaStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, _textureCache, pixelBuffer, NULL,
            MTLPixelFormatR8Unorm, width, height, 0, &lumaRef);
        CVReturn chromaStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, _textureCache, pixelBuffer, NULL,
            MTLPixelFormatRG8Unorm, chromaWidth, chromaHeight, 1, &chromaRef);
        id<MTLTexture> lumaTexture = lumaRef ? CVMetalTextureGetTexture(lumaRef) : nil;
        id<MTLTexture> chromaTexture = chromaRef ? CVMetalTextureGetTexture(chromaRef) : nil;

        if (lumaStatus != kCVReturnSuccess || chromaStatus != kCVReturnSuccess ||
            !lumaTexture || !chromaTexture) {
            if (lumaRef) CFRelease(lumaRef);
            if (chromaRef) CFRelease(chromaRef);
            dispatch_semaphore_signal(_inflightSemaphore);
            fprintf(stderr, "[metal-native] CVMetalTexture creation failed: %d/%d\n",
                    (int)lumaStatus, (int)chromaStatus);
            return -1;
        }

        id<CAMetalDrawable> drawable = [_metalLayer nextDrawable];
        if (!drawable) {
            CFRelease(lumaRef);
            CFRelease(chromaRef);
            dispatch_semaphore_signal(_inflightSemaphore);
            [self recordDrop];
            return 0;
        }

        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);

        TBNativeMetalUniforms uniforms;
        memset(&uniforms, 0, sizeof(uniforms));
        const CGSize drawableSize = _metalLayer.drawableSize;
        uniforms.drawableSize = (vector_float2){(float)drawableSize.width,
                                                (float)drawableSize.height};
        const float sourceWidth = (float)MAX(1, cursorWidth);
        const float sourceHeight = (float)MAX(1, cursorHeight);
        uniforms.cursorPosition = (vector_float2){
            (float)cursorX * (float)drawableSize.width / sourceWidth,
            (float)cursorY * (float)drawableSize.height / sourceHeight
        };
        /* Use drawable pixels, not backingScale. Multiplying by Retina scale
         * made the Metal cursor twice the size of the author's OpenGL fix. */
        const float cursorBase = drawableSize.width >= 5000.0
            ? (cursorLarge ? 58.0f : 32.0f)
            : (cursorLarge ? 44.0f : 24.0f);
        uniforms.cursorSize = (vector_float2){cursorBase * 0.75f,
                                              cursorBase * 1.1875f};
        uniforms.cursorVisible = cursorVisible ? 1u : 0u;
        uniforms.cursorType = (uint32_t)MAX(0, cursorType);
        uniforms.cursorLarge = cursorLarge ? 1u : 0u;
        const OSType format = CVPixelBufferGetPixelFormatType(pixelBuffer);
        uniforms.fullRange =
            format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 1u : 0u;

        id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
        commandBuffer.label = @"TargetBridge NV12 Frame";
        id<MTLRenderCommandEncoder> encoder =
            [commandBuffer renderCommandEncoderWithDescriptor:pass];
        [encoder setRenderPipelineState:_pipeline];
        [encoder setFragmentTexture:lumaTexture atIndex:0];
        [encoder setFragmentTexture:chromaTexture atIndex:1];
        [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [encoder endEncoding];
        [commandBuffer presentDrawable:drawable];

        CVPixelBufferRetain(pixelBuffer);
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            double gpuMS = 0.0;
            if (completed.GPUEndTime > completed.GPUStartTime) {
                gpuMS = (completed.GPUEndTime - completed.GPUStartTime) * 1000.0;
            }
            CVPixelBufferRelease(pixelBuffer);
            CFRelease(lumaRef);
            CFRelease(chromaRef);
            /* Publish completion only after all retained frame resources are
             * released. Callers use this counter as a destruction barrier in
             * benchmarks and diagnostics, so incrementing it earlier exposed
             * a narrow use-after-release race at shutdown. */
            os_unfair_lock_lock(&self->_statsLock);
            self->_stats.completed_frames++;
            self->_stats.gpu_time_ms_total += gpuMS;
            if (gpuMS > self->_stats.gpu_time_ms_max) {
                self->_stats.gpu_time_ms_max = gpuMS;
            }
            os_unfair_lock_unlock(&self->_statsLock);
            dispatch_semaphore_signal(self->_inflightSemaphore);
        }];

        os_unfair_lock_lock(&_statsLock);
        _stats.submitted_frames++;
        os_unfair_lock_unlock(&_statsLock);
        [commandBuffer commit];

        if (!_loggedFirstFrame) {
            _loggedFirstFrame = YES;
            fprintf(stderr,
                    "[metal-native] first NV12 frame %zux%zu submitted without CPU upload\n",
                    width, height);
        }
        return 1;
    }
}

- (int)renderCursorX:(int)cursorX
             cursorY:(int)cursorY
         cursorWidth:(int)cursorWidth
        cursorHeight:(int)cursorHeight
       cursorVisible:(BOOL)cursorVisible
          cursorType:(int)cursorType
         cursorLarge:(BOOL)cursorLarge {
    if (!_latestFrame) return 0;
    return [self renderPixelBuffer:_latestFrame
                           cursorX:cursorX
                           cursorY:cursorY
                       cursorWidth:cursorWidth
                      cursorHeight:cursorHeight
                     cursorVisible:cursorVisible
                        cursorType:cursorType
                       cursorLarge:cursorLarge
                     rememberFrame:NO];
}

- (void)copyStats:(struct tb_native_metal_stats *)stats {
    if (!stats) return;
    os_unfair_lock_lock(&_statsLock);
    *stats = _stats;
    os_unfair_lock_unlock(&_statsLock);
}

- (const char *)colorSpaceName {
    return _displayP3 ? "Display P3" : "sRGB";
}

- (void)waitUntilIdle {
    /* Acquiring every in-flight slot waits for all command-buffer completion
     * handlers, then restores the semaphore for an orderly deallocation. */
    for (int slot = 0; slot < 3; slot++) {
        dispatch_semaphore_wait(_inflightSemaphore, DISPATCH_TIME_FOREVER);
    }
    for (int slot = 0; slot < 3; slot++) {
        dispatch_semaphore_signal(_inflightSemaphore);
    }
}

@end

void *tb_native_metal_create(void) {
    @autoreleasepool {
        TBNativeMetalRenderer *renderer = [[TBNativeMetalRenderer alloc] initRenderer];
        return renderer ? (__bridge_retained void *)renderer : NULL;
    }
}

void tb_native_metal_destroy(void *renderer) {
    if (!renderer) return;
    @autoreleasepool {
        TBNativeMetalRenderer *object = CFBridgingRelease(renderer);
        [object waitUntilIdle];
        [object setVisible:NO];
    }
}

void tb_native_metal_set_visible(void *renderer, int visible) {
    if (!renderer) return;
    @autoreleasepool {
        [(__bridge TBNativeMetalRenderer *)renderer setVisible:visible ? YES : NO];
    }
}

int tb_native_metal_render_nv12(void *renderer,
                                void *pixel_buffer,
                                int cursor_x,
                                int cursor_y,
                                int cursor_source_w,
                                int cursor_source_h,
                                int cursor_visible,
                                int cursor_type,
                                int cursor_large) {
    if (!renderer || !pixel_buffer) return -1;
    @autoreleasepool {
        return [(__bridge TBNativeMetalRenderer *)renderer
            renderPixelBuffer:(CVPixelBufferRef)pixel_buffer
                       cursorX:cursor_x
                       cursorY:cursor_y
                   cursorWidth:cursor_source_w
                  cursorHeight:cursor_source_h
                 cursorVisible:cursor_visible ? YES : NO
                    cursorType:cursor_type
                   cursorLarge:cursor_large ? YES : NO
                 rememberFrame:YES];
    }
}

int tb_native_metal_render_cursor(void *renderer,
                                  int cursor_x,
                                  int cursor_y,
                                  int cursor_source_w,
                                  int cursor_source_h,
                                  int cursor_visible,
                                  int cursor_type,
                                  int cursor_large) {
    if (!renderer) return -1;
    @autoreleasepool {
        return [(__bridge TBNativeMetalRenderer *)renderer
            renderCursorX:cursor_x
                 cursorY:cursor_y
             cursorWidth:cursor_source_w
            cursorHeight:cursor_source_h
           cursorVisible:cursor_visible ? YES : NO
              cursorType:cursor_type
             cursorLarge:cursor_large ? YES : NO];
    }
}

void tb_native_metal_get_stats(void *renderer,
                               struct tb_native_metal_stats *stats) {
    if (!stats) return;
    memset(stats, 0, sizeof(*stats));
    if (!renderer) return;
    @autoreleasepool {
        [(__bridge TBNativeMetalRenderer *)renderer copyStats:stats];
    }
}

const char *tb_native_metal_pixel_buffer_color_space(void *pixel_buffer) {
    return tb_pixel_buffer_uses_display_p3((CVPixelBufferRef)pixel_buffer)
        ? "Display P3"
        : "sRGB";
}

const char *tb_native_metal_color_space_name(void *renderer) {
    if (!renderer) return "unavailable";
    @autoreleasepool {
        return [(__bridge TBNativeMetalRenderer *)renderer colorSpaceName];
    }
}
