#include "decoder.h"
#include <CoreMedia/CoreMedia.h>
#include <VideoToolbox/VideoToolbox.h>
#include <stdio.h>
#include <libavcodec/avcodec.h>

#ifdef TB_TEST_NO_HEVC_HW
Boolean tb_probe_hw_support(CMVideoCodecType codec) {
    (void)codec;
    return 0;
}
#endif

#ifdef TB_TEST_NO_HEVC_CODEC
const AVCodec *tb_probe_find_decoder(enum AVCodecID codec) {
    (void)codec;
    return NULL;
}
#endif

int main(void) {
    int advertised = tb_dec_supports_hevc_hwdecode();
    int software = tb_dec_supports_hevc_softwaredecode();
    printf("hardware_probe=%d receiver_advertisement=%d software=%d\n",
           VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC), advertised, software);
#if defined(TB_TEST_NO_HEVC_CODEC)
    return advertised == 0 && software == 0 ? 0 : 1;
#elif defined(TB_TEST_NO_HEVC_HW)
    return advertised == 0 && software == 1 ? 0 : 1;
#else
    return software == 1 ? 0 : 1;
#endif
}
