/* test_log_ratelimit.c — one log line per window, per kind of event. */

#include "log_ratelimit.h"

#include <stdio.h>
#include <string.h>

static int checks;
static int failures;

#define CHECK(condition) do { \
    checks++; \
    if (!(condition)) { \
        failures++; \
        fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition); \
    } \
} while (0)

static void test_window(void) {
    struct tb_log_ratelimit r;
    memset(&r, 0, sizeof(r));
    unsigned long quiet = 99;

    /* The first event always gets its line, at any clock value (0 included). */
    CHECK(tb_log_ratelimit_allow(&r, 0, 10000, &quiet) == 1);
    CHECK(quiet == 0);
    /* Within the window: held back and counted. */
    CHECK(tb_log_ratelimit_allow(&r, 1, 10000, &quiet) == 0);
    CHECK(tb_log_ratelimit_allow(&r, 9999, 10000, &quiet) == 0);
    /* The window has passed: a line, with the two held back. */
    CHECK(tb_log_ratelimit_allow(&r, 10000, 10000, &quiet) == 1);
    CHECK(quiet == 2);
    CHECK(tb_log_ratelimit_allow(&r, 25000, 10000, &quiet) == 1);
    CHECK(quiet == 0);
    /* A clock that went backwards does not silence it for ever. */
    CHECK(tb_log_ratelimit_allow(&r, 100, 10000, &quiet) == 1);
    /* NULL for the count is allowed. */
    CHECK(tb_log_ratelimit_allow(&r, 50000, 10000, NULL) == 1);
}

/* Two kinds of decode error each keep their own window: a flood of one must
 * not hold back the first line of the other. */
static void test_kinds_apart(void) {
    struct tb_log_ratelimit kinds[2];
    memset(kinds, 0, sizeof(kinds));
    unsigned long quiet = 0;
    CHECK(tb_log_ratelimit_allow(&kinds[0], 1000, 10000, &quiet) == 1);
    for (int i = 1; i <= 60; i++) {
        CHECK(tb_log_ratelimit_allow(&kinds[0], 1000 + (uint64_t)i * 16, 10000, &quiet) == 0);
    }
    CHECK(tb_log_ratelimit_allow(&kinds[1], 2000, 10000, &quiet) == 1);
    CHECK(quiet == 0);
    CHECK(tb_log_ratelimit_allow(&kinds[0], 11000, 10000, &quiet) == 1);
    CHECK(quiet == 60);
}

int main(void) {
    test_window();
    test_kinds_apart();
    if (failures) {
        fprintf(stderr, "log rate limit tests: %d of %d checks failed\n", failures, checks);
        return 1;
    }
    printf("log rate limit tests: %d checks passed\n", checks);
    return 0;
}
