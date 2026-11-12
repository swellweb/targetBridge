#include "connection_log.h"
#include <stdio.h>
#ifdef __APPLE__
#include <os/log.h>
#endif

void tb_connection_log(const char *event, int64_t value) {
    if (!event) return;
    fprintf(stderr, "[connection] %s value=%lld\n", event, (long long)value);
#ifdef __APPLE__
    /* Called on the Receiver event-loop thread; keep lifecycle diagnostics
     * available in Console even when Launch Services discards stderr. */
    static os_log_t logger;
    if (!logger) logger = os_log_create("com.targetbridge.receiver", "connection");
    os_log_with_type(logger, OS_LOG_TYPE_DEFAULT, "%{public}s value=%{public}lld",
                     event, (long long)value);
#endif
}
