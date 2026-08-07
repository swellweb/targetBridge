/* test_net_parser.c — hardware-free unit tests for the streaming packet
 * parser in net.c (the framing layer every receiver session depends on).
 *
 * Build & run:  make test
 *
 * Only needs net.c + POSIX — no ffmpeg, no SDL, no Thunderbolt. */

#include "../src/net.h"
#include "../src/proto.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg) do {                                              \
    g_checks++;                                                            \
    if (!(cond)) {                                                         \
        g_failures++;                                                      \
        fprintf(stderr, "FAIL %s:%d — %s\n", __FILE__, __LINE__, (msg));   \
    }                                                                      \
} while (0)

/* ---- callback capture ------------------------------------------------- */

#define MAX_CAPTURED 16

struct captured_packet {
    uint8_t type;
    size_t  len;
    uint8_t payload[1024];
    int     had_nul_sentinel;   /* payload[len] was '\0' during the callback */
};

static struct captured_packet g_captured[MAX_CAPTURED];
static int g_captured_count = 0;

static void capture_cb(uint8_t type, const uint8_t *payload, size_t len, void *ud) {
    (void)ud;
    if (g_captured_count >= MAX_CAPTURED) return;
    struct captured_packet *c = &g_captured[g_captured_count++];
    c->type = type;
    c->len = len;
    if (len <= sizeof(c->payload)) memcpy(c->payload, payload, len);
    /* net.c promises a NUL one byte past the payload so string functions in
     * the callback cannot run off the end. */
    c->had_nul_sentinel = (payload[len] == '\0');
}

static void reset_capture(void) {
    memset(g_captured, 0, sizeof(g_captured));
    g_captured_count = 0;
}

/* ---- helpers ----------------------------------------------------------- */

static void put_be32(uint8_t *dst, uint32_t v) {
    dst[0] = (uint8_t)(v >> 24);
    dst[1] = (uint8_t)(v >> 16);
    dst[2] = (uint8_t)(v >> 8);
    dst[3] = (uint8_t)v;
}

/* Builds [4B BE len][1B type][payload] into buf; returns total size. */
static size_t build_packet(uint8_t *buf, uint8_t type, const void *payload, size_t plen) {
    put_be32(buf, (uint32_t)(1 + plen));
    buf[4] = type;
    if (plen) memcpy(buf + 5, payload, plen);
    return 5 + plen;
}

/* ---- tests ------------------------------------------------------------- */

static void test_single_packet_whole_feed(void) {
    struct tb_parser p;
    tb_parser_init(&p, capture_cb, NULL);
    reset_capture();

    uint8_t pkt[64];
    size_t n = build_packet(pkt, TB_PKT_HELLO_RECEIVER, "hi", 2);

    CHECK(tb_parser_feed(&p, pkt, n) == 0, "feed should succeed");
    CHECK(g_captured_count == 1, "exactly one packet");
    CHECK(g_captured[0].type == TB_PKT_HELLO_RECEIVER, "type preserved");
    CHECK(g_captured[0].len == 2, "payload length preserved");
    CHECK(memcmp(g_captured[0].payload, "hi", 2) == 0, "payload bytes preserved");
    CHECK(g_captured[0].had_nul_sentinel, "NUL sentinel past payload");

    tb_parser_free(&p);
}

static void test_byte_by_byte_feed(void) {
    struct tb_parser p;
    tb_parser_init(&p, capture_cb, NULL);
    reset_capture();

    uint8_t pkt[64];
    size_t n = build_packet(pkt, TB_PKT_HEARTBEAT, "\x01\x02\x03", 3);

    for (size_t i = 0; i < n; i++) {
        CHECK(tb_parser_feed(&p, pkt + i, 1) == 0, "fragmented feed should succeed");
        if (i < n - 1) {
            CHECK(g_captured_count == 0, "must not fire before final byte");
        }
    }
    CHECK(g_captured_count == 1, "fires exactly once at final byte");
    CHECK(g_captured[0].len == 3, "payload length preserved across fragments");

    tb_parser_free(&p);
}

static void test_two_contiguous_packets(void) {
    struct tb_parser p;
    tb_parser_init(&p, capture_cb, NULL);
    reset_capture();

    uint8_t buf[128];
    size_t n1 = build_packet(buf, TB_PKT_HELLO_RECEIVER, "first", 5);
    size_t n2 = build_packet(buf + n1, TB_PKT_HEARTBEAT, "second!", 7);

    CHECK(tb_parser_feed(&p, buf, n1 + n2) == 0, "feed should succeed");
    CHECK(g_captured_count == 2, "both packets fire");
    CHECK(g_captured[0].type == TB_PKT_HELLO_RECEIVER, "first type");
    CHECK(memcmp(g_captured[0].payload, "first", 5) == 0, "first payload");
    /* The NUL sentinel for packet 1 lands on packet 2's length byte; the
     * save/restore in net.c must leave packet 2 intact. */
    CHECK(g_captured[1].type == TB_PKT_HEARTBEAT, "second type intact after sentinel restore");
    CHECK(g_captured[1].len == 7, "second length intact");
    CHECK(memcmp(g_captured[1].payload, "second!", 7) == 0, "second payload intact");

    tb_parser_free(&p);
}

static void test_split_across_feeds_with_remainder(void) {
    struct tb_parser p;
    tb_parser_init(&p, capture_cb, NULL);
    reset_capture();

    uint8_t buf[128];
    size_t n1 = build_packet(buf, TB_PKT_PARAM_SETS, "abcd", 4);
    size_t n2 = build_packet(buf + n1, TB_PKT_FRAME, "efghij", 6);

    /* Feed 1.5 packets, then the rest. */
    size_t first_chunk = n1 + 3;
    CHECK(tb_parser_feed(&p, buf, first_chunk) == 0, "first chunk ok");
    CHECK(g_captured_count == 1, "only complete packet fires");
    CHECK(tb_parser_feed(&p, buf + first_chunk, n1 + n2 - first_chunk) == 0, "second chunk ok");
    CHECK(g_captured_count == 2, "remainder completes second packet");
    CHECK(g_captured[1].type == TB_PKT_FRAME, "second packet type");
    CHECK(memcmp(g_captured[1].payload, "efghij", 6) == 0, "second packet payload");

    tb_parser_free(&p);
}

static void test_zero_length_is_fatal(void) {
    struct tb_parser p;
    tb_parser_init(&p, capture_cb, NULL);
    reset_capture();

    uint8_t bad[5] = {0x00, 0x00, 0x00, 0x00, 0x30};
    CHECK(tb_parser_feed(&p, bad, sizeof(bad)) == -1, "pkt_len=0 must be rejected");
    CHECK(g_captured_count == 0, "no callback for corrupt framing");

    tb_parser_free(&p);
}

static void test_oversized_length_is_fatal(void) {
    struct tb_parser p;
    tb_parser_init(&p, capture_cb, NULL);
    reset_capture();

    uint8_t bad[5];
    put_be32(bad, 64u * 1024 * 1024 + 1);  /* one past the 64 MiB sanity cap */
    bad[4] = 0x21;
    CHECK(tb_parser_feed(&p, bad, sizeof(bad)) == -1, "oversized pkt_len must be rejected");

    uint8_t worst[5] = {0xFF, 0xFF, 0xFF, 0xFF, 0x21};
    struct tb_parser p2;
    tb_parser_init(&p2, capture_cb, NULL);
    CHECK(tb_parser_feed(&p2, worst, sizeof(worst)) == -1, "0xFFFFFFFF pkt_len must be rejected");

    tb_parser_free(&p);
    tb_parser_free(&p2);
}

static void test_large_payload_roundtrip(void) {
    struct tb_parser p;
    tb_parser_init(&p, capture_cb, NULL);
    reset_capture();

    size_t plen = 1024 * 1024;  /* 1 MiB, exercises parser_reserve growth */
    uint8_t *pkt = malloc(5 + plen);
    CHECK(pkt != NULL, "alloc");
    if (!pkt) return;
    put_be32(pkt, (uint32_t)(1 + plen));
    pkt[4] = TB_PKT_FRAME;
    for (size_t i = 0; i < plen; i++) pkt[5 + i] = (uint8_t)(i * 31);

    /* Feed in 64 KiB slices like a real socket drain. */
    size_t off = 0, total = 5 + plen;
    while (off < total) {
        size_t chunk = total - off > 65536 ? 65536 : total - off;
        CHECK(tb_parser_feed(&p, pkt + off, chunk) == 0, "chunked feed ok");
        off += chunk;
    }
    CHECK(g_captured_count == 1, "large packet fires once");
    CHECK(g_captured[0].len == plen, "large payload length preserved");

    free(pkt);
    tb_parser_free(&p);
}

/* ---- the stall this parser was rewritten to prevent ------------------- */

/* Drives the parser exactly the way link_reader_main does: reserve a 1 MiB
 * window, copy socket bytes into it, commit, and hand off video packets with
 * tb_parser_hold_current() -- recycling the yielded buffer as the next spare.
 *
 * Reproducing the shape matters. The failure was never a wrong packet; it was
 * the COST of a right one growing with how far behind the reader had fallen,
 * which is only visible when packets are large, reads are chunked, and a
 * backlog is present all at once. */
struct replay {
    struct tb_parser *p;
    int   video_seen;
    int   control_seen;
    size_t video_bytes;
};

static void replay_cb(uint8_t type, const uint8_t *payload, size_t len, void *ud) {
    struct replay *r = (struct replay *)ud;
    (void)payload;
    if (type == 0x27) {                 /* stand-in for a DPCM band */
        r->video_seen++;
        r->video_bytes += len;
        tb_parser_hold_current(r->p);   /* what the real reader does */
    } else {
        r->control_seen++;
    }
}

static size_t append_packet(uint8_t *dst, size_t at, uint8_t type, size_t plen, uint8_t fill) {
    uint32_t pkt_len = (uint32_t)(1 + plen);
    dst[at+0] = (uint8_t)(pkt_len >> 24); dst[at+1] = (uint8_t)(pkt_len >> 16);
    dst[at+2] = (uint8_t)(pkt_len >> 8);  dst[at+3] = (uint8_t)pkt_len;
    dst[at+4] = type;
    memset(dst + at + 5, fill, plen);
    return at + 5 + plen;
}

static void test_backlog_cost_stays_linear(void) {
    /* 24 bands of 512 KiB with a small control packet between each, which is
     * how the wire actually looks: DPCM bands interleaved with audio/control. */
    const int    BANDS    = 24;
    const size_t BAND     = 512 * 1024;
    const size_t CTRL     = 128;
    const size_t READ     = 1024 * 1024;   /* link_reader_main's window */

    size_t stream_cap = (size_t)BANDS * (BAND + CTRL + 16);
    uint8_t *stream = (uint8_t *)malloc(stream_cap);
    CHECK(stream != NULL, "replay stream allocated");
    if (!stream) return;

    size_t total = 0;
    for (int i = 0; i < BANDS; ++i) {
        total = append_packet(stream, total, 0x10, CTRL, (uint8_t)i);
        total = append_packet(stream, total, 0x27, BAND, (uint8_t)i);
    }

    struct tb_parser p;
    struct replay r;
    memset(&r, 0, sizeof(r));
    tb_parser_init(&p, replay_cb, &r);
    r.p = &p;

    size_t fed = 0;
    while (fed < total) {
        uint8_t *dst = NULL; size_t avail = 0;
        CHECK(tb_parser_reserve_space(&p, READ, &dst, &avail) == 0, "reserve ok");
        size_t n = total - fed;
        if (n > avail) n = avail;
        if (n > READ)  n = READ;          /* a socket read is bounded */
        memcpy(dst, stream + fed, n);
        fed += n;
        CHECK(tb_parser_commit(&p, n) == 0, "commit ok");

        size_t held_cap = 0;
        uint8_t *held = tb_parser_take_held(&p, &held_cap);
        if (held) tb_parser_set_spare(&p, held, held_cap);   /* recycle */
    }

    /* A hold returns from dispatch immediately, so whatever was already
     * buffered behind the held packet waits for the next commit. The real
     * reader gets those from the next socket read; at end of stream there is
     * none, so drain explicitly. */
    for (;;) {
        int before = r.video_seen + r.control_seen;
        CHECK(tb_parser_commit(&p, 0) == 0, "drain commit ok");
        size_t held_cap = 0;
        uint8_t *held = tb_parser_take_held(&p, &held_cap);
        if (held) tb_parser_set_spare(&p, held, held_cap);
        if (r.video_seen + r.control_seen == before) break;
    }

    CHECK(r.video_seen == BANDS, "every band dispatched");
    CHECK(r.control_seen == BANDS, "every control packet dispatched");
    CHECK(r.video_bytes == (size_t)BANDS * BAND, "band payload bytes intact");

    /* THE ASSERTION THAT MATTERS.
     *
     * Cost must scale with the stream, not with the stream times the number of
     * packets in it. Four bytes shuffled per byte delivered is generous for the
     * offset parser and unreachable for one that compacts on every packet --
     * that one moves most of the buffer per packet, which at this size is an
     * order of magnitude more. */
    /* Was 6 bytes copied per byte received before the read was bounded to the
     * packet boundary (75 MB for this 12 MB stream, all of it the handoff).
     * A quarter of the stream is far under that and still leaves room for the
     * odd partial read; anything approaching 1x means the handoff is copying
     * whole packets again. */
    size_t budget = total / 4;
    printf("  parser copied %zu bytes for %zu received (%.2fx) "
           "[compact %zu, hold %zu]\n",
           p.moved_bytes, total, (double)p.moved_bytes / (double)total,
           p.compact_bytes, p.hold_bytes);
    CHECK(p.moved_bytes <= budget, "per-packet cost does not scale with backlog");

    tb_parser_free(&p);
    free(stream);
}

/* The offset must not change what the parser reports: same packets, same
 * order, same payloads, however the bytes are sliced across reads. */
static void test_offset_preserves_framing(void) {
    struct tb_parser p;
    tb_parser_init(&p, capture_cb, NULL);
    g_captured_count = 0;

    uint8_t buf[4096];
    size_t total = 0;
    for (int i = 0; i < 12; ++i)
        total = append_packet(buf, total, (uint8_t)(0x40 + i), 7 + i * 3, (uint8_t)(i + 1));

    /* Awkward slice size: never aligned to a packet boundary. */
    for (size_t off = 0; off < total; off += 13) {
        size_t chunk = total - off < 13 ? total - off : 13;
        CHECK(tb_parser_feed(&p, buf + off, chunk) == 0, "odd-sliced feed ok");
    }

    CHECK(g_captured_count == 12, "all 12 packets dispatched across odd slices");
    for (int i = 0; i < g_captured_count && i < 12; ++i) {
        CHECK(g_captured[i].type == (uint8_t)(0x40 + i), "type in order");
        CHECK(g_captured[i].len == (size_t)(7 + i * 3), "length preserved");
        CHECK(g_captured[i].payload[0] == (uint8_t)(i + 1), "payload preserved");
        CHECK(g_captured[i].had_nul_sentinel, "NUL sentinel still written");
    }
    /* Whatever the cursor did, the buffer must not have grown without bound. */
    CHECK(p.len - p.off == 0, "no bytes left stranded behind the cursor");

    tb_parser_free(&p);
}

int main(void) {
    test_single_packet_whole_feed();
    test_byte_by_byte_feed();
    test_two_contiguous_packets();
    test_split_across_feeds_with_remainder();
    test_zero_length_is_fatal();
    test_oversized_length_is_fatal();
    test_large_payload_roundtrip();
    test_offset_preserves_framing();
    test_backlog_cost_stays_linear();

    if (g_failures == 0) {
        printf("net parser tests: %d checks passed\n", g_checks);
        return 0;
    }
    fprintf(stderr, "net parser tests: %d/%d checks FAILED\n", g_failures, g_checks);
    return 1;
}
