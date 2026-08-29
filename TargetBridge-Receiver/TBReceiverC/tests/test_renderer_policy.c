#include "renderer_policy.h"

#include <math.h>
#include <stdio.h>

static int checks;
static int failures;

#define CHECK(condition) do {                                                    \
    checks++;                                                                    \
    if (!(condition)) {                                                          \
        failures++;                                                              \
        fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition);    \
    }                                                                            \
} while (0)

static struct tb_renderer_health_result evaluate(
    uint64_t submitted,
    uint64_t completed,
    uint64_t dropped,
    double gpu_total) {
    const struct tb_renderer_health_sample sample = {
        submitted, completed, dropped, gpu_total
    };
    return tb_renderer_evaluate_health(&sample);
}

int main(void) {
    struct tb_renderer_health_result result =
        tb_renderer_evaluate_health(NULL);
    CHECK(result.decision == TB_RENDERER_HEALTH_WAIT);

    result = evaluate(119, 119, 0, 595.0);
    CHECK(result.decision == TB_RENDERER_HEALTH_WAIT);

    result = evaluate(124, 122, 3, 610.0);
    CHECK(result.decision == TB_RENDERER_HEALTH_KEEP_METAL);
    CHECK(result.attempted_frames == 127);
    CHECK(result.outstanding_frames == 2);
    CHECK(fabs(result.gpu_average_ms - 5.0) < 0.001);
    CHECK(result.drop_ratio < 0.03);

    result = evaluate(122, 120, 0, 0.0);
    CHECK(result.decision == TB_RENDERER_HEALTH_KEEP_METAL);

    /* Every healthy boundary is inclusive. */
    result = evaluate(138, 132, 12, 132.0 * 12.0);
    CHECK(result.outstanding_frames == 6);
    CHECK(fabs(result.drop_ratio - 0.08) < 0.000001);
    CHECK(fabs(result.gpu_average_ms - 12.0) < 0.000001);
    CHECK(result.decision == TB_RENDERER_HEALTH_KEEP_METAL);

    result = evaluate(138, 132, 13, 132.0 * 12.0);
    CHECK(result.decision == TB_RENDERER_HEALTH_FALLBACK_OPENGL);

    result = evaluate(139, 132, 0, 132.0 * 12.0);
    CHECK(result.decision == TB_RENDERER_HEALTH_FALLBACK_OPENGL);

    result = evaluate(138, 132, 0, 132.0 * 12.001);
    CHECK(result.decision == TB_RENDERER_HEALTH_FALLBACK_OPENGL);

    result = evaluate(125, 120, 20, 600.0);
    CHECK(result.decision == TB_RENDERER_HEALTH_FALLBACK_OPENGL);

    result = evaluate(135, 120, 0, 600.0);
    CHECK(result.decision == TB_RENDERER_HEALTH_FALLBACK_OPENGL);

    result = evaluate(121, 120, 0, 1560.0);
    CHECK(result.decision == TB_RENDERER_HEALTH_FALLBACK_OPENGL);

    result = evaluate(150, 0, 0, 0.0);
    CHECK(result.decision == TB_RENDERER_HEALTH_FALLBACK_OPENGL);

    result = evaluate(149, 0, 0, 0.0);
    CHECK(result.decision == TB_RENDERER_HEALTH_WAIT);

    /* A reset/out-of-order sample cannot underflow outstanding frames. */
    result = evaluate(120, 121, 0, 500.0);
    CHECK(result.outstanding_frames == 0);
    CHECK(result.decision == TB_RENDERER_HEALTH_KEEP_METAL);

    if (failures == 0) {
        printf("renderer policy tests: %d checks passed\n", checks);
        return 0;
    }
    fprintf(stderr, "renderer policy tests: %d/%d checks failed\n", failures, checks);
    return 1;
}
