#!/usr/bin/env python3
"""Run production socket draining against a fake reader and the real parser.

No sockets, receiver process, GUI or external systems are used. The reader stays
continuously readable, fragments large packets, or injects teardown/errors.
"""
import argparse
import os
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
struct app { int client_fd, close_requested; struct tb_parser parser; };
static uint64_t clock_ms;
static size_t reads, received, packets, payload_bytes;
static int continuous, expensive, interrupt_first, eof;
static uint8_t *input;
static size_t input_size, input_offset;
static uint64_t now_ms(void) { return clock_ms; }
static ssize_t fake_read(int fd, void *output, size_t capacity) {
    (void)fd;
    ++reads;
    /* Bound a broken implementation so this regression itself never hangs. */
    if (reads > 64) { errno = ELOOP; return -1; }
    if (interrupt_first && reads == 1) { errno = EINTR; return -1; }
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
    if (type == TB_PKT_RAW_DPCM) {
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
    assert(reads == 4 && received == 4 * 1024 * 1024 && packets > 0);

    reset(&a); continuous = expensive = 1;
    assert(drain_socket(&a) == 1);
    assert(reads == 1);  /* A costly callback still yields before another read. */

    reset(&a); set_packet(TB_PKT_RAW_DPCM, 5 * 1024 * 1024);
    assert(drain_socket(&a) == 1);
    assert(reads == 4 && packets == 0 && a.parser.len == 4 * 1024 * 1024);
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
    reset(&a);
    tb_parser_free(&a.parser);
    puts("socket drain: byte/time budgets, cross-loop framing, teardown, EAGAIN/EOF/EINTR passed");
}
'''
with tempfile.TemporaryDirectory(prefix="targetbridge-drain-test-") as temporary:
    path = Path(temporary) / "socket_drain.c"
    path.write_text(fixture + function + checks)
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
