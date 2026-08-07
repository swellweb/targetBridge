/* net.c — POSIX socket server + packet parser. */

#include "net.h"
#include "proto.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

/* ---- Parser ----------------------------------------------------------- */

void tb_parser_init(struct tb_parser *p, tb_pkt_cb cb, void *ud) {
    p->buf = NULL;
    p->off = 0;
    p->len = 0;
    p->cap = 0;
    p->moved_bytes = 0;
    p->compact_bytes = 0;
    p->hold_bytes = 0;
    p->cb  = cb;
    p->ud  = ud;
    p->hold = 0;
    p->spare = NULL;
    p->spare_cap = 0;
    p->held = NULL;
    p->held_cap = 0;
}

void tb_parser_hold_current(struct tb_parser *p) { p->hold = 1; }

void tb_parser_set_spare(struct tb_parser *p, uint8_t *buf, size_t cap) {
    if (!buf) return;
    if (p->spare) { free(p->spare); }
    p->spare = buf;
    p->spare_cap = cap;
}

uint8_t *tb_parser_take_held(struct tb_parser *p, size_t *cap_out) {
    uint8_t *b = p->held;
    if (cap_out) *cap_out = p->held_cap;
    p->held = NULL;
    p->held_cap = 0;
    return b;
}

void tb_parser_free(struct tb_parser *p) {
    free(p->buf);
    free(p->spare);
    free(p->held);
    p->buf = p->spare = p->held = NULL;
    p->off = p->len = p->cap = p->spare_cap = p->held_cap = 0;
}

static int parser_reserve(struct tb_parser *p, size_t need) {
    if (p->cap >= need) return 0;
    size_t nc = p->cap ? p->cap : 65536;
    while (nc < need) nc *= 2;
    uint8_t *nb = (uint8_t *)realloc(p->buf, nc);
    if (!nb) return -1;
    p->buf = nb;
    p->cap = nc;
    return 0;
}

/* Reclaim the consumed prefix, but only when the copy pays for itself.
 *
 * Compacting moves `rem` bytes and frees `off`. Doing it whenever off > 0 is
 * what made dispatch quadratic. Requiring off >= rem means every move is at
 * most half the live data and reclaims at least as much as it moves, which
 * amortises to O(1) per byte: the cost of moving a byte is charged to the
 * consumed bytes that paid for the space, and each byte is charged once. */
static void parser_maybe_compact(struct tb_parser *p) {
    if (p->off == 0) return;
    size_t rem = p->len - p->off;
    if (rem == 0) { p->off = p->len = 0; return; }
    if (p->off >= rem) {
        p->moved_bytes += rem; p->compact_bytes += rem;
        memmove(p->buf, p->buf + p->off, rem);
        p->off = 0;
        p->len = rem;
    }
}

/* About to append `want` bytes: if that would grow the allocation and there is
 * a consumed prefix to reclaim, move instead of realloc. Unconditional here
 * rather than paid-for as above, because the alternative is a bigger copy plus
 * a permanently larger buffer — and it only runs when the buffer is otherwise
 * full, so it cannot become the per-packet cost that caused the stall. */
static void parser_reclaim_for(struct tb_parser *p, size_t want) {
    if (p->off == 0) return;
    if (p->len + want + 1 <= p->cap) return;
    size_t rem = p->len - p->off;
    if (rem > 0) { p->moved_bytes += rem; p->compact_bytes += rem; memmove(p->buf, p->buf + p->off, rem); }
    p->off = 0;
    p->len = rem;
}

static uint32_t read_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8)  |  (uint32_t)p[3];
}

/* Dispatch every complete packet currently buffered, then compact. Shared by
 * the copying (feed) and zero-copy (reserve/commit) ingest paths. */
static int parser_dispatch(struct tb_parser *p) {
    size_t off = p->off;
    while (p->len - off >= TB_HDR_BYTES) {
        uint32_t pkt_len = read_be32(p->buf + off);
        if (pkt_len < 1 || pkt_len > 64 * 1024 * 1024) {  /* sanity */
            fprintf(stderr, "[net] bad pkt_len=%u\n", pkt_len);
            return -1;
        }
        if (p->len - off < 4 + pkt_len) break;       /* incomplete */

        uint8_t        type    = p->buf[off + 4];
        const uint8_t *payload = p->buf + off + 5;
        size_t         plen    = pkt_len - 1;
        /* Write a NUL sentinel one byte past the payload so that string
         * functions in the callback (strstr, strchr, strtol, …) cannot
         * read beyond the packet boundary.  The +1 reservation above
         * guarantees this byte is always within the allocated buffer.
         * Save and restore the byte so a following packet's header is
         * not corrupted when two packets are contiguous in the buffer. */
        uint8_t       *sentinel = (uint8_t *)(payload + plen);
        uint8_t        saved    = *sentinel;
        *sentinel = '\0';
        p->cb(type, payload, plen, p->ud);
        *sentinel = saved;
        off += 4 + pkt_len;

        if (p->hold) {
            /* The callback kept this packet. Compacting would memmove the next
             * packet's bytes over the front of it, so instead move the (small)
             * remainder into a fresh buffer and yield this one whole. */
            p->hold = 0;
            size_t rem = p->len - off;
            uint8_t *nb = p->spare;
            size_t   nc = p->spare_cap;
            p->spare = NULL;
            p->spare_cap = 0;
            if (nc < rem + 1) {
                size_t want = rem + 65536;
                uint8_t *grown = (uint8_t *)realloc(nb, want);
                if (!grown) { free(nb); return -1; }
                nb = grown;
                nc = want;
            }
            if (rem > 0) { p->moved_bytes += rem; p->hold_bytes += rem; memcpy(nb, p->buf + off, rem); }
            /* Ownership moves to the caller; the payload pointer handed to the
             * callback stays valid because this buffer is not freed. */
            free(p->held);
            p->held     = p->buf;
            p->held_cap = p->cap;
            p->buf = nb;
            p->cap = nc;
            p->off = 0;
            p->len = rem;
            return 0;
        }
    }

    p->off = off;
    parser_maybe_compact(p);
    return 0;
}

int tb_parser_feed(struct tb_parser *p, const uint8_t *data, size_t n) {
    parser_reclaim_for(p, n);
    if (parser_reserve(p, p->len + n + 1) < 0) return -1;  /* +1 for NUL sentinel */
    memcpy(p->buf + p->len, data, n);
    p->len += n;
    return parser_dispatch(p);
}

int tb_parser_reserve_space(struct tb_parser *p, size_t want, uint8_t **out, size_t *avail) {
    /* Never offer more room than it takes to finish the packet being assembled.
     *
     * Reading past a packet boundary is what made the zero-copy handoff
     * expensive. tb_parser_hold_current() gives the caller the whole buffer, so
     * every byte sitting BEHIND the held packet has to be copied into a fresh
     * one first. Filling a 1 MiB window regardless of where the packet ends
     * meant routinely copying a megabyte of the next packets to hand over this
     * one -- measured at six bytes copied per byte received, and it grows with
     * how far behind the reader is, which is how a busy moment turned into a
     * stall that never recovered.
     *
     * Stopping on the boundary makes the remainder almost always empty, so the
     * handoff is a pointer swap. The cost is more read(2) calls -- a few hundred
     * a second against gigabytes of memcpy, which is not a trade worth
     * agonising over. */
    size_t buffered = p->len - p->off;
    if (buffered < TB_HDR_BYTES) {
        /* No header yet, so the packet's extent is unknown and any guess
         * overshoots. Take the header alone; the next call knows the length and
         * asks for exactly the rest. Two read(2)s per packet instead of one. */
        size_t missing = TB_HDR_BYTES - buffered;
        if (missing < want) want = missing;
    } else {
        uint32_t pkt_len = read_be32(p->buf + p->off);
        if (pkt_len >= 1 && pkt_len <= 64 * 1024 * 1024) {
            size_t need = (size_t)4 + pkt_len;
            if (need > buffered) {
                size_t missing = need - buffered;
                if (missing < want) want = missing;
            }
        }
    }
    parser_reclaim_for(p, want);
    if (parser_reserve(p, p->len + want + 1) < 0) return -1;  /* +1 for NUL sentinel */
    *out   = p->buf + p->len;
    /* Withhold the sentinel byte so parser_dispatch can always write it. */
    *avail = p->cap - p->len - 1;
    if (*avail > want) *avail = want;
    return 0;
}

int tb_parser_commit(struct tb_parser *p, size_t n) {
    p->len += n;
    return parser_dispatch(p);
}

/* ---- Server ----------------------------------------------------------- */

int tb_net_listen(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("[net] socket"); return -1; }

    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, sizeof(yes));

    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family      = AF_INET;
    a.sin_port        = htons(port);
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) < 0) {
        perror("[net] bind"); close(fd); return -1;
    }
    if (listen(fd, 1) < 0) {
        perror("[net] listen"); close(fd); return -1;
    }

    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    return fd;
}

int tb_net_accept(int server_fd) {
    int c = accept(server_fd, NULL, NULL);
    if (c < 0) return -1;
    int fl = fcntl(c, F_GETFL, 0);
    fcntl(c, F_SETFL, fl | O_NONBLOCK);
    int rcvbuf = 4 * 1024 * 1024;
    setsockopt(c, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
    /* disable Nagle for low latency */
    int yes = 1;
    setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
    /* Detect half-open peers (sender crashed / cable pulled without a FIN):
     * probe after 5s idle, every 5s, twice — the OS then errors the fd
     * instead of leaving the session wedged. Complements the app-level
     * idle watchdog in main.c. */
    setsockopt(c, SOL_SOCKET, SO_KEEPALIVE, &yes, sizeof(yes));
    int keep_idle = 5;
    setsockopt(c, IPPROTO_TCP, TCP_KEEPALIVE, &keep_idle, sizeof(keep_idle));
    int keep_intvl = 5;
    setsockopt(c, IPPROTO_TCP, TCP_KEEPINTVL, &keep_intvl, sizeof(keep_intvl));
    int keep_cnt = 2;
    setsockopt(c, IPPROTO_TCP, TCP_KEEPCNT, &keep_cnt, sizeof(keep_cnt));
    return c;
}

/* ---- TB Bridge IP discovery ------------------------------------------- */

static int is_likely_lan_interface_name(const char *name) {
    if (!name) return 0;
    if (strncmp(name, "lo", 2) == 0) return 0;
    if (strncmp(name, "utun", 4) == 0) return 0;
    if (strncmp(name, "awdl", 4) == 0) return 0;
    if (strncmp(name, "llw", 3) == 0) return 0;
    return strncmp(name, "en", 2) == 0 || strncmp(name, "eth", 3) == 0;
}

static int is_rfc1918_ipv4(const char *host) {
    if (!host) return 0;
    if (strncmp(host, "10.", 3) == 0) return 1;
    if (strncmp(host, "192.168.", 8) == 0) return 1;

    unsigned int a = 0, b = 0, c = 0, d = 0;
    if (sscanf(host, "%u.%u.%u.%u", &a, &b, &c, &d) != 4) return 0;
    return a == 172 && b >= 16 && b <= 31;
}

int tb_net_get_tb_ip(char *buf, size_t bufsz) {
    struct ifaddrs *ifap = NULL;
    if (getifaddrs(&ifap) != 0) return -1;

    int ret = -1;
    for (struct ifaddrs *p = ifap; p; p = p->ifa_next) {
        if (!p->ifa_addr) continue;
        if (p->ifa_addr->sa_family != AF_INET) continue;
        if (strncmp(p->ifa_name, "bridge", 6) != 0) continue;

        char host[NI_MAXHOST];
        if (getnameinfo(p->ifa_addr, sizeof(struct sockaddr_in),
                        host, sizeof(host), NULL, 0, NI_NUMERICHOST) == 0) {
            if (strncmp(host, "169.254.", 8) == 0) {
                snprintf(buf, bufsz, "%s", host);
                ret = 0;
                break;
            }
        }
    }
    freeifaddrs(ifap);
    return ret;
}

int tb_net_get_lan_ip(char *buf, size_t bufsz) {
    struct ifaddrs *ifap = NULL;
    if (getifaddrs(&ifap) != 0) return -1;

    int ret = -1;
    for (struct ifaddrs *p = ifap; p; p = p->ifa_next) {
        if (!p->ifa_addr) continue;
        if (p->ifa_addr->sa_family != AF_INET) continue;
        if (!is_likely_lan_interface_name(p->ifa_name)) continue;

        char host[NI_MAXHOST];
        if (getnameinfo(p->ifa_addr, sizeof(struct sockaddr_in),
                        host, sizeof(host), NULL, 0, NI_NUMERICHOST) == 0) {
            if (is_rfc1918_ipv4(host)) {
                snprintf(buf, bufsz, "%s", host);
                ret = 0;
                break;
            }
        }
    }
    freeifaddrs(ifap);
    return ret;
}
