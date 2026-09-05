#include "idle_watchdog.h"

#include <stdint.h>
#include <stdio.h>

static int checks;
static int failures;

#define CHECK(condition) do { \
    checks++; \
    if (!(condition)) { \
        failures++; \
        fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition); \
    } \
} while (0)

int main(void) {
    uint64_t last = 1000;
    uint64_t elapsed = UINT64_MAX;

    CHECK(tb_idle_watchdog_check(10999, &last, 10000, &elapsed) == TB_IDLE_WATCHDOG_OK);
    CHECK(elapsed == 9999);
    CHECK(last == 1000);

    CHECK(tb_idle_watchdog_check(11000, &last, 10000, &elapsed) == TB_IDLE_WATCHDOG_EXPIRED);
    CHECK(elapsed == 10000);

    /* Regression for issue #156: 52 ms backwards must not become
     * UINT64_MAX - 51 and close an active session. */
    last = 5000;
    elapsed = UINT64_MAX;
    CHECK(tb_idle_watchdog_check(4948, &last, 10000, &elapsed) ==
          TB_IDLE_WATCHDOG_CLOCK_REWOUND);
    CHECK(elapsed == 0);
    CHECK(last == 4948);

    CHECK(tb_idle_watchdog_check(14947, &last, 10000, &elapsed) == TB_IDLE_WATCHDOG_OK);
    CHECK(elapsed == 9999);
    CHECK(tb_idle_watchdog_check(14948, &last, 10000, &elapsed) == TB_IDLE_WATCHDOG_EXPIRED);
    CHECK(elapsed == 10000);

    printf("idle watchdog tests: %d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
