/* main.c — TBReceiver pure-C entry point.
 *
 * Single-threaded event loop:
 *   - SDL_PollEvent (non-blocking)  → quit detection
 *   - non-blocking socket read     → packet parser → decoder → renderer
 *   - 1ms sleep when idle           → CPU yield
 *
 * No ObjC. No Cocoa NSApplication. No autoreleasepool.
 * Crashes from objc_release/__CFAutoreleasePoolPop cannot happen here:
 * no Objective-C runtime objects are managed by us. SDL2 may use Cocoa
 * windowing internally on macOS, but with this minimal setup the OCLP-
 * triggered bug pattern (corrupt object in main-thread ARP) is dramatically
 * less likely than with SwiftUI / AppKit programmatic UIs.
 */

#include "net.h"
#include "decoder.h"
#include "display.h"
#include "tb_metal_plane.h"
#include "proto.h"
#include "tb_gesture_bridge.h"
#include "tb_display_tweaks.h"
#include "tb_mic_capture.h"
#include "tb_i18n.h"
#include "tb_logship.h"
#include "tb_health.h"

#include <SDL.h>
#include <ApplicationServices/ApplicationServices.h>
#include <dns_sd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreAudio/CoreAudio.h>

/* kAudioObjectPropertyElementMain is the macOS 12+ SDK spelling; older SDKs
 * only define kAudioObjectPropertyElementMaster (both are numerically 0). */
#ifndef kAudioObjectPropertyElementMain
#define kAudioObjectPropertyElementMain kAudioObjectPropertyElementMaster
#endif

#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <stdarg.h>
#include <time.h>
#include <poll.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>

/* Format constants live in proto.h, next to the packet definitions they
 * describe. Only the buffer policy is local. */
#define AUDIO_BUF_CAP          (1000 * AUDIO_BYTES_PER_MS)   /* 1 second capacity */

/* Playout backlog ceiling. Cushions network and scheduling jitter without
 * letting delay accumulate; the excess is dropped oldest-first, which is the
 * standard jitter-buffer behaviour and what keeps latency from ratcheting up
 * as the two ends' clocks drift apart. */
#define AUDIO_BACKLOG_MAX_MS   150

/* Reap a connected sender that has gone completely silent. The sender
 * heartbeats every 2s and streams frames continuously, so 10s of silence
 * (5 missed heartbeats) means it died without a FIN. */
#define TB_SENDER_IDLE_TIMEOUT_MS 10000

#define TB_CTRL_QUEUE_MAX 512

/* Video packets the reader may hand over before the main thread has caught up.
 * Three frames at EIGHT bands, matching the sender's in-flight budget at its
 * highest usable slice count, so the two ends agree on how far ahead the wire
 * may get.
 *
 * It was 12 (three frames at four bands), which is why N=8 overflowed even with
 * everything else healthy: twelve slots is one and a half frames at eight bands.
 * Each slot holds a reader's parser buffer, and a band shrinks as the count
 * rises, so doubling the slots does not double the memory — it is tens of MB
 * either way, not the 4.4 GB an earlier oversized ring cost. */
#define TB_VIDEO_QUEUE 24
#define TB_VIDEO_POOL  (TB_VIDEO_QUEUE + 4)

/* How far behind capture a frame is presented. It must exceed the usual
 * encode+wire delay or frames arrive after their slot; covering the rare 45 ms
 * tail instead would cost 50 ms of latency to fix a 4% case, and a frame that
 * misses simply shows one refresh late — which is what happens today anyway. */
#define TB_PACE_LEAD_NS      (25ull * 1000000ull)
/* A frame never waits longer than this, whatever the clock estimate says. A
 * wrong offset then costs one late frame instead of the session. */
#define TB_PACE_MAX_HOLD_MS  50

/* A non-frame packet copied off a reader thread for the main thread to run
 * through on_packet() unchanged. */
struct tb_ctrl_msg {
    uint8_t  type;
    uint8_t *payload;
    size_t   len;
};

struct app;

struct tb_link_reader {
    pthread_t         thread;
    int               fd;
    int               active;
    volatile int      stop;
    volatile int      ended;   /* peer closed, or a fatal parse/read error */
    struct tb_parser  parser;
    struct app       *app;
    const uint8_t    *pending_payload;   /* set by the callback, published after commit */
    size_t            pending_len;
    uint8_t           pending_type;
};

struct app {
    struct tb_display *disp;
    struct tb_decoder *dec;
    struct tb_parser   parser;

    int      server_fd;
    int      client_fd;

    /* Threaded receive. read() of a 5K raw frame costs ~23 ms and the GPU
     * upload ~13 ms; run on one thread they serialize to ~36 ms/frame. Each
     * cable gets a reader thread so the two reads run in parallel AND overlap
     * the main thread's render. Packet handlers stay on the main thread (they
     * touch SDL and app state), so readers only parse and hand work across. */
    pthread_mutex_t net_lock;
    int              threaded_rx;

    /* Video packets waiting for the main thread.
     *
     * This was ONE slot, which was right when a frame was one packet. Slicing
     * made a frame four, and because a band is an increment that must not be
     * overwritten, the reader waited up to 100 ms for the slot to clear. That
     * wait is inside the read loop, and the reader is the only thing draining
     * the socket — so on fullscreen video the mailbox saturated, the reader
     * stopped reading, 2.5 MB piled up in the sender's send queue, its
     * in-flight budget pinned at 15/12 and it dropped 206 frames in a window.
     * The receiver sat 94% idle at 4 fps throughout, starved by its own reader,
     * and only killing both ends recovered it.
     *
     * A queue instead, so the reader never stops draining. Twelve is three
     * frames at four bands, matching the sender's in-flight budget: a burst is
     * absorbed, and a genuinely overwhelmed receiver drops rather than wedges.
     *
     * Owned buffers handed over by a reader, plus where the packet sits inside
     * each. No copy: the reader yields its whole parser buffer. */
    struct tb_video_slot {
        uint8_t       *buf;       /* owned allocation */
        size_t         cap;
        const uint8_t *payload;   /* points into buf */
        size_t         len;
        uint8_t        type;      /* RAW_FRAME, RAW_DAMAGE, RAW_DPCM[_SLICE] */
    }                vq[TB_VIDEO_QUEUE];
    int              vq_head;
    int              vq_count;
    uint64_t         vq_overflow;    /* increments dropped because it was full */

    /* Presentation pacing.
     *
     * The transport is clean -- 94-96% of presents one refresh apart, no drops,
     * no lost bands -- and 25 fps video still judders, because macOS has already
     * composited it as a 2,3,2,3 pulldown and we resample that onto this panel's
     * refresh grid. A frame arriving a hair late waits a whole extra period, so
     * 2,3,2,3 becomes 2,4,1,3: a hitch roughly twice a second, worst on the slow
     * pans where the eye is tracking.
     *
     * Presenting on the sender's CAPTURE time instead of on arrival reproduces
     * its spacing rather than the wire's. Simulated against the measured
     * distributions before writing any of it: hitches 8.8% -> 4.7% for 14 ms.
     *
     * `offset` converts a sender capture time into receiver time, estimated as
     * the SMALLEST (arrival - capture) seen recently: the least-delayed frame is
     * the closest thing to a pure clock difference, since every other sample has
     * queueing added and none can have less. */
    uint64_t         pace_offset_ns;
    uint64_t         pace_min_ns;      /* smallest delta this window */
    uint64_t         pace_win_end_ms;
    uint64_t         pace_held_since;  /* 0 when nothing is waiting */
    int              pace_enabled;
    uint32_t         connecting_since;/* when this client last had no video */
    uint32_t         dpcm_frame_id;   /* frame currently being assembled from slices */
    int              dpcm_seq_warned;
    /* Which bands of the current frame actually decoded. A frame presents on its
     * last band whether or not the others arrived, and a missing band leaves the
     * previous frame's pixels in that strip — which looks exactly like a glitch,
     * so it has to be measured rather than assumed. */
    uint32_t         dpcm_got_mask;
    uint32_t         dpcm_frames_total;
    uint32_t         dpcm_frames_short;
    uint32_t         dpcm_bands_lost;
    uint32_t         dpcm_last_report;
    uint64_t         frames_dropped;

    /* Recycled buffers handed back to readers so nothing allocates (or
     * re-faults 59 MB) inside the frame loop. Sized against the video queue:
     * every slot's buffer comes back here when the main thread is done with it,
     * and a pool smaller than the queue would start freeing and reallocating
     * multi-MB blocks in the steady state. */
    uint8_t         *pool_buf[TB_VIDEO_POOL];
    size_t           pool_cap[TB_VIDEO_POOL];
    int              pool_n;

    struct tb_ctrl_msg    *ctrl_q;
    int              ctrl_head;
    int              ctrl_count;
    uint64_t         reader_recv_ms;

    struct tb_link_reader *reader1;

    /* Base image for damage updates: TB_PKT_RAW_DAMAGE patches rectangles into
     * this, so it must persist across frames. Rebuilt whenever a full
     * TB_PKT_RAW_FRAME arrives. */
    uint8_t *base_img;
    size_t   base_cap;
    uint32_t base_w, base_h;
    uint8_t  base_format;      /* 2 = BGRA8888, 3 = ARGB2101010 */
    int      base_valid;

    uint64_t frames;
    uint64_t last_fps_tick_ms;
    uint64_t last_fps_count;
    uint64_t last_ip_check_ms;
    /* Idle watchdog: last time the sender sent anything. Reader threads stamp
     * this asynchronously, so it can be *newer* than the `t` sampled at the top
     * of a loop iteration — every comparison must be underflow-safe. */
    /* Last display-tweak state reported to the sender, so changes made on this
     * Mac (Control Center, System Settings) propagate back and the sender's
     * toggles stay truthful. -1 = nothing sent yet. */
    int      reported_night_shift;
    int      reported_true_tone;
    uint64_t last_tweak_poll_ms;

    uint64_t last_recv_ms;
    int      close_requested;
    int      have_video_frame;
    /* A real streaming session has begun (the sender sent a session packet, not
     * just a transient probe like a UI-language push). Gates the fullscreen
     * "connecting" splash so a bare/short-lived connection doesn't flash it. */
    int      session_active;

    char     ip_text[64];
    char     tb_ip_text[64];
    char     net_ip_text[64];
    char     display_host[128]; /* short hostname (or hostname+IP), cached at startup */
    char     status_text[128];
    char     sender_text[128];
    char     panel_text[128];
    char     mode_text[128];
    char     language_pref[8];
    char     language_text[96];
    char     permissions_text[160];
    char     sender_ui_language[8];
    char     input_control_mode[32];
    int      last_input_monitoring_trusted;
    int      last_accessibility_trusted;
    uint64_t last_permissions_poll_ms;

    DNSServiceRef bonjour_ref;
    char     bonjour_name[128];
    CFMachPortRef input_tap;
    CFRunLoopSourceRef input_tap_source;
    int      input_tap_consumes_events;

    SDL_AudioDeviceID audio_device;

    /* Senders older than the Float32 change send Int16 and do not say so in
     * their hello. Assume Int16 until told otherwise, so such a sender plays
     * correctly instead of as noise. */
    int     audio_input_is_s16;
    uint8_t audio_buf[AUDIO_BUF_CAP];
    int     audio_buf_head;
    int     audio_buf_tail;
    int     audio_buf_size;

    uint64_t input_events_sent;
    uint64_t input_events_received;
    uint64_t last_target_switch_ms;
    uint64_t last_space_switch_ms;
    uint64_t last_space_gesture_ms;
    int      space_gesture_accum_x;
    int      sent_command_down;
    int      sent_shift_down;
    int      sent_option_down;
    int      sent_control_down;
    int      sent_caps_down;
    uint64_t last_clipboard_poll_ms;
    char     last_clipboard_text[4096];
};

static int tb_should_log_input_event(uint64_t count) {
    return count <= 20 || (count % 100) == 0;
}

static void tb_receiver_input_log(const char *fmt, ...) {
    char message[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(message, sizeof(message), fmt, args);
    va_end(args);

    fprintf(stderr, "%s\n", message);

    const char *home = getenv("HOME");
    if (!home || !*home) return;

    char dir[PATH_MAX];
    snprintf(dir, sizeof(dir), "%s/Library/Application Support/TargetBridge Receiver/Logs", home);
    mkdir(dir, 0755);

    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/input-debug.log", dir);
    FILE *f = fopen(path, "a");
    if (!f) return;

    time_t now = time(NULL);
    struct tm tm_now;
    localtime_r(&now, &tm_now);
    char timestamp[64];
    strftime(timestamp, sizeof(timestamp), "%Y-%m-%dT%H:%M:%S%z", &tm_now);
    fprintf(f, "%s %s\n", timestamp, message);
    fclose(f);
}

static volatile sig_atomic_t g_term = 0;
static void on_sigint(int s) { (void)s; g_term = 1; }

static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ULL + ts.tv_nsec / 1000000ULL;
}

static void tb_copy_i18n(char *dest, size_t size, const char *key);
static void tb_format_i18n(char *dest,
                           size_t size,
                           const char *key,
                           const struct tb_i18n_pair *pairs,
                           size_t pair_count);
static void tb_set_receiver_mode_requested(char *dest,
                                           size_t size,
                                           int width,
                                           int height,
                                           const char *source,
                                           const char *preset,
                                           const char *codec);
static void tb_refresh_idle_localized_strings(struct app *a);
static void tb_receiver_load_language_preference(char *dest, size_t size);
static void tb_receiver_save_language_preference(const char *language_pref);
static void tb_receiver_apply_language_preference(struct app *a);
static void tb_receiver_cycle_language_preference(struct app *a);
static void tb_receiver_refresh_language_text(struct app *a);
static void tb_receiver_refresh_permissions_text(struct app *a);
static void tb_receiver_poll_permissions(struct app *a);
static int tb_receiver_input_monitoring_trusted(void);
static int tb_receiver_accessibility_trusted(void);
static void send_receiver_info(struct app *a);
static void tb_receiver_apply_input_event(const uint8_t *payload, size_t len);
static void tb_receiver_apply_input_control_mode(struct app *a, const uint8_t *payload, size_t len);
static void tb_receiver_refresh_input_capture(struct app *a);
static void tb_receiver_set_clipboard_text(const char *text);
static int tb_receiver_get_clipboard_text(char *dest, size_t size);
static void tb_receiver_send_clipboard_if_changed(struct app *a);
static void write_be32(uint8_t *dst, uint32_t value);
static int send_all(int fd, const uint8_t *buf, size_t len);
static void tb_receiver_send_display_tweaks_if_changed(struct app *a);

static int tb_receiver_is_valid_language_pref(const char *language_pref) {
    return language_pref &&
           (strcmp(language_pref, "auto") == 0 ||
            strcmp(language_pref, "it") == 0 ||
            strcmp(language_pref, "en") == 0 ||
            strcmp(language_pref, "de") == 0 ||
            strcmp(language_pref, "fr") == 0 ||
            strcmp(language_pref, "zh") == 0);
}

static void tb_receiver_settings_path(char *dest, size_t size) {
    const char *home = getenv("HOME");
    if (!dest || size == 0) return;
    dest[0] = '\0';
    if (!home || !*home) return;
    snprintf(dest, size, "%s/Library/Application Support/TargetBridge Receiver/settings.json", home);
}

static void tb_receiver_ensure_settings_dir(void) {
    const char *home = getenv("HOME");
    if (!home || !*home) return;

    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/Library", home);
    mkdir(path, 0755);
    snprintf(path, sizeof(path), "%s/Library/Application Support", home);
    mkdir(path, 0755);
    snprintf(path, sizeof(path), "%s/Library/Application Support/TargetBridge Receiver", home);
    mkdir(path, 0755);
}

static void tb_receiver_load_language_preference(char *dest, size_t size) {
    if (!dest || size == 0) return;
    snprintf(dest, size, "%s", "auto");

    char path[PATH_MAX];
    tb_receiver_settings_path(path, sizeof(path));
    if (!path[0]) return;

    FILE *fp = fopen(path, "rb");
    if (!fp) return;

    char buf[256];
    size_t n = fread(buf, 1, sizeof(buf) - 1, fp);
    fclose(fp);
    buf[n] = '\0';

    const char *pos = strstr(buf, "\"language\"");
    if (!pos) return;
    pos = strchr(pos, ':');
    if (!pos) return;
    pos = strchr(pos, '"');
    if (!pos) return;
    pos++;

    char code[8];
    size_t i = 0;
    while (*pos && *pos != '"' && i + 1 < sizeof(code)) code[i++] = *pos++;
    code[i] = '\0';

    if (tb_receiver_is_valid_language_pref(code)) {
        snprintf(dest, size, "%s", code);
    }
}

static void tb_receiver_save_language_preference(const char *language_pref) {
    if (!tb_receiver_is_valid_language_pref(language_pref)) return;
    tb_receiver_ensure_settings_dir();

    char path[PATH_MAX];
    tb_receiver_settings_path(path, sizeof(path));
    if (!path[0]) return;

    FILE *fp = fopen(path, "wb");
    if (!fp) return;
    fprintf(fp, "{\n  \"language\": \"%s\"\n}\n", language_pref);
    fclose(fp);
}

static const char *tb_receiver_language_display_name(const char *language_code) {
    if (!language_code || !*language_code) language_code = "en";
    if (strcmp(language_code, "it") == 0) return tb_i18n_get("common.language.italian");
    if (strcmp(language_code, "de") == 0) return tb_i18n_get("common.language.german");
    if (strcmp(language_code, "fr") == 0) return tb_i18n_get("common.language.french");
    if (strcmp(language_code, "zh") == 0) return tb_i18n_get("common.language.chinese");
    return tb_i18n_get("common.language.english");
}

static void tb_receiver_refresh_language_text(struct app *a) {
    if (!a) return;
    if (strcmp(a->language_pref, "auto") == 0) {
        snprintf(a->language_text,
                 sizeof(a->language_text),
                 "%s · %s",
                 tb_i18n_get("receiver.language.auto"),
                 tb_receiver_language_display_name(tb_i18n_current_language()));
    } else {
        snprintf(a->language_text,
                 sizeof(a->language_text),
                 "%s",
                 tb_receiver_language_display_name(a->language_pref));
    }
}

static void tb_receiver_refresh_permissions_text(struct app *a) {
    if (!a) return;

    const int input_monitoring = (a->last_input_monitoring_trusted >= 0)
        ? a->last_input_monitoring_trusted
        : tb_receiver_input_monitoring_trusted();
    const int accessibility = (a->last_accessibility_trusted >= 0)
        ? a->last_accessibility_trusted
        : tb_receiver_accessibility_trusted();
    const char *lang = tb_i18n_current_language();

    if (lang && strncmp(lang, "it", 2) == 0) {
        snprintf(
            a->permissions_text,
            sizeof(a->permissions_text),
            "Monitoraggio input: %s   Accessibilità: %s",
            input_monitoring ? "OK" : "Mancante",
            accessibility ? "OK" : "Mancante"
        );
    } else if (lang && strncmp(lang, "de", 2) == 0) {
        snprintf(
            a->permissions_text,
            sizeof(a->permissions_text),
            "Input-Monitoring: %s   Bedienungshilfen: %s",
            input_monitoring ? "OK" : "Fehlt",
            accessibility ? "OK" : "Fehlt"
        );
    } else if (lang && strncmp(lang, "zh", 2) == 0) {
        snprintf(
            a->permissions_text,
            sizeof(a->permissions_text),
            "输入监控：%s   辅助功能：%s",
            input_monitoring ? "正常" : "缺失",
            accessibility ? "正常" : "缺失"
        );
    } else {
        snprintf(
            a->permissions_text,
            sizeof(a->permissions_text),
            "Input Monitoring: %s   Accessibility: %s",
            input_monitoring ? "OK" : "Missing",
            accessibility ? "OK" : "Missing"
        );
    }
}

static void tb_receiver_poll_permissions(struct app *a) {
    if (!a) return;

    const int input_monitoring = tb_receiver_input_monitoring_trusted();
    const int accessibility = tb_receiver_accessibility_trusted();

    const int changed =
        input_monitoring != a->last_input_monitoring_trusted ||
        accessibility != a->last_accessibility_trusted;

    a->last_input_monitoring_trusted = input_monitoring;
    a->last_accessibility_trusted = accessibility;

    if (!changed) return;

    tb_receiver_refresh_permissions_text(a);
    tb_receiver_refresh_input_capture(a);
    if (a->client_fd >= 0) {
        send_receiver_info(a);
    }
    tb_receiver_input_log("[input] permission state changed inputMonitoring=%s accessibility=%s",
                          input_monitoring ? "true" : "false",
                          accessibility ? "true" : "false");
}

static void tb_receiver_apply_language_preference(struct app *a) {
    if (!a) return;

    if (strcmp(a->language_pref, "auto") == 0) {
        if (a->sender_ui_language[0] != '\0') {
            tb_i18n_set_runtime_language(a->sender_ui_language);
        } else {
            tb_i18n_set_runtime_language("auto");
        }
    } else {
        tb_i18n_set_runtime_language(a->language_pref);
    }

    tb_refresh_idle_localized_strings(a);
    tb_receiver_refresh_language_text(a);
    tb_receiver_refresh_permissions_text(a);
}

static int tb_receiver_input_monitoring_trusted(void) {
    return CGPreflightListenEventAccess() ? 1 : 0;
}

static int tb_receiver_accessibility_trusted(void) {
    return AXIsProcessTrusted() ? 1 : 0;
}

static void tb_receiver_cycle_language_preference(struct app *a) {
    if (!a) return;

    if (strcmp(a->language_pref, "auto") == 0) {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "it");
    } else if (strcmp(a->language_pref, "it") == 0) {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "en");
    } else if (strcmp(a->language_pref, "en") == 0) {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "de");
    } else if (strcmp(a->language_pref, "de") == 0) {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "fr");
    } else if (strcmp(a->language_pref, "fr") == 0) {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "zh");
    } else {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "auto");
    }

    tb_receiver_save_language_preference(a->language_pref);
    tb_receiver_apply_language_preference(a);
}

static void tb_refresh_idle_localized_strings(struct app *a) {
    if (!a) return;
    tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.waiting_for_sender");
    tb_copy_i18n(a->sender_text, sizeof(a->sender_text), "receiver.status.waiting");
    tb_copy_i18n(a->mode_text, sizeof(a->mode_text), "receiver.mode.default");
    tb_receiver_refresh_permissions_text(a);
    if (a->ip_text[0] == '\0') {
        tb_copy_i18n(a->ip_text, sizeof(a->ip_text), "receiver.network.not_detected");
    }
}

static void tb_copy_i18n(char *dest, size_t size, const char *key) {
    if (!dest || size == 0) return;
    snprintf(dest, size, "%s", tb_i18n_get(key));
}

static void tb_json_escape_string(const char *src, char *dest, size_t size) {
    if (!dest || size == 0) return;
    if (!src) {
        dest[0] = '\0';
        return;
    }

    size_t j = 0;
    for (size_t i = 0; src[i] != '\0' && j + 1 < size; i++) {
        char c = src[i];
        const char *escape = NULL;
        switch (c) {
        case '\\': escape = "\\\\"; break;
        case '"': escape = "\\\""; break;
        case '\n': escape = "\\n"; break;
        case '\r': escape = "\\r"; break;
        case '\t': escape = "\\t"; break;
        default: break;
        }

        if (escape) {
            for (size_t k = 0; escape[k] != '\0' && j + 1 < size; k++) {
                dest[j++] = escape[k];
            }
        } else {
            dest[j++] = c;
        }
    }
    dest[j] = '\0';
}

static void tb_receiver_set_clipboard_text(const char *text) {
    FILE *pipe = popen("pbcopy", "w");
    if (!pipe) return;
    if (text && *text) {
        fwrite(text, 1, strlen(text), pipe);
    }
    pclose(pipe);
}

static int tb_receiver_get_clipboard_text(char *dest, size_t size) {
    if (!dest || size == 0) return 0;
    dest[0] = '\0';

    FILE *pipe = popen("pbpaste", "r");
    if (!pipe) return 0;

    size_t total = 0;
    while (!feof(pipe) && total + 1 < size) {
        size_t n = fread(dest + total, 1, size - total - 1, pipe);
        total += n;
        if (n == 0) break;
    }
    dest[total] = '\0';
    pclose(pipe);
    return 1;
}

static void tb_receiver_send_clipboard_if_changed(struct app *a) {
    if (!a || strcmp(a->input_control_mode, "receiverMaster") != 0 || a->client_fd < 0) return;

    char text[4096];
    if (!tb_receiver_get_clipboard_text(text, sizeof(text))) return;
    if (strcmp(text, a->last_clipboard_text) == 0) return;

    snprintf(a->last_clipboard_text, sizeof(a->last_clipboard_text), "%s", text);

    char escaped[8192];
    tb_json_escape_string(text, escaped, sizeof(escaped));

    char json[8300];
    int len = snprintf(json, sizeof(json), "{\"text\":\"%s\"}", escaped);
    if (len <= 0 || (size_t)len >= sizeof(json)) return;

    uint8_t header[TB_HDR_BYTES];
    write_be32(header, (uint32_t)(1 + len));
    header[4] = TB_PKT_CLIPBOARD;
    if (write(a->client_fd, header, TB_HDR_BYTES) != TB_HDR_BYTES) return;
    (void)write(a->client_fd, json, (size_t)len);
}

static void tb_format_i18n(char *dest,
                           size_t size,
                           const char *key,
                           const struct tb_i18n_pair *pairs,
                           size_t pair_count) {
    tb_i18n_format(dest, size, key, pairs, pair_count);
}

static void tb_set_receiver_mode_requested(char *dest,
                                           size_t size,
                                           int width,
                                           int height,
                                           const char *source,
                                           const char *preset,
                                           const char *codec) {
    char width_text[16];
    char height_text[16];
    snprintf(width_text, sizeof(width_text), "%d", width);
    snprintf(height_text, sizeof(height_text), "%d", height);

    struct tb_i18n_pair pairs[] = {
        { "width", width_text },
        { "height", height_text },
        { "source", source ? source : "" },
        { "preset", preset ? preset : "" },
        { "codec", codec ? codec : "" }
    };

    if (width > 0 && height > 0 && source && *source && preset && *preset && codec && *codec) {
        tb_format_i18n(dest, size, "receiver.mode.requested_source_preset_codec", pairs, 5);
    } else if (width > 0 && height > 0 && preset && *preset && codec && *codec) {
        tb_format_i18n(dest, size, "receiver.mode.requested_preset_codec", pairs, 5);
    } else if (width > 0 && height > 0 && preset && *preset) {
        tb_format_i18n(dest, size, "receiver.mode.requested_preset", pairs, 5);
    } else if (width > 0 && height > 0 && codec && *codec) {
        tb_format_i18n(dest, size, "receiver.mode.requested_codec", pairs, 5);
    } else if (width > 0 && height > 0) {
        tb_format_i18n(dest, size, "receiver.mode.requested", pairs, 5);
    }
}

static void bonjour_deinit(struct app *a) {
    if (a->bonjour_ref) {
        DNSServiceRefDeallocate(a->bonjour_ref);
        a->bonjour_ref = NULL;
    }
}

static void on_bonjour_register(DNSServiceRef sdRef,
                                DNSServiceFlags flags,
                                DNSServiceErrorType errorCode,
                                const char *name,
                                const char *regtype,
                                const char *domain,
                                void *context) {
    (void)sdRef;
    (void)flags;
    (void)context;
    if (errorCode == kDNSServiceErr_NoError) {
        fprintf(stderr, "[bonjour] published %s.%s%s\n", name ? name : "TargetBridge Receiver", regtype ? regtype : "", domain ? domain : "");
    } else {
        fprintf(stderr, "[bonjour] register failed: %d\n", (int)errorCode);
    }
}

static void bonjour_update(struct app *a, uint16_t port) {
    bonjour_deinit(a);

    if (a->ip_text[0] == '\0' || strcmp(a->ip_text, tb_i18n_get("receiver.network.not_detected")) == 0) return;

    TXTRecordRef txt;
    TXTRecordCreate(&txt, 0, NULL);
    TXTRecordSetValue(&txt, "name", (uint8_t)strlen(a->bonjour_name), a->bonjour_name);
    TXTRecordSetValue(&txt, "ip", (uint8_t)strlen(a->ip_text), a->ip_text);
    if (a->tb_ip_text[0] != '\0') {
        TXTRecordSetValue(&txt, "tbIP", (uint8_t)strlen(a->tb_ip_text), a->tb_ip_text);
    }
    if (a->net_ip_text[0] != '\0') {
        TXTRecordSetValue(&txt, "netIP", (uint8_t)strlen(a->net_ip_text), a->net_ip_text);
    }
    TXTRecordSetValue(&txt, "panel", (uint8_t)strlen(a->panel_text), a->panel_text);
    TXTRecordSetValue(&txt, "version", (uint8_t)strlen(TB_RECEIVER_VERSION), TB_RECEIVER_VERSION);
    TXTRecordSetValue(&txt, "supportsHEVCDecode", 1, tb_dec_supports_hevc_hwdecode() ? "1" : "0");
    TXTRecordSetValue(&txt, "supportsRawNV12", 1, "1");

    struct tb_display_info info;
    if (tb_disp_get_info(a->disp, &info) == 0) {
        char panel_w[16];
        char panel_h[16];
        snprintf(panel_w, sizeof(panel_w), "%u", info.active_w);
        snprintf(panel_h, sizeof(panel_h), "%u", info.active_h);
        TXTRecordSetValue(&txt, "panelWidth", (uint8_t)strlen(panel_w), panel_w);
        TXTRecordSetValue(&txt, "panelHeight", (uint8_t)strlen(panel_h), panel_h);
    }

    DNSServiceErrorType err = DNSServiceRegister(
        &a->bonjour_ref,
        0,
        0,
        a->bonjour_name,
        "_targetbridge._tcp",
        "local.",
        NULL,
        htons(port),
        TXTRecordGetLength(&txt),
        TXTRecordGetBytesPtr(&txt),
        on_bonjour_register,
        a
    );
    TXTRecordDeallocate(&txt);

    if (err != kDNSServiceErr_NoError) {
        fprintf(stderr, "[bonjour] unable to publish receiver service: %d\n", (int)err);
        bonjour_deinit(a);
    }
}

static void extract_json_string_field(const uint8_t *payload,
                                      size_t len,
                                      const char *key,
                                      char *out,
                                      size_t out_size) {
    if (!payload || !key || !out || out_size == 0) return;
    out[0] = '\0';

    const char *text = (const char *)payload;
    const char *pos = strstr(text, key);
    if (!pos) return;

    pos = strchr(pos, ':');
    if (!pos) return;
    pos = strchr(pos, '"');
    if (!pos) return;
    pos++;

    size_t i = 0;
    while ((size_t)(pos - text) < len && *pos && *pos != '"' && i + 1 < out_size) {
        if (*pos == '\\' && (size_t)(pos - text + 1) < len && pos[1] != '\0') pos++;
        out[i++] = *pos++;
    }
    out[i] = '\0';
}

static int extract_json_int_field(const uint8_t *payload,
                                  size_t len,
                                  const char *key,
                                  int *out_value) {
    if (!payload || !key || !out_value) return 0;

    const char *text = (const char *)payload;
    const char *pos = strstr(text, key);
    if (!pos) return 0;

    pos = strchr(pos, ':');
    if (!pos) return 0;
    pos++;
    while ((size_t)(pos - text) < len && (*pos == ' ' || *pos == '\t')) pos++;
    if ((size_t)(pos - text) >= len) return 0;

    char *end = NULL;
    long value = strtol(pos, &end, 10);
    if (end == pos) return 0;
    *out_value = (int)value;
    return 1;
}

static int extract_json_bool_field(const uint8_t *payload,
                                   size_t len,
                                   const char *key,
                                   int *out_value) {
    if (!payload || !key || !out_value) return 0;

    const char *text = (const char *)payload;
    const char *pos = strstr(text, key);
    if (!pos) return 0;

    pos = strchr(pos, ':');
    if (!pos) return 0;
    pos++;
    while ((size_t)(pos - text) < len && (*pos == ' ' || *pos == '\t')) pos++;
    if ((size_t)(pos - text) >= len) return 0;

    if (strncmp(pos, "true", 4) == 0) {
        *out_value = 1;
        return 1;
    }
    if (strncmp(pos, "false", 5) == 0) {
        *out_value = 0;
        return 1;
    }
    return extract_json_int_field(payload, len, key, out_value);
}

static int extract_json_double_field(const uint8_t *payload,
                                     size_t len,
                                     const char *key,
                                     double *out_value) {
    if (!payload || !key || !out_value) return 0;

    const char *text = (const char *)payload;
    const char *pos = strstr(text, key);
    if (!pos) return 0;

    pos = strchr(pos, ':');
    if (!pos) return 0;
    pos++;
    while ((size_t)(pos - text) < len && (*pos == ' ' || *pos == '\t')) pos++;
    if ((size_t)(pos - text) >= len) return 0;

    char *end = NULL;
    double value = strtod(pos, &end);
    if (end == pos) return 0;
    *out_value = value;
    return 1;
}

static CGPoint tb_receiver_current_mouse_location(void) {
    CGPoint point = CGPointZero;
    CGEventRef event = CGEventCreate(NULL);
    if (event) {
        point = CGEventGetLocation(event);
        CFRelease(event);
    }
    return point;
}

static void tb_receiver_post_mouse_move(int dx, int dy, CGEventType type, CGMouseButton button) {
    CGPoint current = tb_receiver_current_mouse_location();
    CGPoint target = CGPointMake(current.x + dx, current.y + dy);
    CGEventRef event = CGEventCreateMouseEvent(NULL, type, target, button);
    if (!event) return;
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void tb_receiver_post_mouse_button(CGEventType type, CGMouseButton button) {
    CGPoint current = tb_receiver_current_mouse_location();
    CGEventRef event = CGEventCreateMouseEvent(NULL, type, current, button);
    if (!event) return;
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void tb_receiver_post_scroll(int scroll_x, int scroll_y) {
    CGEventRef event = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitLine, 2, scroll_y, scroll_x);
    if (!event) return;
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void tb_receiver_post_key(uint16_t key_code, int is_down) {
    CGEventRef event = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)key_code, is_down ? true : false);
    if (!event) return;
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void tb_receiver_apply_input_event(const uint8_t *payload, size_t len) {
    char kind[32];
    kind[0] = '\0';
    extract_json_string_field(payload, len, "\"kind\"", kind, sizeof(kind));
    if (kind[0] == '\0') return;
    tb_receiver_input_log("[input][sender->receiver] received kind=%s len=%zu", kind, len);

    if (strcmp(kind, "move") == 0) {
        int dx = 0;
        int dy = 0;
        (void)extract_json_int_field(payload, len, "\"dx\"", &dx);
        (void)extract_json_int_field(payload, len, "\"dy\"", &dy);
        tb_receiver_post_mouse_move(dx, dy, kCGEventMouseMoved, kCGMouseButtonLeft);
        return;
    }

    if (strcmp(kind, "leftDrag") == 0) {
        int dx = 0;
        int dy = 0;
        (void)extract_json_int_field(payload, len, "\"dx\"", &dx);
        (void)extract_json_int_field(payload, len, "\"dy\"", &dy);
        tb_receiver_post_mouse_move(dx, dy, kCGEventLeftMouseDragged, kCGMouseButtonLeft);
        return;
    }

    if (strcmp(kind, "rightDrag") == 0) {
        int dx = 0;
        int dy = 0;
        (void)extract_json_int_field(payload, len, "\"dx\"", &dx);
        (void)extract_json_int_field(payload, len, "\"dy\"", &dy);
        tb_receiver_post_mouse_move(dx, dy, kCGEventRightMouseDragged, kCGMouseButtonRight);
        return;
    }

    if (strcmp(kind, "otherDrag") == 0) {
        int dx = 0;
        int dy = 0;
        (void)extract_json_int_field(payload, len, "\"dx\"", &dx);
        (void)extract_json_int_field(payload, len, "\"dy\"", &dy);
        tb_receiver_post_mouse_move(dx, dy, kCGEventOtherMouseDragged, kCGMouseButtonCenter);
        return;
    }

    if (strcmp(kind, "leftDown") == 0) {
        tb_receiver_post_mouse_button(kCGEventLeftMouseDown, kCGMouseButtonLeft);
        return;
    }
    if (strcmp(kind, "leftUp") == 0) {
        tb_receiver_post_mouse_button(kCGEventLeftMouseUp, kCGMouseButtonLeft);
        return;
    }
    if (strcmp(kind, "rightDown") == 0) {
        tb_receiver_post_mouse_button(kCGEventRightMouseDown, kCGMouseButtonRight);
        return;
    }
    if (strcmp(kind, "rightUp") == 0) {
        tb_receiver_post_mouse_button(kCGEventRightMouseUp, kCGMouseButtonRight);
        return;
    }
    if (strcmp(kind, "otherDown") == 0) {
        tb_receiver_post_mouse_button(kCGEventOtherMouseDown, kCGMouseButtonCenter);
        return;
    }
    if (strcmp(kind, "otherUp") == 0) {
        tb_receiver_post_mouse_button(kCGEventOtherMouseUp, kCGMouseButtonCenter);
        return;
    }
    if (strcmp(kind, "scroll") == 0) {
        int scroll_x = 0;
        int scroll_y = 0;
        (void)extract_json_int_field(payload, len, "\"scrollX\"", &scroll_x);
        (void)extract_json_int_field(payload, len, "\"scrollY\"", &scroll_y);
        tb_receiver_post_scroll(scroll_x, scroll_y);
        return;
    }
    if (strcmp(kind, "keyDown") == 0 || strcmp(kind, "keyUp") == 0) {
        int key_code = 0;
        if (extract_json_int_field(payload, len, "\"keyCode\"", &key_code)) {
            tb_receiver_post_key((uint16_t)key_code, strcmp(kind, "keyDown") == 0);
        }
    }
}

static void tb_receiver_apply_input_control_mode(struct app *a, const uint8_t *payload, size_t len) {
    char mode[32];
    mode[0] = '\0';
    extract_json_string_field(payload, len, "\"mode\"", mode, sizeof(mode));
    if (mode[0] == '\0') {
        snprintf(a->input_control_mode, sizeof(a->input_control_mode), "off");
    } else {
        snprintf(a->input_control_mode, sizeof(a->input_control_mode), "%s", mode);
    }
    tb_receiver_input_log("[input] control mode updated to %s", a->input_control_mode);
    if (strcmp(a->input_control_mode, "receiverMaster") != 0) {
        a->sent_command_down = 0;
        a->sent_shift_down = 0;
        a->sent_option_down = 0;
        a->sent_control_down = 0;
        a->sent_caps_down = 0;
    }
    tb_receiver_refresh_input_capture(a);
}

/* ---- Callbacks: decoder → display ------------------------------------ */

static void on_frame(const uint8_t *y, int y_stride,
                     const uint8_t *uv, int uv_stride,
                     int w, int h, void *ud) {
    struct app *a = (struct app *)ud;
    a->have_video_frame = 1;
    tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.stream_active");
    {
        char width_text[16];
        char height_text[16];
        struct tb_i18n_pair pairs[] = {
            { "width", width_text },
            { "height", height_text }
        };
        snprintf(width_text, sizeof(width_text), "%d", w);
        snprintf(height_text, sizeof(height_text), "%d", h);
        tb_format_i18n(a->mode_text, sizeof(a->mode_text), "receiver.mode.receiving", pairs, 2);
    }
    tb_disp_render_nv12(a->disp, y, y_stride, uv, uv_stride, w, h);
    a->frames++;
}

/* Raw passthrough: render received NV12 planes directly, bypassing the decoder.
 * Payload: [1: format=1(NV12)][BE32 w][BE32 h][BE32 yStride][BE32 uvStride]
 *          [Y plane: yStride*h][CbCr plane: uvStride*(h/2)] */
static void handle_raw_frame(struct app *a, const uint8_t *p, size_t len) {
    if (len < 13) return;
    uint8_t format = p[0];  /* 1 = NV12 4:2:0, 2 = BGRA8888 4:4:4, 3 = ARGB2101010 4:4:4 */
    uint32_t w = ((uint32_t)p[1] << 24) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 8) | (uint32_t)p[4];
    uint32_t h = ((uint32_t)p[5] << 24) | ((uint32_t)p[6] << 16) | ((uint32_t)p[7] << 8) | (uint32_t)p[8];
    /* Sanity bounds: reject implausible dimensions so the size math below can't
     * overflow on a malformed packet. */
    if (w == 0 || h == 0 || w > 16384 || h > 16384) return;

    const uint8_t *y = NULL, *uv = NULL, *rgba = NULL;
    uint32_t ys = 0, us = 0, stride = 0;

    if (format == 1) {
        if (len < 17) return;
        ys = ((uint32_t)p[9]  << 24) | ((uint32_t)p[10] << 16) | ((uint32_t)p[11] << 8) | (uint32_t)p[12];
        us = ((uint32_t)p[13] << 24) | ((uint32_t)p[14] << 16) | ((uint32_t)p[15] << 8) | (uint32_t)p[16];
        if (ys < w || us < w) return;
        size_t y_size  = (size_t)ys * h;
        size_t uv_size = (size_t)us * (h / 2);
        if (len < (size_t)17 + y_size + uv_size) return;
        y  = p + 17;
        uv = y + y_size;
    } else if (format == 2 || format == 3) {
        /* Both packed 4:4:4 at 4 bytes/pixel — identical layout, and only the
         * texture format the receiver picks differs. */
        stride = ((uint32_t)p[9] << 24) | ((uint32_t)p[10] << 16) | ((uint32_t)p[11] << 8) | (uint32_t)p[12];
        if ((uint64_t)stride < (uint64_t)w * 4) return;   /* 4 bytes/pixel */
        size_t size = (size_t)stride * h;
        if (len < (size_t)13 + size) return;
        rgba = p + 13;
    } else {
        return;  /* unknown format */
    }

    a->have_video_frame = 1;
    tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.stream_active");
    {
        char width_text[16];
        char height_text[16];
        struct tb_i18n_pair pairs[] = {
            { "width", width_text },
            { "height", height_text }
        };
        snprintf(width_text, sizeof(width_text), "%u", w);
        snprintf(height_text, sizeof(height_text), "%u", h);
        tb_format_i18n(a->mode_text, sizeof(a->mode_text), "receiver.mode.receiving", pairs, 2);
    }
    if (format == 1) {
        /* Snapshot both planes tightly packed (Y then interleaved UV) so damage
         * packets can patch them. Chroma is half resolution in both axes. */
        size_t y_sz = (size_t)w * h;
        size_t need = y_sz + (size_t)w * (h / 2);
        if (a->base_cap < need) {
            uint8_t *nb = (uint8_t *)realloc(a->base_img, need);
            if (nb) { a->base_img = nb; a->base_cap = need; }
        }
        if (a->base_img && a->base_cap >= need) {
            for (uint32_t row = 0; row < h; ++row)
                memcpy(a->base_img + (size_t)row * w, y + (size_t)row * ys, w);
            for (uint32_t row = 0; row < h / 2; ++row)
                memcpy(a->base_img + y_sz + (size_t)row * w, uv + (size_t)row * us, w);
            a->base_w = w; a->base_h = h; a->base_format = 1; a->base_valid = 1;
        } else {
            a->base_valid = 0;
        }
        tb_disp_render_nv12(a->disp, y, (int)ys, uv, (int)us, (int)w, (int)h);
    } else {
        /* Snapshot as the base image so subsequent damage packets can patch it.
         * Stored tightly packed (stride == w*4) regardless of the wire stride. */
        size_t need = (size_t)w * h * 4;
        if (a->base_cap < need) {
            uint8_t *nb = (uint8_t *)realloc(a->base_img, need);
            if (nb) { a->base_img = nb; a->base_cap = need; }
        }
        if (a->base_img && a->base_cap >= need) {
            for (uint32_t row = 0; row < h; ++row) {
                memcpy(a->base_img + (size_t)row * w * 4,
                       rgba + (size_t)row * stride, (size_t)w * 4);
            }
            a->base_w = w; a->base_h = h; a->base_format = format; a->base_valid = 1;
        } else {
            a->base_valid = 0;
        }
        tb_disp_render_packed32(a->disp, rgba, (int)stride, (int)w, (int)h, format == 3);
    }
    a->frames++;
}


/* TB_PKT_RAW_DPCM — a whole frame, losslessly compressed (tb_dpcm.h). Decoded
 * on the GPU; there is no CPU-side copy and no base image, which is why the
 * sender does not mix damage packets into this path.
 *
 * Nothing is validated here on purpose: tb_metal_plane_render_dpcm calls
 * tb_dpcm_parse, which checks every declared length against the actual one and
 * re-derives the offset table from the width plane. That check is what allows
 * the decode kernel to run with no bounds tests at all. */
static void handle_raw_dpcm(struct app *a, const uint8_t *payload, size_t len) {
    if (tb_disp_render_dpcm(a->disp, payload, len) != 0) {
        a->frames_dropped++;
        return;
    }
    /* A DPCM frame leaves no CPU base image behind, so a damage packet arriving
     * after one has nothing to patch. Saying so here means a sender that mixes
     * the two gets refused rather than showing a frame built on stale pixels. */
    a->base_valid = 0;
    a->have_video_frame = 1;
    tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.stream_active");
    a->frames++;
}

/* The protocol is big-endian on the wire; main.c had only a writer. */
static inline uint32_t be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16)
         | ((uint32_t)p[2] <<  8) | (uint32_t)p[3];
}

/* TB_PKT_RAW_DPCM_SLICE — one band of a frame. See proto.h for the header.
 *
 * Bands are decoded as they arrive and only the last presents, so the GPU works
 * on band k while band k+1 is still on the wire. Every field is checked here
 * because the blob's own validation covers the blob, not the placement: a band
 * claiming the wrong y0 would be written to the wrong rows and still look like a
 * picture. */
/* TB_PKT_RAW_DPCM_RECT — one tile-aligned rectangle. See proto.h.
 *
 * Deliberately a near-copy of the band handler rather than a shared one with
 * flags: the two differ only in header layout and the presence of x0, and the
 * band path is load-bearing enough that threading a mode through it is the more
 * dangerous edit. */
static void handle_raw_dpcm_rect(struct app *a, const uint8_t *p, size_t len) {
    if (len < TB_DPCM_RECT_HEADER) { a->frames_dropped++; return; }

    const uint32_t frame_id = be32(p + 8);
    const uint32_t frame_w  = be32(p + 12);
    const uint32_t frame_h  = be32(p + 16);
    const uint32_t x0       = be32(p + 20);
    const uint32_t y0       = be32(p + 24);
    const uint16_t index    = (uint16_t)((p[28] << 8) | p[29]);
    const uint16_t count    = (uint16_t)((p[30] << 8) | p[31]);

    if (count == 0 || index >= count) { a->frames_dropped++; return; }
    if (frame_w == 0 || frame_h == 0 || frame_w > 16384 || frame_h > 16384) { a->frames_dropped++; return; }
    if (x0 >= frame_w || y0 >= frame_h) { a->frames_dropped++; return; }
    /* Both offsets must land on the tile grid or the shader writes a region
     * shifted against the tiles it decoded. */
    if ((x0 % 8u) || (y0 % 8u)) { a->frames_dropped++; return; }

    if (frame_id != a->dpcm_frame_id) {
        if (index != 0 && !a->dpcm_seq_warned) {
            a->dpcm_seq_warned = 1;
            fprintf(stderr, "[dpcm] frame %u started at rect %u of %u\n", frame_id, index, count);
        }
        a->dpcm_frame_id = frame_id;
    }

    const int is_last = (index + 1 == count);
    if (tb_disp_render_dpcm_slice(a->disp, p + TB_DPCM_RECT_HEADER,
                                  len - TB_DPCM_RECT_HEADER,
                                  (int)frame_w, (int)frame_h,
                                  (int)x0, (int)y0, is_last) != 0) {
        a->frames_dropped++;
    } else if (index < 32) {
        a->dpcm_got_mask |= (1u << index);
    }

    if (is_last) {
        const uint32_t want = (count >= 32) ? 0xFFFFFFFFu : ((1u << count) - 1u);
        a->dpcm_frames_total++;
        if ((a->dpcm_got_mask & want) != want) {
            a->dpcm_frames_short++;
            for (int b = 0; b < count && b < 32; ++b)
                if (!(a->dpcm_got_mask & (1u << b))) a->dpcm_bands_lost++;
        }
        a->dpcm_got_mask = 0;
    }
    a->have_video_frame = 1;
}

static void handle_raw_dpcm_slice(struct app *a, const uint8_t *p, size_t len) {
    if (len < TB_DPCM_SLICE_HEADER) { a->frames_dropped++; return; }

    const uint32_t frame_id = be32(p + 8);
    const uint32_t frame_w  = be32(p + 12);
    const uint32_t frame_h  = be32(p + 16);
    const uint32_t y0       = be32(p + 20);
    const uint16_t index    = (uint16_t)((p[24] << 8) | p[25]);
    const uint16_t count    = (uint16_t)((p[26] << 8) | p[27]);

    if (count == 0 || index >= count) { a->frames_dropped++; return; }
    if (frame_w == 0 || frame_h == 0 || frame_w > 16384 || frame_h > 16384) { a->frames_dropped++; return; }
    if (y0 >= frame_h) { a->frames_dropped++; return; }

    /* TCP delivers in order, so out-of-sequence means a genuine break — a
     * reconnect, or a sender bug. Log once rather than per frame. */
    if (frame_id != a->dpcm_frame_id) {
        if (index != 0 && !a->dpcm_seq_warned) {
            a->dpcm_seq_warned = 1;
            fprintf(stderr, "[dpcm] frame %u started at slice %u of %u\n", frame_id, index, count);
        }
        a->dpcm_frame_id = frame_id;
    }

    const int is_last = (index + 1 == count);
    if (tb_disp_render_dpcm_slice(a->disp, p + TB_DPCM_SLICE_HEADER,
                                  len - TB_DPCM_SLICE_HEADER,
                                  (int)frame_w, (int)frame_h, 0, (int)y0, is_last) != 0) {
        a->frames_dropped++;
        /* Fall through: the frame still presents on its last band, so a lost
         * band must be counted, not silently forgotten. */
    } else if (index < 32) {
        a->dpcm_got_mask |= (1u << index);
    }

    if (is_last) {
        const uint32_t want = (count >= 32) ? 0xFFFFFFFFu : ((1u << count) - 1u);
        const uint32_t got  = a->dpcm_got_mask;
        a->dpcm_frames_total++;
        if ((got & want) != want) {
            a->dpcm_frames_short++;
            for (int b = 0; b < count && b < 32; ++b)
                if (!(got & (1u << b))) a->dpcm_bands_lost++;
        }
        a->dpcm_got_mask = 0;

        const uint32_t now_s = SDL_GetTicks() / 1000;
        if (now_s != a->dpcm_last_report && a->dpcm_frames_total >= 30) {
            a->dpcm_last_report = now_s;
            /* queue depth and overflow say whether the reader is getting ahead
             * of the renderer — the condition that used to wedge the session. */
            pthread_mutex_lock(&a->net_lock);
            const int qd = a->vq_count;
            const uint64_t qo = a->vq_overflow;
            a->vq_overflow = 0;
            pthread_mutex_unlock(&a->net_lock);
            fprintf(stderr,
                    "[slices] %u frames, %u incomplete (%.1f%%), %u bands lost | queue %d/%d, %llu overflow\n",
                    a->dpcm_frames_total, a->dpcm_frames_short,
                    100.0 * a->dpcm_frames_short / a->dpcm_frames_total,
                    a->dpcm_bands_lost, qd, TB_VIDEO_QUEUE,
                    (unsigned long long)qo);
            a->dpcm_frames_total = a->dpcm_frames_short = a->dpcm_bands_lost = 0;
        }
    }
    /* Set before the last-band gate: the main loop uses this to decide whether
     * the stream is live, and a frame mid-assembly is very much live. */
    a->have_video_frame = 1;

    if (!is_last) return;

    /* A DPCM frame leaves no CPU base image behind, so a damage packet arriving
     * after one has nothing to patch. */
    a->base_valid = 0;
    tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.stream_active");
    a->frames++;
}

/* TB_PKT_RAW_DAMAGE — patch changed rectangles into the base image, then
 * render it. Every bounds check matters here: the payload is attacker-shaped
 * data and a bad rect would write outside the frame buffer. */
static void handle_raw_damage(struct app *a, const uint8_t *p, size_t len) {
    if (len < 11) return;
    uint8_t  format = p[0];
    uint32_t w = ((uint32_t)p[1] << 24) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 8) | (uint32_t)p[4];
    uint32_t h = ((uint32_t)p[5] << 24) | ((uint32_t)p[6] << 16) | ((uint32_t)p[7] << 8) | (uint32_t)p[8];
    uint16_t rects = (uint16_t)(((uint16_t)p[9] << 8) | (uint16_t)p[10]);

    /* Without a matching base image there is nothing to patch; wait for the
     * next full frame rather than rendering garbage. */
    if (!a->base_valid || w != a->base_w || h != a->base_h || format != a->base_format) return;
    if (format != 1 && format != 2 && format != 3) return;
    const size_t y_plane = (size_t)w * h;   /* only meaningful for format 1 */

    size_t off = 11;
    for (uint16_t i = 0; i < rects; ++i) {
        if (len - off < 16) return;
        uint32_t rx = ((uint32_t)p[off]   << 24) | ((uint32_t)p[off+1] << 16) | ((uint32_t)p[off+2] << 8) | (uint32_t)p[off+3];
        uint32_t ry = ((uint32_t)p[off+4] << 24) | ((uint32_t)p[off+5] << 16) | ((uint32_t)p[off+6] << 8) | (uint32_t)p[off+7];
        uint32_t rw = ((uint32_t)p[off+8] << 24) | ((uint32_t)p[off+9] << 16) | ((uint32_t)p[off+10]<< 8) | (uint32_t)p[off+11];
        uint32_t rh = ((uint32_t)p[off+12]<< 24) | ((uint32_t)p[off+13]<< 16) | ((uint32_t)p[off+14]<< 8) | (uint32_t)p[off+15];
        off += 16;

        if (rw == 0 || rh == 0) continue;
        /* Reject anything that would land outside the frame, using 64-bit maths
         * so the sum cannot wrap. */
        if ((uint64_t)rx + rw > (uint64_t)w || (uint64_t)ry + rh > (uint64_t)h) return;

        if (format == 1) {
            /* Planar: rects are even-aligned by the sender so the half-resolution
             * chroma rect is exact. Y is rw x rh; UV is rw bytes x rh/2 rows
             * (rw/2 chroma pairs). */
            if ((rx | ry | rw | rh) & 1u) return;    /* misaligned: refuse */
            size_t y_bytes  = (size_t)rw * rh;
            size_t uv_bytes = (size_t)rw * (rh / 2);
            if (len - off < y_bytes + uv_bytes) return;

            for (uint32_t row = 0; row < rh; ++row)
                memcpy(a->base_img + (size_t)(ry + row) * w + rx,
                       p + off + (size_t)row * rw, rw);
            off += y_bytes;
            for (uint32_t row = 0; row < rh / 2; ++row)
                memcpy(a->base_img + y_plane + (size_t)(ry / 2 + row) * w + rx,
                       p + off + (size_t)row * rw, rw);
            off += uv_bytes;
        } else {
            size_t bytes = (size_t)rw * rh * 4;
            if (len - off < bytes) return;
            for (uint32_t row = 0; row < rh; ++row) {
                memcpy(a->base_img + ((size_t)(ry + row) * w + rx) * 4,
                       p + off + (size_t)row * rw * 4,
                       (size_t)rw * 4);
            }
            off += bytes;
        }
    }

    a->have_video_frame = 1;
    tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.stream_active");
    if (format == 1) {
        tb_disp_render_nv12(a->disp, a->base_img, (int)w,
                            a->base_img + y_plane, (int)w, (int)w, (int)h);
    } else {
        tb_disp_render_packed32(a->disp, a->base_img, (int)(w * 4), (int)w, (int)h, format == 3);
    }
    a->frames++;
}

static void ring_read(struct app *a, Uint8 *dst, int len) {
    int first = AUDIO_BUF_CAP - a->audio_buf_tail;
    if (first >= len) {
        memcpy(dst, a->audio_buf + a->audio_buf_tail, len);
    } else {
        memcpy(dst, a->audio_buf + a->audio_buf_tail, first);
        memcpy(dst + first, a->audio_buf, len - first);
    }
    a->audio_buf_tail = (a->audio_buf_tail + len) % AUDIO_BUF_CAP;
    a->audio_buf_size -= len;
}

static void audio_callback(void *userdata, Uint8 *stream, int len) {
    struct app *a = (struct app *)userdata;
    if (a->audio_buf_size >= len) {
        ring_read(a, stream, len);
    } else {
        int available = a->audio_buf_size;
        if (available > 0) ring_read(a, stream, available);
        memset(stream + available, 0, len - available);
    }
}

/* Drive the receiver's master output volume knob (with the system volume HUD).
 * level is clamped to 0.0..1.0. Sets the default output device's scalar volume,
 * preferring the master element and falling back to per-channel when a device
 * has no master volume control. Safe to call from the network/parser thread. */
static void tb_set_system_volume(double level) {
    if (level < 0.0) level = 0.0;
    if (level > 1.0) level = 1.0;
    Float32 vol = (Float32)level;

    AudioObjectPropertyAddress dev_addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &dev_addr, 0, NULL,
                                   &size, &device) != noErr ||
        device == kAudioObjectUnknown) {
        return;
    }

    AudioObjectPropertyAddress vol_addr = {
        kAudioDevicePropertyVolumeScalar,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain   /* element 0 = master */
    };
    Boolean settable = false;
    if (AudioObjectHasProperty(device, &vol_addr) &&
        AudioObjectIsPropertySettable(device, &vol_addr, &settable) == noErr &&
        settable) {
        AudioObjectSetPropertyData(device, &vol_addr, 0, NULL, sizeof(vol), &vol);
        return;
    }

    /* No master element — set the left/right channels individually. */
    for (UInt32 ch = 1; ch <= 2; ch++) {
        vol_addr.mElement = ch;
        settable = false;
        if (AudioObjectHasProperty(device, &vol_addr) &&
            AudioObjectIsPropertySettable(device, &vol_addr, &settable) == noErr &&
            settable) {
            AudioObjectSetPropertyData(device, &vol_addr, 0, NULL, sizeof(vol), &vol);
        }
    }
}

/* ---- Callbacks: parser → decoder ------------------------------------- */

static void on_packet(uint8_t type, const uint8_t *payload, size_t len, void *ud) {
    struct app *a = (struct app *)ud;
    switch (type) {
    case TB_PKT_UI_LANGUAGE:
        {
            char ui_language[16];
            ui_language[0] = '\0';
            extract_json_string_field(payload, len, "\"uiLanguage\"", ui_language, sizeof(ui_language));
            if (ui_language[0] != '\0') {
                snprintf(a->sender_ui_language, sizeof(a->sender_ui_language), "%s", ui_language);
                if (strcmp(a->language_pref, "auto") == 0) {
                    tb_i18n_set_runtime_language(ui_language);
                }
                if (a->client_fd < 0 || !a->have_video_frame) {
                    tb_refresh_idle_localized_strings(a);
                }
            }
        }
        break;
    case TB_PKT_HELLO_RECEIVER:
        extract_json_string_field(payload, len, "\"senderName\"", a->sender_text, sizeof(a->sender_text));
        {
            char ui_language[16];
            ui_language[0] = '\0';
            extract_json_string_field(payload, len, "\"uiLanguage\"", ui_language, sizeof(ui_language));
            if (ui_language[0] != '\0') {
                snprintf(a->sender_ui_language, sizeof(a->sender_ui_language), "%s", ui_language);
                if (strcmp(a->language_pref, "auto") == 0) {
                    tb_i18n_set_runtime_language(ui_language);
                }
            }
        }
        if (a->sender_text[0] == '\0') {
            tb_copy_i18n(a->sender_text, sizeof(a->sender_text), "receiver.status.sender_connected");
        }
        {
            char preset[64];
            char source[64];
            char codec[64];
            int capture_w = 0;
            int capture_h = 0;
            preset[0] = '\0';
            source[0] = '\0';
            codec[0] = '\0';
            extract_json_string_field(payload, len, "\"capturePreset\"", preset, sizeof(preset));
            extract_json_string_field(payload, len, "\"captureSource\"", source, sizeof(source));
            extract_json_string_field(payload, len, "\"codec\"", codec, sizeof(codec));
            (void)extract_json_int_field(payload, len, "\"captureWidth\"", &capture_w);
            (void)extract_json_int_field(payload, len, "\"captureHeight\"", &capture_h);

            tb_set_receiver_mode_requested(a->mode_text, sizeof(a->mode_text), capture_w, capture_h, source, preset, codec);
        }
        {
            char audio_format[8] = {0};
            extract_json_string_field(payload, len, "\"audioFormat\"",
                                      audio_format, sizeof(audio_format));
            a->audio_input_is_s16 = (strcmp(audio_format, "f32") != 0);
            if (a->audio_input_is_s16) {
                fprintf(stderr, "[main] sender sends Int16 audio; converting\n");
            }
        }
        a->session_active = 1;
        fprintf(stderr, "[main] hello from sender\n");
        tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.sender_connected_profile_sent");
        break;
    case TB_PKT_CREATE_SESSION_ACK:
        a->session_active = 1;
        fprintf(stderr, "[main] sender session ack: %.*s\n", (int)len, (const char *)payload);
        tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.session_accepted_waiting_frames");
        break;
    case TB_PKT_PARAM_SETS:
        a->session_active = 1;
        /* tb_dec_set_param_sets is now a no-op if the sets are unchanged,
         * so we don't spam a log line per keyframe. */
        tb_dec_set_param_sets(a->dec, payload, len);
        break;
    case TB_PKT_FRAME:
        a->session_active = 1;
        tb_dec_feed_frame(a->dec, payload, len);
        break;
    case TB_PKT_RAW_FRAME:
        handle_raw_frame(a, payload, len);
        break;
    case TB_PKT_RAW_DAMAGE:
        handle_raw_damage(a, payload, len);
        break;
    case TB_PKT_RAW_DPCM:
        handle_raw_dpcm(a, payload, len);
        break;
    case TB_PKT_RAW_DPCM_SLICE:
        handle_raw_dpcm_slice(a, payload, len);
        break;
    case TB_PKT_CURSOR:
        {
            int x = 0;
            int y = 0;
            int w = 0;
            int h = 0;
            int visible = 0;
            int type = 0;
            (void)extract_json_int_field(payload, len, "\"x\"", &x);
            (void)extract_json_int_field(payload, len, "\"y\"", &y);
            (void)extract_json_int_field(payload, len, "\"width\"", &w);
            (void)extract_json_int_field(payload, len, "\"height\"", &h);
            (void)extract_json_bool_field(payload, len, "\"visible\"", &visible);
            (void)extract_json_int_field(payload, len, "\"type\"", &type);
            tb_disp_set_cursor(a->disp, x, y, w, h, visible, type);
        }
        break;
    case TB_PKT_BRIGHTNESS:
        {
            double level = 1.0;
            (void)extract_json_double_field(payload, len, "\"level\"", &level);
            tb_disp_set_brightness(a->disp, level);
        }
        break;
    case TB_PKT_DISPLAY_TWEAKS:
        {
            /* Absent fields are left alone rather than defaulted, so the sender
             * can change one without disturbing the other. */
            int night = 0, tone = 0;
            if (extract_json_bool_field(payload, len, "\"nightShift\"", &night)) {
                tb_night_shift_set(night);
            }
            if (extract_json_bool_field(payload, len, "\"trueTone\"", &tone)) {
                tb_true_tone_set(tone);
            }
            int vsync = 0;
            if (extract_json_bool_field(payload, len, "\"vsync\"", &vsync)) {
                tb_metal_plane_set_vsync(vsync);
            }
        }
        break;
    case TB_PKT_CLIPBOARD:
        {
            char text[4096];
            extract_json_string_field(payload, len, "\"text\"", text, sizeof(text));
            tb_receiver_set_clipboard_text(text);
        }
        break;
    case TB_PKT_VOLUME:
        {
            double level = 1.0;
            (void)extract_json_double_field(payload, len, "\"level\"", &level);
            tb_set_system_volume(level);
        }
        break;
    case TB_PKT_AUDIO_FRAME:
        if (a->audio_device != 0) {
            /* The output device is opened as float. Widen an older sender's
             * Int16 rather than reopening the device mid-session. */
            const uint8_t *audio = payload;
            size_t audio_len = len;
            float *widened = NULL;
            if (a->audio_input_is_s16) {
                const size_t samples = len / sizeof(int16_t);
                widened = (float *)malloc(samples * sizeof(float));
                if (!widened) break;
                const int16_t *src = (const int16_t *)payload;
                for (size_t i = 0; i < samples; ++i) {
                    widened[i] = (float)src[i] / AUDIO_INT16_TO_FLOAT;
                }
                audio = (const uint8_t *)widened;
                audio_len = samples * sizeof(float);
            }
            payload = audio;
            len = audio_len;

            SDL_LockAudioDevice(a->audio_device);

            // Cap the backlog so playout stays tight, cushioning network and
            // scheduling jitter without letting delay accumulate.
            const int cap_bytes = AUDIO_BACKLOG_MAX_MS * AUDIO_BYTES_PER_MS;
            if (a->audio_buf_size + len > cap_bytes) {
                int excess = (a->audio_buf_size + len) - cap_bytes;
                a->audio_buf_tail = (a->audio_buf_tail + excess) % AUDIO_BUF_CAP;
                a->audio_buf_size -= excess;
            }

            // Write payload to circular buffer
            if (a->audio_buf_size + (int)len <= AUDIO_BUF_CAP) {
                int first = AUDIO_BUF_CAP - a->audio_buf_head;
                if (first >= (int)len) {
                    memcpy(a->audio_buf + a->audio_buf_head, payload, len);
                } else {
                    memcpy(a->audio_buf + a->audio_buf_head, payload, first);
                    memcpy(a->audio_buf, payload + first, len - first);
                }
                a->audio_buf_head = (a->audio_buf_head + (int)len) % AUDIO_BUF_CAP;
                a->audio_buf_size += (int)len;
            }

            SDL_UnlockAudioDevice(a->audio_device);
            free(widened);
        }
        break;
    case TB_PKT_INPUT_EVENT:
        tb_receiver_apply_input_event(payload, len);
        break;
    case TB_PKT_INPUT_CONTROL:
        tb_receiver_apply_input_control_mode(a, payload, len);
        break;
    case TB_PKT_HEARTBEAT:
        break;
    case TB_PKT_TEST_DATA:
        /* Performance test data; discard */
        break;
    case TB_PKT_TEARDOWN:
        fprintf(stderr, "[main] teardown requested by sender\n");
        tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.session_closed_by_sender");
        a->close_requested = 1;
        break;
    default:
        fprintf(stderr, "[main] unknown pkt type=0x%02x\n", type);
        break;
    }
}

/* ---- Networking helpers ---------------------------------------------- */

static double now_ms_f(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
}

static int drain_fd(int fd, struct tb_parser *parser) {
    /* Read straight into the parser buffer: at raw 4:4:4 a 5K frame is ~59 MB,
     * so a staging buffer would cost a full extra copy of every frame. */
    const size_t chunk = 1024 * 1024;
    int saw_data = 0;
    for (;;) {
        uint8_t *dst   = NULL;
        size_t   avail = 0;
        if (tb_parser_reserve_space(parser, chunk, &dst, &avail) < 0) return -1;
        ssize_t n = read(fd, dst, avail);
        if (n > 0) {
            saw_data = 1;
            if (tb_parser_commit(parser, (size_t)n) < 0) return -1;
        } else if (n == 0) {
            return -1;  /* peer closed */
        } else {
            if (errno == EAGAIN || errno == EWOULDBLOCK) return saw_data;
            perror("[main] read");
            return -1;
        }
    }
}

static int drain_socket(struct app *a) {
    return drain_fd(a->client_fd, &a->parser);
}

static void write_be32(uint8_t *dst, uint32_t value) {
    dst[0] = (uint8_t)((value >> 24) & 0xff);
    dst[1] = (uint8_t)((value >> 16) & 0xff);
    dst[2] = (uint8_t)((value >> 8) & 0xff);
    dst[3] = (uint8_t)(value & 0xff);
}

static int send_all_within(int fd, const uint8_t *buf, size_t len, unsigned budget_ms) {
    /* Bound the EAGAIN retry loop: this runs on the event-loop thread, so an
     * unresponsive reader (half-open peer, saturated link) must not wedge
     * rendering and quit handling forever. 2s of zero progress means the
     * session is effectively dead; give up and let the caller/watchdog
     * tear it down.
     *
     * Optional traffic passes a much smaller budget — see pump_log_shipping. */
    const uint64_t deadline_ms = now_ms() + budget_ms;
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, buf + off, len - off);
        if (n > 0) {
            off += (size_t)n;
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (now_ms() >= deadline_ms) {
                fprintf(stderr, "[net] send stalled for 2s; dropping write\n");
                return -1;
            }
            usleep(1000);
            continue;
        }
        return -1;
    }
    return 0;
}

static int send_all(int fd, const uint8_t *buf, size_t len) {
    return send_all_within(fd, buf, len, 2000);
}

/* Every packet written to the client socket goes through here.
 *
 * There is more than one writer: the mic callback runs on AVFoundation's
 * capture queue while the main loop sends profiles, input events and shipped
 * log text. send_all() loops over partial writes, so without this lock two
 * writers interleave mid-packet and the sender sees a length field spliced out
 * of somebody else's payload. It reported exactly that —
 * "corrupt inbound stream (invalid packet length 2199163323)" — and dropped the
 * connection. The race was always there; it only became certain once log
 * shipping gave the main loop something to send every frame. */
static pthread_mutex_t g_send_lock = PTHREAD_MUTEX_INITIALIZER;

/* Caller must hold g_send_lock. */
static int tb_send_packet_locked(struct app *a, uint8_t type,
                                 const uint8_t *body, size_t len) {
    uint8_t header[TB_HDR_BYTES];
    write_be32(header, (uint32_t)(1 + len));
    header[4] = type;
    if (send_all(a->client_fd, header, sizeof(header)) < 0) return -1;
    if (len > 0 && send_all(a->client_fd, body, len) < 0) return -1;
    return 0;
}

static int tb_send_packet(struct app *a, uint8_t type,
                          const uint8_t *body, size_t len) {
    if (!a || a->client_fd < 0) return -1;
    pthread_mutex_lock(&g_send_lock);
    const int rc = tb_send_packet_locked(a, type, body, len);
    pthread_mutex_unlock(&g_send_lock);
    return rc;
}

static void tb_receiver_send_input_event(struct app *a,
                                         const char *kind,
                                         int has_dx, int dx,
                                         int has_dy, int dy,
                                         int has_scroll_x, int scroll_x,
                                         int has_scroll_y, int scroll_y,
                                         int has_key_code, uint16_t key_code) {
    if (!a || a->client_fd < 0) return;
    if (strcmp(a->input_control_mode, "receiverMaster") != 0) return;

    char json[256];
    int len = snprintf(json, sizeof(json), "{\"kind\":\"%s\"", kind ? kind : "");
    if (len <= 0 || (size_t)len >= sizeof(json)) return;

    if (has_dx) len += snprintf(json + len, sizeof(json) - (size_t)len, ",\"dx\":%d", dx);
    if (has_dy) len += snprintf(json + len, sizeof(json) - (size_t)len, ",\"dy\":%d", dy);
    if (has_scroll_x) len += snprintf(json + len, sizeof(json) - (size_t)len, ",\"scrollX\":%d", scroll_x);
    if (has_scroll_y) len += snprintf(json + len, sizeof(json) - (size_t)len, ",\"scrollY\":%d", scroll_y);
    if (has_key_code) len += snprintf(json + len, sizeof(json) - (size_t)len, ",\"keyCode\":%u", (unsigned int)key_code);
    len += snprintf(json + len, sizeof(json) - (size_t)len, "}");
    if (len <= 0 || (size_t)len >= sizeof(json)) return;

    uint8_t pkt[4 + 1 + sizeof(json)];
    write_be32(pkt, (uint32_t)(1 + len));
    pkt[4] = TB_PKT_INPUT_EVENT;
    memcpy(pkt + 5, json, (size_t)len);
    a->input_events_sent += 1;
    if (tb_should_log_input_event(a->input_events_sent)) {
        tb_receiver_input_log("[input][receiver->sender] send #%llu kind=%s dx=%d dy=%d sx=%d sy=%d key=%u mode=%s",
                              (unsigned long long)a->input_events_sent,
                              kind ? kind : "?",
                              has_dx ? dx : 0,
                              has_dy ? dy : 0,
                              has_scroll_x ? scroll_x : 0,
                              has_scroll_y ? scroll_y : 0,
                              has_key_code ? (unsigned int)key_code : 0,
                              a->input_control_mode);
    }
    (void)tb_send_packet(a, TB_PKT_INPUT_EVENT, pkt + 5, (size_t)len);
}

static void tb_receiver_send_target_switch(struct app *a, int direction) {
    tb_receiver_send_input_event(a,
                                 direction < 0 ? "switchPrevTarget" : "switchNextTarget",
                                 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
}

static void tb_receiver_sync_modifier_state(struct app *a,
                                            int command_down,
                                            int shift_down,
                                            int option_down,
                                            int control_down,
                                            int caps_down) {
    if (!a) return;

    struct {
        int *state;
        int desired;
        uint16_t key_code;
    } modifiers[] = {
        { &a->sent_command_down, command_down, 55 },
        { &a->sent_shift_down,   shift_down,   56 },
        { &a->sent_option_down,  option_down,  58 },
        { &a->sent_control_down, control_down, 59 },
        { &a->sent_caps_down,    caps_down,    57 }
    };

    for (size_t i = 0; i < sizeof(modifiers) / sizeof(modifiers[0]); i++) {
        if (*modifiers[i].state == modifiers[i].desired) continue;
        tb_receiver_send_input_event(a,
                                     modifiers[i].desired ? "keyDown" : "keyUp",
                                     0, 0, 0, 0, 0, 0, 0, 0, 1, modifiers[i].key_code);
        *modifiers[i].state = modifiers[i].desired;
    }
}

static void tb_receiver_send_space_switch(struct app *a, int direction) {
    tb_receiver_send_input_event(a,
                                 direction < 0 ? "switchPrevSpace" : "switchNextSpace",
                                 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
}

static void tb_receiver_space_switch_callback(int direction, void *context) {
    struct app *a = (struct app *)context;
    if (!a || strcmp(a->input_control_mode, "receiverMaster") != 0 || a->client_fd < 0) return;
    tb_receiver_send_space_switch(a, direction);
}

static void tb_receiver_send_deactivate_control(struct app *a) {
    tb_receiver_send_input_event(a,
                                 "deactivateInputControl",
                                 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
}

static CGEventRef tb_receiver_input_tap_callback(CGEventTapProxy proxy,
                                                 CGEventType type,
                                                 CGEventRef event,
                                                 void *user_info) {
    (void)proxy;
    struct app *a = (struct app *)user_info;
    if (!a) return event;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (a->input_tap) CGEventTapEnable(a->input_tap, true);
        return event;
    }

    if (strcmp(a->input_control_mode, "receiverMaster") != 0) return event;

    /* Only drive the sender while the user is actually on the shared display
     * window's Space. The global tap also sees events from other receiver
     * Spaces; forwarding those would make the sender's cursor jump while the
     * user is doing local work on the receiver. When the window is on a
     * different Space, pass the event through untouched and forward nothing. */
    if (!tb_disp_window_on_active_space(a->disp)) return event;

    int should_consume = 0;

    switch (type) {
    case kCGEventMouseMoved:
    case kCGEventLeftMouseDragged:
    case kCGEventRightMouseDragged:
    case kCGEventOtherMouseDragged: {
        int dx = (int)CGEventGetIntegerValueField(event, kCGMouseEventDeltaX);
        int dy = (int)CGEventGetIntegerValueField(event, kCGMouseEventDeltaY);
        CGPoint location = CGEventGetLocation(event);
        CGRect bounds = CGDisplayBounds(CGMainDisplayID());
        uint64_t now = now_ms();
        if (now - a->last_target_switch_ms > 450) {
            if (location.x <= CGRectGetMinX(bounds) + 2.0 && dx < 0) {
                a->last_target_switch_ms = now;
                tb_receiver_send_target_switch(a, -1);
                should_consume = a->input_tap_consumes_events;
                break;
            }
            if (location.x >= CGRectGetMaxX(bounds) - 2.0 && dx > 0) {
                a->last_target_switch_ms = now;
                tb_receiver_send_target_switch(a, 1);
                should_consume = a->input_tap_consumes_events;
                break;
            }
        }
        const char *kind = "move";
        if (type == kCGEventLeftMouseDragged) kind = "leftDrag";
        else if (type == kCGEventRightMouseDragged) kind = "rightDrag";
        else if (type == kCGEventOtherMouseDragged) kind = "otherDrag";
        tb_receiver_send_input_event(a, kind, 1, dx, 1, dy, 0, 0, 0, 0, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    }
    case kCGEventLeftMouseDown:
        tb_receiver_send_input_event(a, "leftDown", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventLeftMouseUp:
        tb_receiver_send_input_event(a, "leftUp", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventRightMouseDown:
        tb_receiver_send_input_event(a, "rightDown", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventRightMouseUp:
        tb_receiver_send_input_event(a, "rightUp", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventOtherMouseDown:
        tb_receiver_send_input_event(a, "otherDown", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventOtherMouseUp:
        tb_receiver_send_input_event(a, "otherUp", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventScrollWheel: {
        int sx = (int)CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2);
        int sy = (int)CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1);
        int point_sx = (int)CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis2);
        int point_sy = (int)CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis1);
        int is_continuous = (int)CGEventGetIntegerValueField(event, kCGScrollWheelEventIsContinuous);
        CGEventFlags flags = CGEventGetFlags(event);
        const CGEventFlags effective_flags = flags & ~kCGEventFlagMaskSecondaryFn;
        uint64_t now = now_ms();
        if ((effective_flags & kCGEventFlagMaskAlternate) &&
            (llabs((long long)point_sx) > llabs((long long)point_sy) * 2 || llabs((long long)sx) > llabs((long long)sy) * 2) &&
            now - a->last_space_switch_ms > 300) {
            int direction = 0;
            if (point_sx != 0) direction = point_sx > 0 ? 1 : -1;
            else if (sx != 0) direction = sx > 0 ? 1 : -1;
            if (direction != 0) {
                a->last_space_switch_ms = now;
                a->space_gesture_accum_x = 0;
                tb_receiver_send_space_switch(a, direction);
                should_consume = a->input_tap_consumes_events;
                break;
            }
        }
        if (is_continuous &&
            (point_sx != 0 || point_sy != 0) &&
            llabs((long long)point_sx) > llabs((long long)point_sy) * 2) {
            if (now - a->last_space_gesture_ms > 250) {
                a->space_gesture_accum_x = 0;
            }
            a->last_space_gesture_ms = now;
            a->space_gesture_accum_x += point_sx;
            if (llabs((long long)a->space_gesture_accum_x) >= 45 &&
                now - a->last_space_switch_ms > 450) {
                a->last_space_switch_ms = now;
                tb_receiver_send_space_switch(a, a->space_gesture_accum_x > 0 ? 1 : -1);
                a->space_gesture_accum_x = 0;
            }
            should_consume = a->input_tap_consumes_events;
            break;
        }
        if (now - a->last_space_gesture_ms > 250) {
            a->space_gesture_accum_x = 0;
        }
        tb_receiver_send_input_event(a, "scroll", 0, 0, 0, 0, 1, sx, 1, sy, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    }
    case kCGEventKeyDown: {
        uint16_t key_code = (uint16_t)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        CGEventFlags flags = CGEventGetFlags(event);
        const CGEventFlags effective_flags = flags & ~kCGEventFlagMaskSecondaryFn;
        tb_receiver_sync_modifier_state(a,
                                        (effective_flags & kCGEventFlagMaskCommand) != 0,
                                        (effective_flags & kCGEventFlagMaskShift) != 0,
                                        (effective_flags & kCGEventFlagMaskAlternate) != 0,
                                        (effective_flags & kCGEventFlagMaskControl) != 0,
                                        (effective_flags & kCGEventFlagMaskAlphaShift) != 0);
        if ((flags & kCGEventFlagMaskControl) &&
            (flags & kCGEventFlagMaskAlternate) &&
            (flags & kCGEventFlagMaskCommand) &&
            key_code == 40) {
            tb_receiver_send_deactivate_control(a);
            should_consume = a->input_tap_consumes_events;
            break;
        }
        if ((effective_flags & kCGEventFlagMaskControl) && (effective_flags & kCGEventFlagMaskCommand)) {
            if (key_code == 123) {
                tb_receiver_send_target_switch(a, -1);
                should_consume = a->input_tap_consumes_events;
                break;
            }
            if (key_code == 124) {
                tb_receiver_send_target_switch(a, 1);
                should_consume = a->input_tap_consumes_events;
                break;
            }
        }
        tb_receiver_send_input_event(a, "keyDown", 0, 0, 0, 0, 0, 0, 0, 0, 1, key_code);
        should_consume = a->input_tap_consumes_events;
        break;
    }
    case kCGEventKeyUp:
    {
        uint16_t key_code = (uint16_t)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        CGEventFlags flags = CGEventGetFlags(event);
        const CGEventFlags effective_flags = flags & ~kCGEventFlagMaskSecondaryFn;
        tb_receiver_sync_modifier_state(a,
                                        (effective_flags & kCGEventFlagMaskCommand) != 0,
                                        (effective_flags & kCGEventFlagMaskShift) != 0,
                                        (effective_flags & kCGEventFlagMaskAlternate) != 0,
                                        (effective_flags & kCGEventFlagMaskControl) != 0,
                                        (effective_flags & kCGEventFlagMaskAlphaShift) != 0);
        if ((flags & kCGEventFlagMaskControl) &&
            (flags & kCGEventFlagMaskAlternate) &&
            (flags & kCGEventFlagMaskCommand) &&
            key_code == 40) {
            should_consume = a->input_tap_consumes_events;
            break;
        }
        if ((effective_flags & kCGEventFlagMaskControl) && (effective_flags & kCGEventFlagMaskCommand) &&
            (key_code == 123 || key_code == 124)) {
            should_consume = a->input_tap_consumes_events;
            break;
        }
        tb_receiver_send_input_event(a, "keyUp", 0, 0, 0, 0, 0, 0, 0, 0, 1, key_code);
        should_consume = a->input_tap_consumes_events;
        break;
    }
    case kCGEventFlagsChanged: {
        CGEventFlags flags = CGEventGetFlags(event);
        const CGEventFlags effective_flags = flags & ~kCGEventFlagMaskSecondaryFn;
        should_consume = a->input_tap_consumes_events;
        tb_receiver_sync_modifier_state(a,
                                        (effective_flags & kCGEventFlagMaskCommand) != 0,
                                        (effective_flags & kCGEventFlagMaskShift) != 0,
                                        (effective_flags & kCGEventFlagMaskAlternate) != 0,
                                        (effective_flags & kCGEventFlagMaskControl) != 0,
                                        (effective_flags & kCGEventFlagMaskAlphaShift) != 0);
        break;
    }
    default:
        break;
    }

    return should_consume ? NULL : event;
}

static void tb_receiver_stop_input_tap(struct app *a) {
    if (!a) return;
    if (a->input_tap_source) {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), a->input_tap_source, kCFRunLoopCommonModes);
        CFRelease(a->input_tap_source);
        a->input_tap_source = NULL;
    }
    if (a->input_tap) {
        CFMachPortInvalidate(a->input_tap);
        CFRelease(a->input_tap);
        a->input_tap = NULL;
    }
    a->input_tap_consumes_events = 0;
}

static void tb_receiver_start_input_tap(struct app *a) {
    if (!a || a->input_tap) return;

    if (!tb_receiver_input_monitoring_trusted()) {
        return;
    }

    const int can_consume = tb_receiver_accessibility_trusted() ? 1 : 0;
    CGEventTapOptions tap_options = can_consume ? kCGEventTapOptionDefault : kCGEventTapOptionListenOnly;

    CGEventMask mask =
        CGEventMaskBit(kCGEventMouseMoved) |
        CGEventMaskBit(kCGEventLeftMouseDragged) |
        CGEventMaskBit(kCGEventRightMouseDragged) |
        CGEventMaskBit(kCGEventOtherMouseDragged) |
        CGEventMaskBit(kCGEventLeftMouseDown) |
        CGEventMaskBit(kCGEventLeftMouseUp) |
        CGEventMaskBit(kCGEventRightMouseDown) |
        CGEventMaskBit(kCGEventRightMouseUp) |
        CGEventMaskBit(kCGEventOtherMouseDown) |
        CGEventMaskBit(kCGEventOtherMouseUp) |
        CGEventMaskBit(kCGEventScrollWheel) |
        CGEventMaskBit(kCGEventKeyDown) |
        CGEventMaskBit(kCGEventKeyUp) |
        CGEventMaskBit(kCGEventFlagsChanged);

    a->input_tap = CGEventTapCreate(
        kCGHIDEventTap,
        kCGHeadInsertEventTap,
        tap_options,
        mask,
        tb_receiver_input_tap_callback,
        a
    );
    if (!a->input_tap) {
        tb_receiver_input_log("[input] global event tap unavailable; will fall back to SDL window input");
        return;
    }

    a->input_tap_source = CFMachPortCreateRunLoopSource(NULL, a->input_tap, 0);
    if (!a->input_tap_source) {
        tb_receiver_stop_input_tap(a);
        tb_receiver_input_log("[input] failed to create runloop source for event tap; using SDL fallback");
        return;
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), a->input_tap_source, kCFRunLoopCommonModes);
    CGEventTapEnable(a->input_tap, true);
    a->input_tap_consumes_events = can_consume;
    tb_receiver_input_log("[input] global event tap enabled for receiverMaster mode (consume=%s)",
                          can_consume ? "true" : "false");
}

static void tb_receiver_refresh_input_capture(struct app *a) {
    if (!a) return;
    if (strcmp(a->input_control_mode, "receiverMaster") == 0 && a->client_fd >= 0) {
        const int wants_global_tap = tb_receiver_input_monitoring_trusted() ? 1 : 0;
        const int wants_consume = tb_receiver_accessibility_trusted() ? 1 : 0;
        if (a->input_tap && (!wants_global_tap || a->input_tap_consumes_events != wants_consume)) {
            tb_receiver_stop_input_tap(a);
        }
        tb_receiver_start_input_tap(a);
        tb_disp_set_input_intercept_active(a->disp, 1);
        tb_disp_set_input_capture_active(a->disp, a->input_tap == NULL ? 1 : 0);
        tb_gesture_bridge_set_active(1);
        tb_receiver_input_log("[input] receiverMaster capture path = %s",
                              a->input_tap ? "global-tap" : "sdl-fallback");
    } else {
        tb_receiver_stop_input_tap(a);
        tb_disp_set_input_intercept_active(a->disp, 0);
        tb_disp_set_input_capture_active(a->disp, 0);
        tb_gesture_bridge_set_active(0);
        tb_receiver_input_log("[input] input capture disabled");
    }
}


/* Report Night Shift / True Tone back to the sender when they change, so its
 * menu reflects the panel's real state rather than only what it last asked for. */
static void tb_receiver_send_display_tweaks_if_changed(struct app *a) {
    if (a->client_fd < 0) return;

    const int night = tb_night_shift_supported() ? tb_night_shift_enabled() : 0;
    const int tone  = tb_true_tone_supported() ? tb_true_tone_enabled() : 0;
    if (night == a->reported_night_shift && tone == a->reported_true_tone) return;

    a->reported_night_shift = night;
    a->reported_true_tone = tone;

    char json[192];
    int len = snprintf(json, sizeof(json),
                       "{\"nightShift\":%s,\"trueTone\":%s}",
                       night ? "true" : "false",
                       tone ? "true" : "false");
    if (len <= 0 || (size_t)len >= sizeof(json)) return;

    (void)tb_send_packet(a, TB_PKT_DISPLAY_TWEAKS, (const uint8_t *)json, (size_t)len);
}


/* Mic frames come from AVFoundation's capture queue, not the main loop, so this
 * only touches the socket. send_all() on a non-blocking fd may drop under
 * pressure, which for live audio is the right trade — better a gap than a
 * growing backlog of stale sound. */
static struct app *g_mic_app = NULL;

static void tb_mic_frame_cb(const uint8_t *pcm, size_t bytes, void *user_data) {
    struct app *a = (struct app *)user_data;
    if (!a || a->client_fd < 0 || bytes == 0) return;
    /* Cap per packet so one oversized buffer cannot stall the link. */
    const size_t kMax = 8192;
    while (bytes > 0) {
        const size_t chunk = bytes > kMax ? kMax : bytes;
        if (tb_send_packet(a, TB_PKT_MIC_FRAME, pcm, chunk) < 0) return;
        pcm += chunk;
        bytes -= chunk;
    }
}

static void tb_mic_start_if_possible(struct app *a) {
    if (!tb_mic_capture_available()) return;
    g_mic_app = a;
    if (tb_mic_capture_start(tb_mic_frame_cb, a) != 0) {
        /* Permission not granted yet; the prompt has been raised and the next
         * session will retry. */
        fprintf(stderr, "[mic] not started (microphone permission pending)\n");
    } else {
        fprintf(stderr, "[mic] capturing and streaming to sender\n");
    }
}

static void send_receiver_info(struct app *a) {
    struct tb_display_info info;
    if (tb_disp_get_info(a->disp, &info) < 0) return;

    /* Always advertise the intended iMac target panel, not the transient
     * SDL window/debug drawable size. Using the drawable here breaks the
     * sender's virtual display creation path when running windowed or on
     * scaled desktops because macOS rejects a HiDPI mode larger than the
     * advertised backing panel. */
    const uint32_t panel_w = 5120;
    const uint32_t panel_h = 2880;
    const uint32_t mode_w = 2560;
    const uint32_t mode_h = 1440;
    const uint32_t capture_w = 2560;
    const uint32_t capture_h = 1440;

    char escaped_name[256];
    size_t out = 0;
    for (size_t i = 0; info.name[i] != '\0' && out + 2 < sizeof(escaped_name); i++) {
        unsigned char c = (unsigned char)info.name[i];
        if (c == '"' || c == '\\') {
            escaped_name[out++] = '\\';
            escaped_name[out++] = (char)c;
        } else if (c >= 0x20) {
            escaped_name[out++] = (char)c;
        }
    }
    escaped_name[out] = '\0';

    char json[1024];
    int json_len = snprintf(
        json,
        sizeof(json),
        "{\"receiverName\":\"%s\",\"panelWidth\":%u,\"panelHeight\":%u,"
        "\"modeWidth\":%u,\"modeHeight\":%u,\"refreshRate\":60,"
        "\"hiDPI\":true,\"captureWidth\":%u,\"captureHeight\":%u,"
        "\"supportsHEVCDecode\":%s,\"supportsRawNV12\":true,\"supportsFloat32Audio\":true,\"supportsDPCM\":%s,\"supportsDPCMSlices\":%s,\"supportsDPCMRects\":%s,\"inputMonitoringTrusted\":%s,\"accessibilityTrusted\":%s,"
        "\"supportsNightShift\":%s,\"supportsTrueTone\":%s}",
        escaped_name,
        panel_w,
        panel_h,
        mode_w,
        mode_h,
        capture_w,
        capture_h,
        tb_dec_supports_hevc_hwdecode() ? "true" : "false",
        tb_disp_supports_dpcm() ? "true" : "false",
        tb_disp_supports_dpcm() ? "true" : "false",
        /* Rects need exactly what slices need — the same GPU decoder placing a
         * region at an offset — so they ride on the same capability. */
        tb_disp_supports_dpcm() ? "true" : "false",
        tb_receiver_input_monitoring_trusted() ? "true" : "false",
        tb_receiver_accessibility_trusted() ? "true" : "false",
        tb_night_shift_supported() ? "true" : "false",
        tb_true_tone_supported() ? "true" : "false");
    if (json_len <= 0 || (size_t)json_len >= sizeof(json)) return;

    const size_t packet_len = 4 + 1 + (size_t)json_len;
    uint8_t *pkt = (uint8_t *)calloc(1, packet_len);
    if (!pkt) return;

    write_be32(pkt, (uint32_t)(1 + json_len));
    pkt[4] = TB_PKT_DISPLAY_PROFILE;
    memcpy(pkt + 5, json, (size_t)json_len);

    if (tb_send_packet(a, TB_PKT_DISPLAY_PROFILE, pkt + 5, (size_t)json_len) == 0) {
        fprintf(stderr,
                "[main] sent display profile: panel=%ux%u mode=%ux%u hidpi name=%s\n",
                panel_w, panel_h, mode_w, mode_h, info.name);
    }
    free(pkt);
}


/* ---- threaded link readers --------------------------------------------- */

/* Runs on a reader thread. Frames go to the newest-wins mailbox; everything
 * else is copied into a queue so the main thread can run the existing
 * handlers unchanged. */
static void reader_on_packet(uint8_t type, const uint8_t *payload, size_t len, void *ud) {
    struct tb_link_reader *r = (struct tb_link_reader *)ud;
    struct app *a = r->app;

    if (type == TB_PKT_RAW_FRAME || type == TB_PKT_RAW_DAMAGE ||
        type == TB_PKT_RAW_DPCM || type == TB_PKT_RAW_DPCM_SLICE ||
        type == TB_PKT_RAW_DPCM_RECT) {
        /* Keep this packet without copying it: ask the parser to yield its
         * buffer. The `payload` pointer stays valid inside that buffer, which
         * the reader loop collects and publishes right after commit returns. */
        r->pending_payload = payload;
        r->pending_len     = len;
        r->pending_type    = type;
        tb_parser_hold_current(&r->parser);
        return;
    }

    pthread_mutex_lock(&a->net_lock);
    if (a->ctrl_count < TB_CTRL_QUEUE_MAX) {
        uint8_t *copy = (uint8_t *)malloc(len ? len + 1 : 1);
        if (copy) {
            if (len) memcpy(copy, payload, len);
            copy[len] = '\0';   /* preserve on_packet's NUL-sentinel guarantee */
            int slot = (a->ctrl_head + a->ctrl_count) % TB_CTRL_QUEUE_MAX;
            a->ctrl_q[slot].type    = type;
            a->ctrl_q[slot].payload = copy;
            a->ctrl_q[slot].len     = len;
            a->ctrl_count++;
        }
    }
    pthread_mutex_unlock(&a->net_lock);
}

static void *link_reader_main(void *ud) {
    struct tb_link_reader *r = (struct tb_link_reader *)ud;
    struct app *a = r->app;

    while (!r->stop) {
        struct pollfd pfd;
        pfd.fd = r->fd; pfd.events = POLLIN; pfd.revents = 0;
        int pr = poll(&pfd, 1, 20);   /* bounded so `stop` is noticed promptly */
        if (pr < 0) {
            if (errno == EINTR) continue;
            r->ended = 1; return NULL;
        }
        if (pr == 0) continue;

        for (;;) {
            uint8_t *dst = NULL;
            size_t   avail = 0;
            if (tb_parser_reserve_space(&r->parser, 1024 * 1024, &dst, &avail) < 0) {
                r->ended = 1; return NULL;
            }
            double rd0 = now_ms_f();
            ssize_t n = read(r->fd, dst, avail);
            tb_health_note_read(now_ms_f() - rd0);
            if (n > 0) {
                pthread_mutex_lock(&a->net_lock);
                a->reader_recv_ms = now_ms();
                pthread_mutex_unlock(&a->net_lock);
                if (tb_parser_commit(&r->parser, (size_t)n) < 0) { r->ended = 1; return NULL; }
                if (r->pending_payload) {
                    size_t held_cap = 0;
                    uint8_t *held = tb_parser_take_held(&r->parser, &held_cap);
                    if (held) {
                        pthread_mutex_lock(&a->net_lock);
                        /* Never block here. This thread is the only one draining
                         * the socket, so anything it waits for it also stops
                         * receiving — which is precisely how the old 100 ms wait
                         * turned a busy moment into a wedged session.
                         *
                         * The two packet kinds still mean different things:
                         *
                         * A whole frame is a complete image, so it supersedes
                         * everything queued — including bands of a frame that
                         * will now never be finished. Keeping at most one also
                         * stops the queue adding latency on the unsliced path,
                         * where newest-wins has always been correct.
                         *
                         * A band or a damage rect is an INCREMENT: discarding it
                         * loses those pixels for good. Bands were briefly filed
                         * with the whole frames when slicing was added and each
                         * overwrote the last, presenting 4-40% of frames with
                         * strips of the previous one. So they queue, and only
                         * when the queue is genuinely full is the arriving one
                         * dropped and counted — the sender's ~1s resync repairs
                         * it, exactly as the old timeout path did, but without
                         * stalling the socket to get there. */
                        const int is_increment =
                            (r->pending_type == TB_PKT_RAW_DAMAGE ||
                             r->pending_type == TB_PKT_RAW_DPCM_SLICE ||
                             r->pending_type == TB_PKT_RAW_DPCM_RECT);

                        if (!is_increment) {
                            while (a->vq_count > 0) {
                                struct tb_video_slot *old =
                                    &a->vq[(a->vq_head + a->vq_count - 1) % TB_VIDEO_QUEUE];
                                if (a->pool_n < TB_VIDEO_POOL) {
                                    a->pool_buf[a->pool_n] = old->buf;
                                    a->pool_cap[a->pool_n] = old->cap;
                                    a->pool_n++;
                                } else {
                                    free(old->buf);
                                }
                                old->buf = NULL;
                                a->vq_count--;
                                a->frames_dropped++;
                            }
                        }

                        if (a->vq_count >= TB_VIDEO_QUEUE) {
                            /* Full, and this one is an increment (a whole frame
                             * just cleared the queue above). Give the buffer
                             * back rather than leak it. */
                            a->vq_overflow++;
                            if (a->pool_n < TB_VIDEO_POOL) {
                                a->pool_buf[a->pool_n] = held;
                                a->pool_cap[a->pool_n] = held_cap;
                                a->pool_n++;
                            } else {
                                free(held);
                            }
                        } else {
                            struct tb_video_slot *slot =
                                &a->vq[(a->vq_head + a->vq_count) % TB_VIDEO_QUEUE];
                            slot->buf     = held;
                            slot->cap     = held_cap;
                            slot->payload = r->pending_payload;
                            slot->len     = r->pending_len;
                            slot->type    = r->pending_type;
                            a->vq_count++;
                        }
                        /* Take a recycled buffer back for the next frame. */
                        if (a->pool_n > 0) {
                            a->pool_n--;
                            tb_parser_set_spare(&r->parser,
                                                a->pool_buf[a->pool_n],
                                                a->pool_cap[a->pool_n]);
                            a->pool_buf[a->pool_n] = NULL;
                            a->pool_cap[a->pool_n] = 0;
                        }
                        pthread_mutex_unlock(&a->net_lock);
                    }
                    r->pending_payload = NULL;
                    r->pending_len = 0;
                }
            } else if (n == 0) {
                r->ended = 1; return NULL;      /* peer closed */
            } else {
                if (errno == EAGAIN || errno == EWOULDBLOCK) break;
                if (errno == EINTR) continue;
                r->ended = 1; return NULL;
            }
        }
    }
    return NULL;
}

static int link_reader_start(struct tb_link_reader *r, struct app *a, int fd) {
    memset(r, 0, sizeof(*r));
    r->app = a; r->fd = fd;
    tb_parser_init(&r->parser, reader_on_packet, r);
    if (pthread_create(&r->thread, NULL, link_reader_main, r) != 0) {
        fprintf(stderr, "[main] reader thread create failed: %s\n", strerror(errno));
        tb_parser_free(&r->parser);
        return -1;
    }
    r->active = 1;
    return 0;
}

static void link_reader_stop(struct tb_link_reader *r) {
    if (!r || !r->active) return;
    r->stop = 1;
    pthread_join(r->thread, NULL);
    tb_parser_free(&r->parser);
    r->active = 0;
}

/* Ship whatever stderr has produced since the last pass.
 *
 * On the main thread on purpose: the mic callback is already an off-thread
 * writer to this fd, and a second one would let two partial packets interleave
 * on the same socket. Bounded per call so a burst of logging cannot displace
 * the frame this loop exists to render — the rest waits for the next pass. */
/* Shipping the log must never cost a frame.
 *
 * The first version ran every main-loop pass and used the ordinary two-second
 * stall budget, which created a feedback loop that collapsed the stream to
 * 7 fps on fullscreen video: a saturated sender stops reading upstream, the
 * receiver's send buffer fills, the render loop blocks inside send_all(), so it
 * stops reading frames, so the sender's writes never complete, so its in-flight
 * budget pins (13/12 observed) and it drops nearly every frame (96 in one
 * window). The receiver looked 90% idle throughout because it was starved, not
 * busy.
 *
 * Three limits, all of them about never blocking the render loop:
 *   - at most one 8 KB packet every 200 ms, so ~40 KB/s, far too little to fill
 *     a socket buffer even when the link is busy;
 *   - trylock, so a mic write in progress defers us instead of queueing;
 *   - a 15 ms stall budget instead of 2000, so a full buffer costs at most part
 *     of one frame.
 * Anything not sent stays in the ring for the next pass, and the ring already
 * reports what it had to drop. */
static void pump_log_shipping(struct app *a) {
    if (!a || a->client_fd < 0) return;

    static uint64_t next_ship_ms = 0;
    const uint64_t now = now_ms();
    if (now < next_ship_ms) return;

    /* Take the lock BEFORE draining. Draining removes bytes from the ring, so
     * discovering afterwards that the socket is busy would throw them away. */
    if (pthread_mutex_trylock(&g_send_lock) != 0) return;

    uint8_t buf[8192];
    const size_t n = tb_logship_drain(buf, sizeof(buf));
    if (n > 0) {
        uint8_t header[TB_HDR_BYTES];
        write_be32(header, (uint32_t)(1 + n));
        header[4] = TB_PKT_LOG;
        /* Header and body share the budget. Giving up between them would leave
         * a partial packet and corrupt the stream, so the body is only attempted
         * once the header is fully out, and both use the same short budget. */
        if (send_all_within(a->client_fd, header, sizeof(header), 15) == 0) {
            (void)send_all_within(a->client_fd, buf, n, 15);
        }
    }

    pthread_mutex_unlock(&g_send_lock);
    next_ship_ms = now + 200;
}

/* Main thread: run queued control packets, then render at most one frame (the
 * newest). Returns non-zero if any work was done. */
static int pump_network(struct app *a) {
    int worked = 0;

    pump_log_shipping(a);

    for (;;) {
        struct tb_ctrl_msg msg;
        pthread_mutex_lock(&a->net_lock);
        if (a->ctrl_count == 0) { pthread_mutex_unlock(&a->net_lock); break; }
        msg = a->ctrl_q[a->ctrl_head];
        a->ctrl_head = (a->ctrl_head + 1) % TB_CTRL_QUEUE_MAX;
        a->ctrl_count--;
        pthread_mutex_unlock(&a->net_lock);

        on_packet(msg.type, msg.payload, msg.len, a);
        free(msg.payload);
        worked = 1;
    }

    pthread_mutex_lock(&a->net_lock);
    if (a->reader_recv_ms > a->last_recv_ms) a->last_recv_ms = a->reader_recv_ms;
    /* Snapshot the depth and drain exactly that many. Taking one per pass was
     * the other half of the stall: a frame is four bands, so one-per-iteration
     * capped the receiver at a quarter of the loop rate no matter how idle it
     * was. Bounding to the snapshot rather than looping until empty keeps a
     * flood from starving input and quit handling. */
    int pending = a->vq_count;
    pthread_mutex_unlock(&a->net_lock);

    while (pending-- > 0) {
        uint8_t       *owned = NULL;
        size_t         owned_cap = 0;
        const uint8_t *payload = NULL;
        size_t         plen = 0;
        uint8_t        ptype = TB_PKT_RAW_FRAME;

        /* Pacing gate: hold a frame's LAST band until its capture time comes
         * round. Earlier bands decode on arrival, so only the moment of
         * presentation moves and the GPU work still spreads across the frame.
         *
         * Everything here is guarded so it can only ever be a small
         * improvement, never a new stall -- a previous pacing attempt made
         * playback worse and had to be reverted:
         *   - a backed-up queue skips pacing entirely and catches up;
         *   - a frame held too long presents anyway, so a bad clock estimate
         *     costs one late frame rather than the stream;
         *   - TB_PACE=0 turns it off without a rebuild.
         */
        if (a->pace_enabled) {
            pthread_mutex_lock(&a->net_lock);
            const int depth = a->vq_count;
            const struct tb_video_slot *head = depth > 0 ? &a->vq[a->vq_head] : NULL;
            const int gate = head && head->type == TB_PKT_RAW_DPCM_SLICE &&
                             head->len >= TB_DPCM_SLICE_HEADER && depth <= 2;
            uint64_t capture_ns = 0;
            int is_last = 0;
            if (gate) {
                const uint8_t *h = head->payload;
                capture_ns = ((uint64_t)be32(h) << 32) | be32(h + 4);
                const uint16_t index = (uint16_t)((h[24] << 8) | h[25]);
                const uint16_t count = (uint16_t)((h[26] << 8) | h[27]);
                is_last = (count > 0 && index + 1 == count);
            }
            pthread_mutex_unlock(&a->net_lock);

            if (gate && is_last && capture_ns > 0) {
                const uint64_t now_ns = now_ms() * 1000000ull;
                const uint64_t delta = (now_ns > capture_ns) ? now_ns - capture_ns : 0;
                if (a->pace_min_ns == 0 || delta < a->pace_min_ns) a->pace_min_ns = delta;
                if (now_ms() >= a->pace_win_end_ms) {
                    a->pace_offset_ns = a->pace_min_ns;
                    a->pace_min_ns = 0;
                    a->pace_win_end_ms = now_ms() + 2000;
                }
                if (a->pace_offset_ns > 0) {
                    const uint64_t due = capture_ns + a->pace_offset_ns + TB_PACE_LEAD_NS;
                    if (now_ns < due) {
                        if (a->pace_held_since == 0) a->pace_held_since = now_ms();
                        if (now_ms() - a->pace_held_since < TB_PACE_MAX_HOLD_MS) break;
                    }
                }
            }
            a->pace_held_since = 0;
        }

        pthread_mutex_lock(&a->net_lock);
        if (a->vq_count > 0) {
            struct tb_video_slot *slot = &a->vq[a->vq_head];
            owned     = slot->buf;
            owned_cap = slot->cap;
            payload   = slot->payload;
            plen      = slot->len;
            ptype     = slot->type;
            slot->buf = NULL;
            a->vq_head = (a->vq_head + 1) % TB_VIDEO_QUEUE;
            a->vq_count--;
        }
        pthread_mutex_unlock(&a->net_lock);
        if (!owned) break;

        /* Frames bypass on_packet, so mark the session live here — otherwise
         * the fullscreen gate never opens. */
        a->session_active = 1;
        if (ptype == TB_PKT_RAW_DAMAGE)   handle_raw_damage(a, payload, plen);
        else if (ptype == TB_PKT_RAW_DPCM) handle_raw_dpcm(a, payload, plen);
        else if (ptype == TB_PKT_RAW_DPCM_SLICE) handle_raw_dpcm_slice(a, payload, plen);
        else if (ptype == TB_PKT_RAW_DPCM_RECT)  handle_raw_dpcm_rect(a, payload, plen);
        else                              handle_raw_frame(a, payload, plen);
        worked = 1;

        /* Return the buffer for a reader to reuse; only free if the pool is
         * full, so the steady state never allocates. */
        pthread_mutex_lock(&a->net_lock);
        if (a->pool_n < TB_VIDEO_POOL) {
            a->pool_buf[a->pool_n] = owned;
            a->pool_cap[a->pool_n] = owned_cap;
            a->pool_n++;
            owned = NULL;
        }
        pthread_mutex_unlock(&a->net_lock);
        free(owned);   /* no-op when pooled */
    }
    return worked;
}

static void drop_pending_network(struct app *a) {
    pthread_mutex_lock(&a->net_lock);
    while (a->ctrl_count > 0) {
        free(a->ctrl_q[a->ctrl_head].payload);
        a->ctrl_head = (a->ctrl_head + 1) % TB_CTRL_QUEUE_MAX;
        a->ctrl_count--;
    }
    while (a->vq_count > 0) {
        struct tb_video_slot *slot = &a->vq[a->vq_head];
        free(slot->buf);
        slot->buf = NULL;
        a->vq_head = (a->vq_head + 1) % TB_VIDEO_QUEUE;
        a->vq_count--;
    }
    a->vq_head = 0;
    for (int i = 0; i < a->pool_n; ++i) { free(a->pool_buf[i]); a->pool_buf[i] = NULL; }
    a->pool_n = 0;
    pthread_mutex_unlock(&a->net_lock);
}

static void close_client(struct app *a) {
    tb_mic_capture_stop();
    g_mic_app = NULL;
    link_reader_stop(a->reader1);
    drop_pending_network(a);
    if (a->client_fd >= 0) close(a->client_fd);
    a->client_fd = -1;
    a->session_active = 0;
    a->close_requested = 0;
    a->have_video_frame = 0;
    snprintf(a->input_control_mode, sizeof(a->input_control_mode), "off");
    SDL_EnableScreenSaver();
    tb_receiver_refresh_input_capture(a);
    tb_disp_set_connection_state(a->disp, 0);
    tb_disp_set_cursor(a->disp, 0, 0, 1, 1, 0, 0);
    tb_refresh_idle_localized_strings(a);
    a->last_clipboard_text[0] = '\0';
    tb_parser_free(&a->parser);
    tb_parser_init(&a->parser, on_packet, a);
    tb_dec_reset(a->dec);   /* fresh decoder for next session */
    if (a->audio_device != 0) {
        SDL_LockAudioDevice(a->audio_device);
        a->audio_buf_head = 0;
        a->audio_buf_tail = 0;
        a->audio_buf_size = 0;
        SDL_UnlockAudioDevice(a->audio_device);
    }
    fprintf(stderr, "[main] client disconnected\n");
}

/* Build the display string for the host/IP line of the status screen.
 * have_ip: non-zero if ip_fallback is a real IP, zero if no IP is available.
 * Called once at startup (and when the IP changes) to cache the result in
 * a.display_host — do NOT call gethostname() in the render loop. */
static void build_display_host(char *buf, size_t bufsz, const char *ip_fallback, int have_ip) {
    if (!buf || bufsz == 0) return;
    char host[96] = {0};
    if (gethostname(host, sizeof(host)) == 0 && host[0] != '\0' && strcmp(host, "localhost") != 0) {
        char short_host[96] = {0};
        size_t i = 0;
        for (; host[i] != '\0' && host[i] != '.' && i + 1 < sizeof(short_host); i++) {
            short_host[i] = host[i];
        }
        short_host[i] = '\0';
        if (short_host[0] != '\0') {
            if (have_ip && ip_fallback && ip_fallback[0] != '\0') {
                snprintf(buf, bufsz, "%s (%s)", short_host, ip_fallback);
            } else {
                snprintf(buf, bufsz, "%s", short_host);
            }
            return;
        }
    }
    snprintf(buf, bufsz, "%s", (have_ip && ip_fallback && ip_fallback[0] != '\0')
             ? ip_fallback : tb_i18n_get("receiver.network.not_detected"));
}

/* ---- Main ------------------------------------------------------------ */

int main(int argc, char **argv) {
    int fullscreen = 1;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--windowed") == 0) fullscreen = 0;
    }

    char startup_language_pref[8];
    tb_receiver_load_language_preference(startup_language_pref, sizeof(startup_language_pref));
    if (strcmp(startup_language_pref, "auto") != 0) {
        tb_i18n_set_runtime_language(startup_language_pref);
    }
    (void)tb_i18n_init();

    signal(SIGINT,  on_sigint);
    signal(SIGTERM, on_sigint);
    signal(SIGPIPE, SIG_IGN);

    /* Before anything worth logging happens. SIGPIPE is already ignored above,
     * which matters here: the reader thread writes to a pipe and this process
     * writes to a socket, and neither should be able to kill the receiver. */
    (void)tb_logship_start();


    char tb_ip[64] = {0};
    char net_ip[64] = {0};
    if (tb_net_get_tb_ip(tb_ip, sizeof(tb_ip)) == 0) {
        printf("TBReceiver: Thunderbolt Bridge IP = %s\n", tb_ip);
    } else {
        printf("TBReceiver: warning, no bridge IP detected (169.254.x.x)\n");
    }
    if (tb_net_get_lan_ip(net_ip, sizeof(net_ip)) == 0) {
        printf("TBReceiver: Local network IP = %s\n", net_ip);
    } else {
        printf("TBReceiver: warning, no LAN IP detected (RFC1918 IPv4)\n");
    }
    printf("TBReceiver: listening on TCP port %d\n", TB_PORT);

    struct app a;
    memset(&a, 0, sizeof(a));
    // Int16 until a hello says otherwise — zeroed would mean "float", which is
    // the wrong way to guess about a sender we have not heard from yet.
    a.audio_input_is_s16 = 1;
    a.server_fd = -1;
    a.client_fd = -1;
    pthread_mutex_init(&a.net_lock, NULL);

    /* Pacing defaults on but stays one env var from off: the last attempt at
     * this made playback worse, and a bad night should not need a rebuild. */
    /* Vitals for the machine nobody is sitting at. Its stderr is shipped to the
     * sender, so this lands next to the sender's own telemetry. */
    tb_health_start();

    {
        const char *pace = getenv("TB_PACE");
        a.pace_enabled = !(pace && pace[0] == '0');
        a.pace_win_end_ms = now_ms() + 2000;
        fprintf(stderr, "[pace] presentation pacing %s\n",
                a.pace_enabled ? "on (TB_PACE=0 disables)" : "off");
    }
    a.reader1 = (struct tb_link_reader *)calloc(1, sizeof(*a.reader1));
    a.ctrl_q  = (struct tb_ctrl_msg *)calloc(TB_CTRL_QUEUE_MAX, sizeof(*a.ctrl_q));
    if (!a.reader1 || !a.ctrl_q) {
        fprintf(stderr, "[main] reader allocation failed\n");
        return 1;
    }
    {
        char host[96] = {0};
        if (gethostname(host, sizeof(host)) != 0 || host[0] == '\0') {
            snprintf(host, sizeof(host), "%s", "Receiver");
        }
        snprintf(a.bonjour_name, sizeof(a.bonjour_name), "TargetBridge %s", host);
    }
    snprintf(a.tb_ip_text, sizeof(a.tb_ip_text), "%s", tb_ip);
    snprintf(a.net_ip_text, sizeof(a.net_ip_text), "%s", net_ip);
    snprintf(a.ip_text, sizeof(a.ip_text), "%s", tb_ip[0] ? tb_ip : (net_ip[0] ? net_ip : tb_i18n_get("receiver.network.not_detected")));
    snprintf(a.language_pref, sizeof(a.language_pref), "%s", startup_language_pref);
    snprintf(a.input_control_mode, sizeof(a.input_control_mode), "%s", "off");
    a.last_input_monitoring_trusted = -1;
    a.last_accessibility_trusted = -1;
    tb_refresh_idle_localized_strings(&a);
    build_display_host(a.display_host, sizeof(a.display_host), a.ip_text, tb_ip[0] || net_ip[0]);
    tb_receiver_apply_language_preference(&a);
    tb_gesture_bridge_install(tb_receiver_space_switch_callback, &a);
    tb_gesture_bridge_set_active(0);

    a.disp = tb_disp_create(fullscreen);
    if (!a.disp) { fprintf(stderr, "tb_disp_create failed\n"); return 1; }

    /* Open SDL Audio Device */
    SDL_AudioSpec spec;
    SDL_zero(spec);
    spec.freq = AUDIO_SAMPLE_RATE;
    spec.format = AUDIO_F32SYS; // 32-bit float, native endian — CoreAudio's own format
    spec.channels = AUDIO_CHANNELS;          // Stereo
    /* Frames per callback. A power of two, as SDL expects, and ~21 ms at
     * 48 kHz: small enough that output latency stays tight, large enough that a
     * scheduling hiccup does not underrun. */
    spec.samples = 1024;
    spec.callback = audio_callback;
    spec.userdata = &a;
    SDL_AudioSpec obtained;
    a.audio_device = SDL_OpenAudioDevice(NULL, 0, &spec, &obtained, 0);
    if (a.audio_device != 0) {
        SDL_PauseAudioDevice(a.audio_device, 0); // Start playing (unpaused)
        fprintf(stderr, "[main] SDL audio device opened: %d Hz, %d ch, 32-bit float (obtained %d samples)\n",
                AUDIO_SAMPLE_RATE, AUDIO_CHANNELS, obtained.samples);
    } else {
        fprintf(stderr, "[main] warning: SDL_OpenAudioDevice failed: %s\n", SDL_GetError());
    }

    struct tb_display_info boot_info;
    if (tb_disp_get_info(a.disp, &boot_info) == 0) {
        snprintf(a.panel_text, sizeof(a.panel_text), "%u x %u px (%s)",
                 boot_info.active_w, boot_info.active_h, boot_info.name);
    } else {
        tb_copy_i18n(a.panel_text, sizeof(a.panel_text), "receiver.panel.default");
    }
    bonjour_update(&a, TB_PORT);

    a.dec = tb_dec_create(on_frame, &a);
    if (!a.dec) { fprintf(stderr, "tb_dec_create failed\n"); tb_disp_destroy(a.disp); return 1; }

    tb_parser_init(&a.parser, on_packet, &a);

    a.server_fd = tb_net_listen(TB_PORT);
    if (a.server_fd < 0) { fprintf(stderr, "tb_net_listen failed\n"); return 1; }

    a.last_fps_tick_ms = now_ms();
    a.last_ip_check_ms = 0;

    /* Wall-clock accounting: every millisecond of the loop lands in exactly one
     * bucket, so the bottleneck is read off rather than guessed at. Note the
     * render runs inside the packet callback, hence inside drain — so
     * recv+parse == drain - (upload+present) reported by [perf]. */
    double acc_drain_ms = 0.0, acc_wait_ms = 0.0, acc_other_ms = 0.0;
    double acc_since_ms = now_ms_f();
    while (!g_term) {
        double loop_mark_ms = now_ms_f();
        unsigned int disp_actions = tb_disp_poll_actions(a.disp);
        int socket_activity = 0;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.0, true);
        if (disp_actions & TB_DISP_ACTION_QUIT) break;
        if ((disp_actions & TB_DISP_ACTION_CYCLE_LANGUAGE) && a.client_fd < 0) {
            tb_receiver_cycle_language_preference(&a);
        }

        uint64_t t = now_ms();

        if (t - a.last_ip_check_ms >= 1000) {
            char refreshed_tb_ip[64] = {0};
            char refreshed_net_ip[64] = {0};
            a.last_ip_check_ms = t;
            (void)tb_net_get_tb_ip(refreshed_tb_ip, sizeof(refreshed_tb_ip));
            (void)tb_net_get_lan_ip(refreshed_net_ip, sizeof(refreshed_net_ip));

            const int have_refreshed_ip = refreshed_tb_ip[0] || refreshed_net_ip[0];
            const char *preferred_ip = refreshed_tb_ip[0] ? refreshed_tb_ip
                                     : (refreshed_net_ip[0] ? refreshed_net_ip
                                     : tb_i18n_get("receiver.network.not_detected"));
            if (strcmp(a.tb_ip_text, refreshed_tb_ip) != 0 ||
                strcmp(a.net_ip_text, refreshed_net_ip) != 0 ||
                strcmp(a.ip_text, preferred_ip) != 0) {
                snprintf(a.tb_ip_text, sizeof(a.tb_ip_text), "%s", refreshed_tb_ip);
                snprintf(a.net_ip_text, sizeof(a.net_ip_text), "%s", refreshed_net_ip);
                snprintf(a.ip_text, sizeof(a.ip_text), "%s", preferred_ip);
                build_display_host(a.display_host, sizeof(a.display_host), preferred_ip, have_refreshed_ip);
                if (refreshed_tb_ip[0] != '\0') {
                    fprintf(stderr, "[main] Thunderbolt Bridge IP = %s\n", refreshed_tb_ip);
                }
                if (refreshed_net_ip[0] != '\0') {
                    fprintf(stderr, "[main] Local network IP = %s\n", refreshed_net_ip);
                }
                bonjour_update(&a, TB_PORT);
            }
        }

        /* Accept the client. One accept per iteration. */
        if (a.client_fd < 0) {
            int c = tb_net_accept(a.server_fd);
            if (c >= 0) {
                a.client_fd = c;
                a.have_video_frame = 0;
                a.session_active = 0;
                a.connecting_since = SDL_GetTicks();
                a.audio_input_is_s16 = 1;   // re-learned from the next hello
                a.reported_night_shift = -1;   /* force one report per session */
                a.reported_true_tone = -1;
                a.last_recv_ms = t;
                SDL_DisableScreenSaver();
                fprintf(stderr, "[main] client connected\n");
                tb_parser_free(&a.parser);
                tb_parser_init(&a.parser, on_packet, &a);
                /* Threaded receive is OFF by default: measured on the 5K iMac
                 * it moved `upload` from 12.4 ms to 27.9 ms for no fps gain.
                 * The reader's memcpy into the frame mailbox adds ~118 MB/frame
                 * of DRAM traffic that competes with the GPU upload's DMA, and
                 * this machine is memory-bandwidth bound at 59 MB/frame. Worth
                 * revisiting once the render path stops being the constraint. */
                /* On by default: the drop rule is now type-aware, so damage
                 * updates are never discarded (see the publish path). Threading
                 * overlaps receive with the ~13 ms GPU upload, which is what
                 * full-frame content — video, scrolling — is bound by.
                 * TB_RECEIVER_THREADED_RX=0 forces the serial path. */
                const char *rx_env = getenv("TB_RECEIVER_THREADED_RX");
                int want_threaded = !(rx_env && (rx_env[0] == '0' || rx_env[0] == 'n'));
                a.threaded_rx = want_threaded && (link_reader_start(a.reader1, &a, c) == 0);
                if (want_threaded && !a.threaded_rx) {
                    fprintf(stderr, "[main] falling back to inline (single-threaded) receive\n");
                }
                tb_receiver_refresh_input_capture(&a);
                tb_mic_start_if_possible(&a);
                send_receiver_info(&a);
            }
        }

        acc_other_ms += now_ms_f() - loop_mark_ms;
        double drain_mark_ms = now_ms_f();
        if (a.client_fd >= 0) {
            int fatal = 0;
            if (a.threaded_rx) {
                /* Reader threads own the sockets; here we only consume what
                 * they produced and watch for a link that ended. */
                socket_activity = pump_network(&a);
                if (a.reader1 && a.reader1->ended) fatal = 1;
            } else {
                int drain_result = drain_socket(&a);   /* primary */
                if (drain_result < 0) {
                    fatal = 1;
                } else {
                    socket_activity = drain_result;
                    if (drain_result > 0) a.last_recv_ms = t;
                }
            }
            if (fatal) {
                close_client(&a);                   /* also drops the secondary */
            } else {

                if (a.close_requested) {
                    close_client(&a);
                } else if (a.last_recv_ms < t &&
                           t - a.last_recv_ms >= TB_SENDER_IDLE_TIMEOUT_MS) {
                    /* The sender streams frames continuously and heartbeats
                     * every 2s. Total silence means it died without a FIN
                     * (crash, pulled cable, force sleep). Without this reap,
                     * the dead fd is held forever and every future connect is
                     * locked out until the app is restarted. */
                    fprintf(stderr, "[main] no data from sender for %llu ms; closing stale session\n",
                            (unsigned long long)(t > a.last_recv_ms ? t - a.last_recv_ms : 0));
                    close_client(&a);
                }
            }
        }

        if (t - a.last_permissions_poll_ms >= 250) {
            a.last_permissions_poll_ms = t;
            tb_receiver_poll_permissions(&a);
        }

        /* Cheap enough to poll: two private-framework getters, twice a second. */
        if (t - a.last_tweak_poll_ms >= 500) {
            a.last_tweak_poll_ms = t;
            tb_receiver_send_display_tweaks_if_changed(&a);
        }

        if (a.client_fd < 0 || !a.session_active) {
            /* No client, or a connection that hasn't started a real streaming
             * session (e.g. a transient UI-language push during discovery):
             * stay on the windowed waiting screen, don't flash fullscreen. */
            tb_disp_render_status(a.disp, a.display_host, a.status_text, a.sender_text, a.panel_text, a.mode_text, a.language_text, a.permissions_text);
        } else if (!a.have_video_frame) {
            /* "Connecting..." is only honest while a first frame is plausibly on
             * its way. When the sender stops streaming it keeps the control
             * connection open, so client_fd and session_active both stay set and
             * this screen used to persist forever — the receiver looked stuck
             * when it was simply idle and perfectly ready to accept a new
             * session. After a few seconds, say so. */
            if (t - a.connecting_since > 4000) {
                tb_disp_render_status(a.disp, a.display_host, a.status_text, a.sender_text,
                                      a.panel_text, a.mode_text, a.language_text,
                                      a.permissions_text);
            } else {
                tb_disp_render_connecting(a.disp);
            }
        } else {
            /* Frames are arriving; the next quiet spell starts its clock now. */
            a.connecting_since = t;
        }

        if (strcmp(a.input_control_mode, "receiverMaster") == 0 && a.client_fd >= 0) {
            if (t - a.last_clipboard_poll_ms >= 100) {
                a.last_clipboard_poll_ms = t;
                tb_receiver_send_clipboard_if_changed(&a);
            }
            struct tb_input_event input_event;
            while (tb_disp_pop_input_event(a.disp, &input_event)) {
                switch (input_event.kind) {
                case TB_INPUT_EVENT_MOVE:
                    tb_receiver_send_input_event(&a, "move", 1, input_event.dx, 1, input_event.dy, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_LEFT_DRAG:
                    tb_receiver_send_input_event(&a, "leftDrag", 1, input_event.dx, 1, input_event.dy, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_RIGHT_DRAG:
                    tb_receiver_send_input_event(&a, "rightDrag", 1, input_event.dx, 1, input_event.dy, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_OTHER_DRAG:
                    tb_receiver_send_input_event(&a, "otherDrag", 1, input_event.dx, 1, input_event.dy, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_SCROLL:
                    tb_receiver_send_input_event(&a, "scroll", 0, 0, 0, 0, 1, input_event.scroll_x, 1, input_event.scroll_y, 0, 0);
                    break;
                case TB_INPUT_EVENT_LEFT_DOWN:
                    tb_receiver_send_input_event(&a, "leftDown", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_LEFT_UP:
                    tb_receiver_send_input_event(&a, "leftUp", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_RIGHT_DOWN:
                    tb_receiver_send_input_event(&a, "rightDown", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_RIGHT_UP:
                    tb_receiver_send_input_event(&a, "rightUp", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_OTHER_DOWN:
                    tb_receiver_send_input_event(&a, "otherDown", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_OTHER_UP:
                    tb_receiver_send_input_event(&a, "otherUp", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_KEY_DOWN:
                    tb_receiver_send_input_event(&a, "keyDown", 0, 0, 0, 0, 0, 0, 0, 0, 1, input_event.key_code);
                    break;
                case TB_INPUT_EVENT_KEY_UP:
                    tb_receiver_send_input_event(&a, "keyUp", 0, 0, 0, 0, 0, 0, 0, 0, 1, input_event.key_code);
                    break;
                case TB_INPUT_EVENT_SWITCH_PREV_TARGET:
                    tb_receiver_send_target_switch(&a, -1);
                    break;
                case TB_INPUT_EVENT_SWITCH_NEXT_TARGET:
                    tb_receiver_send_target_switch(&a, 1);
                    break;
                case TB_INPUT_EVENT_SWITCH_PREV_SPACE:
                    tb_receiver_send_space_switch(&a, -1);
                    break;
                case TB_INPUT_EVENT_SWITCH_NEXT_SPACE:
                    tb_receiver_send_space_switch(&a, 1);
                    break;
                case TB_INPUT_EVENT_DEACTIVATE_CONTROL:
                    tb_receiver_send_deactivate_control(&a);
                    break;
                case TB_INPUT_EVENT_NONE:
                default:
                    break;
                }
            }
        }

        /* FPS log */
        if (t - a.last_fps_tick_ms >= 1000) {
            uint64_t df = a.frames - a.last_fps_count;
            a.last_fps_count   = a.frames;
            a.last_fps_tick_ms = t;
            if (df > 0) fprintf(stderr, "[main] %llu fps\n", (unsigned long long)df);
        }

        /* Yield when idle or when a nonblocking active socket had no data,
         * otherwise the receiver can busy-spin between incoming frame packets.
         *
         * Wait on the sockets rather than sleeping blindly: a raw 5K frame is
         * far larger than the socket buffer, so mid-frame the receiver drains
         * it empty many times while the rest of the frame is still on the wire.
         * A fixed sleep costs 1-2 ms on each of those, which at ~15-20 per
         * frame burned ~20 ms — more than the GPU upload itself. poll() returns
         * the moment bytes land, and the timeout only applies when the sender
         * really has gone quiet. */
        acc_drain_ms += now_ms_f() - drain_mark_ms;
        double wait_mark_ms = now_ms_f();
        if (a.threaded_rx && a.client_fd >= 0) {
            /* Sockets belong to the reader threads; waiting on them here too
             * would just duplicate their wakeups. Yield only when idle. */
            if (socket_activity == 0) SDL_Delay(1);
        } else if (a.client_fd < 0 || !a.have_video_frame || socket_activity == 0) {
            struct pollfd pfds[2];
            nfds_t npfd = 0;
            if (a.client_fd >= 0) {
                pfds[npfd].fd = a.client_fd;
                pfds[npfd].events = POLLIN;
                pfds[npfd].revents = 0;
                npfd++;
            }
            if (npfd > 0) {
                /* Bounded so SDL events, the cursor overlay and the fps tick
                 * stay responsive if the stream stalls. */
                poll(pfds, npfd, 2);
            } else {
                SDL_Delay(1);
            }
        }
        acc_wait_ms += now_ms_f() - wait_mark_ms;

        {
            double span = now_ms_f() - acc_since_ms;
            if (span >= 1000.0 && a.client_fd >= 0) {
                fprintf(stderr,
                        "[loop] over %.0f ms: drain %.0f ms (%.0f%%) | wait %.0f ms (%.0f%%) | other %.0f ms (%.0f%%)\n",
                        span,
                        acc_drain_ms, acc_drain_ms * 100.0 / span,
                        acc_wait_ms,  acc_wait_ms  * 100.0 / span,
                        acc_other_ms, acc_other_ms * 100.0 / span);
                acc_drain_ms = acc_wait_ms = acc_other_ms = 0.0;
                acc_since_ms = now_ms_f();
            }
        }
    }

    if (a.client_fd >= 0) close(a.client_fd);
    tb_receiver_stop_input_tap(&a);
    if (a.server_fd >= 0) close(a.server_fd);
    bonjour_deinit(&a);
    tb_parser_free(&a.parser);
    tb_dec_destroy(a.dec);
    if (a.audio_device != 0) {
        SDL_CloseAudioDevice(a.audio_device);
    }
    tb_disp_destroy(a.disp);
    fprintf(stderr, "[main] bye\n");
    return 0;
}
