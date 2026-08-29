#import "tb_native_metal_renderer.h"

#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>

#include <stdio.h>
#include <string.h>

int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            printf("native Metal renderer test: skipped (no Metal device)\n");
            return 0;
        }

        void *renderer = tb_native_metal_create();
        if (!renderer) {
            fprintf(stderr,
                    "native Metal renderer test: device exists but renderer/shader creation failed\n");
            return 1;
        }
        CVPixelBufferRef pixelBuffer = NULL;
        CFDictionaryRef attributes = (__bridge CFDictionaryRef)@{
            (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        CVReturn status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            640,
            360,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes,
            &pixelBuffer);
        if (status != kCVReturnSuccess || !pixelBuffer) {
            fprintf(stderr, "native Metal renderer test: pixel buffer creation failed\n");
            tb_native_metal_destroy(renderer);
            return 1;
        }

        if (strcmp(tb_native_metal_pixel_buffer_color_space(pixelBuffer), "sRGB") != 0) {
            fprintf(stderr, "native Metal renderer test: untagged buffer must use sRGB\n");
            CVPixelBufferRelease(pixelBuffer);
            tb_native_metal_destroy(renderer);
            return 1;
        }
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_P3_D65,
            kCVAttachmentMode_ShouldPropagate);
        if (strcmp(tb_native_metal_pixel_buffer_color_space(pixelBuffer), "Display P3") != 0) {
            fprintf(stderr, "native Metal renderer test: P3 metadata not recognized\n");
            CVPixelBufferRelease(pixelBuffer);
            tb_native_metal_destroy(renderer);
            return 1;
        }

        CVPixelBufferRelease(pixelBuffer);
        tb_native_metal_destroy(renderer);
        printf("native Metal renderer test: device=%s shader/pipeline passed\n",
               device.name.UTF8String ?: "unknown");
        return 0;
    }
}
