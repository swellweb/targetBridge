/* Optional Metal encoder parity test. Uses synthetic opaque pixels only: no
 * screen capture, windows, network, or permissions. Exit 77 means no GPU. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "tb_dpcm.h"
#include "tb_dpcm_gpu.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Include the production implementation so faults can replace just its Metal
 * device/queue boundary, without introducing test hooks into the public API. */
static id<MTLDevice> tb_test_device;
static id<MTLDevice> tb_test_default_device(void) {
    return tb_test_device ?: MTLCreateSystemDefaultDevice();
}
#define MTLCreateSystemDefaultDevice tb_test_default_device
#include "../../../TargetBridge-Shared/codec/tb_dpcm_gpu.m"
#undef MTLCreateSystemDefaultDevice

typedef NS_ENUM(int, TBFault) {
    TBAnalyzeBufferMissing = 1,
    TBAnalyzeEncoderMissing,
    TBAnalyzeNotCompleted,
    TBAnalyzeErrorWithoutNSError,
    TBPackBufferMissing,
    TBBlitEncoderMissing,
    TBPackEncoderMissing,
    TBPackNotCompleted,
    TBPackErrorWithoutNSError
};

@interface TBFaultCommandBuffer : NSObject
@property(nonatomic, strong) id<MTLCommandBuffer> real;
@property(nonatomic) TBFault fault;
@property(nonatomic) int phase;
@end
@implementation TBFaultCommandBuffer
- (id)forwardingTargetForSelector:(SEL)selector { return self.real; }
- (id<MTLComputeCommandEncoder>)computeCommandEncoder {
    if ((self.phase == 1 && self.fault == TBAnalyzeEncoderMissing) ||
        (self.phase == 2 && self.fault == TBPackEncoderMissing)) return nil;
    return [self.real computeCommandEncoder];
}
- (id<MTLBlitCommandEncoder>)blitCommandEncoder {
    if (self.fault == TBBlitEncoderMissing) return nil;
    return [self.real blitCommandEncoder];
}
- (MTLCommandBufferStatus)status {
    if ((self.phase == 1 && self.fault == TBAnalyzeNotCompleted) ||
        (self.phase == 2 && self.fault == TBPackNotCompleted))
        return MTLCommandBufferStatusScheduled;
    if ((self.phase == 1 && self.fault == TBAnalyzeErrorWithoutNSError) ||
        (self.phase == 2 && self.fault == TBPackErrorWithoutNSError))
        return MTLCommandBufferStatusError;
    return self.real.status;
}
- (NSError *)error { return nil; }
@end

@interface TBFaultQueue : NSObject
@property(nonatomic, strong) id<MTLCommandQueue> real;
@property(nonatomic) TBFault fault;
@property(nonatomic) int phase;
@end
@implementation TBFaultQueue
- (id<MTLCommandBuffer>)commandBuffer {
    self.phase += 1;
    if ((self.phase == 1 && self.fault == TBAnalyzeBufferMissing) ||
        (self.phase == 2 && self.fault == TBPackBufferMissing)) return nil;
    TBFaultCommandBuffer *buffer = [TBFaultCommandBuffer new];
    buffer.real = [self.real commandBuffer];
    buffer.fault = self.fault;
    buffer.phase = self.phase;
    return (id<MTLCommandBuffer>)buffer;
}
@end

@interface TBFaultDevice : NSObject
@property(nonatomic, strong) id<MTLDevice> real;
@property(nonatomic) int failure;
@end
@implementation TBFaultDevice
- (id)forwardingTargetForSelector:(SEL)selector { return self.real; }
- (id<MTLLibrary>)newLibraryWithSource:(NSString *)source
                              options:(MTLCompileOptions *)options
                                error:(NSError **)error {
    if (self.failure == 1) return nil;
    return [self.real newLibraryWithSource:source options:options error:error];
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)function
                                                           error:(NSError **)error {
    if (self.failure == 2) return nil;
    return [self.real newComputePipelineStateWithFunction:function error:error];
}
- (id<MTLCommandQueue>)newCommandQueue {
    if (self.failure == 3) return nil;
    return [self.real newCommandQueue];
}
@end

static int check_create_failures(id<MTLDevice> real) {
    int failures = 0;
    for (int fault = 1; fault <= 3; ++fault) {
        __weak TBFaultDevice *weakDevice = nil;
        @autoreleasepool {
            TBFaultDevice *device = [TBFaultDevice new];
            device.real = real;
            device.failure = fault;
            weakDevice = device;
            tb_test_device = (id<MTLDevice>)device;
            tb_dpcm_gpu *encoder = tb_dpcm_gpu_create();
            tb_test_device = nil;
            if (encoder) {
                fprintf(stderr, "FAIL create fault %d returned an encoder\n", fault);
                ++failures;
                tb_dpcm_gpu_destroy(encoder);
            }
        }
        if (weakDevice) {
            fprintf(stderr, "FAIL create fault %d leaked its retained device\n", fault);
            ++failures;
        }
    }
    return failures;
}

static int check_submission_failures(tb_dpcm_gpu *encoder) {
    int failures = 0;
    uint32_t pixels[64];
    for (int i = 0; i < 64; ++i)
        pixels[i] = (3u << 30) | ((uint32_t)i << 20) | ((uint32_t)(63 - i) << 10) | (uint32_t)i;
    const uint8_t sentinel = 0;
    id<MTLCommandQueue> real = encoder->queue;
    for (int fault = TBAnalyzeBufferMissing; fault <= TBPackErrorWithoutNSError; ++fault) {
        /* Seed reusable buffers with an earlier frame. A failed submission must
         * not report those old pixels/metadata as a successful new frame. */
        const uint8_t *blob = NULL;
        if (!tb_dpcm_gpu_encode(encoder, (const uint8_t *)pixels, 32, 8, 8, 1, 0, &blob))
            return failures + 1;
        pixels[0] ^= 1u;
        TBFaultQueue *queue = [TBFaultQueue new];
        queue.real = real;
        queue.fault = fault;
        encoder->queue = (id<MTLCommandQueue>)queue;
        blob = &sentinel;
        const size_t len = tb_dpcm_gpu_encode(encoder, (const uint8_t *)pixels,
                                               32, 8, 8, 1, 0, &blob);
        encoder->queue = real;
        if (len != 0 || blob != &sentinel) {
            fprintf(stderr, "FAIL submission fault %d returned stale/unfinished output\n", fault);
            ++failures;
        }
        tb_dpcm_gpu_band band = { &sentinel, 17 };
        queue.phase = 0;
        encoder->queue = (id<MTLCommandQueue>)queue;
        const size_t band_len = tb_dpcm_gpu_encode_bands(encoder, (const uint8_t *)pixels,
                                                        32, 8, 8, 1, 1, 0, &band);
        encoder->queue = real;
        if (band_len != 0 || band.blob != &sentinel || band.len != 17) {
            fprintf(stderr, "FAIL submission fault %d mutated failed band output\n", fault);
            ++failures;
        }
        queue.phase = 0;
        encoder->queue = (id<MTLCommandQueue>)queue;
        blob = &sentinel;
        const size_t adaptive_len = tb_dpcm_gpu_encode_adaptive(encoder,
            (const uint8_t *)pixels, 32, 8, 8, 1, 0, &blob);
        encoder->queue = real;
        if (adaptive_len != 0 || blob != &sentinel) {
            fprintf(stderr, "FAIL submission fault %d mutated failed adaptive output\n", fault);
            ++failures;
        }
    }
    return failures;
}

static int check_frame(tb_dpcm_gpu *encoder, int w, int h, int ten_bit,
                       int pattern, int unaligned, int adaptive) {
    const int stride = (w * 4 + 63) & ~63;
    const size_t bytes = (size_t)stride * h;
    const size_t page = (size_t)getpagesize();
    const size_t allocation = (bytes + page) & ~(page - 1);
    void *storage = NULL;
    if (posix_memalign(&storage, page, allocation) != 0) return 1;
    uint8_t *src = (uint8_t *)storage + unaligned;
    memset(storage, 0, allocation);
    const uint32_t mask = ten_bit ? 1023u : 255u;
    uint32_t rng = 0xC0FFEEu;
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
            uint32_t b = pattern == 0 ? 129u : (uint32_t)x;
            uint32_t g = pattern == 0 ? 65u : mask - ((uint32_t)x & mask);
            uint32_t r = pattern == 0 ? 3u : (uint32_t)x * 5u + (uint32_t)y;
            if (pattern == 2) { b = rng; g = rng >> 7; r = rng >> 13; }
            if (pattern == 3 || (pattern == 4 && ((x / 8 + y / 8) & 1) == 0))
                b = g = r = ((uint32_t)x * 13u + (uint32_t)y * 7u) & mask;
            if (pattern == 5 || (pattern == 4 && ((x / 8 + y / 8) & 1) != 0)) {
                g = ((uint32_t)x + (uint32_t)y) & mask;
                b = r = mask - g;
            }
            /* Alpha is omitted. Vary it in mixed-domain frames so an input
             * alpha bit cannot accidentally become the tile's domain marker. */
            const uint32_t alpha = pattern == 4 ? (rng & (ten_bit ? 3u : 255u))
                                                : (ten_bit ? 3u : 255u);
            const uint32_t pixel = ten_bit
                ? (alpha << 30) | ((r & mask) << 20) | ((g & mask) << 10) | (b & mask)
                : (alpha << 24) | ((r & mask) << 16) | ((g & mask) << 8) | (b & mask);
            memcpy(src + (size_t)y * stride + (size_t)x * 4, &pixel, 4);
        }
    }
    const size_t capacity = tb_dpcm_max_size(w, h);
    uint8_t *reference = malloc(capacity);
    uint8_t *decoded = calloc(1, bytes);
    int failed = 1;
    if (reference && decoded) {
        const size_t legacy_len = tb_dpcm_encode(src, stride, w, h, ten_bit,
                                                reference, capacity);
        const size_t cpu_len = adaptive
            ? tb_dpcm_encode_adaptive(src, stride, w, h, ten_bit, reference, capacity)
            : legacy_len;
        const uint8_t *gpu_blob = NULL;
        const size_t reserve = adaptive && unaligned ? 5 : 0;
        const size_t returned_len = adaptive
            ? tb_dpcm_gpu_encode_adaptive(encoder, src, stride, w, h, ten_bit, reserve, &gpu_blob)
            : tb_dpcm_gpu_encode(encoder, src, stride, w, h, ten_bit, reserve, &gpu_blob);
        failed = !cpu_len || !gpu_blob || returned_len != cpu_len + reserve;
        const size_t gpu_len = returned_len >= reserve ? returned_len - reserve : 0;
        if (!failed && reserve) {
            memset((uint8_t *)gpu_blob, 0xA5, reserve);
            gpu_blob += reserve;
        }
        if (!failed) failed = gpu_len > legacy_len;
        if (!failed) failed = memcmp(reference, gpu_blob, cpu_len) != 0;
        struct tb_dpcm_info info;
        if (!failed) failed = tb_dpcm_parse(gpu_blob, gpu_len, &info) != 0;
        if (!failed) failed = info.adaptive_color != adaptive;
        if (!failed && adaptive) {
            unsigned green_tiles = 0;
            for (uint32_t t = 0; t < info.tile_count; ++t) {
                uint32_t seed;
                memcpy(&seed, gpu_blob + info.seed_plane_off + (size_t)t * 4, 4);
                green_tiles += (seed & TB_DPCM_SEED_ADAPTIVE_COLOR) != 0;
            }
            if ((pattern == 0 || pattern == 5) && green_tiles != 0) failed = 1;
            if (pattern == 4 && w >= 16 && h >= 8 &&
                (green_tiles == 0 || green_tiles == info.tile_count)) failed = 1;
            if (pattern == 3 && w * h >= 4096 && gpu_len * 2 >= legacy_len) failed = 1;
        }
        if (!failed) failed = tb_dpcm_decode(gpu_blob, gpu_len, decoded, stride) != 0;
        const uint32_t alpha_mask = ten_bit ? (3u << 30) : (255u << 24);
        for (int y = 0; !failed && y < h; ++y) {
            for (int x = 0; !failed && x < w; ++x) {
                uint32_t want, got;
                memcpy(&want, src + (size_t)y * stride + (size_t)x * 4, 4);
                memcpy(&got, decoded + (size_t)y * stride + (size_t)x * 4, 4);
                failed = got != (want | alpha_mask);
            }
        }
    }
    if (failed)
        fprintf(stderr, "FAIL GPU parity %dx%d %d-bit pattern=%d unaligned=%d adaptive=%d\n",
                w, h, ten_bit ? 10 : 8, pattern, unaligned, adaptive);
    free(decoded); free(reference); free(storage);
    return failed;
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            fprintf(stderr, "SKIP GPU parity: no Metal device\n");
            return 77;
        }
        tb_dpcm_gpu *encoder = tb_dpcm_gpu_create();
        if (!encoder) {
            fprintf(stderr, "FAIL GPU parity: encoder creation failed\n");
            return 1;
        }
        printf("GPU parity device: %s\n", tb_dpcm_gpu_device_name(encoder));
        const int sizes[][2] = {{1,1}, {7,5}, {8,8}, {65,17}, {1024,9}};
        int failures = check_create_failures(device) + check_submission_failures(encoder);
        printf("GPU fault injection: 3 creation and 9 submission cases, %d failures\n", failures);
        int checks = 0;
        for (int ten = 0; ten <= 1; ++ten)
            for (size_t i = 0; i < sizeof(sizes) / sizeof(sizes[0]); ++i)
                for (int pattern = 0; pattern < 3; ++pattern)
                    for (int unaligned = 0; unaligned <= 1; ++unaligned) {
                        failures += check_frame(encoder, sizes[i][0], sizes[i][1],
                                                ten, pattern, unaligned, 0);
                        ++checks;
                    }
        // Native M1 iMac resolution leaves 16 tiles in the last 64-tile group.
        for (int pattern = 0; pattern < 3; ++pattern) {
            failures += check_frame(encoder, 4480, 2520, 1, pattern, 0, 0);
            ++checks;
        }
        const int adaptive_sizes[][2] = {{1,1}, {7,5}, {8,8}, {16,8}, {65,17}, {1024,9}};
        for (int ten = 0; ten <= 1; ++ten)
            for (size_t i = 0; i < sizeof(adaptive_sizes) / sizeof(adaptive_sizes[0]); ++i)
                for (int pattern = 0; pattern < 6; ++pattern)
                    for (int unaligned = 0; unaligned <= 1; ++unaligned) {
                        failures += check_frame(encoder, adaptive_sizes[i][0], adaptive_sizes[i][1],
                                                ten, pattern, unaligned, 1);
                        ++checks;
                    }
        for (int pattern = 2; pattern <= 4; ++pattern) {
            failures += check_frame(encoder, 4480, 2520, 1, pattern, 0, 1);
            ++checks;
        }
        tb_dpcm_gpu_destroy(encoder);
        printf("GPU parity: %d frames, %d failures\n", checks, failures);
        return failures ? 1 : 0;
    }
}
