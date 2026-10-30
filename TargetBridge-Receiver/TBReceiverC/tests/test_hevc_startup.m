/* Optional macOS hardware regression. Synthetic pixels only: no capture,
 * window, network, input hooks, or display-setting changes.
 *
 * Match the 4.5K HEVC preset and submit only 1, 2, or 3 frames. The Sender
 * reserves at most three pending/encoding frames, so testing after a large
 * batch or forced flush could hide an encoder startup deadlock. Callbacks
 * return to a serial pipeline queue, as in the Sender. Check the callbacks
 * BEFORE CompleteFrames, then feed the production Receiver decoder. */
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include <assert.h>
#include <dlfcn.h>
#include <unistd.h>
#include <libavcodec/avcodec.h>
#include "decoder.h"

typedef struct {
    CFMutableArrayRef samples;
    __unsafe_unretained dispatch_queue_t queue;
    __unsafe_unretained dispatch_semaphore_t callbacks;
    int errors;
    int in_flight;
} Encoded;

static void encoded(void *opaque, void *source, OSStatus status,
                    VTEncodeInfoFlags flags, CMSampleBufferRef sample) {
    (void)source; (void)flags;
    Encoded *e = opaque;
    if (sample) CFRetain(sample);
    dispatch_async(e->queue, ^{
        e->in_flight--;
        if (status || !sample) {
            fprintf(stderr, "encode callback status=%d sample=%p\n", (int)status, sample);
            e->errors++;
        } else {
            CFArrayAppendValue(e->samples, sample);
        }
        if (sample) CFRelease(sample);
        dispatch_semaphore_signal(e->callbacks);
    });
}

typedef struct { int width, height, count; } Decoded;
static void decoded(const uint8_t *y, int ys, const uint8_t *uv, int uvs,
                    int width, int height, void *opaque) {
    Decoded *d = opaque;
    assert(y && uv && ys >= width && uvs >= width);
    assert(width == d->width && height == d->height);
    /* Both input formats are gray. Allow the lossy encoder and video-range
     * RGB conversion a small tolerance while rejecting invalid NV12 planes. */
    assert(abs((int)y[width / 2] - 96) <= 8);
    assert(abs((int)uv[width / 2] - 128) <= 8);
    d->count++;
}

static void set_params(struct tb_decoder *decoder, CMSampleBufferRef sample) {
    CMVideoFormatDescriptionRef desc = CMSampleBufferGetFormatDescription(sample);
    size_t count = 0;
    int nalu_bytes = 0;
    assert(CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(desc, 0, NULL, NULL,
                                                           &count, &nalu_bytes) == noErr);
    assert(count > 0 && count <= 255 && nalu_bytes == 4);
    NSMutableData *payload = [NSMutableData data];
    uint8_t head[] = {2, (uint8_t)count};
    [payload appendBytes:head length:sizeof(head)];
    for (size_t i = 0; i < count; ++i) {
        const uint8_t *bytes = NULL;
        size_t size = 0;
        assert(CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(desc, i, &bytes, &size,
                                                               NULL, NULL) == noErr);
        assert(size > 0 && size <= UINT32_MAX);
        uint32_t be = CFSwapInt32HostToBig((uint32_t)size);
        [payload appendBytes:&be length:sizeof(be)];
        [payload appendBytes:bytes length:size];
    }
    assert(tb_dec_set_param_sets(decoder, payload.bytes, payload.length) == 0);
}

static void set_property(VTCompressionSessionRef encoder, CFStringRef key,
                         CFTypeRef value, int required) {
    OSStatus status = VTSessionSetProperty(encoder, key, value);
    if (status) fprintf(stderr, "property %s status=%d (%s)\n",
                        [(__bridge NSString *)key UTF8String], (int)status,
                        required ? "required" : "optional");
    assert(!required || status == noErr);
}

static void probe(int width, int height, int frame_count, int bgra) {
    dispatch_queue_t pipeline = dispatch_queue_create("test.hevc.pipeline", DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t callbacks = dispatch_semaphore_create(0);
    Encoded state = { .samples = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks),
                      .queue = pipeline, .callbacks = callbacks };
    Encoded *e = &state;
    VTCompressionSessionRef encoder = NULL;
    NSDictionary *spec = @{(__bridge NSString *)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: @YES,
                           (__bridge NSString *)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES};
    OSStatus status = VTCompressionSessionCreate(NULL, width, height, kCMVideoCodecType_HEVC,
        (__bridge CFDictionaryRef)spec, NULL, NULL, encoded, e, &encoder);
    if (status) fprintf(stderr, "create HEVC hardware encoder %dx%d status=%d\n", width, height, (int)status);
    assert(status == noErr && encoder);
    set_property(encoder, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue, 1);
    set_property(encoder, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel, 1);
    set_property(encoder, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse, 1);
    set_property(encoder, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFNumberRef)@60, 0);
    set_property(encoder, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFNumberRef)@60, 0);
    set_property(encoder, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, (__bridge CFNumberRef)@1, 0);
    /* Some hardware encoders return kVTPropertyNotSupportedErr for zero while
     * still emitting the first frame promptly. Preserve that compatibility. */
    set_property(encoder, kVTCompressionPropertyKey_MaxFrameDelayCount, (__bridge CFNumberRef)@0, 0);
    set_property(encoder, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFNumberRef)@120000000, 0);
    set_property(encoder, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue, 0);
    assert(VTCompressionSessionPrepareToEncodeFrames(encoder) == noErr);

    CVPixelBufferRef pixel = NULL;
    NSDictionary *attrs = @{(__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    assert(CVPixelBufferCreate(NULL, width, height,
        bgra ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        (__bridge CFDictionaryRef)attrs, &pixel) == kCVReturnSuccess);
    assert(CVPixelBufferLockBaseAddress(pixel, 0) == kCVReturnSuccess);
    if (bgra) {
        uint8_t *pixels = CVPixelBufferGetBaseAddress(pixel);
        for (int y = 0; y < height; ++y) {
            uint8_t *row = pixels + y * CVPixelBufferGetBytesPerRow(pixel);
            for (int x = 0; x < width; ++x) {
                row[4 * x] = row[4 * x + 1] = row[4 * x + 2] = 96;
                row[4 * x + 3] = 255;
            }
        }
    } else {
        memset(CVPixelBufferGetBaseAddressOfPlane(pixel, 0), 96, CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) * height);
        memset(CVPixelBufferGetBaseAddressOfPlane(pixel, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(pixel, 1) * height / 2);
    }
    CVPixelBufferUnlockBaseAddress(pixel, 0);
    for (int i = 0; i < frame_count; ++i) {
        dispatch_sync(pipeline, ^{
            /* pending=0 because this isolated test has no network. */
            assert(e->in_flight < 3);
            e->in_flight++;
            OSStatus result = VTCompressionSessionEncodeFrame(encoder, pixel, CMTimeMake(i, 60),
                                                               kCMTimeInvalid, NULL, NULL, NULL);
            if (result) fprintf(stderr, "encode frame %d status=%d\n", i, (int)result);
            assert(result == noErr);
        });
        usleep(16667);
    }
    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC);
    for (int i = 0; i < frame_count; ++i) {
        if (dispatch_semaphore_wait(callbacks, deadline)) break;
    }
    __block CFIndex preflush_count = 0;
    dispatch_sync(pipeline, ^{ preflush_count = CFArrayGetCount(e->samples); });
    fprintf(stderr, "BEFORE FLUSH %dx%d %s submitted=%d received=%ld\n",
            width, height, bgra ? "BGRA" : "NV12", frame_count, (long)preflush_count);
    /* Flush only for cleanup after recording the startup result. A flush can
     * never turn a failed preflush_count assertion into a passing test. */
    assert(VTCompressionSessionCompleteFrames(encoder, kCMTimeInvalid) == noErr);
    dispatch_sync(pipeline, ^{});
    VTCompressionSessionInvalidate(encoder);
    CFRelease(encoder);
    CVPixelBufferRelease(pixel);
    assert(e->errors == 0 && preflush_count == frame_count);

    Decoded d = {.width = width, .height = height};
    struct tb_decoder *decoder = tb_dec_create(decoded, &d);
    assert(decoder && tb_dec_supports_hevc_hwdecode());
    for (CFIndex i = 0; i < preflush_count; ++i) {
        CMSampleBufferRef sample = (CMSampleBufferRef)CFArrayGetValueAtIndex(e->samples, i);
        if (i == 0) set_params(decoder, sample);
        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
        size_t length = CMBlockBufferGetDataLength(block);
        NSMutableData *data = [NSMutableData dataWithLength:length];
        assert(CMBlockBufferCopyDataBytes(block, 0, length, data.mutableBytes) == kCMBlockBufferNoErr);
        assert(tb_dec_feed_frame(decoder, data.bytes, data.length) == 0);
        /* Includes the first AVCC packet: the Receiver must not need a later
         * keyframe or extra packets to produce its first NV12 callback. */
        assert(d.count == i + 1);
    }
    tb_dec_destroy(decoder);
    CFRelease(e->samples);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        int width = 4480, height = 2520;
        assert(argc == 1 || argc == 3);
        if (argc == 3) { width = atoi(argv[1]); height = atoi(argv[2]); }
        assert(width > 0 && height > 0 && width <= 5120 && height <= 2880);
        assert(width % 2 == 0 && height % 2 == 0);
        Dl_info dylib = {0};
        assert(dladdr(avcodec_version, &dylib));
        fprintf(stderr, "avcodec %u loaded from %s\n", avcodec_version(), dylib.dli_fname);
        for (int bgra = 0; bgra <= 1; ++bgra) {
            for (int frames = 1; frames <= 3; ++frames) probe(width, height, frames, bgra);
        }
        puts("HEVC startup: all NV12/BGRA 1/2/3-frame cases passed without startup flush");
    }
    return 0;
}
