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
#include "tb_clipboard_bridge.h"
#include "tb_display_tweaks.h"
#include "tb_i18n.h"
#include "sender_control.h"
#include "receiver_state.h"

#include <SDL.h>
#include <ApplicationServices/ApplicationServices.h>
#include <dns_sd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreAudio/CoreAudio.h>

/* kAudioObjectPropertyElementMain is the macOS 12+ SDK spelling; older SDKs
 * only define kAudioObjectPropertyElementMaster (both are numerically 0). */
#if defined(__MAC_OS_X_VERSION_MAX_ALLOWED) && __MAC_OS_X_VERSION_MAX_ALLOWED < 120000
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

/* Reap a connected sender that has gone completely silent. The sender
 * heartbeats every 2s and streams frames continuously, so 10s of silence
 * (5 missed heartbeats) means it died without a FIN. */
#define TB_SENDER_IDLE_TIMEOUT_MS 10000
#define TB_INPUT_LOG_MAX_BYTES (5 * 1024 * 1024)
#define TB_LAUNCH_LOG_MAX_BYTES (20 * 1024 * 1024)

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
    /* Last display-tweak state reported to the sender, so changes made on this
     * Mac (Control Center, System Settings) propagate back and the sender's
     * toggles stay truthful. -1 = nothing sent yet. */
    int      reported_night_shift;
    int      reported_true_tone;
    uint64_t last_tweak_poll_ms;

    uint64_t last_recv_ms;      /* idle watchdog: last time the sender sent anything */
    int      close_requested;
    int      have_video_frame;
    /* A real streaming session has begun (the sender sent a session packet, not
     * just a transient probe like a UI-language push). Gates the fullscreen
     * "connecting" splash so a bare/short-lived connection doesn't flash it. */
    int      session_active;

    char     ip_text[64];
    char     tb_ip_text[64];
    char     usb_ip_text[64];
    char     net_ip_text[64];
    char     ethernet_ip_text[64];
    char     wifi_ip_text[64];
    char     display_host[128]; /* short hostname (or hostname+IP), cached at startup */
    char     status_text[128];
    char     sender_text[128];
    char     panel_text[128];
    char     mode_text[128];
    char     language_pref[8];
    char     language_text[96];
    char     permissions_text[160];
    char     control_text[192];
    char     control_status_key[96];
    char     selected_path_text[64];
    char     selected_path_key[96];
    char     selected_path_id[24];
    char     preferred_sender_action[32];
    char     sender_ui_language[8];
    char     input_control_mode[32];
    int      last_input_monitoring_trusted;
    int      last_accessibility_trusted;
    int      sender_accessibility_trusted;
    int      sender_accessibility_known;
    uint64_t last_permissions_poll_ms;
    struct tb_sender_control sender_control;
    uint64_t next_sender_control_ms;
    int      auto_sender_enabled;
    int      input_enabled;
    int      input_sync_pending;
    int      zero_frame_disconnects;

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
    int64_t  last_clipboard_change_count;
    char     last_clipboard_text[4096];
    uint64_t last_local_ui_check_ms;
    int      local_ui_passthrough;
    unsigned int local_pointer_buttons;
    unsigned int remote_pointer_buttons;
    char     local_ui_owner[96];
    volatile sig_atomic_t local_stop_requested;
    volatile sig_atomic_t local_release_requested;
};

static int tb_should_log_input_event(uint64_t count) {
    return count <= 20 || (count % 100) == 0;
}

static void tb_trim_regular_stream(FILE *stream, off_t maximum_bytes) {
    if (!stream) return;
    int fd = fileno(stream);
    struct stat status;
    if (fd < 0 || fstat(fd, &status) != 0 || !S_ISREG(status.st_mode) ||
        status.st_size <= maximum_bytes) return;
    (void)ftruncate(fd, 0);
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
    struct stat status;
    if (fstat(fileno(f), &status) == 0 && status.st_size > TB_INPUT_LOG_MAX_BYTES) {
        fclose(f);
        f = fopen(path, "w");
        if (!f) return;
    }

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
static int  tb_receiver_sender_input_ready(const struct app *a);
static int  tb_receiver_input_capture_ready(const struct app *a);
static int  tb_receiver_input_setup_needed(const struct app *a);
static void tb_receiver_poll_permissions(struct app *a);
static void tb_receiver_refresh_control_text(struct app *a);
static void tb_receiver_set_control_status(struct app *a, const char *key);
static void tb_receiver_set_selected_path(struct app *a, const char *key, const char *path_id);
static int  tb_receiver_save_diagnostics(struct app *a, char *saved_path, size_t saved_path_size);
static void tb_receiver_start_remote_action(struct app *a, const char *action, uint64_t now);
static void tb_receiver_start_input_action(struct app *a,
                                           int enabled,
                                           uint64_t now,
                                           int request_permissions);
static void tb_receiver_poll_remote_action(struct app *a, uint64_t now);
static void tb_receiver_persist_monitor_state(const struct app *a);
static int tb_receiver_input_monitoring_trusted(void);
static int tb_receiver_accessibility_trusted(void);
static void send_receiver_info(struct app *a);
static void tb_receiver_apply_input_event(const uint8_t *payload, size_t len);
static void tb_receiver_apply_input_control_mode(struct app *a, const uint8_t *payload, size_t len);
static void tb_receiver_refresh_input_capture(struct app *a);
static void tb_receiver_set_clipboard_text(struct app *a, const char *text);
static void tb_receiver_send_clipboard_if_changed(struct app *a);
static void write_be32(uint8_t *dst, uint32_t value);
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

    if (!a->input_enabled) {
        if (lang && strncmp(lang, "it", 2) == 0) {
            snprintf(a->permissions_text, sizeof(a->permissions_text),
                     "Mouse e tastiera dell'iMac: funzione opzionale disattivata");
        } else if (lang && strncmp(lang, "de", 2) == 0) {
            snprintf(a->permissions_text, sizeof(a->permissions_text),
                     "iMac-Maus und -Tastatur: optionale Steuerung deaktiviert");
        } else if (lang && strncmp(lang, "fr", 2) == 0) {
            snprintf(a->permissions_text, sizeof(a->permissions_text),
                     "Souris et clavier de l’iMac : commande optionnelle désactivée");
        } else if (lang && strncmp(lang, "zh", 2) == 0) {
            snprintf(a->permissions_text, sizeof(a->permissions_text),
                     "iMac 鼠标和键盘：可选控制已关闭");
        } else {
            snprintf(a->permissions_text, sizeof(a->permissions_text),
                     "iMac mouse and keyboard: optional control is off");
        }
        return;
    }

    const char *mini_state = a->sender_accessibility_known
        ? (a->sender_accessibility_trusted ? "OK" : "Missing")
        : "Check pending";

    if (lang && strncmp(lang, "it", 2) == 0) {
        snprintf(
            a->permissions_text,
            sizeof(a->permissions_text),
            "Mac mini Accessibilità: %s · Controllo globale iMac: %s",
            a->sender_accessibility_known
                ? (a->sender_accessibility_trusted ? "OK" : "Mancante")
                : "Da verificare",
            input_monitoring && accessibility ? "OK" : "Opzionale"
        );
    } else if (lang && strncmp(lang, "de", 2) == 0) {
        snprintf(
            a->permissions_text,
            sizeof(a->permissions_text),
            "Mac mini Bedienungshilfen: %s · Globale iMac-Steuerung: %s",
            a->sender_accessibility_known
                ? (a->sender_accessibility_trusted ? "OK" : "Fehlt")
                : "Prüfung ausstehend",
            input_monitoring && accessibility ? "OK" : "Optional"
        );
    } else if (lang && strncmp(lang, "zh", 2) == 0) {
        snprintf(
            a->permissions_text,
            sizeof(a->permissions_text),
            "Mac mini 辅助功能：%s · iMac 全局控制：%s",
            a->sender_accessibility_known
                ? (a->sender_accessibility_trusted ? "正常" : "缺失")
                : "待检查",
            input_monitoring && accessibility ? "正常" : "可选"
        );
    } else {
        snprintf(
            a->permissions_text,
            sizeof(a->permissions_text),
            "Mac mini Accessibility: %s · Global iMac control: %s",
            mini_state,
            input_monitoring && accessibility ? "OK" : "Optional"
        );
    }
}

static int tb_receiver_sender_input_ready(const struct app *a) {
    return a &&
           a->input_enabled &&
           a->sender_accessibility_known &&
           a->sender_accessibility_trusted;
}

/* Basic fullscreen control uses SDL window events and needs no receiver-side
 * privacy permission. The two iMac permissions only upgrade that path to a
 * global event tap, which can safely coexist with local notifications/UI. */
static int tb_receiver_input_capture_ready(const struct app *a) {
    return tb_receiver_sender_input_ready(a);
}

static int tb_receiver_input_setup_needed(const struct app *a) {
    return a && a->input_enabled && !tb_receiver_input_capture_ready(a);
}

static void tb_receiver_refresh_control_text(struct app *a) {
    if (!a) return;
    tb_copy_i18n(a->control_text, sizeof(a->control_text),
                 a->control_status_key[0]
                     ? a->control_status_key
                     : "receiver.control.ready");
    tb_copy_i18n(a->selected_path_text, sizeof(a->selected_path_text),
                 a->selected_path_key[0]
                     ? a->selected_path_key
                     : "receiver.control.path_auto");
}

static void tb_receiver_set_control_status(struct app *a, const char *key) {
    if (!a || !key) return;
    snprintf(a->control_status_key, sizeof(a->control_status_key), "%s", key);
    tb_copy_i18n(a->control_text, sizeof(a->control_text), key);
}

static void tb_receiver_set_selected_path(struct app *a, const char *key, const char *path_id) {
    if (!a || !key || !path_id) return;
    snprintf(a->selected_path_key, sizeof(a->selected_path_key), "%s", key);
    snprintf(a->selected_path_id, sizeof(a->selected_path_id), "%s", path_id);
    tb_copy_i18n(a->selected_path_text, sizeof(a->selected_path_text), key);
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
    tb_receiver_refresh_control_text(a);
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

static const char *tb_receiver_path_key_for_action(const char *action) {
    if (!action) return "receiver.control.path_auto";
    if (strcmp(action, "path thunderbolt") == 0) return "receiver.control.path_thunderbolt";
    if (strcmp(action, "path usb") == 0) return "receiver.control.path_usb";
    if (strcmp(action, "path ethernet") == 0) return "receiver.control.path_ethernet";
    if (strcmp(action, "path wifi") == 0) return "receiver.control.path_wifi";
    return "receiver.control.path_auto";
}

static const char *tb_receiver_path_id_for_action(const char *action) {
    if (!action) return "auto";
    if (strcmp(action, "path thunderbolt") == 0) return "thunderbolt";
    if (strcmp(action, "path usb") == 0) return "usb";
    if (strcmp(action, "path ethernet") == 0) return "ethernet";
    if (strcmp(action, "path wifi") == 0) return "wifi";
    return "auto";
}

static void tb_receiver_start_remote_action(struct app *a, const char *action, uint64_t now) {
    if (!a || !action) return;

    /* Stop must win immediately over an automatic retry already in flight. */
    if (tb_sender_control_busy(&a->sender_control)) {
        tb_sender_control_cancel(&a->sender_control);
    }

    if (strcmp(action, "stop") == 0) {
        a->auto_sender_enabled = 0;
        a->next_sender_control_ms = 0;
        tb_receiver_set_control_status(a, "receiver.control.stopping");
    } else {
        a->auto_sender_enabled = 1;
        snprintf(a->preferred_sender_action, sizeof(a->preferred_sender_action), "%s", action);
        tb_receiver_set_selected_path(a,
                                      tb_receiver_path_key_for_action(action),
                                      tb_receiver_path_id_for_action(action));
        tb_receiver_set_control_status(a, "receiver.control.starting");
    }
    tb_receiver_persist_monitor_state(a);

    int start_result = tb_sender_control_start(&a->sender_control, action);
    if (start_result != 0) {
        tb_receiver_set_control_status(a, "receiver.control.unavailable");
        if (a->auto_sender_enabled) a->next_sender_control_ms = now + 10000;
        return;
    }
    fprintf(stderr, "[control] action started: %s\n", action);
}

static void tb_receiver_persist_monitor_state(const struct app *a) {
    if (!a) return;
    struct tb_receiver_monitor_state state;
    state.auto_sender_enabled = a->auto_sender_enabled ? 1 : 0;
    state.input_enabled = a->input_enabled ? 1 : 0;
    snprintf(state.preferred_action, sizeof(state.preferred_action), "%s",
             tb_receiver_monitor_action_is_valid(a->preferred_sender_action)
                 ? a->preferred_sender_action
                 : "path auto");
    if (tb_receiver_monitor_state_save(&state) != 0) {
        fprintf(stderr, "[control] warning: unable to persist monitor-mode state\n");
    }
}

static void tb_receiver_start_input_action(struct app *a,
                                           int enabled,
                                           uint64_t now,
                                           int request_permissions) {
    if (!a) return;
    if (tb_sender_control_busy(&a->sender_control)) {
        tb_sender_control_cancel(&a->sender_control);
    }

    a->input_enabled = enabled ? 1 : 0;
    a->input_sync_pending = 1;
    tb_receiver_persist_monitor_state(a);
    tb_receiver_refresh_permissions_text(a);
    /* The default fullscreen SDL path needs no iMac privacy permission. The
     * helper restarts the Sender, which presents the only mandatory prompt:
     * Accessibility on the Mac mini. Receiver global-control permissions stay
     * an optional advanced upgrade instead of blocking first-time setup. */
    (void)request_permissions;
    if (a->input_enabled) {
        tb_receiver_set_control_status(a, "receiver.control.input_enabling");
    } else {
        snprintf(a->input_control_mode, sizeof(a->input_control_mode), "%s", "off");
        tb_receiver_refresh_input_capture(a);
        tb_receiver_set_control_status(a, "receiver.control.input_disabling");
    }

    const char *action = a->input_enabled ? "input on" : "input off";
    if (tb_sender_control_start(&a->sender_control, action) != 0) {
        tb_receiver_set_control_status(a, "receiver.control.input_unavailable");
        if (a->auto_sender_enabled) a->next_sender_control_ms = now + 10000;
        return;
    }
    fprintf(stderr, "[control] input action started: %s\n", action);
    (void)now;
}

static void tb_receiver_poll_remote_action(struct app *a, uint64_t now) {
    if (!a || !tb_sender_control_poll(&a->sender_control)) return;

    const int was_stop = strcmp(a->sender_control.action, "stop") == 0;
    const int was_input = strncmp(a->sender_control.action, "input ", 6) == 0;
    if (a->sender_control.state == TB_SENDER_CONTROL_SUCCEEDED) {
        if (was_input) {
            a->input_sync_pending = 0;
            tb_receiver_set_control_status(a,
                a->input_enabled
                    ? "receiver.control.input_enabled"
                    : "receiver.control.input_disabled");
            if (a->auto_sender_enabled && a->client_fd < 0) {
                a->next_sender_control_ms = now + 500;
            }
        } else {
            tb_receiver_set_control_status(a,
                was_stop ? "receiver.control.stopped" : "receiver.control.started");
            a->next_sender_control_ms = was_stop ? 0 : now + 30000;
        }
        fprintf(stderr, "[control] action succeeded: %s\n", a->sender_control.action);
    } else {
        tb_receiver_set_control_status(a,
            was_input ? "receiver.control.input_unavailable" : "receiver.control.unavailable");
        if (a->auto_sender_enabled) a->next_sender_control_ms = now + 10000;
        fprintf(stderr, "[control] action failed: %s output=%s\n",
                a->sender_control.action,
                a->sender_control.output[0] ? a->sender_control.output : "(empty)");
    }
}

static int tb_receiver_save_diagnostics(struct app *a,
                                        char *saved_path,
                                        size_t saved_path_size) {
    if (!a || !saved_path || saved_path_size == 0) return -1;
    saved_path[0] = '\0';

    const char *diagnostics_dir = getenv("TB_DIAGNOSTICS_DIR");
    char default_diagnostics_dir[PATH_MAX];
    if (!diagnostics_dir || !*diagnostics_dir) {
        const char *home = getenv("HOME");
        if (!home || !*home) return -1;
        int dir_written = snprintf(default_diagnostics_dir,
                                   sizeof(default_diagnostics_dir),
                                   "%s/Desktop", home);
        if (dir_written <= 0 || (size_t)dir_written >= sizeof(default_diagnostics_dir)) {
            return -1;
        }
        diagnostics_dir = default_diagnostics_dir;
    }

    time_t wall_time = time(NULL);
    struct tm local_time;
    if (!localtime_r(&wall_time, &local_time)) return -1;

    char stamp[32];
    if (strftime(stamp, sizeof(stamp), "%Y%m%d-%H%M%S", &local_time) == 0) {
        return -1;
    }

    int written = snprintf(saved_path, saved_path_size,
                           "%s/TargetBridge-Diagnostica-%s.txt",
                           diagnostics_dir, stamp);
    if (written <= 0 || (size_t)written >= saved_path_size) {
        saved_path[0] = '\0';
        return -1;
    }

    FILE *report = fopen(saved_path, "w");
    if (!report) {
        saved_path[0] = '\0';
        return -1;
    }

    char readable_time[64] = {0};
    (void)strftime(readable_time, sizeof(readable_time), "%Y-%m-%d %H:%M:%S %Z", &local_time);
    fprintf(report, "TargetBridge Receiver — diagnostica locale\n");
    fprintf(report, "Data: %s\n", readable_time[0] ? readable_time : "non disponibile");
    fprintf(report, "Versione: %s (%s)\n", TB_RECEIVER_VERSION, TB_RECEIVER_BUILD);
    fprintf(report, "Receiver: %s\n", a->display_host[0] ? a->display_host : "non rilevato");
    fprintf(report, "Stato: %s\n", a->status_text);
    fprintf(report, "Controllo Mac mini: %s\n", a->control_text);
    fprintf(report, "Percorso selezionato: %s [%s]\n",
            a->selected_path_text, a->selected_path_id);
    fprintf(report, "Azione automatica: %s\n", a->preferred_sender_action);
    fprintf(report, "Avvio automatico: %s\n", a->auto_sender_enabled ? "attivo" : "sospeso");
    fprintf(report, "\nInterfacce Receiver\n");
    fprintf(report, "Thunderbolt Bridge: %s\n", a->tb_ip_text[0] ? a->tb_ip_text : "non rilevato");
    fprintf(report, "USB diretto: %s\n", a->usb_ip_text[0] ? a->usb_ip_text : "non rilevato");
    fprintf(report, "Ethernet: %s\n", a->ethernet_ip_text[0] ? a->ethernet_ip_text : "non rilevato");
    fprintf(report, "Wi-Fi: %s\n", a->wifi_ip_text[0] ? a->wifi_ip_text : "non rilevato");
    fprintf(report, "Rete preferita pubblicata: %s\n", a->net_ip_text[0] ? a->net_ip_text : "non rilevata");
    fprintf(report, "\nSessione\n");
    fprintf(report, "Client collegato: %s\n", a->client_fd >= 0 ? "sì" : "no");
    fprintf(report, "Sessione attiva: %s\n", a->session_active ? "sì" : "no");
    fprintf(report, "Primo frame ricevuto: %s\n", a->have_video_frame ? "sì" : "no");
    fprintf(report, "Frame totali: %llu\n", (unsigned long long)a->frames);
    fprintf(report, "Disconnessioni senza frame: %d\n", a->zero_frame_disconnects);
    fprintf(report, "Sender: %s\n", a->sender_text);
    fprintf(report, "Display: %s\n", a->panel_text);
    fprintf(report, "Profilo: %s\n", a->mode_text);
    fprintf(report, "Permessi iMac: %s\n", a->permissions_text);
    fprintf(report, "\nUltimo risultato controllo remoto\n%s\n",
            a->sender_control.output[0] ? a->sender_control.output : "nessun risultato disponibile");

    if (fclose(report) != 0) {
        saved_path[0] = '\0';
        return -1;
    }
    return 0;
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

static void tb_receiver_set_clipboard_text(struct app *a, const char *text) {
    if (!a || !tb_clipboard_write_text(text ? text : "")) return;
    a->last_clipboard_change_count = tb_clipboard_change_count();
    snprintf(a->last_clipboard_text, sizeof(a->last_clipboard_text), "%s",
             text ? text : "");
}

static void tb_receiver_send_clipboard_if_changed(struct app *a) {
    if (!a || strcmp(a->input_control_mode, "receiverMaster") != 0 || a->client_fd < 0) return;

    int64_t change_count = tb_clipboard_change_count();
    if (change_count == a->last_clipboard_change_count) return;
    a->last_clipboard_change_count = change_count;

    char text[4096];
    if (!tb_clipboard_read_text(text, sizeof(text))) return;
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
    if (a->usb_ip_text[0] != '\0') {
        TXTRecordSetValue(&txt, "usbIP", (uint8_t)strlen(a->usb_ip_text), a->usb_ip_text);
    }
    if (a->net_ip_text[0] != '\0') {
        TXTRecordSetValue(&txt, "netIP", (uint8_t)strlen(a->net_ip_text), a->net_ip_text);
    }
    if (a->ethernet_ip_text[0] != '\0') {
        TXTRecordSetValue(&txt, "ethernetIP", (uint8_t)strlen(a->ethernet_ip_text), a->ethernet_ip_text);
    }
    if (a->wifi_ip_text[0] != '\0') {
        TXTRecordSetValue(&txt, "wifiIP", (uint8_t)strlen(a->wifi_ip_text), a->wifi_ip_text);
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
    if (mode[0] == '\0' || (!a->input_enabled && strcmp(mode, "receiverMaster") == 0)) {
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
    a->zero_frame_disconnects = 0;
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
    if (len < 17) return;
    if (p[0] != 1) return; /* only NV12 is supported */
    uint32_t w  = ((uint32_t)p[1]  << 24) | ((uint32_t)p[2]  << 16) | ((uint32_t)p[3]  << 8) | (uint32_t)p[4];
    uint32_t h  = ((uint32_t)p[5]  << 24) | ((uint32_t)p[6]  << 16) | ((uint32_t)p[7]  << 8) | (uint32_t)p[8];
    uint32_t ys = ((uint32_t)p[9]  << 24) | ((uint32_t)p[10] << 16) | ((uint32_t)p[11] << 8) | (uint32_t)p[12];
    uint32_t us = ((uint32_t)p[13] << 24) | ((uint32_t)p[14] << 16) | ((uint32_t)p[15] << 8) | (uint32_t)p[16];
    /* Keep malformed peer data from turning into oversized stride arithmetic or
     * an out-of-bounds render. TargetBridge RAW is intentionally limited to
     * practical 4:2:0 display sizes and the protocol packet cap. */
    if (w == 0 || h == 0 || (w & 1) || (h & 1) ||
        w > 8192 || h > 8192 || ys < w || us < w ||
        ys > 16384 || us > 16384) return;
    size_t y_size  = (size_t)ys * h;
    size_t uv_size = (size_t)us * (h / 2);
    size_t payload_size = len - 17;
    if (y_size > payload_size || uv_size > payload_size - y_size) return;
    const uint8_t *y  = p + 17;
    const uint8_t *uv = y + y_size;

    a->have_video_frame = 1;
    a->zero_frame_disconnects = 0;
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
    tb_disp_render_nv12(a->disp, y, (int)ys, uv, (int)us, (int)w, (int)h);
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
    if (!a || !payload) return;
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
            int sender_accessibility = 0;
            if (extract_json_bool_field(payload, len, "\"accessibilityTrusted\"",
                                        &sender_accessibility)) {
                a->sender_accessibility_known = 1;
                a->sender_accessibility_trusted = sender_accessibility ? 1 : 0;
                fprintf(stderr, "[input] Mac mini accessibility=%s\n",
                        a->sender_accessibility_trusted ? "true" : "false");
                tb_receiver_refresh_permissions_text(a);
                tb_receiver_refresh_input_capture(a);
            }
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
        a->session_active = 1;
        handle_raw_frame(a, payload, len);
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
        }
        break;
    case TB_PKT_CLIPBOARD:
        {
            char text[4096] = {0};
            extract_json_string_field(payload, len, "\"text\"", text, sizeof(text));
            tb_receiver_set_clipboard_text(a, text);
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
            size_t audio_len = len;
            const uint8_t *audio_payload = payload;
            if (audio_len > (size_t)cap_bytes) {
                audio_payload += audio_len - (size_t)cap_bytes;
                audio_len = (size_t)cap_bytes;
            }
            if (a->audio_buf_size + (int)audio_len > cap_bytes) {
                int excess = a->audio_buf_size + (int)audio_len - cap_bytes;
                a->audio_buf_tail = (a->audio_buf_tail + excess) % AUDIO_BUF_CAP;
                a->audio_buf_size -= excess;
            }

            // Write payload to circular buffer
            if (a->audio_buf_size + (int)audio_len <= AUDIO_BUF_CAP) {
                int first = AUDIO_BUF_CAP - a->audio_buf_head;
                if (first >= (int)audio_len) {
                    memcpy(a->audio_buf + a->audio_buf_head, audio_payload, audio_len);
                } else {
                    memcpy(a->audio_buf + a->audio_buf_head, audio_payload, (size_t)first);
                    memcpy(a->audio_buf, audio_payload + first, audio_len - (size_t)first);
                }
                a->audio_buf_head = (a->audio_buf_head + (int)audio_len) % AUDIO_BUF_CAP;
                a->audio_buf_size += (int)audio_len;
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
    case TB_PKT_TEARDOWN: {
        char reason[64] = {0};
        extract_json_string_field(payload, len, "\"reason\"", reason, sizeof(reason));
        fprintf(stderr, "[main] teardown requested by sender reason=%s\n",
                reason[0] ? reason : "unspecified");
        if (tb_receiver_teardown_requests_suspend(reason)) {
            /* A user who presses Stop on the Mac mini is explicitly asking to
             * regain the iMac. Persist that choice before closing the socket,
             * so neither side's crash-recovery loop can undo it. */
            a->auto_sender_enabled = 0;
            a->next_sender_control_ms = 0;
            tb_receiver_persist_monitor_state(a);
            tb_receiver_set_control_status(a, "receiver.control.stopped");
            fprintf(stderr, "[control] user stop received from sender; automatic restart suspended\n");
        }
        tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.session_closed_by_sender");
        a->close_requested = 1;
        break;
    }
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
    /* Bound the EAGAIN retry loop: this runs on the event-loop thread, so an
     * unresponsive reader (half-open peer, saturated link) must not wedge
     * rendering and quit handling forever. 2s of zero progress means the
     * session is effectively dead; give up and let the caller/watchdog
     * tear it down. */
    const uint64_t deadline_ms = now_ms() + 2000;
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

static void tb_receiver_send_input_button_event(struct app *a,
                                                const char *kind,
                                                int click_count) {
    if (!a || a->client_fd < 0) return;
    if (strcmp(a->input_control_mode, "receiverMaster") != 0) return;

    if (click_count < 1) click_count = 1;
    if (click_count > 3) click_count = 3;

    char json[128];
    int len = snprintf(json, sizeof(json),
                       "{\"kind\":\"%s\",\"clickCount\":%d}",
                       kind ? kind : "",
                       click_count);
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
                              0,
                              0,
                              0,
                              0,
                              0,
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

static unsigned int tb_receiver_pointer_button_bit(CGEventType type) {
    switch (type) {
    case kCGEventLeftMouseDown:
    case kCGEventLeftMouseUp:
        return 1u;
    case kCGEventRightMouseDown:
    case kCGEventRightMouseUp:
        return 2u;
    case kCGEventOtherMouseDown:
    case kCGEventOtherMouseUp:
        return 4u;
    default:
        return 0u;
    }
}

static int tb_receiver_pointer_event_is_down(CGEventType type) {
    return type == kCGEventLeftMouseDown ||
           type == kCGEventRightMouseDown ||
           type == kCGEventOtherMouseDown;
}

static int tb_receiver_pointer_event_is_up(CGEventType type) {
    return type == kCGEventLeftMouseUp ||
           type == kCGEventRightMouseUp ||
           type == kCGEventOtherMouseUp;
}

static int tb_receiver_pointer_event(CGEventType type) {
    return type == kCGEventMouseMoved ||
           type == kCGEventLeftMouseDragged ||
           type == kCGEventRightMouseDragged ||
           type == kCGEventOtherMouseDragged ||
           tb_receiver_pointer_button_bit(type) != 0 ||
           type == kCGEventScrollWheel;
}

static int tb_receiver_update_local_ui_gate(struct app *a,
                                            CGEventRef event,
                                            int force_refresh) {
    if (!a || !event) return 0;
    uint64_t now = now_ms();
    if (!force_refresh && now - a->last_local_ui_check_ms < 80) {
        return a->local_ui_passthrough;
    }
    a->last_local_ui_check_ms = now;

    char owner[96] = {0};
    int passthrough = 0;
    if (!tb_receiver_app_is_active()) {
        passthrough = 1;
        snprintf(owner, sizeof(owner), "%s", "applicazione locale");
    } else {
        CGPoint location = CGEventGetLocation(event);
        passthrough = tb_local_ui_above_receiver_at_point(
            a->disp, location.x, location.y, owner, sizeof(owner));
    }

    if (passthrough != a->local_ui_passthrough ||
        (passthrough && strcmp(owner, a->local_ui_owner) != 0)) {
        a->local_ui_passthrough = passthrough;
        snprintf(a->local_ui_owner, sizeof(a->local_ui_owner), "%s", owner);
        tb_disp_set_local_ui_passthrough(a->disp, passthrough);
        if (passthrough) {
            /* Never leave Command/Option/etc. logically held on the Mini when
             * the pointer moves to a local notification or alert. */
            tb_receiver_sync_modifier_state(a, 0, 0, 0, 0, 0);
        }
        tb_receiver_input_log("[input] local UI passthrough=%s owner=%s",
                              passthrough ? "true" : "false",
                              owner[0] ? owner : "none");
    }
    return passthrough;
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

    if (tb_receiver_pointer_event(type)) {
        const unsigned int button_bit = tb_receiver_pointer_button_bit(type);
        const int force_refresh = button_bit != 0 || type == kCGEventScrollWheel;
        const int local_ui = tb_receiver_update_local_ui_gate(a, event, force_refresh);

        if (tb_receiver_pointer_event_is_down(type)) {
            if (local_ui) {
                a->local_pointer_buttons |= button_bit;
                return event;
            }
            a->remote_pointer_buttons |= button_bit;
        } else if (tb_receiver_pointer_event_is_up(type)) {
            if (a->local_pointer_buttons & button_bit) {
                a->local_pointer_buttons &= ~button_bit;
                return event;
            }
            if (a->remote_pointer_buttons & button_bit) {
                a->remote_pointer_buttons &= ~button_bit;
                /* Complete the remote click/drag even if an overlay appeared
                 * after the corresponding mouse-down. */
            } else if (local_ui) {
                return event;
            }
        } else if (a->local_pointer_buttons != 0 ||
                   (a->remote_pointer_buttons == 0 && local_ui)) {
            return event;
        }
    } else if (!tb_receiver_app_is_active()) {
        return event;
    }

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
        tb_receiver_send_input_button_event(
            a,
            "leftDown",
            (int)CGEventGetIntegerValueField(event, kCGMouseEventClickState));
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventLeftMouseUp:
        tb_receiver_send_input_button_event(
            a,
            "leftUp",
            (int)CGEventGetIntegerValueField(event, kCGMouseEventClickState));
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventRightMouseDown:
        tb_receiver_send_input_button_event(
            a,
            "rightDown",
            (int)CGEventGetIntegerValueField(event, kCGMouseEventClickState));
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventRightMouseUp:
        tb_receiver_send_input_button_event(
            a,
            "rightUp",
            (int)CGEventGetIntegerValueField(event, kCGMouseEventClickState));
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventOtherMouseDown:
        tb_receiver_send_input_button_event(
            a,
            "otherDown",
            (int)CGEventGetIntegerValueField(event, kCGMouseEventClickState));
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventOtherMouseUp:
        tb_receiver_send_input_button_event(
            a,
            "otherUp",
            (int)CGEventGetIntegerValueField(event, kCGMouseEventClickState));
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
            key_code == 53) {
            fprintf(stderr, "[input] local stop requested\n");
            a->local_stop_requested = 1;
            should_consume = a->input_tap_consumes_events;
            break;
        }
        if ((flags & kCGEventFlagMaskControl) &&
            (flags & kCGEventFlagMaskAlternate) &&
            (flags & kCGEventFlagMaskCommand) &&
            key_code == 40) {
            tb_receiver_send_deactivate_control(a);
            a->local_release_requested = 1;
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
            key_code == 53) {
            should_consume = a->input_tap_consumes_events;
            break;
        }
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
    a->local_pointer_buttons = 0;
    a->remote_pointer_buttons = 0;
    a->local_ui_passthrough = 0;
    a->local_ui_owner[0] = '\0';
    tb_disp_set_local_ui_passthrough(a->disp, 0);
}

static void tb_receiver_start_input_tap(struct app *a) {
    if (!a || a->input_tap) return;

    if (a->last_input_monitoring_trusted != 1 ||
        a->last_accessibility_trusted != 1) {
        return;
    }

    const int can_consume = 1;
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
    if (strcmp(a->input_control_mode, "receiverMaster") == 0 &&
        a->client_fd >= 0 &&
        tb_receiver_input_capture_ready(a)) {
        const int wants_global_tap =
            a->last_input_monitoring_trusted == 1 &&
            a->last_accessibility_trusted == 1;
        if (a->input_tap && !wants_global_tap) {
            tb_receiver_stop_input_tap(a);
        }
        if (wants_global_tap) tb_receiver_start_input_tap(a);
        tb_disp_set_input_intercept_active(a->disp, 1);
        tb_disp_set_input_capture_active(a->disp, wants_global_tap && a->input_tap ? 0 : 1);
        tb_gesture_bridge_set_active(1);
        tb_receiver_input_log("[input] receiverMaster capture path = %s",
                              a->input_tap ? "global-tap" : "sdl-fallback");
    } else {
        tb_receiver_stop_input_tap(a);
        tb_disp_set_input_intercept_active(a->disp, 0);
        tb_disp_set_input_capture_active(a->disp, 0);
        tb_gesture_bridge_set_active(0);
        if (strcmp(a->input_control_mode, "receiverMaster") == 0 && a->input_enabled) {
            tb_receiver_input_log("[input] capture blocked until Mac mini Accessibility is ready");
        } else {
            tb_receiver_input_log("[input] input capture disabled");
        }
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

    uint8_t pkt[4 + 1 + sizeof(json)];
    write_be32(pkt, (uint32_t)(1 + len));
    pkt[4] = TB_PKT_DISPLAY_TWEAKS;
    memcpy(pkt + 5, json, (size_t)len);
    (void)send_all(a->client_fd, pkt, 5 + (size_t)len);
}

static void send_receiver_info(struct app *a) {
    struct tb_display_info info;
    if (tb_disp_get_info(a->disp, &info) < 0) return;

    /* Preserve the upstream 5K profile unless the receiver is clearly running
     * on a 4096x2304 Retina panel. SDL's drawable size exposes the physical
     * backing pixels on scaled Retina desktops, so this keeps both 21.5-inch
     * 4K and 27-inch 5K iMacs working without a machine-specific build. */
    uint32_t panel_w = 5120;
    uint32_t panel_h = 2880;
    uint32_t mode_w = 2560;
    uint32_t mode_h = 1440;
    uint32_t capture_w = 2560;
    uint32_t capture_h = 1440;
    if (info.active_w >= 3840 && info.active_w < 4800 &&
        info.active_h >= 2160 && info.active_h < 2700) {
        panel_w = 4096;
        panel_h = 2304;
        mode_w = 2048;
        mode_h = 1152;
        capture_w = 4096;
        capture_h = 2304;
    }

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
        "\"supportsHEVCDecode\":%s,\"supportsRawNV12\":true,\"inputMonitoringTrusted\":%s,\"accessibilityTrusted\":%s,"
        "\"supportsNightShift\":%s,\"supportsTrueTone\":%s}",
        escaped_name,
        panel_w,
        panel_h,
        mode_w,
        mode_h,
        capture_w,
        capture_h,
        tb_dec_supports_hevc_hwdecode() ? "true" : "false",
        a->last_input_monitoring_trusted == 1 ? "true" : "false",
        a->last_accessibility_trusted == 1 ? "true" : "false",
        tb_night_shift_supported() ? "true" : "false",
        tb_true_tone_supported() ? "true" : "false");
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
    const int session_failed_without_frame = a->session_active && !a->have_video_frame;
    if (session_failed_without_frame) {
        a->zero_frame_disconnects++;
    } else if (a->have_video_frame) {
        a->zero_frame_disconnects = 0;
    }
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
    if (a->zero_frame_disconnects >= 2) {
        tb_receiver_set_control_status(a, "receiver.control.no_frames_permission");
    }
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
    a->last_clipboard_change_count = -1;
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
    tb_trim_regular_stream(stdout, TB_LAUNCH_LOG_MAX_BYTES);
    tb_trim_regular_stream(stderr, TB_LAUNCH_LOG_MAX_BYTES);
    int fullscreen = 1;
    int auto_start_sender = 1;
    int diagnostics_on_start = 0;
    int exit_code = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--windowed") == 0) fullscreen = 0;
        else if (strcmp(argv[i], "--no-auto-start") == 0) auto_start_sender = 0;
        else if (strcmp(argv[i], "--diagnostics-on-start") == 0) diagnostics_on_start = 1;
    }

    int instance_lock_fd = tb_receiver_single_instance_lock();
    if (instance_lock_fd == -2) {
        fprintf(stderr, "TBReceiver: another Receiver instance is already running\n");
        return 0;
    }
    if (instance_lock_fd < 0) {
        fprintf(stderr, "TBReceiver: warning, unable to create the single-instance lock\n");
    }

    struct tb_receiver_monitor_state startup_monitor_state;
    if (tb_receiver_monitor_state_load(&startup_monitor_state) != 0) {
        tb_receiver_monitor_state_default(&startup_monitor_state);
        fprintf(stderr, "TBReceiver: warning, unable to load monitor-mode state; using defaults\n");
    }
    if (!auto_start_sender) startup_monitor_state.auto_sender_enabled = 0;

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
    char usb_ip[64] = {0};
    char net_ip[64] = {0};
    char ethernet_ip[64] = {0};
    char wifi_ip[64] = {0};
    if (tb_net_get_tb_ip(tb_ip, sizeof(tb_ip)) == 0) {
        printf("TBReceiver: Thunderbolt Bridge IP = %s\n", tb_ip);
    } else {
        printf("TBReceiver: warning, no bridge IP detected (169.254.x.x)\n");
    }
    if (tb_net_get_link_local_ip(usb_ip, sizeof(usb_ip)) == 0) {
        printf("TBReceiver: Direct USB-NCM IP = %s\n", usb_ip);
    } else {
        printf("TBReceiver: warning, no direct USB-NCM/link-local IP detected\n");
    }
    if (tb_net_get_lan_ip(net_ip, sizeof(net_ip)) == 0) {
        printf("TBReceiver: Local network IP = %s\n", net_ip);
    } else {
        printf("TBReceiver: warning, no LAN IP detected (RFC1918 IPv4)\n");
    }
    if (tb_net_get_ethernet_ip(ethernet_ip, sizeof(ethernet_ip)) == 0) {
        printf("TBReceiver: Ethernet IP = %s\n", ethernet_ip);
    }
    if (tb_net_get_wifi_ip(wifi_ip, sizeof(wifi_ip)) == 0) {
        printf("TBReceiver: Wi-Fi IP = %s\n", wifi_ip);
    }
    printf("TBReceiver: listening on TCP port %d\n", TB_PORT);

    struct app a;
    memset(&a, 0, sizeof(a));
    a.server_fd = -1;
    a.client_fd = -1;
    a.last_clipboard_change_count = -1;
    tb_sender_control_init(&a.sender_control);
    a.auto_sender_enabled = startup_monitor_state.auto_sender_enabled;
    a.input_enabled = startup_monitor_state.input_enabled;
    a.input_sync_pending = 1;
    a.next_sender_control_ms = a.auto_sender_enabled ? now_ms() + 1500 : 0;
    snprintf(a.preferred_sender_action, sizeof(a.preferred_sender_action), "%s",
             startup_monitor_state.preferred_action);
    snprintf(a.control_status_key, sizeof(a.control_status_key), "%s",
             a.auto_sender_enabled ? "receiver.control.ready" : "receiver.control.stopped");
    snprintf(a.selected_path_key, sizeof(a.selected_path_key), "%s",
             tb_receiver_path_key_for_action(a.preferred_sender_action));
    snprintf(a.selected_path_id, sizeof(a.selected_path_id), "%s",
             tb_receiver_path_id_for_action(a.preferred_sender_action));
    {
        char host[96] = {0};
        if (gethostname(host, sizeof(host)) != 0 || host[0] == '\0') {
            snprintf(host, sizeof(host), "%s", "Receiver");
        }
        snprintf(a.bonjour_name, sizeof(a.bonjour_name), "TargetBridge %s", host);
    }
    snprintf(a.tb_ip_text, sizeof(a.tb_ip_text), "%s", tb_ip);
    snprintf(a.usb_ip_text, sizeof(a.usb_ip_text), "%s", usb_ip);
    snprintf(a.net_ip_text, sizeof(a.net_ip_text), "%s", net_ip);
    snprintf(a.ethernet_ip_text, sizeof(a.ethernet_ip_text), "%s", ethernet_ip);
    snprintf(a.wifi_ip_text, sizeof(a.wifi_ip_text), "%s", wifi_ip);
    snprintf(a.ip_text, sizeof(a.ip_text), "%s",
             tb_ip[0] ? tb_ip
                      : (usb_ip[0] ? usb_ip
                                   : (net_ip[0] ? net_ip : tb_i18n_get("receiver.network.not_detected"))));
    snprintf(a.language_pref, sizeof(a.language_pref), "%s", startup_language_pref);
    snprintf(a.input_control_mode, sizeof(a.input_control_mode), "%s", "off");
    a.last_input_monitoring_trusted = -1;
    a.last_accessibility_trusted = -1;
    a.sender_accessibility_trusted = 0;
    a.sender_accessibility_known = 0;
    tb_refresh_idle_localized_strings(&a);
    build_display_host(a.display_host, sizeof(a.display_host), a.ip_text,
                       tb_ip[0] || usb_ip[0] || net_ip[0]);
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

    if (diagnostics_on_start) {
        char diagnostics_path[PATH_MAX];
        if (tb_receiver_save_diagnostics(&a, diagnostics_path, sizeof(diagnostics_path)) != 0) {
            fprintf(stderr, "[diagnostics] startup diagnostic failed\n");
            exit_code = 1;
            g_term = 1;
        } else {
            fprintf(stderr, "[diagnostics] startup diagnostic saved: %s\n", diagnostics_path);
            g_term = 1;
        }
    }

    while (!g_term) {
        unsigned int disp_actions = tb_disp_poll_actions(a.disp);
        int socket_activity = 0;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.0, true);
        if (disp_actions & TB_DISP_ACTION_QUIT) {
            /* Receiver is an appliance-style login service. A clean close must
             * not leave a headless iMac unreachable; persist the safe stopped
             * state before launchd recreates the local dashboard. */
            a.auto_sender_enabled = 0;
            a.next_sender_control_ms = 0;
            tb_receiver_persist_monitor_state(&a);
            if (a.client_fd >= 0) close_client(&a);
            fprintf(stderr, "[main] local quit requested; monitor mode suspended\n");
            break;
        }
        if ((disp_actions & TB_DISP_ACTION_CYCLE_LANGUAGE) && a.client_fd < 0) {
            tb_receiver_cycle_language_preference(&a);
        }

        uint64_t t = now_ms();

        if (a.local_release_requested) {
            a.local_release_requested = 0;
            snprintf(a.input_control_mode, sizeof(a.input_control_mode), "%s", "off");
            tb_receiver_refresh_input_capture(&a);
            tb_receiver_input_log("[input] local control released");
        }

        if (a.local_stop_requested) {
            a.local_stop_requested = 0;
            if (a.client_fd >= 0) close_client(&a);
            tb_receiver_start_remote_action(&a, "stop", t);
        } else if (disp_actions & TB_DISP_ACTION_STOP_SENDER) {
            if (a.client_fd >= 0) close_client(&a);
            tb_receiver_start_remote_action(&a, "stop", t);
        } else if (disp_actions & TB_DISP_ACTION_START_AUTO) {
            tb_receiver_start_remote_action(&a, "path auto", t);
        } else if (disp_actions & TB_DISP_ACTION_PATH_THUNDERBOLT) {
            tb_receiver_start_remote_action(&a, "path thunderbolt", t);
        } else if (disp_actions & TB_DISP_ACTION_PATH_USB) {
            tb_receiver_start_remote_action(&a, "path usb", t);
        } else if (disp_actions & TB_DISP_ACTION_PATH_ETHERNET) {
            tb_receiver_start_remote_action(&a, "path ethernet", t);
        } else if (disp_actions & TB_DISP_ACTION_PATH_WIFI) {
            tb_receiver_start_remote_action(&a, "path wifi", t);
        } else if (disp_actions & TB_DISP_ACTION_TOGGLE_INPUT) {
            tb_receiver_start_input_action(&a, !a.input_enabled, t, 1);
        } else if (disp_actions & TB_DISP_ACTION_SETUP_INPUT) {
            tb_receiver_start_input_action(&a, 1, t, 1);
        } else if (disp_actions & TB_DISP_ACTION_SAVE_DIAGNOSTICS) {
            char diagnostics_path[PATH_MAX];
            if (tb_receiver_save_diagnostics(&a, diagnostics_path,
                                             sizeof(diagnostics_path)) == 0) {
                tb_receiver_set_control_status(&a, "receiver.control.diagnostics_saved");
                fprintf(stderr, "[diagnostics] saved: %s\n", diagnostics_path);
            } else {
                tb_receiver_set_control_status(&a, "receiver.control.diagnostics_failed");
                fprintf(stderr, "[diagnostics] unable to save report\n");
            }
        }

        tb_receiver_poll_remote_action(&a, t);
        if (a.auto_sender_enabled &&
            a.client_fd < 0 &&
            !tb_sender_control_busy(&a.sender_control) &&
            a.next_sender_control_ms > 0 &&
            t >= a.next_sender_control_ms) {
            if (a.input_sync_pending) {
                tb_receiver_start_input_action(&a, a.input_enabled, t, 0);
            } else {
                tb_receiver_start_remote_action(&a, a.preferred_sender_action, t);
            }
            /* A failed immediate launch sets its own earlier retry; otherwise
             * this guards against re-entering before the child completes. */
            if (tb_sender_control_busy(&a.sender_control)) {
                a.next_sender_control_ms = t + 30000;
            }
        }

        if (t - a.last_ip_check_ms >= 1000) {
            char refreshed_tb_ip[64] = {0};
            char refreshed_usb_ip[64] = {0};
            char refreshed_net_ip[64] = {0};
            char refreshed_ethernet_ip[64] = {0};
            char refreshed_wifi_ip[64] = {0};
            a.last_ip_check_ms = t;
            (void)tb_net_get_tb_ip(refreshed_tb_ip, sizeof(refreshed_tb_ip));
            (void)tb_net_get_link_local_ip(refreshed_usb_ip, sizeof(refreshed_usb_ip));
            (void)tb_net_get_lan_ip(refreshed_net_ip, sizeof(refreshed_net_ip));
            (void)tb_net_get_ethernet_ip(refreshed_ethernet_ip, sizeof(refreshed_ethernet_ip));
            (void)tb_net_get_wifi_ip(refreshed_wifi_ip, sizeof(refreshed_wifi_ip));

            const int have_refreshed_ip =
                refreshed_tb_ip[0] || refreshed_usb_ip[0] || refreshed_net_ip[0];
            const char *preferred_ip = refreshed_tb_ip[0] ? refreshed_tb_ip
                                     : (refreshed_usb_ip[0] ? refreshed_usb_ip
                                     : (refreshed_net_ip[0] ? refreshed_net_ip
                                     : tb_i18n_get("receiver.network.not_detected")));
            if (strcmp(a.tb_ip_text, refreshed_tb_ip) != 0 ||
                strcmp(a.usb_ip_text, refreshed_usb_ip) != 0 ||
                strcmp(a.net_ip_text, refreshed_net_ip) != 0 ||
                strcmp(a.ethernet_ip_text, refreshed_ethernet_ip) != 0 ||
                strcmp(a.wifi_ip_text, refreshed_wifi_ip) != 0 ||
                strcmp(a.ip_text, preferred_ip) != 0) {
                snprintf(a.tb_ip_text, sizeof(a.tb_ip_text), "%s", refreshed_tb_ip);
                snprintf(a.usb_ip_text, sizeof(a.usb_ip_text), "%s", refreshed_usb_ip);
                snprintf(a.net_ip_text, sizeof(a.net_ip_text), "%s", refreshed_net_ip);
                snprintf(a.ethernet_ip_text, sizeof(a.ethernet_ip_text), "%s", refreshed_ethernet_ip);
                snprintf(a.wifi_ip_text, sizeof(a.wifi_ip_text), "%s", refreshed_wifi_ip);
                snprintf(a.ip_text, sizeof(a.ip_text), "%s", preferred_ip);
                build_display_host(a.display_host, sizeof(a.display_host), preferred_ip, have_refreshed_ip);
                if (refreshed_tb_ip[0] != '\0') {
                    fprintf(stderr, "[main] Thunderbolt Bridge IP = %s\n", refreshed_tb_ip);
                }
                if (refreshed_usb_ip[0] != '\0') {
                    fprintf(stderr, "[main] Direct USB-NCM IP = %s\n", refreshed_usb_ip);
                }
                if (refreshed_net_ip[0] != '\0') {
                    fprintf(stderr, "[main] Local network IP = %s\n", refreshed_net_ip);
                }
                if (refreshed_ethernet_ip[0] != '\0') {
                    fprintf(stderr, "[main] Ethernet IP = %s\n", refreshed_ethernet_ip);
                }
                if (refreshed_wifi_ip[0] != '\0') {
                    fprintf(stderr, "[main] Wi-Fi IP = %s\n", refreshed_wifi_ip);
                }
                bonjour_update(&a, TB_PORT);
            }
        }

        /* Accept new client */
        if (a.client_fd < 0) {
            int c = tb_net_accept(a.server_fd);
            if (c >= 0) {
                if (!a.auto_sender_enabled) {
                    fprintf(stderr, "[main] rejecting client while monitor mode is suspended\n");
                    close(c);
                    continue;
                }
                a.client_fd = c;
                a.have_video_frame = 0;
                a.session_active = 0;
                a.reported_night_shift = -1;   /* force one report per session */
                a.reported_true_tone = -1;
                a.last_clipboard_change_count = -1;
                a.last_recv_ms = t;
                SDL_DisableScreenSaver();
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
                if (drain_result > 0) a.last_recv_ms = t;
                if (a.close_requested) {
                    close_client(&a);
                } else if (t - a.last_recv_ms >= TB_SENDER_IDLE_TIMEOUT_MS) {
                    /* The sender streams frames continuously and heartbeats
                     * every 2s. Total silence means it died without a FIN
                     * (crash, pulled cable, force sleep). Without this reap,
                     * the dead fd is held forever and — because the receiver
                     * is single-client — every future connect is locked out
                     * until the app is restarted. */
                    fprintf(stderr, "[main] no data from sender for %llu ms; closing stale session\n",
                            (unsigned long long)(t - a.last_recv_ms));
                    close_client(&a);
                }
            }
        }

        /* Receiver-side permissions are only an optional upgrade to the
         * fullscreen SDL path. Poll slowly to avoid waking TCC continuously
         * during a video session; the mandatory Sender permission arrives in
         * the heartbeat immediately when it changes. */
        if (t - a.last_permissions_poll_ms >= 5000) {
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
            tb_disp_render_status(a.disp, a.display_host, a.status_text, a.sender_text,
                                  a.panel_text, a.mode_text, a.language_text,
                                  a.permissions_text, a.control_text,
                                  a.selected_path_text, a.selected_path_id,
                                  a.input_enabled,
                                  tb_receiver_input_setup_needed(&a));
        } else if (!a.have_video_frame) {
            tb_disp_render_connecting(a.disp);
        }

        if (strcmp(a.input_control_mode, "receiverMaster") == 0 && a.client_fd >= 0) {
            if (t - a.last_clipboard_poll_ms >= 250) {
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
                    tb_receiver_send_input_button_event(&a, "leftDown", input_event.click_count);
                    break;
                case TB_INPUT_EVENT_LEFT_UP:
                    tb_receiver_send_input_button_event(&a, "leftUp", input_event.click_count);
                    break;
                case TB_INPUT_EVENT_RIGHT_DOWN:
                    tb_receiver_send_input_button_event(&a, "rightDown", input_event.click_count);
                    break;
                case TB_INPUT_EVENT_RIGHT_UP:
                    tb_receiver_send_input_button_event(&a, "rightUp", input_event.click_count);
                    break;
                case TB_INPUT_EVENT_OTHER_DOWN:
                    tb_receiver_send_input_button_event(&a, "otherDown", input_event.click_count);
                    break;
                case TB_INPUT_EVENT_OTHER_UP:
                    tb_receiver_send_input_button_event(&a, "otherUp", input_event.click_count);
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
                    snprintf(a.input_control_mode, sizeof(a.input_control_mode), "%s", "off");
                    tb_receiver_refresh_input_capture(&a);
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
    tb_sender_control_destroy(&a.sender_control);
    tb_receiver_stop_input_tap(&a);
    if (a.server_fd >= 0) close(a.server_fd);
    bonjour_deinit(&a);
    tb_parser_free(&a.parser);
    tb_dec_destroy(a.dec);
    if (a.audio_device != 0) {
        SDL_CloseAudioDevice(a.audio_device);
    }
    tb_disp_destroy(a.disp);
    if (instance_lock_fd >= 0) close(instance_lock_fd);
    fprintf(stderr, "[main] bye\n");
    return exit_code;
}
