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

/* CLOCK_MONOTONIC, matching main.c and tb_metal_plane.m. Only ever used for
 * differences here, so gettimeofday was not wrong — but three files timing the
 * same session on two different epochs is a trap, and it already caught us once
 * when a cross-file subtraction produced a 1.7e12 ms latency. */
static double tb_health_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
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

/* Latency samples: count/sum/max rather than a running share, so the report can
 * show a mean and the worst case. Plain doubles under no lock — these are
 * statistics, and a torn sample costs a slightly wrong average once an hour,
 * which is not worth a mutex on the present path. */
static volatile double g_draw_sum = 0, g_draw_max = 0;
static volatile long   g_draw_n   = 0;
static volatile double g_cur_gap_sum = 0, g_cur_gap_max = 0;
static volatile long   g_cur_n = 0;
static double          g_cur_last_ms = 0;

/* A SECOND accumulator over the same samples, for the phase report.
 *
 * It cannot share the health report's totals: that report drains them on its own
 * ~5s cadence, and a feedback loop reading the same variables would get whatever
 * fraction of a window happened to have accumulated since the last drain — a
 * mean over 200ms one second and over 4s the next. Two counters over one sample
 * is a few bytes and removes the coupling entirely. */
static volatile double g_phase_sum = 0;
static volatile long   g_phase_n   = 0;

void tb_health_note_drawable_wait(double ms) {
    g_draw_sum += ms;
    if (ms > g_draw_max) g_draw_max = ms;
    g_draw_n++;
    g_phase_sum += ms;
    g_phase_n++;
}

int tb_health_take_drawable_phase(double *mean_ms, long *n) {
    const double sum = g_phase_sum;
    const long   cnt = g_phase_n;
    g_phase_sum = 0;
    g_phase_n   = 0;
    if (cnt <= 0) return 0;
    if (mean_ms) *mean_ms = sum / (double)cnt;
    if (n)       *n = cnt;
    return 1;
}

static volatile double g_curlat_sum = 0, g_curlat_max = 0;
static volatile long   g_curlat_n = 0;

void tb_health_note_cursor_latency(double ms) {
    g_curlat_sum += ms;
    if (ms > g_curlat_max) g_curlat_max = ms;
    g_curlat_n++;
}

/* Gaps longer than this are the user not moving the mouse, not us gating
 * anything — the sender only sends on movement. Counting them made `max` read
 * 3878ms, which says nothing about the cursor path. */
#define TB_CURSOR_IDLE_GAP_MS 100.0

void tb_health_note_cursor_commit(void) {
    const double now = tb_health_now_ms();
    if (g_cur_last_ms > 0.0) {
        const double gap = now - g_cur_last_ms;
        if (gap <= TB_CURSOR_IDLE_GAP_MS) {
            g_cur_gap_sum += gap;
            if (gap > g_cur_gap_max) g_cur_gap_max = gap;
            g_cur_n++;
        }
    }
    g_cur_last_ms = now;
}

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

    const double dsum = g_draw_sum, dmax = g_draw_max; const long dn = g_draw_n;
    const double csum = g_cur_gap_sum, cmax = g_cur_gap_max; const long cn = g_cur_n;
    g_draw_sum = g_draw_max = 0; g_draw_n = 0;
    g_cur_gap_sum = g_cur_gap_max = 0; g_cur_n = 0;
    const double lsum = g_curlat_sum, lmax = g_curlat_max; const long ln = g_curlat_n;
    g_curlat_sum = g_curlat_max = 0; g_curlat_n = 0;

    char latbuf[160];
    snprintf(latbuf, sizeof(latbuf),
             " || drawable %.1f/%.1fms n=%ld | cursor gap %.1f/%.1fms %.0f/s"
             " | cursor lat %.2f/%.2fms n=%ld",
             dn ? dsum / (double)dn : 0.0, dmax, dn,
             cn ? csum / (double)cn : 0.0, cmax,
             cn ? (double)cn * 1000.0 / span_ms : 0.0,
             ln ? lsum / (double)ln : 0.0, lmax, ln);

    fprintf(stderr,
            "[health] thermal %s | cpu %.0f%% | gpu %s | load %.2f"
            " || read %.0f%% | uploadcopy %.0f%% | submit %.0f%%%s\n",
            tb_health_thermal(), cpu_pct < 0 ? 0.0 : cpu_pct, gpubuf, load[0],
            rd / span_ms * 100.0, cp / span_ms * 100.0, sb / span_ms * 100.0,
            latbuf);
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

void tb_health_hold_awake(void) {
    static id<NSObject> activity = nil;
    if (activity) return;
    /* userInitiated: this is work the user asked for and is waiting on.
     * latencyCritical: the frame cadence is the product -- timer coalescing and
     * CPU throttling are exactly what must not happen here. */
    activity = [[NSProcessInfo processInfo]
        beginActivityWithOptions:(NSActivityUserInitiated |
                                  NSActivityLatencyCritical)
                          reason:@"TargetBridge is presenting a live display"];
    /* No explicit retain: ARC keeps the static strong reference alive, and the
     * assertion lasts as long as the object does -- i.e. the whole process. */
    fprintf(stderr, "[health] holding off App Nap (userInitiated|latencyCritical)\n");
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
