#!/usr/bin/env python3
"""Run production socket draining against a fake reader and the real parser.

No sockets, receiver process, GUI or external systems are used. The reader stays
continuously readable, fragments large packets, or injects teardown/errors.
"""
import argparse
import os
import re
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

source_dir = Path(__file__).resolve().parents[1] / "src"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path, default=source_dir / "main.c")
args = parser.parse_args()
source = args.source.read_text()
start = source.index("static int drain_socket(")
end = source.index("\nstatic void write_be32", start)
function = source[start:end]
yield_block = source[source.index("        /* Yield when idle"):]
yield_expression = re.search(r"if \(([^\n]+)\) \{\s*SDL_Delay\(1\)", yield_block).group(1)
yield_function = "\nstatic int should_yield(struct app *a, int socket_activity) { return " + yield_expression.replace("a.", "a->") + "; }\n"
render_start = source.find("        if (tb_nonvideo_render_due(&a, t)) {")
if render_start < 0:
    render_start = source.index("        if (a.client_fd < 0 || !a.session_active) {")
render_end = source.index('        if (strcmp(a.input_control_mode, "receiverMaster")', render_start)
render_block = source[render_start:render_end].replace("&a", "a").replace("a.", "a->")
render_helper = ""
if "static int tb_nonvideo_render_due(" in source:
    helper_start = source.index("static int tb_nonvideo_render_due(")
    helper_end = source.index("\nstatic int drain_socket(", helper_start)
    render_helper = source[helper_start:helper_end]
render_function = "\nstatic void render_step(struct app *a, uint64_t t) { (void)t;\n" + render_block + "}\n"

fixture = r'''
#include "net.h"
#include "proto.h"
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
struct app {
    int client_fd, close_requested, have_video_frame, session_active;
    uint64_t last_nonvideo_render_ms;
    int last_nonvideo_state;
    void *disp;
    char display_host[1], status_text[1], sender_text[1], panel_text[1], mode_text[1], language_text[1], permissions_text[1];
    struct tb_parser parser;
};
static int status_renders, connecting_renders;
static void tb_disp_render_status(void *d, const char *h, const char *s, const char *sender,
                                 const char *panel, const char *mode, const char *language, const char *permissions) {
    (void)d;(void)h;(void)s;(void)sender;(void)panel;(void)mode;(void)language;(void)permissions;++status_renders;
}
static void tb_disp_render_connecting(void *d) { (void)d;++connecting_renders; }
static uint64_t clock_ms;
static size_t reads, received, packets, payload_bytes;
static int continuous, expensive, interrupt_first, eof;
static int require_direct_payload;
static size_t short_read_limit;
static struct app *reader_app;
static uint8_t *input;
static size_t input_size, input_offset;
static uint64_t now_ms(void) { return clock_ms; }
static ssize_t fake_read(int fd, void *output, size_t capacity) {
    (void)fd;
    ++reads;
    /* Bound a broken implementation so this regression itself never hangs. */
    if (reads > 8192) { errno = ELOOP; return -1; }
    if (interrupt_first && reads == 1) { errno = EINTR; return -1; }
    if (require_direct_payload && reader_app->parser.len >= TB_HDR_BYTES)
        assert(output == reader_app->parser.buf + reader_app->parser.len);
    if (short_read_limit && capacity > short_read_limit) capacity = short_read_limit;
    if (continuous) {
        uint8_t *b = output;
        /* Repeated 4096-byte heartbeat packets. */
        for (size_t i = 0; i < capacity; ++i) {
            size_t position = (received + i) % 4096;
            b[i] = position == 2 ? 0x0f : position == 3 ? 0xfc :
                   position == 4 ? TB_PKT_HEARTBEAT : 0;
        }
        received += capacity;
        return (ssize_t)capacity;
    }
    if (input_offset < input_size) {
        size_t n = input_size - input_offset;
        if (n > capacity) n = capacity;
        memcpy(output, input + input_offset, n);
        input_offset += n;
        received += n;
        return (ssize_t)n;
    }
    if (eof) return 0;
    errno = EAGAIN;
    return -1;
}
#define read fake_read
'''
checks = r'''
static void packet(uint8_t type, const uint8_t *data, size_t length, void *context) {
    struct app *a = context;
    ++packets;
    payload_bytes += length;
    if (type == TB_PKT_TEARDOWN) a->close_requested = 1;
    if (type == TB_PKT_RAW_FRAME) {
        assert(length > 0 && data[0] == 0x5a && data[length - 1] == 0x5a);
    }
    if (expensive) clock_ms += 9;
}
static void reset(struct app *a) {
    tb_parser_free(&a->parser);
    free(input);
    input = NULL;
    input_size = input_offset = 0;
    clock_ms = reads = received = packets = payload_bytes = 0;
    continuous = expensive = interrupt_first = eof = 0;
    require_direct_payload = 0; short_read_limit = 0; reader_app = a;
    a->close_requested = 0;
    tb_parser_init(&a->parser, packet, a);
}
static void set_packet(uint8_t type, size_t length) {
    input_size = length + 5;
    input = malloc(input_size);
    assert(input);
    uint32_t framed = (uint32_t)length + 1;
    input[0] = framed >> 24; input[1] = framed >> 16;
    input[2] = framed >> 8; input[3] = framed; input[4] = type;
    memset(input + 5, 0x5a, length);
}
int main(void) {
    struct app a = {0};
    tb_parser_init(&a.parser, packet, &a);
    reset(&a); continuous = 1;
    assert(drain_socket(&a) == 1);
    assert(received == 4 * 1024 * 1024 && packets > 0);

    reset(&a); continuous = expensive = 1;
    assert(drain_socket(&a) == 1);
    assert(packets > 0 && received <= 1024 * 1024); /* Callback yields before another read. */

    reset(&a); set_packet(TB_PKT_RAW_FRAME, 5 * 1024 * 1024);
    require_direct_payload = 1;
    assert(drain_socket(&a) == 1);
    assert(received == 4 * 1024 * 1024 && packets == 0 && a.parser.len == received);
    assert(drain_socket(&a) == 1);
    assert(packets == 1 && payload_bytes == 5 * 1024 * 1024 && a.parser.len == 0);

    reset(&a); set_packet(TB_PKT_TEARDOWN, 0);
    assert(drain_socket(&a) == 1);
    assert(a.close_requested && reads == 1);
    assert(drain_socket(&a) == 0 && reads == 1);

    reset(&a);
    assert(drain_socket(&a) == 0 && reads == 1);
    reset(&a); eof = 1;
    assert(drain_socket(&a) == -1 && reads == 1);
    reset(&a); interrupt_first = 1; set_packet(TB_PKT_HEARTBEAT, 0);
    assert(drain_socket(&a) == 1 && packets == 1 && reads == 3);

    reset(&a); set_packet(TB_PKT_TEST_DATA, 5 * 1024 * 1024);
    a.client_fd = 1; a.have_video_frame = 0;
    assert(drain_socket(&a) == 1 && received == 4 * 1024 * 1024 && packets == 0);
    assert(a.parser.len == 0 && a.parser.cap <= 1024 * 1024);
    assert(!should_yield(&a, 1));  /* Active cable-test traffic has no video. */
    assert(drain_socket(&a) == 1 && packets == 0);
    assert(drain_socket(&a) == 0 && should_yield(&a, 0));
    a.have_video_frame = 1;
    assert(!should_yield(&a, 1) && should_yield(&a, 0));
    a.client_fd = -1;
    assert(should_yield(&a, 1));

    reset(&a); short_read_limit = 3; interrupt_first = 1;
    set_packet(TB_PKT_RAW_FRAME, 19); require_direct_payload = 1;
    assert(drain_socket(&a) == 1 && packets == 1 && payload_bytes == 19);
    assert(a.parser.len == 0 && received == 24);
    assert(drain_socket(&a) == 0);  /* EAGAIN after partial header/body reads. */

    reset(&a); set_packet(TB_PKT_TEARDOWN, 0);
    input = realloc(input, 10); assert(input); input_size = 10;
    memcpy(input + 5, input, 5); input[9] = TB_PKT_HEARTBEAT;
    assert(drain_socket(&a) == 1 && a.close_requested && packets == 1);
    assert(received == 5); /* A following packet stays unread after teardown. */

    a.have_video_frame = a.session_active = 0;
    render_step(&a, 1000);
    for (uint64_t t = 1001; t < 1100; ++t) render_step(&a, t);
    assert(status_renders == 1);  /* No redraw for every 4 MiB socket drain. */
    render_step(&a, 1100);
    assert(status_renders == 2);
    a.client_fd = 1; a.session_active = 1;
    render_step(&a, 1101);
    assert(connecting_renders == 1);  /* State transitions repaint immediately. */
    render_step(&a, 1102);
    assert(connecting_renders == 1);
    render_step(&a, 1201);
    assert(connecting_renders == 2);  /* Spinner/expose can still refresh. */
    a.have_video_frame = 1;
    render_step(&a, 1202);
    assert(connecting_renders == 2);
    a.have_video_frame = 0;
    render_step(&a, 1203);
    assert(connecting_renders == 3);
    a.client_fd = -1;
    render_step(&a, 1204);
    assert(status_renders == 3);
    render_step(&a, 1);
    assert(status_renders == 4);  /* Rebase if the monotonic clock rewinds. */
    reset(&a);
    tb_parser_free(&a.parser);
    puts("socket drain: budgets, framing, discard, teardown, idle yield and bounded nonvideo rendering passed");
}
'''
with tempfile.TemporaryDirectory(prefix="targetbridge-drain-test-") as temporary:
    path = Path(temporary) / "socket_drain.c"
    path.write_text(fixture + function + yield_function + render_helper + render_function + checks)
    executable = path.with_suffix("")
    command = shlex.split(os.environ.get("CC", "cc")) + [
        "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter",
        "-I" + str(source_dir), str(path), str(source_dir / "net.c"),
        "-o", str(executable),
    ]
    if sys.platform == "darwin":
        command += ["-framework", "CoreFoundation", "-framework", "SystemConfiguration"]
    subprocess.run(command, check=True)
    subprocess.run([str(executable)], check=True)
