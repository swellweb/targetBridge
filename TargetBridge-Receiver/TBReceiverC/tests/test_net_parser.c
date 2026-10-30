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

static void test_link_local_ipv4_classifier(void) {
    CHECK(tb_net_is_link_local_ipv4("169.254.189.3"), "USB-NCM link-local address");
    CHECK(tb_net_is_link_local_ipv4("169.254.0.1"), "link-local lower boundary");
    CHECK(tb_net_is_link_local_ipv4("169.254.255.254"), "link-local upper boundary");
    CHECK(!tb_net_is_link_local_ipv4("169.255.1.1"), "outside link-local prefix");
    CHECK(!tb_net_is_link_local_ipv4("10.77.77.2"), "private LAN is not link-local");
    CHECK(!tb_net_is_link_local_ipv4("not-an-ip"), "invalid address rejected");
    CHECK(!tb_net_is_link_local_ipv4(NULL), "NULL address rejected");
}

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

static void test_discarded_test_data_is_not_buffered(void) {
    struct tb_parser p;
    tb_parser_init(&p, capture_cb, NULL);
    reset_capture();
    const size_t plen = 4 * 1024 * 1024;
    uint8_t header[5], chunk[65536];
    memset(chunk, 0x5a, sizeof(chunk));
    put_be32(header, (uint32_t)plen + 1);
    header[4] = TB_PKT_TEST_DATA;
    for (size_t i = 0; i < sizeof(header); ++i)
        CHECK(tb_parser_feed(&p, header + i, 1) == 0, "split test header accepted");
    for (size_t off = 0; off < plen; off += sizeof(chunk))
        CHECK(tb_parser_feed(&p, chunk, sizeof(chunk)) == 0, "test payload discarded incrementally");
    CHECK(g_captured_count == 0, "discard-only test packets do not invoke payload callback");
    CHECK(p.len == 0, "no discarded payload is retained");
    CHECK(p.cap <= sizeof(chunk), "test stream does not allocate a full payload buffer");
    uint8_t heartbeat[5];
    build_packet(heartbeat, TB_PKT_HEARTBEAT, NULL, 0);
    CHECK(tb_parser_feed(&p, heartbeat, sizeof(heartbeat)) == 0, "packet after discard accepted");
    CHECK(g_captured_count == 1 && g_captured[0].type == TB_PKT_HEARTBEAT,
          "next packet begins at the exact discarded boundary");
    tb_parser_free(&p);
}

static void test_discard_preserves_mixed_packet_boundaries(void) {
    uint8_t stream[128], fake_teardown[5];
    build_packet(fake_teardown, TB_PKT_TEARDOWN, NULL, 0);
    size_t n = build_packet(stream, TB_PKT_HEARTBEAT, "before", 6);
    n += build_packet(stream + n, TB_PKT_TEST_DATA, fake_teardown, sizeof(fake_teardown));
    n += build_packet(stream + n, TB_PKT_TEST_DATA, NULL, 0);
    n += build_packet(stream + n, 0x7e, "unknown", 7);
    n += build_packet(stream + n, TB_PKT_TEARDOWN, NULL, 0);
    for (size_t split = 0; split <= n; ++split) {
        struct tb_parser p;
        tb_parser_init(&p, capture_cb, NULL);
        reset_capture();
        CHECK(tb_parser_feed(&p, stream, split) == 0, "mixed first fragment");
        CHECK(tb_parser_feed(&p, stream + split, n - split) == 0, "mixed second fragment");
        CHECK(g_captured_count == 3, "only control and unknown packets are delivered");
        CHECK(g_captured[0].type == TB_PKT_HEARTBEAT && g_captured[0].had_nul_sentinel,
              "preceding control retains sentinel");
        CHECK(g_captured[1].type == 0x7e && g_captured[1].len == 7 &&
              memcmp(g_captured[1].payload, "unknown", 7) == 0 && g_captured[1].had_nul_sentinel,
              "unknown packets retain bytes and sentinel");
        CHECK(g_captured[2].type == TB_PKT_TEARDOWN && g_captured[2].len == 0,
              "embedded fake packet is skipped, real teardown retained");
        CHECK(p.len == 0, "mixed feed fully consumed");
        tb_parser_free(&p);
    }
}

static void test_discard_length_validation_and_reset(void) {
    const uint32_t invalid[] = {0, 64u * 1024 * 1024 + 1, UINT32_MAX};
    for (size_t i = 0; i < sizeof(invalid) / sizeof(invalid[0]); ++i) {
        struct tb_parser p;
        uint8_t header[5];
        tb_parser_init(&p, capture_cb, NULL);
        reset_capture();
        put_be32(header, invalid[i]); header[4] = TB_PKT_TEST_DATA;
        CHECK(tb_parser_feed(&p, header, sizeof(header)) == -1,
              "discarded type still enforces length sanity");
        CHECK(g_captured_count == 0, "invalid discarded packet has no callback");
        tb_parser_free(&p);
    }
    struct tb_parser p;
    uint8_t header[5], chunk[65536] = {0};
    tb_parser_init(&p, capture_cb, NULL);
    reset_capture();
    put_be32(header, 64u * 1024 * 1024); header[4] = TB_PKT_TEST_DATA;
    CHECK(tb_parser_feed(&p, header, sizeof(header)) == 0, "exact maximum length accepted");
    size_t remaining = 64u * 1024 * 1024 - 1;
    while (remaining) {
        size_t n = remaining < sizeof(chunk) ? remaining : sizeof(chunk);
        CHECK(tb_parser_feed(&p, chunk, n) == 0, "maximum test frame streams without retention");
        remaining -= n;
    }
    CHECK(p.len == 0 && p.cap <= sizeof(chunk), "maximum test frame does not grow buffer");
    put_be32(header, 0); header[4] = TB_PKT_HEARTBEAT;
    CHECK(tb_parser_feed(&p, header, sizeof(header)) == -1,
          "invalid following header remains fatal after a discarded frame");
    tb_parser_free(&p);
    tb_parser_init(&p, capture_cb, NULL);
    put_be32(header, 1000); header[4] = TB_PKT_TEST_DATA;
    CHECK(tb_parser_feed(&p, header, sizeof(header)) == 0, "incomplete discarded frame begins");
    CHECK(tb_parser_feed(&p, chunk, 7) == 0, "incomplete discarded payload begins");
    tb_parser_free(&p);
    tb_parser_init(&p, capture_cb, NULL);
    reset_capture();
    build_packet(header, TB_PKT_HEARTBEAT, NULL, 0);
    CHECK(tb_parser_feed(&p, header, sizeof(header)) == 0 && g_captured_count == 1,
          "reconnect resets unfinished discard state");
    tb_parser_free(&p);
}

/* Model a nonblocking read: the kernel writes directly into the offered tail,
 * which remains borrowed only until commit (or a subsequent prepare/feed). */
static int direct_feed(struct tb_parser *p, const uint8_t *src, size_t n,
                       size_t read_limit) {
    while (n) {
        uint8_t *dst = NULL;
        size_t capacity = 0;
        if (tb_parser_prepare_write(p, read_limit, &dst, &capacity) < 0) return -1;
        CHECK(dst != NULL && capacity > 0 && capacity <= read_limit,
              "direct read offers a bounded destination");
        if (!p->discard_remaining)
            CHECK(dst == p->buf + p->len, "read destination is the parser tail");
        size_t take = n < capacity ? n : capacity;
        memcpy(dst, src, take);
        if (tb_parser_commit_write(p, take) < 0) return -1;
        src += take; n -= take;
    }
    return 0;
}

static void test_direct_fragmented_mixed_packets(void) {
    uint8_t stream[128], fake_teardown[5];
    build_packet(fake_teardown, TB_PKT_TEARDOWN, NULL, 0);
    size_t n = build_packet(stream, TB_PKT_HEARTBEAT, "before", 6);
    n += build_packet(stream + n, TB_PKT_TEST_DATA, fake_teardown, sizeof(fake_teardown));
    n += build_packet(stream + n, TB_PKT_TEST_DATA, NULL, 0);
    n += build_packet(stream + n, 0x7e, "unknown", 7);
    n += build_packet(stream + n, TB_PKT_TEARDOWN, NULL, 0);
    for (size_t split = 0; split <= n; ++split) {
        struct tb_parser p;
        tb_parser_init(&p, capture_cb, NULL); reset_capture();
        CHECK(direct_feed(&p, stream, split, 3) == 0, "short direct first fragment");
        CHECK(direct_feed(&p, stream + split, n - split, 1024) == 0,
              "direct mixed fragment completes");
        CHECK(g_captured_count == 3, "discard does not callback or parse embedded headers");
        CHECK(g_captured[0].type == TB_PKT_HEARTBEAT && g_captured[0].had_nul_sentinel,
              "direct control callback and sentinel");
        CHECK(g_captured[1].type == 0x7e && g_captured[1].len == 7 &&
              memcmp(g_captured[1].payload, "unknown", 7) == 0 &&
              g_captured[1].had_nul_sentinel, "direct unknown payload is unchanged");
        CHECK(g_captured[2].type == TB_PKT_TEARDOWN && g_captured[2].len == 0 &&
              g_captured[2].had_nul_sentinel, "direct empty control packet");
        CHECK(p.len == 0 && p.discard_remaining == 0, "direct fragments fully consumed");
        tb_parser_free(&p);
    }
}

static void test_direct_commit_contract_and_reset(void) {
    struct tb_parser p;
    uint8_t header[5], *dst = NULL;
    size_t capacity = 0;
    tb_parser_init(&p, capture_cb, NULL); reset_capture();
    CHECK(tb_parser_commit_write(&p, 1) == -1, "commit without prepare rejected");
    CHECK(tb_parser_prepare_write(&p, 0, &dst, &capacity) == -1, "zero read limit rejected");
    CHECK(tb_parser_prepare_write(&p, SIZE_MAX, &dst, &capacity) == 0 && capacity == 5,
          "untrusted read limit cannot exceed header boundary");
    CHECK(tb_parser_commit_write(&p, capacity + 1) == -1 && p.len == 0,
          "oversized commit cannot advance parser state");
    CHECK(tb_parser_commit_write(&p, 1) == -1, "failed commit invalidates old offer");
    CHECK(tb_parser_prepare_write(&p, 5, &dst, &capacity) == 0, "prepare after rejected commit");
    CHECK(tb_parser_commit_write(&p, 0) == 0 && p.len == 0,
          "zero-byte commit cancels read after EINTR/EAGAIN");
    CHECK(tb_parser_commit_write(&p, 1) == -1, "cancelled offer cannot be committed again");
    build_packet(header, TB_PKT_HEARTBEAT, NULL, 0);
    CHECK(direct_feed(&p, header, 2, 5) == 0 && p.len == 2, "partial direct header");
    CHECK(tb_parser_feed(&p, header + 2, 3) == 0 && g_captured_count == 1,
          "legacy feed can finish a direct header");
    CHECK(tb_parser_prepare_write(&p, 5, &dst, &capacity) == 0, "pending offer");
    CHECK(tb_parser_feed(&p, header, 5) == 0 && g_captured_count == 2,
          "feed invalidates a pending write offer");
    CHECK(tb_parser_commit_write(&p, 1) == -1, "stale offer after feed rejected");
    put_be32(header, 1000); header[4] = TB_PKT_TEST_DATA;
    CHECK(direct_feed(&p, header, 5, 5) == 0 && p.discard_remaining == 999,
          "direct discard starts after validated header");
    CHECK(tb_parser_prepare_write(&p, 100, &dst, &capacity) == 0, "discard offer");
    CHECK(tb_parser_commit_write(&p, capacity + 1) == -1 && p.discard_remaining == 999,
          "discard overcommit also rejected");
    CHECK(tb_parser_prepare_write(&p, 100, &dst, &capacity) == 0, "pending discard before reconnect");
    tb_parser_free(&p); tb_parser_init(&p, capture_cb, NULL); reset_capture();
    CHECK(tb_parser_commit_write(&p, 1) == -1 && p.discard_remaining == 0,
          "reconnect resets write offers and discard state");
    build_packet(header, TB_PKT_HEARTBEAT, NULL, 0);
    CHECK(direct_feed(&p, header, 5, 1) == 0 && g_captured_count == 1,
          "new session starts at its own header");
    tb_parser_free(&p);
}

static void test_direct_length_bounds(void) {
    const uint32_t invalid[] = {0, 64u * 1024 * 1024 + 1, UINT32_MAX};
    for (int test = 0; test < 2; ++test) {
        for (size_t i = 0; i < sizeof(invalid) / sizeof(invalid[0]); ++i) {
            struct tb_parser p; uint8_t header[5];
            tb_parser_init(&p, capture_cb, NULL); reset_capture();
            put_be32(header, invalid[i]); header[4] = test ? TB_PKT_TEST_DATA : 0x7e;
            CHECK(direct_feed(&p, header, 5, 1) == -1, "direct invalid length is fatal");
            CHECK(g_captured_count == 0 && p.cap <= 65536, "bad length allocates no payload");
            tb_parser_free(&p);
        }
        struct tb_parser p; uint8_t header[5];
        tb_parser_init(&p, capture_cb, NULL); reset_capture();
        put_be32(header, 64u * 1024 * 1024); header[4] = test ? TB_PKT_TEST_DATA : 0x7e;
        CHECK(direct_feed(&p, header, 5, 5) == 0, "direct maximum length accepted");
        CHECK(p.cap <= 65536, "header alone does not eagerly allocate a full frame");
        size_t remaining = 64u * 1024 * 1024 - 1;
        while (remaining) {
            uint8_t *dst = NULL; size_t capacity = 0;
            CHECK(tb_parser_prepare_write(&p, 1024 * 1024, &dst, &capacity) == 0,
                  "maximum direct frame grows incrementally");
            CHECK(capacity && capacity <= remaining && capacity <= 1024 * 1024,
                  "direct write stays inside remaining packet");
            if (!capacity || capacity > remaining) break;
            memset(dst, 0x5a, capacity);
            CHECK(tb_parser_commit_write(&p, capacity) == 0, "maximum direct frame commit");
            remaining -= capacity;
        }
        CHECK(remaining == 0 && p.len == 0 && !p.discard_remaining,
              "maximum direct frame completes exactly");
        if (test) {
            CHECK(g_captured_count == 0 && p.cap <= 1024 * 1024,
                  "discard uses at most 1 MiB scratch, not a full frame");
        } else {
            CHECK(g_captured_count == 1 && g_captured[0].len == 64u * 1024 * 1024 - 1 &&
                  g_captured[0].had_nul_sentinel, "maximum normal frame and sentinel delivered");
        }
        build_packet(header, TB_PKT_HEARTBEAT, NULL, 0);
        CHECK(direct_feed(&p, header, 5, 5) == 0,
              "maximum frame leaves next header aligned");
        tb_parser_free(&p);
    }
}

int main(void) {
    test_link_local_ipv4_classifier();
    test_single_packet_whole_feed();
    test_byte_by_byte_feed();
    test_two_contiguous_packets();
    test_split_across_feeds_with_remainder();
    test_zero_length_is_fatal();
    test_oversized_length_is_fatal();
    test_large_payload_roundtrip();
    test_discarded_test_data_is_not_buffered();
    test_discard_preserves_mixed_packet_boundaries();
    test_discard_length_validation_and_reset();
    test_direct_fragmented_mixed_packets();
    test_direct_commit_contract_and_reset();
    test_direct_length_bounds();

    if (g_failures == 0) {
        printf("net parser tests: %d checks passed\n", g_checks);
        return 0;
    }
    fprintf(stderr, "net parser tests: %d/%d checks FAILED\n", g_failures, g_checks);
    return 1;
}
