#include "../src/receiver_profile.h"

#include <stdio.h>

static int failures = 0;
static int checks = 0;

#define CHECK(condition, message) do {                                   \
    checks++;                                                              \
    if (!(condition)) {                                                    \
        failures++;                                                        \
        fprintf(stderr, "FAIL %s:%d — %s\\n", __FILE__, __LINE__, message); \
    }                                                                      \
} while (0)

static void test_retina_5k(void) {
    struct tb_receiver_profile p;
    CHECK(tb_receiver_profile_from_dimensions(2560, 1440, 5120, 2880, &p) == 0,
          "5K profile builds");
    CHECK(p.hi_dpi, "5K panel is HiDPI");
    CHECK(p.mode_w == 2560 && p.mode_h == 1440, "5K uses logical mode");
    CHECK(p.capture_w == 5120 && p.capture_h == 2880, "5K capture uses native pixels");
}

static void test_retina_4k(void) {
    struct tb_receiver_profile p;
    CHECK(tb_receiver_profile_from_dimensions(2048, 1152, 4096, 2304, &p) == 0,
          "4K profile builds");
    CHECK(p.hi_dpi, "4K panel is HiDPI");
    CHECK(p.mode_w == 2048 && p.mode_h == 1152, "4K uses logical mode");
}

static void test_non_retina_1080p(void) {
    struct tb_receiver_profile p;
    CHECK(tb_receiver_profile_from_dimensions(1920, 1080, 1920, 1080, &p) == 0,
          "1080p profile builds");
    CHECK(!p.hi_dpi, "1080p panel is not HiDPI");
    CHECK(p.mode_w == 1920 && p.mode_h == 1080, "1080p uses native mode");
    CHECK(p.capture_w == 1920 && p.capture_h == 1080, "1080p capture uses native pixels");
}

static void test_retina_45k(void) {
    struct tb_receiver_profile p;
    CHECK(tb_receiver_profile_from_dimensions(2240, 1260, 4480, 2520, &p) == 0,
          "4.5K profile builds");
    CHECK(p.hi_dpi, "4.5K panel is HiDPI");
    CHECK(p.mode_w == 2240 && p.mode_h == 1260, "4.5K uses logical mode");
    CHECK(p.capture_w == 4480 && p.capture_h == 2520, "4.5K capture uses native pixels");
}

static void test_invalid_panel(void) {
    struct tb_receiver_profile p;
    CHECK(tb_receiver_profile_from_dimensions(1920, 1080, 0, 1080, &p) < 0,
          "zero panel width is rejected");
    CHECK(tb_receiver_profile_from_dimensions(1920, 1080, 1920, 1080, NULL) < 0,
          "NULL output is rejected");
}

int main(void) {
    test_retina_5k();
    test_retina_4k();
    test_retina_45k();
    test_non_retina_1080p();
    test_invalid_panel();
    if (!failures) {
        printf("receiver profile tests: %d checks passed\n", checks);
        return 0;
    }
    fprintf(stderr, "receiver profile tests: %d/%d checks FAILED\n", failures, checks);
    return 1;
}
