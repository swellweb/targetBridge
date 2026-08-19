#ifndef TB_IDLE_WATCHDOG_H
#define TB_IDLE_WATCHDOG_H

#include <stdint.h>

enum tb_idle_watchdog_result {
    TB_IDLE_WATCHDOG_OK = 0,
    TB_IDLE_WATCHDOG_EXPIRED,
    TB_IDLE_WATCHDOG_CLOCK_REWOUND
};

/* Compare timestamps without allowing an unsigned subtraction to turn a
 * small backward jump into an immediate timeout.  A backward jump rebases the
 * last-activity timestamp so a genuinely stale connection can still expire. */
enum tb_idle_watchdog_result tb_idle_watchdog_check(uint64_t now_ms,
                                                    uint64_t *last_activity_ms,
                                                    uint64_t timeout_ms,
                                                    uint64_t *elapsed_ms);

#endif
