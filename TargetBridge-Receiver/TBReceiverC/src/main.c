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
#include "proto.h"
#include "tb_gesture_bridge.h"
#include "tb_i18n.h"

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
#include <unistd.h>

#define AUDIO_BUF_CAP (192000) // 1 second buffer of 48000Hz stereo 16-bit PCM

struct app {
    struct tb_display *disp;
    struct tb_decoder *dec;
    struct tb_parser   parser;

    int      server_fd;
    int      client_fd;

    uint64_t frames;
    uint64_t last_fps_tick_ms;
    uint64_t last_fps_count;
    uint64_t last_ip_check_ms;
    int      close_requested;
    int      have_video_frame;

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

static int tb_receiver_is_valid_language_pref(const char *language_pref) {
    return language_pref &&
           (strcmp(language_pref, "auto") == 0 ||
            strcmp(language_pref, "it") == 0 ||
            strcmp(language_pref, "en") == 0 ||
            strcmp(language_pref, "de") == 0 ||
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
        fprintf(stderr, "[main] hello from sender\n");
        tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.sender_connected_profile_sent");
        break;
    case TB_PKT_CREATE_SESSION_ACK:
        fprintf(stderr, "[main] sender session ack: %.*s\n", (int)len, (const char *)payload);
        tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.session_accepted_waiting_frames");
        break;
    case TB_PKT_PARAM_SETS:
        /* tb_dec_set_param_sets is now a no-op if the sets are unchanged,
         * so we don't spam a log line per keyframe. */
        tb_dec_set_param_sets(a->dec, payload, len);
        break;
    case TB_PKT_FRAME:
        tb_dec_feed_frame(a->dec, payload, len);
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
            SDL_LockAudioDevice(a->audio_device);

            // Limit audio backlog to 150ms (150 * 192 = 28800 bytes) to cushion
            // against network / scheduling jitter while still keeping playout tight.
            const int cap_bytes = 28800;
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

static int drain_socket(struct app *a) {
    uint8_t buf[1024 * 1024];
    int saw_data = 0;
    for (;;) {
        ssize_t n = read(a->client_fd, buf, sizeof(buf));
        if (n > 0) {
            saw_data = 1;
            if (tb_parser_feed(&a->parser, buf, (size_t)n) < 0) return -1;
        } else if (n == 0) {
            return -1;  /* peer closed */
        } else {
            if (errno == EAGAIN || errno == EWOULDBLOCK) return saw_data;
            perror("[main] read");
            return -1;
        }
    }
}

static void write_be32(uint8_t *dst, uint32_t value) {
    dst[0] = (uint8_t)((value >> 24) & 0xff);
    dst[1] = (uint8_t)((value >> 16) & 0xff);
    dst[2] = (uint8_t)((value >> 8) & 0xff);
    dst[3] = (uint8_t)(value & 0xff);
}

static int send_all(int fd, const uint8_t *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, buf + off, len - off);
        if (n > 0) {
            off += (size_t)n;
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            usleep(1000);
            continue;
        }
        return -1;
    }
    return 0;
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
    (void)send_all(a->client_fd, pkt, 5 + (size_t)len);
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

    char json[768];
    int json_len = snprintf(
        json,
        sizeof(json),
        "{\"receiverName\":\"%s\",\"panelWidth\":%u,\"panelHeight\":%u,"
        "\"modeWidth\":%u,\"modeHeight\":%u,\"refreshRate\":60,"
        "\"hiDPI\":true,\"captureWidth\":%u,\"captureHeight\":%u,"
        "\"supportsHEVCDecode\":%s,\"inputMonitoringTrusted\":%s,\"accessibilityTrusted\":%s}",
        escaped_name,
        panel_w,
        panel_h,
        mode_w,
        mode_h,
        capture_w,
        capture_h,
        tb_dec_supports_hevc_hwdecode() ? "true" : "false",
        tb_receiver_input_monitoring_trusted() ? "true" : "false",
        tb_receiver_accessibility_trusted() ? "true" : "false"
    );
    if (json_len <= 0 || (size_t)json_len >= sizeof(json)) return;

    const size_t packet_len = 4 + 1 + (size_t)json_len;
    uint8_t *pkt = (uint8_t *)calloc(1, packet_len);
    if (!pkt) return;

    write_be32(pkt, (uint32_t)(1 + json_len));
    pkt[4] = TB_PKT_DISPLAY_PROFILE;
    memcpy(pkt + 5, json, (size_t)json_len);

    if (send_all(a->client_fd, pkt, packet_len) == 0) {
        fprintf(stderr,
                "[main] sent display profile: panel=%ux%u mode=%ux%u hidpi name=%s\n",
                panel_w, panel_h, mode_w, mode_h, info.name);
    }
    free(pkt);
}

static void close_client(struct app *a) {
    if (a->client_fd >= 0) close(a->client_fd);
    a->client_fd = -1;
    a->close_requested = 0;
    a->have_video_frame = 0;
    snprintf(a->input_control_mode, sizeof(a->input_control_mode), "off");
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
    a.server_fd = -1;
    a.client_fd = -1;
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
    spec.freq = 48000;
    spec.format = AUDIO_S16LSB; // 16-bit signed, little-endian PCM
    spec.channels = 2;          // Stereo
    spec.samples = 1024;        // Buffer size (approx 21.3ms)
    spec.callback = audio_callback;
    spec.userdata = &a;
    SDL_AudioSpec obtained;
    a.audio_device = SDL_OpenAudioDevice(NULL, 0, &spec, &obtained, 0);
    if (a.audio_device != 0) {
        SDL_PauseAudioDevice(a.audio_device, 0); // Start playing (unpaused)
        fprintf(stderr, "[main] SDL audio device opened: 48000Hz stereo 16-bit PCM (obtained %d samples)\n", obtained.samples);
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

    while (!g_term) {
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

        /* Accept new client */
        if (a.client_fd < 0) {
            int c = tb_net_accept(a.server_fd);
            if (c >= 0) {
                a.client_fd = c;
                a.have_video_frame = 0;
                fprintf(stderr, "[main] client connected\n");
                tb_parser_free(&a.parser);
                tb_parser_init(&a.parser, on_packet, &a);
                tb_receiver_refresh_input_capture(&a);
                send_receiver_info(&a);
            }
        } else {
            int drain_result = drain_socket(&a);
            if (drain_result < 0) {
                close_client(&a);
            } else {
                socket_activity = drain_result;
                if (a.close_requested) close_client(&a);
            }
        }

        if (t - a.last_permissions_poll_ms >= 250) {
            a.last_permissions_poll_ms = t;
            tb_receiver_poll_permissions(&a);
        }

        if (a.client_fd < 0 || !a.have_video_frame) {
            tb_disp_render_status(a.disp, a.display_host, a.status_text, a.sender_text, a.panel_text, a.mode_text, a.language_text, a.permissions_text);
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
         * otherwise the receiver can busy-spin between incoming frame packets. */
        if (a.client_fd < 0 || !a.have_video_frame || socket_activity == 0) {
            SDL_Delay(1);
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
