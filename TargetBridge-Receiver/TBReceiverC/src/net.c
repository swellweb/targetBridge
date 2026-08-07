/* net.c — POSIX socket server + packet parser. */

#include "net.h"
#include "proto.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#include <SystemConfiguration/SystemConfiguration.h>
#endif

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
    if (parser_reserve(p, p->len + n + 1) < 0) return -1;  /* +1 for NUL sentinel */
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

enum tb_lan_interface_kind {
    TB_LAN_INTERFACE_ETHERNET = 1,
    TB_LAN_INTERFACE_WIFI = 2
};

static int interface_matches_kind(const char *name, enum tb_lan_interface_kind kind) {
    if (!name || !*name) return 0;
#if defined(__APPLE__)
    CFArrayRef interfaces = SCNetworkInterfaceCopyAll();
    if (!interfaces) return 0;
    int matched = 0;
    CFIndex count = CFArrayGetCount(interfaces);
    for (CFIndex index = 0; index < count; index++) {
        SCNetworkInterfaceRef interface = (SCNetworkInterfaceRef)CFArrayGetValueAtIndex(interfaces, index);
        CFStringRef bsd_name = SCNetworkInterfaceGetBSDName(interface);
        CFStringRef interface_type = SCNetworkInterfaceGetInterfaceType(interface);
        if (!bsd_name || !interface_type) continue;

        char candidate_name[IFNAMSIZ] = {0};
        if (!CFStringGetCString(bsd_name, candidate_name, sizeof(candidate_name), kCFStringEncodingUTF8)) continue;
        if (strcmp(candidate_name, name) != 0) continue;

        CFStringRef expected_type = kind == TB_LAN_INTERFACE_WIFI
            ? kSCNetworkInterfaceTypeIEEE80211
            : kSCNetworkInterfaceTypeEthernet;
        matched = CFEqual(interface_type, expected_type);
        break;
    }
    CFRelease(interfaces);
    return matched;
#else
    if (kind == TB_LAN_INTERFACE_WIFI) {
        return strncmp(name, "wlan", 4) == 0 || strncmp(name, "wifi", 4) == 0;
    }
    return strncmp(name, "en", 2) == 0 || strncmp(name, "eth", 3) == 0;
#endif
}

static int get_lan_ip_for_kind(char *buf, size_t bufsz, enum tb_lan_interface_kind kind) {
    struct ifaddrs *ifap = NULL;
    if (!buf || bufsz == 0) return -1;
    buf[0] = '\0';
    if (getifaddrs(&ifap) != 0) return -1;

    int ret = -1;
    for (struct ifaddrs *p = ifap; p; p = p->ifa_next) {
        if (!p->ifa_addr) continue;
        if (p->ifa_addr->sa_family != AF_INET) continue;
        if (!interface_matches_kind(p->ifa_name, kind)) continue;

        char host[NI_MAXHOST];
        if (getnameinfo(p->ifa_addr, sizeof(struct sockaddr_in),
                        host, sizeof(host), NULL, 0, NI_NUMERICHOST) == 0 &&
            is_rfc1918_ipv4(host)) {
            snprintf(buf, bufsz, "%s", host);
            ret = 0;
            break;
        }
    }
    freeifaddrs(ifap);
    return ret;
}

int tb_net_is_link_local_ipv4(const char *host) {
    unsigned int a = 0, b = 0, c = 0, d = 0;
    if (!host) return 0;
    if (sscanf(host, "%u.%u.%u.%u", &a, &b, &c, &d) != 4) return 0;
    return a == 169 && b == 254 && c <= 255 && d <= 255;
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

int tb_net_get_link_local_ip(char *buf, size_t bufsz) {
    struct ifaddrs *ifap = NULL;
    if (!buf || bufsz == 0) return -1;
    buf[0] = '\0';
    if (getifaddrs(&ifap) != 0) return -1;

    int ret = -1;
    for (struct ifaddrs *p = ifap; p; p = p->ifa_next) {
        if (!p->ifa_addr) continue;
        if (p->ifa_addr->sa_family != AF_INET) continue;
        if (!is_likely_lan_interface_name(p->ifa_name)) continue;

        char host[NI_MAXHOST];
        if (getnameinfo(p->ifa_addr, sizeof(struct sockaddr_in),
                        host, sizeof(host), NULL, 0, NI_NUMERICHOST) == 0 &&
            tb_net_is_link_local_ipv4(host)) {
            snprintf(buf, bufsz, "%s", host);
            ret = 0;
            break;
        }
    }
    freeifaddrs(ifap);
    return ret;
}

int tb_net_get_lan_ip(char *buf, size_t bufsz) {
    if (tb_net_get_ethernet_ip(buf, bufsz) == 0) return 0;
    return tb_net_get_wifi_ip(buf, bufsz);
}

int tb_net_get_ethernet_ip(char *buf, size_t bufsz) {
    return get_lan_ip_for_kind(buf, bufsz, TB_LAN_INTERFACE_ETHERNET);
}

int tb_net_get_wifi_ip(char *buf, size_t bufsz) {
    return get_lan_ip_for_kind(buf, bufsz, TB_LAN_INTERFACE_WIFI);
}
