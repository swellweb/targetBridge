#include "session_metrics.h"

#include <stdio.h>

int tb_session_metrics_json(char *dst,
                            size_t dst_size,
                            uint64_t receiver_fps,
                            uint64_t rendered_frames,
                            uint64_t decode_errors,
                            const char *renderer,
                            const char *decoder,
                            const char *codec) {
    if (!dst || dst_size == 0) return -1;

    int len = snprintf(
        dst,
        dst_size,
        "{\"receiverFPS\":%llu,\"renderedFrames\":%llu,\"decodeErrors\":%llu,"
        "\"renderer\":\"%s\",\"decoder\":\"%s\",\"codec\":\"%s\"}",
        (unsigned long long)receiver_fps,
        (unsigned long long)rendered_frames,
        (unsigned long long)decode_errors,
        renderer ? renderer : "unknown",
        decoder ? decoder : "unknown",
        codec ? codec : "unknown");

    if (len <= 0 || (size_t)len >= dst_size) return -1;
    return len;
}
