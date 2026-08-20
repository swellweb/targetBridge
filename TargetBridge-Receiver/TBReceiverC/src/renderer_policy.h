#ifndef TB_RENDERER_POLICY_H
#define TB_RENDERER_POLICY_H

#include <stdint.h>

enum tb_renderer_health_decision {
    TB_RENDERER_HEALTH_WAIT = 0,
    TB_RENDERER_HEALTH_KEEP_METAL = 1,
    TB_RENDERER_HEALTH_FALLBACK_OPENGL = -1
};

struct tb_renderer_health_sample {
    uint64_t submitted_frames;
    uint64_t completed_frames;
    uint64_t dropped_frames;
    double gpu_time_ms_total;
};

struct tb_renderer_health_result {
    enum tb_renderer_health_decision decision;
    uint64_t attempted_frames;
    uint64_t outstanding_frames;
    double drop_ratio;
    double gpu_average_ms;
};

/* Decide only after a meaningful real-frame sample. Metal must complete at
 * least 120 frames, average no more than 12 ms of GPU time, drop no more than
 * 8% of attempts and leave no more than 6 command buffers outstanding. A zero
 * GPU duration is treated as unavailable because some drivers omit timing. */
struct tb_renderer_health_result tb_renderer_evaluate_health(
    const struct tb_renderer_health_sample *sample);

#endif /* TB_RENDERER_POLICY_H */
