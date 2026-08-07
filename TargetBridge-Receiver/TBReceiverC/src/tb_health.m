/* tb_health.m — see tb_health.h for why this exists. */

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>

#include "tb_health.h"

#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <pthread.h>
#include <unistd.h>

#define TB_HEALTH_INTERVAL_MS 5000.0

static double tb_health_now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000.0 + tv.tv_usec / 1000.0;
}

/* Total CPU time this process has burned, across every thread, in seconds.
 * Differenced between reports to get a rate — an absolute total says nothing
 * about whether we are busy NOW, which is the only question being asked. */
static double tb_health_cpu_seconds(void) {
    task_thread_times_info_data_t times;
    mach_msg_type_number_t count = TASK_THREAD_TIMES_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_THREAD_TIMES_INFO,
                  (task_info_t)&times, &count) != KERN_SUCCESS) return -1.0;

    /* Live threads only tells half the story: threads that have exited since
     * the last sample took their time with them, and TASK_BASIC_INFO carries
     * that terminated total. Both, or the rate quietly under-reports. */
    task_basic_info_64_data_t basic;
    count = TASK_BASIC_INFO_64_COUNT;
    if (task_info(mach_task_self(), TASK_BASIC_INFO_64,
                  (task_info_t)&basic, &count) != KERN_SUCCESS) return -1.0;

    return (double)times.user_time.seconds + times.user_time.microseconds / 1e6
         + (double)times.system_time.seconds + times.system_time.microseconds / 1e6
         + (double)basic.user_time.seconds + basic.user_time.microseconds / 1e6
         + (double)basic.system_time.seconds + basic.system_time.microseconds / 1e6;
}

static const char *tb_health_thermal(void) {
    if (@available(macOS 10.10.3, *)) {
        switch ([[NSProcessInfo processInfo] thermalState]) {
            case NSProcessInfoThermalStateNominal:  return "nominal";
            case NSProcessInfoThermalStateFair:     return "fair";
            case NSProcessInfoThermalStateSerious:  return "SERIOUS";
            case NSProcessInfoThermalStateCritical: return "CRITICAL";
        }
    }
    return "?";
}

/* Accelerator utilisation, 0-100, or -1 when the driver does not publish it.
 *
 * IOAccelerator's PerformanceStatistics dictionary is the only route to this
 * without private frameworks, and the key naming is driver-specific — AMD and
 * Intel do not agree — so several spellings are tried rather than assuming the
 * one this iMac happens to use. */
static int tb_health_gpu_percent(void) {
    int best = -1;
    io_iterator_t it = 0;
    /* 0 rather than kIOMainPortDefault: that constant is macOS 12+, this builds
     * against 11.0, and a null port already means "the default one" on every
     * version — including back when it was spelled kIOMasterPortDefault. */
    if (IOServiceGetMatchingServices(MACH_PORT_NULL,
                                     IOServiceMatching("IOAccelerator"),
                                     &it) != KERN_SUCCESS) return -1;

    io_object_t svc;
    while ((svc = IOIteratorNext(it))) {
        CFMutableDictionaryRef props = NULL;
        if (IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0)
                == KERN_SUCCESS && props) {
            CFDictionaryRef stats =
                (CFDictionaryRef)CFDictionaryGetValue(props, CFSTR("PerformanceStatistics"));
            if (stats && CFGetTypeID(stats) == CFDictionaryGetTypeID()) {
                const CFStringRef keys[] = {
                    CFSTR("Device Utilization %"),
                    CFSTR("GPU Activity(%)"),
                    CFSTR("GPU Core Utilization"),
                };
                for (size_t i = 0; i < sizeof(keys)/sizeof(*keys); ++i) {
                    CFNumberRef n = (CFNumberRef)CFDictionaryGetValue(stats, keys[i]);
                    if (n && CFGetTypeID(n) == CFNumberGetTypeID()) {
                        long v = 0;
                        CFNumberGetValue(n, kCFNumberLongType, &v);
                        /* "GPU Core Utilization" is reported in ten-millionths
                         * on some drivers, not percent. Normalise by magnitude
                         * rather than by key name, which varies by version. */
                        if (v > 100) v = v / 10000000;
                        if (v > best) best = (int)v;
                    }
                }
            }
            CFRelease(props);
        }
        IOObjectRelease(svc);
    }
    IOObjectRelease(it);
    return best;
}

/* Written by the reader and render threads, read by the reporter. Doubles are
 * not atomic, so a report can catch a partially-updated total -- accepted
 * deliberately: a lock here would put contention on the two hottest threads to
 * protect a diagnostic, and being off by one frame's microseconds changes no
 * decision this number informs. */
static volatile double g_read_ms = 0, g_copy_ms = 0, g_submit_ms = 0;

void tb_health_note_read(double ms)        { g_read_ms   += ms; }
void tb_health_note_upload_copy(double ms) { g_copy_ms   += ms; }
void tb_health_note_submit(double ms)      { g_submit_ms += ms; }

static void tb_health_sample(double span_ms, double *last_cpu_s) {
    double cpu_s = tb_health_cpu_seconds();
    double cpu_pct = -1.0;
    if (cpu_s >= 0.0 && *last_cpu_s >= 0.0)
        cpu_pct = (cpu_s - *last_cpu_s) * 1000.0 / span_ms * 100.0;
    *last_cpu_s = cpu_s;

    int gpu = tb_health_gpu_percent();
    double load[3] = {0, 0, 0};
    getloadavg(load, 3);

    char gpubuf[32];
    if (gpu >= 0) snprintf(gpubuf, sizeof(gpubuf), "%d%%", gpu);
    else          snprintf(gpubuf, sizeof(gpubuf), "n/a");

    /* As a share of wall-clock, so it reads on the same scale as cpu%. */
    double rd = g_read_ms, cp = g_copy_ms, sb = g_submit_ms;
    g_read_ms = g_copy_ms = g_submit_ms = 0;

    fprintf(stderr,
            "[health] thermal %s | cpu %.0f%% | gpu %s | load %.2f"
            " || read %.0f%% | uploadcopy %.0f%% | submit %.0f%%\n",
            tb_health_thermal(), cpu_pct < 0 ? 0.0 : cpu_pct, gpubuf, load[0],
            rd / span_ms * 100.0, cp / span_ms * 100.0, sb / span_ms * 100.0);
}

static void *tb_health_main(void *unused) {
    (void)unused;
    double last_cpu_s = tb_health_cpu_seconds();
    double last_ms = tb_health_now_ms();
    for (;;) {
        usleep((useconds_t)(TB_HEALTH_INTERVAL_MS * 1000.0));
        @autoreleasepool {
            double now = tb_health_now_ms();
            tb_health_sample(now - last_ms, &last_cpu_s);
            last_ms = now;
        }
    }
    return NULL;
}

void tb_health_start(void) {
    static pthread_t thread;
    static int started = 0;
    if (started) return;
    started = 1;
    if (pthread_create(&thread, NULL, tb_health_main, NULL) != 0) {
        fprintf(stderr, "[health] reporter thread failed to start\n");
        started = 0;
        return;
    }
    pthread_detach(thread);
}
