#include "renderer_policy.h"

#include <string.h>

struct tb_renderer_health_result tb_renderer_evaluate_health(
    const struct tb_renderer_health_sample *sample) {
    struct tb_renderer_health_result result;
    memset(&result, 0, sizeof(result));
    result.decision = TB_RENDERER_HEALTH_WAIT;
    if (!sample) return result;

    result.attempted_frames = sample->submitted_frames + sample->dropped_frames;
    result.outstanding_frames = sample->submitted_frames > sample->completed_frames
        ? sample->submitted_frames - sample->completed_frames
        : 0;
    result.drop_ratio = result.attempted_frames
        ? (double)sample->dropped_frames / (double)result.attempted_frames
        : 0.0;
    result.gpu_average_ms = sample->completed_frames
        ? sample->gpu_time_ms_total / (double)sample->completed_frames
        : 0.0;

    if (sample->completed_frames < 120 && result.attempted_frames < 150) {
        return result;
    }

    const int gpu_healthy = result.gpu_average_ms <= 0.0 ||
                            result.gpu_average_ms <= 12.0;
    const int healthy = sample->completed_frames >= 120 &&
                        gpu_healthy &&
                        result.drop_ratio <= 0.08 &&
                        result.outstanding_frames <= 6;
    result.decision = healthy
        ? TB_RENDERER_HEALTH_KEEP_METAL
        : TB_RENDERER_HEALTH_FALLBACK_OPENGL;
    return result;
}
