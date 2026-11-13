#define _POSIX_C_SOURCE 200809L
#include "heartbeat_monitor.h"
#include "heartbeat_loopback.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <time.h>

struct monitor {
    pthread_t thread;
    int socket;
    uint64_t timeout;
    atomic_int expired;
    atomic_int received;
    atomic_int stopping;
};

static uint64_t now_ms(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return (uint64_t)time.tv_sec * 1000 + time.tv_nsec / 1000000;
}

static void *observe(void *context) {
    struct monitor *monitor = context;
    uint64_t last = now_ms();
    const struct timespec pause = { .tv_nsec = 10000000 };
    while (!atomic_load(&monitor->stopping)) {
        uint64_t now = now_ms(), elapsed = 0;
        if (tb_heartbeat_read(monitor->socket) > 0) {
            last = now;
            atomic_fetch_add(&monitor->received, 1);
        }
        if (tb_idle_watchdog_check(now, &last, monitor->timeout, &elapsed) == TB_IDLE_WATCHDOG_EXPIRED) {
            atomic_store(&monitor->expired, 1);
            break;
        }
        nanosleep(&pause, NULL);
    }
    return NULL;
}

void *tb_heartbeat_monitor_start(int socket, uint64_t timeout_ms) {
    struct monitor *monitor = calloc(1, sizeof(*monitor));
    if (!monitor) return NULL;
    monitor->socket = socket;
    monitor->timeout = timeout_ms;
    atomic_init(&monitor->expired, 0);
    atomic_init(&monitor->received, 0);
    atomic_init(&monitor->stopping, 0);
    if (pthread_create(&monitor->thread, NULL, observe, monitor) != 0) {
        free(monitor);
        return NULL;
    }
    return monitor;
}

int tb_heartbeat_monitor_expired(void *context) {
    return atomic_load(&((struct monitor *)context)->expired);
}

int tb_heartbeat_monitor_received(void *context) {
    return atomic_load(&((struct monitor *)context)->received);
}

void tb_heartbeat_monitor_stop(void *context) {
    struct monitor *monitor = context;
    atomic_store(&monitor->stopping, 1);
    pthread_join(monitor->thread, NULL);
    free(monitor);
}
