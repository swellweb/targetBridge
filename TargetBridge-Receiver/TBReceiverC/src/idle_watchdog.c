#include "idle_watchdog.h"

enum tb_idle_watchdog_result tb_idle_watchdog_check(uint64_t now_ms,
                                                    uint64_t *last_activity_ms,
                                                    uint64_t timeout_ms,
                                                    uint64_t *elapsed_ms) {
    if (!last_activity_ms || !elapsed_ms) return TB_IDLE_WATCHDOG_OK;

    if (now_ms < *last_activity_ms) {
        *last_activity_ms = now_ms;
        *elapsed_ms = 0;
        return TB_IDLE_WATCHDOG_CLOCK_REWOUND;
    }

    *elapsed_ms = now_ms - *last_activity_ms;
    return *elapsed_ms >= timeout_ms
        ? TB_IDLE_WATCHDOG_EXPIRED
        : TB_IDLE_WATCHDOG_OK;
}
