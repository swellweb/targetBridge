#!/usr/bin/env python3
"""Execute production encoded-video handlers with a mocked decoder boundary.

Checks first-stage logs, bounded errors, full counters and reconnect reset.
No FFmpeg, SDL, network, GUI or user files are accessed.
"""
from pathlib import Path
import os
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "src/main.c").read_text()
struct_start = source.index("struct tb_video_diagnostics {")
struct_end = source.index("\n};", struct_start) + len("\n};")
functions_start = source.index("static void tb_video_diagnostics_reset(")
functions_end = source.index("/* ---- Callbacks: decoder → display", functions_start)
decoder_source = (root / "src/decoder.c").read_text()
log_start = decoder_source.index("static void log_decoder_error(")
log_end = decoder_source.index("/* Detect available HW device type", log_start)
reset_start = decoder_source.index("void tb_dec_reset(")
reset_end = decoder_source.index("void tb_dec_destroy(", reset_start)

fixture = r'''
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
struct tb_decoder {
    void *ctx;
    uint8_t *extradata;
    int extradata_size, opened;
    unsigned int logged_errors;
};
#define AV_ERROR_MAX_STRING_SIZE 64
static void av_strerror(int error, char *message, size_t length) {
    snprintf(message, length, "mock ffmpeg error %d", error);
}
static void avcodec_free_context(void **context) { *context = NULL; }
static void av_free(void *data) { free(data); }
static int param_status, feed_status, param_calls, feed_calls;
static char output[16384];
static size_t output_size;
static int tb_dec_set_param_sets(struct tb_decoder *d, const uint8_t *p, size_t n) {
    (void)d; (void)p; (void)n; ++param_calls; return param_status;
}
static int tb_dec_feed_frame(struct tb_decoder *d, const uint8_t *p, size_t n) {
    (void)d; (void)p; (void)n; ++feed_calls; return feed_status;
}
static int capture_log(FILE *stream, const char *format, ...) {
    (void)stream;
    va_list args;
    va_start(args, format);
    int length = vsnprintf(output + output_size, sizeof(output) - output_size, format, args);
    va_end(args);
    assert(length >= 0 && (size_t)length < sizeof(output) - output_size);
    output_size += (size_t)length;
    return length;
}
#define fprintf capture_log
'''
checks = r'''
static size_t occurrences(const char *text) {
    size_t count = 0;
    for (const char *p = output; (p = strstr(p, text)); p += strlen(text)) ++count;
    return count;
}
int main(void) {
    struct app a = {0};
    const uint8_t payload[] = {2, 3};
    for (int i = 0; i < 1000; ++i) {
        handle_encoded_param_sets(&a, payload, sizeof(payload));
        handle_encoded_frame(&a, payload, sizeof(payload));
        tb_video_diagnostics_decoded(&a, 4480, 2520, 4480, 4480);
    }
    assert(param_calls == 1000 && feed_calls == 1000);
    assert(a.video_diagnostics.param_sets == 1000);
    assert(a.video_diagnostics.encoded_packets == 1000);
    assert(a.video_diagnostics.decoded_frames == 1000);
    assert(occurrences("stage=param_sets_received") == 1);
    assert(occurrences("stage=param_sets_ready") == 1);
    assert(occurrences("stage=encoded_packet") == 1);
    assert(occurrences("stage=decoded_first_frame") == 1);
    assert(strstr(output, "size=4480x2520 strides=4480/4480"));

    param_status = -7; feed_status = -8;
    for (int i = 0; i < 1000; ++i) {
        handle_encoded_param_sets(&a, payload, sizeof(payload));
        handle_encoded_frame(&a, payload, sizeof(payload));
    }
    assert(a.video_diagnostics.param_errors == 1000);
    assert(a.video_diagnostics.decode_errors == 1000);
    assert(occurrences("stage=param_sets error=-7") == 3);
    assert(occurrences("stage=decode_packet error=-8") == 3);
    assert(occurrences("further errors suppressed") == 2);
    tb_video_diagnostics_finish(&a);
    assert(strstr(output, "param_sets=2000 encoded_packets=2000 decoded_frames=1000 param_errors=1000 decode_errors=1000"));
    assert(a.video_diagnostics.param_sets == 0 && a.video_diagnostics.encoded_packets == 0);
    assert(a.video_diagnostics.decoded_frames == 0 && a.video_diagnostics.param_errors == 0);
    assert(a.video_diagnostics.decode_errors == 0 && !a.video_diagnostics.param_sets_ready);

    /* A bad first parameter packet may recover later. Log readiness exactly
     * when it succeeds, then reset both success and error gates on reconnect. */
    handle_encoded_param_sets(&a, NULL, 0);
    assert(occurrences("stage=param_sets_received") == 2);
    assert(occurrences("stage=param_sets error=-7") == 4);
    assert(occurrences("stage=param_sets_ready") == 1);
    param_status = 0; feed_status = 0;
    handle_encoded_param_sets(&a, payload, sizeof(payload));
    handle_encoded_frame(&a, payload, sizeof(payload));
    tb_video_diagnostics_decoded(&a, 320, 180, 384, 384);
    assert(occurrences("stage=param_sets_ready") == 2);
    assert(occurrences("stage=encoded_packet") == 2);
    assert(occurrences("stage=decoded_first_frame") == 2);
    tb_video_diagnostics_reset(&a);
    assert(!a.video_diagnostics.param_sets_ready && a.video_diagnostics.param_errors == 0);
    struct tb_decoder decoder = {0};
    for (int i = 0; i < 1000; ++i) log_decoder_error(&decoder, "mock_decode_failure", -9);
    assert(occurrences("stage=mock_decode_failure") == 3);
    assert(occurrences("mock ffmpeg error -9") == 3);
    tb_dec_reset(&decoder);
    log_decoder_error(&decoder, "mock_decode_failure", -9);
    assert(occurrences("stage=mock_decode_failure") == 4);
    puts("video diagnostics: first stages, bounded failures, counters and reconnect passed");
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix="tb-video-diagnostics-") as directory:
    path = Path(directory)
    harness = path / "test_video_diagnostics.c"
    harness.write_text(fixture + source[struct_start:struct_end] +
                       "\nstruct app { struct tb_decoder *dec; struct tb_video_diagnostics video_diagnostics; };\n" +
                       source[functions_start:functions_end] + decoder_source[log_start:log_end] +
                       decoder_source[reset_start:reset_end] + checks)
    executable = path / "test_video_diagnostics"
    subprocess.run([*shlex.split(os.environ.get("CC", "cc")), "-std=c11", "-Wall", "-Wextra", "-Werror",
                    str(harness), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
