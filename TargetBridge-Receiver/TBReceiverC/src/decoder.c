/* decoder.c — FFmpeg HEVC hardware decoder.
 *
 * Strategy: VideoToolbox HW decode → av_hwframe_transfer_data → NV12 in CPU
 * memory → upload to SDL texture (Metal renderer). Single GPU→CPU→GPU hop,
 * acceptable for ~30 fps 2560×1440. Zero ObjC at this layer.
 */

#include "decoder.h"

#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libavutil/pixdesc.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__)
#  include <CoreVideo/CoreVideo.h>
#endif

#define ANNEXB_START   "\x00\x00\x00\x01"
#define ANNEXB_START_N 4

struct tb_decoder {
    const AVCodec    *codec;
    enum AVCodecID    codec_id;
    AVCodecContext   *ctx;
    AVBufferRef      *hw_dev;
    AVFrame          *hw_frame;
    AVFrame          *sw_frame;
    AVPacket         *pkt;

    uint8_t          *extradata;
    int               extradata_size;

    /* scratch for AVCC→Annex B conversion */
    uint8_t          *scratch;
    size_t            scratch_cap;

    tb_frame_cb       cb;
    void             *ud;

    int               opened;
};

/* Detect available HW device type (platform-specific). */
static enum AVHWDeviceType pick_hwdev(void) {
#if defined(__APPLE__)
    return AV_HWDEVICE_TYPE_VIDEOTOOLBOX;
#elif defined(__linux__)
    return AV_HWDEVICE_TYPE_VAAPI;
#elif defined(_WIN32)
    return AV_HWDEVICE_TYPE_D3D11VA;
#else
    return AV_HWDEVICE_TYPE_NONE;
#endif
}

static enum AVPixelFormat hw_pix_fmt;

static enum AVPixelFormat get_hw_format(AVCodecContext *ctx,
                                        const enum AVPixelFormat *pix_fmts) {
    (void)ctx;
    for (const enum AVPixelFormat *p = pix_fmts; *p != -1; p++) {
        if (*p == hw_pix_fmt) return *p;
    }
    fprintf(stderr, "[dec] no HW pix fmt available\n");
    return AV_PIX_FMT_NONE;
}

struct tb_decoder *tb_dec_create(tb_frame_cb cb, void *ud) {
    struct tb_decoder *d = (struct tb_decoder *)calloc(1, sizeof(*d));
    if (!d) return NULL;
    d->cb       = cb;
    d->ud       = ud;
    d->hw_frame = av_frame_alloc();
    d->sw_frame = av_frame_alloc();
    d->pkt      = av_packet_alloc();
    if (!d->hw_frame || !d->sw_frame || !d->pkt) {
        tb_dec_destroy(d); return NULL;
    }
    return d;
}

void tb_dec_reset(struct tb_decoder *d) {
    if (!d) return;
    if (d->ctx) avcodec_free_context(&d->ctx);
    av_free(d->extradata);
    d->extradata      = NULL;
    d->extradata_size = 0;
    d->opened         = 0;
    /* hw_dev, hw_frame, sw_frame, pkt stay allocated for reuse. */
}

void tb_dec_destroy(struct tb_decoder *d) {
    if (!d) return;
    if (d->ctx)      avcodec_free_context(&d->ctx);
    if (d->hw_dev)   av_buffer_unref(&d->hw_dev);
    if (d->hw_frame) av_frame_free(&d->hw_frame);
    if (d->sw_frame) av_frame_free(&d->sw_frame);
    if (d->pkt)      av_packet_free(&d->pkt);
    av_free(d->extradata);   /* allocated with av_malloc */
    free(d->scratch);
    free(d);
}

/* Parse param-set payload and build Annex B extradata buffer. */
static int build_extradata(struct tb_decoder *d,
                           const uint8_t *payload, size_t len) {
    if (len < 2) return -1;

    switch (payload[0]) {
    case 1:
        d->codec_id = AV_CODEC_ID_H264;
        break;
    case 2:
        d->codec_id = AV_CODEC_ID_HEVC;
        break;
    default:
        fprintf(stderr, "[dec] unsupported codec marker %u\n", (unsigned)payload[0]);
        return -1;
    }

    int count = payload[1];
    size_t off = 2;

    size_t need = 0;
    /* first pass: compute size */
    size_t tmp_off = off;
    for (int i = 0; i < count; i++) {
        if (tmp_off + 4 > len) return -1;
        uint32_t sz = ((uint32_t)payload[tmp_off]     << 24) |
                      ((uint32_t)payload[tmp_off + 1] << 16) |
                      ((uint32_t)payload[tmp_off + 2] << 8)  |
                       (uint32_t)payload[tmp_off + 3];
        tmp_off += 4;
        if (tmp_off + sz > len) return -1;
        need += ANNEXB_START_N + sz;
        tmp_off += sz;
    }

    av_free(d->extradata);
    d->extradata = (uint8_t *)av_malloc(need + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!d->extradata) return -1;
    memset(d->extradata + need, 0, AV_INPUT_BUFFER_PADDING_SIZE);

    size_t out = 0;
    for (int i = 0; i < count; i++) {
        uint32_t sz = ((uint32_t)payload[off]     << 24) |
                      ((uint32_t)payload[off + 1] << 16) |
                      ((uint32_t)payload[off + 2] << 8)  |
                       (uint32_t)payload[off + 3];
        off += 4;
        memcpy(d->extradata + out, ANNEXB_START, ANNEXB_START_N);
        out += ANNEXB_START_N;
        memcpy(d->extradata + out, payload + off, sz);
        out += sz;
        off += sz;
    }
    d->extradata_size = (int)need;
    return 0;
}

static int open_decoder(struct tb_decoder *d) {
    if (d->codec_id == AV_CODEC_ID_NONE) d->codec_id = AV_CODEC_ID_H264;
    d->codec = avcodec_find_decoder(d->codec_id);
    if (!d->codec) {
        fprintf(stderr, "[dec] decoder not found for codec id %d\n", d->codec_id);
        return -1;
    }

    /* find HW pix fmt that the codec advertises */
    enum AVHWDeviceType type = pick_hwdev();
    hw_pix_fmt = AV_PIX_FMT_NONE;
    for (int i = 0;; i++) {
        const AVCodecHWConfig *cfg = avcodec_get_hw_config(d->codec, i);
        if (!cfg) break;
        if ((cfg->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) &&
            cfg->device_type == type) {
            hw_pix_fmt = cfg->pix_fmt;
            break;
        }
    }
    if (hw_pix_fmt == AV_PIX_FMT_NONE) {
        fprintf(stderr, "[dec] WARNING: no HW pix fmt for codec, using SW decode (slow!)\n");
    } else {
        fprintf(stderr, "[dec] HW decode pix_fmt=%s device=%s\n",
                av_get_pix_fmt_name(hw_pix_fmt),
                av_hwdevice_get_type_name(type));
    }

    if (d->ctx) avcodec_free_context(&d->ctx);
    d->ctx = avcodec_alloc_context3(d->codec);
    if (!d->ctx) return -1;

    if (hw_pix_fmt != AV_PIX_FMT_NONE) {
        if (av_hwdevice_ctx_create(&d->hw_dev, type, NULL, NULL, 0) < 0) {
            fprintf(stderr, "[dec] av_hwdevice_ctx_create failed\n");
        } else {
            d->ctx->hw_device_ctx = av_buffer_ref(d->hw_dev);
            d->ctx->get_format    = get_hw_format;
        }
    }

    /* Install extradata so FFmpeg knows VPS/SPS/PPS up front. */
    if (d->extradata && d->extradata_size > 0) {
        d->ctx->extradata =
            (uint8_t *)av_malloc(d->extradata_size + AV_INPUT_BUFFER_PADDING_SIZE);
        memcpy(d->ctx->extradata, d->extradata, d->extradata_size);
        memset(d->ctx->extradata + d->extradata_size, 0, AV_INPUT_BUFFER_PADDING_SIZE);
        d->ctx->extradata_size = d->extradata_size;
    }

    if (avcodec_open2(d->ctx, d->codec, NULL) < 0) {
        fprintf(stderr, "[dec] avcodec_open2 failed\n");
        avcodec_free_context(&d->ctx);
        return -1;
    }
    d->opened = 1;
    return 0;
}

int tb_dec_set_param_sets(struct tb_decoder *d, const uint8_t *payload, size_t len) {
    /* Sender re-emits VPS/SPS/PPS with every keyframe (every ~2 seconds).
     * Re-creating the decoder each time stalls decode for ~200ms causing
     * the fps drops to 4 seen in the logs. Only rebuild if param sets
     * actually changed (resolution change, codec reconfig, etc.). */
    uint8_t *prev_ed  = d->extradata;
    int      prev_sz  = d->extradata_size;
    d->extradata      = NULL;
    d->extradata_size = 0;

    if (build_extradata(d, payload, len) < 0) {
        d->extradata      = prev_ed;
        d->extradata_size = prev_sz;
        fprintf(stderr, "[dec] build_extradata failed\n");
        return -1;
    }

    if (d->opened && prev_ed && prev_sz == d->extradata_size &&
        memcmp(prev_ed, d->extradata, prev_sz) == 0) {
        /* Identical → no rebuild. Keep old, drop new. */
        av_free(d->extradata);
        d->extradata      = prev_ed;
        d->extradata_size = prev_sz;
        return 0;
    }

    av_free(prev_ed);
    fprintf(stderr, "[dec] param sets changed, opening decoder\n");
    return open_decoder(d);
}

/* Convert AVCC (length-prefixed) frame to Annex B (start codes) in scratch. */
static int avcc_to_annexb(struct tb_decoder *d,
                          const uint8_t *in, size_t in_len,
                          uint8_t **out, size_t *out_len) {
    if (d->scratch_cap < in_len + AV_INPUT_BUFFER_PADDING_SIZE) {
        size_t nc = in_len + AV_INPUT_BUFFER_PADDING_SIZE;
        uint8_t *nb = (uint8_t *)realloc(d->scratch, nc);
        if (!nb) return -1;
        d->scratch     = nb;
        d->scratch_cap = nc;
    }

    size_t off = 0, dst = 0;
    while (off + 4 <= in_len) {
        uint32_t nal = ((uint32_t)in[off]     << 24) |
                       ((uint32_t)in[off + 1] << 16) |
                       ((uint32_t)in[off + 2] << 8)  |
                        (uint32_t)in[off + 3];
        off += 4;
        if (off + nal > in_len) return -1;
        if (dst + 4 + nal > d->scratch_cap) return -1;
        memcpy(d->scratch + dst, ANNEXB_START, ANNEXB_START_N);
        dst += ANNEXB_START_N;
        memcpy(d->scratch + dst, in + off, nal);
        dst += nal;
        off += nal;
    }
    memset(d->scratch + dst, 0, AV_INPUT_BUFFER_PADDING_SIZE);
    *out     = d->scratch;
    *out_len = dst;
    return 0;
}

int tb_dec_feed_frame(struct tb_decoder *d, const uint8_t *avcc, size_t len) {
    if (!d->opened) return -1;

    uint8_t *anb = NULL;
    size_t   anb_len = 0;
    if (avcc_to_annexb(d, avcc, len, &anb, &anb_len) < 0) return -1;

    d->pkt->data = anb;
    d->pkt->size = (int)anb_len;

    int r = avcodec_send_packet(d->ctx, d->pkt);
    if (r < 0 && r != AVERROR(EAGAIN)) {
        fprintf(stderr, "[dec] send_packet=%d\n", r);
        return -1;
    }

    while (1) {
        r = avcodec_receive_frame(d->ctx, d->hw_frame);
        if (r == AVERROR(EAGAIN) || r == AVERROR_EOF) return 0;
        if (r < 0) { fprintf(stderr, "[dec] recv_frame=%d\n", r); return -1; }

#if defined(__APPLE__)
        /* Zero-copy fast path: VideoToolbox decoded frames carry a
         * CVPixelBufferRef in data[3]. Locking its base address gives direct
         * access to the IOSurface-backed NV12 planes without the
         * GPU→staging→CPU copy that av_hwframe_transfer_data performs.
         * Major win on Intel iMac + Radeon (~6× faster in practice). */
        if (d->hw_frame->format == hw_pix_fmt && d->hw_frame->data[3]) {
            CVPixelBufferRef pb = (CVPixelBufferRef)d->hw_frame->data[3];
            if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) == 0) {
                uint8_t *y   = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
                size_t   ys  =            CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
                uint8_t *uv  = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1);
                size_t   uvs =            CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
                int      w   = (int)CVPixelBufferGetWidth(pb);
                int      h   = (int)CVPixelBufferGetHeight(pb);
                d->cb(y, (int)ys, uv, (int)uvs, w, h, d->ud);
                CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
            }
            av_frame_unref(d->hw_frame);
            continue;
        }
#endif

        /* Generic path: HW transfer (Linux VAAPI / Windows D3D11VA / SW). */
        AVFrame *out = d->hw_frame;
        if (d->hw_frame->format == hw_pix_fmt) {
            d->sw_frame->format = AV_PIX_FMT_NV12;
            if (av_hwframe_transfer_data(d->sw_frame, d->hw_frame, 0) < 0) {
                fprintf(stderr, "[dec] hwframe_transfer failed\n");
                av_frame_unref(d->hw_frame);
                continue;
            }
            out = d->sw_frame;
        }

        if (out->format != AV_PIX_FMT_NV12) {
            fprintf(stderr, "[dec] unexpected pix fmt %d\n", out->format);
        } else {
            d->cb(out->data[0], out->linesize[0],
                  out->data[1], out->linesize[1],
                  out->width,   out->height, d->ud);
        }
        av_frame_unref(d->sw_frame);
        av_frame_unref(d->hw_frame);
    }
}
