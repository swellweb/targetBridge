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
    p->len = 0;
    p->cap = 0;
    p->cb  = cb;
    p->ud  = ud;
}

void tb_parser_free(struct tb_parser *p) {
    free(p->buf);
    p->buf = NULL;
    p->len = p->cap = 0;
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

static uint32_t read_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8)  |  (uint32_t)p[3];
}

int tb_parser_feed(struct tb_parser *p, const uint8_t *data, size_t n) {
    if (parser_reserve(p, p->len + n) < 0) return -1;
    memcpy(p->buf + p->len, data, n);
    p->len += n;

    size_t off = 0;
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
        p->cb(type, payload, plen, p->ud);
        off += 4 + pkt_len;
    }

    /* shift remainder to front */
    if (off > 0) {
        size_t rem = p->len - off;
        if (rem > 0) memmove(p->buf, p->buf + off, rem);
        p->len = rem;
    }
    return 0;
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
    /* disable Nagle for low latency */
    int yes = 1;
    setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
    return c;
}

/* ---- TB Bridge IP discovery ------------------------------------------- */

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
