#import "renderer_policy.h"
#import "tb_native_metal_renderer.h"

#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static CVPixelBufferRef make_frame(size_t width, size_t height) {
    CVPixelBufferRef pixelBuffer = NULL;
    CFDictionaryRef attributes = (__bridge CFDictionaryRef)@{
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES
    };
    CVReturn status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        attributes,
        &pixelBuffer);
    if (status != kCVReturnSuccess || !pixelBuffer) return NULL;

    if (CVPixelBufferLockBaseAddress(pixelBuffer, 0) == kCVReturnSuccess) {
        memset(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
               128,
               CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) *
                   CVPixelBufferGetHeightOfPlane(pixelBuffer, 0));
        memset(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1),
               128,
               CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) *
                   CVPixelBufferGetHeightOfPlane(pixelBuffer, 1));
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    }
    CVBufferSetAttachment(pixelBuffer,
                          kCVImageBufferColorPrimariesKey,
                          kCVImageBufferColorPrimaries_P3_D65,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixelBuffer,
                          kCVImageBufferTransferFunctionKey,
                          kCVImageBufferTransferFunction_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixelBuffer,
                          kCVImageBufferYCbCrMatrixKey,
                          kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    return pixelBuffer;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        const int width = argc > 1 ? atoi(argv[1]) : 4096;
        const int height = argc > 2 ? atoi(argv[2]) : 2304;
        const int frameCount = argc > 3 ? atoi(argv[3]) : 180;
        const int targetFPS = argc > 4 ? atoi(argv[4]) : 60;
        if (width <= 0 || height <= 0 || frameCount < 120 || targetFPS <= 0) {
            fprintf(stderr, "usage: benchmark_native_metal_renderer [width height frames>=120 fps]\n");
            return 64;
        }
        if (!MTLCreateSystemDefaultDevice()) {
            fprintf(stderr, "TB_METAL_BENCHMARK result=unavailable reason=no-metal-device\n");
            return 69;
        }

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        const CGFloat windowWidth = MAX(1.0, (CGFloat)width / 2.0);
        const CGFloat windowHeight = MAX(1.0, (CGFloat)height / 2.0);
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, windowWidth, windowHeight)
                      styleMask:NSWindowStyleMaskBorderless
                        backing:NSBackingStoreBuffered
                          defer:NO];
        window.title = @"TargetBridge Metal Benchmark";
        /* Command-line AppKit harnesses own this window through ARC. Avoid the
         * legacy close-time self-release, which would otherwise release it a
         * second time when the autorelease pool drains. */
        window.releasedWhenClosed = NO;
        window.alphaValue = 0.02;
        [window orderFront:nil];
        [[NSRunLoop currentRunLoop]
            runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];

        CVPixelBufferRef pixelBuffer = make_frame((size_t)width, (size_t)height);
        void *renderer = tb_native_metal_create();
        if (!pixelBuffer || !renderer) {
            fprintf(stderr, "TB_METAL_BENCHMARK result=failed reason=setup\n");
            if (pixelBuffer) CVPixelBufferRelease(pixelBuffer);
            if (renderer) tb_native_metal_destroy(renderer);
            [window close];
            return 70;
        }

        const CFTimeInterval started = CACurrentMediaTime();
        double submitTimeMsTotal = 0.0;
        double submitTimeMsMax = 0.0;
        for (int frame = 0; frame < frameCount; frame++) {
            const CFTimeInterval submitStarted = CACurrentMediaTime();
            (void)tb_native_metal_render_nv12(
                renderer,
                pixelBuffer,
                (frame * 13) % width,
                (frame * 7) % height,
                width,
                height,
                1,
                0,
                0);
            const double submitTimeMs =
                (CACurrentMediaTime() - submitStarted) * 1000.0;
            submitTimeMsTotal += submitTimeMs;
            if (submitTimeMs > submitTimeMsMax) submitTimeMsMax = submitTimeMs;
            const CFTimeInterval target = started +
                (CFTimeInterval)(frame + 1) / (CFTimeInterval)targetFPS;
            const CFTimeInterval delay = target - CACurrentMediaTime();
            if (delay > 0) {
                [[NSRunLoop currentRunLoop]
                    runUntilDate:[NSDate dateWithTimeIntervalSinceNow:delay]];
            }
        }

        struct tb_native_metal_stats stats;
        const CFTimeInterval completionDeadline = CACurrentMediaTime() + 3.0;
        do {
            tb_native_metal_get_stats(renderer, &stats);
            if (stats.completed_frames >= stats.submitted_frames) break;
            [[NSRunLoop currentRunLoop]
                runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        } while (CACurrentMediaTime() < completionDeadline);

        tb_native_metal_get_stats(renderer, &stats);
        const struct tb_renderer_health_sample sample = {
            stats.submitted_frames,
            stats.completed_frames,
            stats.dropped_frames,
            stats.gpu_time_ms_total
        };
        const struct tb_renderer_health_result health =
            tb_renderer_evaluate_health(&sample);
        const double elapsed = CACurrentMediaTime() - started;
        const char *decision = health.decision == TB_RENDERER_HEALTH_KEEP_METAL
            ? "metal"
            : health.decision == TB_RENDERER_HEALTH_FALLBACK_OPENGL
                ? "opengl"
                : "insufficient-sample";
        printf(
            "TB_METAL_BENCHMARK result=%s size=%dx%d requested=%d targetFPS=%d "
            "elapsed=%.3fs submitted=%llu completed=%llu dropped=%llu "
            "submitAvg=%.3fms submitMax=%.3fms gpuAvg=%.3fms gpuMax=%.3fms "
            "color=%s\n",
            decision,
            width,
            height,
            frameCount,
            targetFPS,
            elapsed,
            (unsigned long long)stats.submitted_frames,
            (unsigned long long)stats.completed_frames,
            (unsigned long long)stats.dropped_frames,
            submitTimeMsTotal / (double)frameCount,
            submitTimeMsMax,
            health.gpu_average_ms,
            stats.gpu_time_ms_max,
            tb_native_metal_color_space_name(renderer));

        CVPixelBufferRelease(pixelBuffer);
        tb_native_metal_destroy(renderer);
        [window close];
        return health.decision == TB_RENDERER_HEALTH_KEEP_METAL ? 0 : 2;
    }
}
