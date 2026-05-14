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

#include <SDL.h>

#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

struct app {
    struct tb_display *disp;
    struct tb_decoder *dec;
    struct tb_parser   parser;

    int      server_fd;
    int      client_fd;

    uint64_t frames;
    uint64_t last_fps_tick_ms;
    uint64_t last_fps_count;
    int      close_requested;
    int      have_video_frame;

    char     ip_text[64];
    char     status_text[128];
    char     sender_text[128];
    char     panel_text[128];
    char     mode_text[128];
};

static volatile sig_atomic_t g_term = 0;
static void on_sigint(int s) { (void)s; g_term = 1; }

static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ULL + ts.tv_nsec / 1000000ULL;
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

/* ---- Callbacks: decoder → display ------------------------------------ */

static void on_frame(const uint8_t *y, int y_stride,
                     const uint8_t *uv, int uv_stride,
                     int w, int h, void *ud) {
    struct app *a = (struct app *)ud;
    a->have_video_frame = 1;
    snprintf(a->status_text, sizeof(a->status_text), "%s", "stream attivo");
    snprintf(a->mode_text, sizeof(a->mode_text), "%d x %d px in ricezione", w, h);
    tb_disp_render_nv12(a->disp, y, y_stride, uv, uv_stride, w, h);
    a->frames++;
}

/* ---- Callbacks: parser → decoder ------------------------------------- */

static void on_packet(uint8_t type, const uint8_t *payload, size_t len, void *ud) {
    struct app *a = (struct app *)ud;
    switch (type) {
    case TB_PKT_HELLO_RECEIVER:
        extract_json_string_field(payload, len, "\"senderName\"", a->sender_text, sizeof(a->sender_text));
        if (a->sender_text[0] == '\0') {
            snprintf(a->sender_text, sizeof(a->sender_text), "%s", "sender collegato");
        }
        {
            char preset[64];
            char codec[64];
            int capture_w = 0;
            int capture_h = 0;
            preset[0] = '\0';
            codec[0] = '\0';
            extract_json_string_field(payload, len, "\"capturePreset\"", preset, sizeof(preset));
            extract_json_string_field(payload, len, "\"codec\"", codec, sizeof(codec));
            (void)extract_json_int_field(payload, len, "\"captureWidth\"", &capture_w);
            (void)extract_json_int_field(payload, len, "\"captureHeight\"", &capture_h);

            if (capture_w > 0 && capture_h > 0 && preset[0] != '\0' && codec[0] != '\0') {
                snprintf(a->mode_text, sizeof(a->mode_text), "%d x %d px richiesti (%s, %s)", capture_w, capture_h, preset, codec);
            } else if (capture_w > 0 && capture_h > 0 && preset[0] != '\0') {
                snprintf(a->mode_text, sizeof(a->mode_text), "%d x %d px richiesti (%s)", capture_w, capture_h, preset);
            } else if (capture_w > 0 && capture_h > 0 && codec[0] != '\0') {
                snprintf(a->mode_text, sizeof(a->mode_text), "%d x %d px richiesti (%s)", capture_w, capture_h, codec);
            } else if (capture_w > 0 && capture_h > 0) {
                snprintf(a->mode_text, sizeof(a->mode_text), "%d x %d px richiesti", capture_w, capture_h);
            }
        }
        fprintf(stderr, "[main] hello from sender\n");
        snprintf(a->status_text, sizeof(a->status_text), "%s", "sender connesso, profilo inviato");
        break;
    case TB_PKT_CREATE_SESSION_ACK:
        fprintf(stderr, "[main] sender session ack: %.*s\n", (int)len, (const char *)payload);
        snprintf(a->status_text, sizeof(a->status_text), "%s", "sessione accettata, attendo i frame");
        break;
    case TB_PKT_PARAM_SETS:
        /* tb_dec_set_param_sets is now a no-op if the sets are unchanged,
         * so we don't spam a log line per keyframe. */
        tb_dec_set_param_sets(a->dec, payload, len);
        break;
    case TB_PKT_FRAME:
        tb_dec_feed_frame(a->dec, payload, len);
        break;
    case TB_PKT_HEARTBEAT:
        break;
    case TB_PKT_TEARDOWN:
        fprintf(stderr, "[main] teardown requested by sender\n");
        snprintf(a->status_text, sizeof(a->status_text), "%s", "sessione chiusa dal sender");
        a->close_requested = 1;
        break;
    default:
        fprintf(stderr, "[main] unknown pkt type=0x%02x\n", type);
        break;
    }
}

/* ---- Networking helpers ---------------------------------------------- */

static int drain_socket(struct app *a) {
    uint8_t buf[131072];
    for (;;) {
        ssize_t n = read(a->client_fd, buf, sizeof(buf));
        if (n > 0) {
            if (tb_parser_feed(&a->parser, buf, (size_t)n) < 0) return -1;
        } else if (n == 0) {
            return -1;  /* peer closed */
        } else {
            if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
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

static void send_receiver_info(struct app *a) {
    struct tb_display_info info;
    if (tb_disp_get_info(a->disp, &info) < 0) return;

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
        "\"modeWidth\":2560,\"modeHeight\":1440,\"refreshRate\":60,"
        "\"hiDPI\":true,\"captureWidth\":2560,\"captureHeight\":1440}",
        escaped_name,
        info.active_w,
        info.active_h
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
                "[main] sent display profile: panel=%ux%u mode=2560x1440 hidpi name=%s\n",
                info.active_w, info.active_h, info.name);
    }
    free(pkt);
}

static void close_client(struct app *a) {
    if (a->client_fd >= 0) close(a->client_fd);
    a->client_fd = -1;
    a->close_requested = 0;
    a->have_video_frame = 0;
    tb_disp_set_connection_state(a->disp, 0);
    snprintf(a->status_text, sizeof(a->status_text), "%s", "in attesa del sender");
    snprintf(a->sender_text, sizeof(a->sender_text), "%s", "in attesa");
    tb_parser_free(&a->parser);
    tb_parser_init(&a->parser, on_packet, a);
    tb_dec_reset(a->dec);   /* fresh decoder for next session */
    fprintf(stderr, "[main] client disconnected\n");
}

/* ---- Main ------------------------------------------------------------ */

int main(int argc, char **argv) {
    int fullscreen = 1;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--windowed") == 0) fullscreen = 0;
    }

    signal(SIGINT,  on_sigint);
    signal(SIGTERM, on_sigint);
    signal(SIGPIPE, SIG_IGN);

    char ip[64] = {0};
    if (tb_net_get_tb_ip(ip, sizeof(ip)) == 0) {
        printf("TBReceiver: Thunderbolt Bridge IP = %s\n", ip);
    } else {
        printf("TBReceiver: warning, no bridge IP detected (169.254.x.x)\n");
    }
    printf("TBReceiver: listening on TCP port %d\n", TB_PORT);

    struct app a;
    memset(&a, 0, sizeof(a));
    a.server_fd = -1;
    a.client_fd = -1;
    snprintf(a.ip_text, sizeof(a.ip_text), "%s", ip[0] ? ip : "non rilevato");
    snprintf(a.status_text, sizeof(a.status_text), "%s", "in attesa del sender");
    snprintf(a.sender_text, sizeof(a.sender_text), "%s", "in attesa");
    snprintf(a.mode_text, sizeof(a.mode_text), "%s", "2560 x 1440 HiDPI su pannello 5K");

    a.disp = tb_disp_create(fullscreen);
    if (!a.disp) { fprintf(stderr, "tb_disp_create failed\n"); return 1; }

    struct tb_display_info boot_info;
    if (tb_disp_get_info(a.disp, &boot_info) == 0) {
        snprintf(a.panel_text, sizeof(a.panel_text), "%u x %u px (%s)",
                 boot_info.active_w, boot_info.active_h, boot_info.name);
    } else {
        snprintf(a.panel_text, sizeof(a.panel_text), "%s", "pannello 5K");
    }

    a.dec = tb_dec_create(on_frame, &a);
    if (!a.dec) { fprintf(stderr, "tb_dec_create failed\n"); tb_disp_destroy(a.disp); return 1; }

    tb_parser_init(&a.parser, on_packet, &a);

    a.server_fd = tb_net_listen(TB_PORT);
    if (a.server_fd < 0) { fprintf(stderr, "tb_net_listen failed\n"); return 1; }

    a.last_fps_tick_ms = now_ms();

    while (!g_term && !tb_disp_poll_quit(a.disp)) {
        /* Accept new client */
        if (a.client_fd < 0) {
            int c = tb_net_accept(a.server_fd);
            if (c >= 0) {
                a.client_fd = c;
                a.have_video_frame = 0;
                snprintf(a.status_text, sizeof(a.status_text), "%s", "sender collegato, negoziazione in corso");
                snprintf(a.sender_text, sizeof(a.sender_text), "%s", "identificazione in corso");
                fprintf(stderr, "[main] client connected\n");
                send_receiver_info(&a);
            }
        } else {
            if (drain_socket(&a) < 0) close_client(&a);
            else if (a.close_requested) close_client(&a);
        }

        if (a.client_fd < 0 || !a.have_video_frame) {
            tb_disp_render_status(a.disp, a.ip_text, a.status_text, a.sender_text, a.panel_text, a.mode_text);
        }

        /* FPS log */
        uint64_t t = now_ms();
        if (t - a.last_fps_tick_ms >= 1000) {
            uint64_t df = a.frames - a.last_fps_count;
            a.last_fps_count   = a.frames;
            a.last_fps_tick_ms = t;
            if (df > 0) fprintf(stderr, "[main] %llu fps\n", (unsigned long long)df);
        }

        /* Yield: don't burn a core when idle. */
        SDL_Delay(1);
    }

    if (a.client_fd >= 0) close(a.client_fd);
    if (a.server_fd >= 0) close(a.server_fd);
    tb_parser_free(&a.parser);
    tb_dec_destroy(a.dec);
    tb_disp_destroy(a.disp);
    fprintf(stderr, "[main] bye\n");
    return 0;
}
