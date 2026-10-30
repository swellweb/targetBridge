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
    p->discard_remaining = 0;
    p->write_capacity = 0;
    p->cb  = cb;
    p->ud  = ud;
}

void tb_parser_free(struct tb_parser *p) {
    free(p->buf);
    p->buf = NULL;
    p->len = p->cap = 0;
    p->discard_remaining = 0;
    p->write_capacity = 0;
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

int tb_parser_prepare_write(struct tb_parser *p, size_t limit,
                            uint8_t **dst, size_t *capacity) {
    if (!p) return -1;
    p->write_capacity = 0;
    if (dst) *dst = NULL;
    if (capacity) *capacity = 0;
    if (!dst || !capacity || !limit) return -1;

    size_t remaining;
    size_t offset = p->len;
    if (p->discard_remaining) {
        remaining = p->discard_remaining;
        if (remaining > 1024 * 1024) remaining = 1024 * 1024;
        offset = 0; /* Reuse bounded scratch; no discarded payload is retained. */
    } else if (p->len < TB_HDR_BYTES) {
        remaining = TB_HDR_BYTES - p->len;
    } else {
        const uint32_t pkt_len = read_be32(p->buf);
        if (pkt_len < 1 || pkt_len > 64u * 1024 * 1024) return -1;
        const size_t total = 4 + (size_t)pkt_len;
        if (p->len >= total) return -1;
        remaining = total - p->len;
    }
    const size_t take = limit < remaining ? limit : remaining;
    const size_t sentinel = p->discard_remaining ? 0 : 1;
    if (parser_reserve(p, offset + take + sentinel) < 0) return -1;
    *dst = p->buf + offset;
    *capacity = p->write_capacity = take;
    return 0;
}

int tb_parser_commit_write(struct tb_parser *p, size_t n) {
    if (!p) return -1;
    const size_t offered = p->write_capacity;
    p->write_capacity = 0;
    if (!offered || n > offered) return -1;
    if (!n) return 0;
    if (p->discard_remaining) {
        p->discard_remaining -= n;
        return 0;
    }
    p->len += n;
    if (p->len < TB_HDR_BYTES) return 0;
    const uint32_t pkt_len = read_be32(p->buf);
    if (pkt_len < 1 || pkt_len > 64u * 1024 * 1024) {
        fprintf(stderr, "[net] bad pkt_len=%u\n", pkt_len);
        return -1;
    }
    if (p->buf[4] == TB_PKT_TEST_DATA) {
        p->discard_remaining = (size_t)pkt_len - 1;
        p->len = 0;
        return 0;
    }
    const size_t total = 4 + (size_t)pkt_len;
    if (p->len == total) {
        /* No following header is buffered. The sentinel stays inside the
         * reservation, and callback payload ownership remains synchronous. */
        p->buf[total] = '\0';
        p->cb(p->buf[4], p->buf + TB_HDR_BYTES, (size_t)pkt_len - 1, p->ud);
        p->len = 0;
    }
    return 0;
}

int tb_parser_feed(struct tb_parser *p, const uint8_t *data, size_t n) {
    p->write_capacity = 0;
    if (n && !data) return -1;
    while (n) {
        if (p->discard_remaining) {
            const size_t take = n < p->discard_remaining ? n : p->discard_remaining;
            p->discard_remaining -= take;
            data += take; n -= take;
            continue;
        }
        uint8_t *dst;
        size_t take;
        if (tb_parser_prepare_write(p, n, &dst, &take) < 0) return -1;
        memcpy(dst, data, take);
        if (tb_parser_commit_write(p, take) < 0) return -1;
        data += take; n -= take;
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

#if defined(__APPLE__)
static int interface_matches_kind_in(CFArrayRef interfaces, const char *name,
                                     enum tb_lan_interface_kind kind) {
    if (!interfaces || !name || !*name) return 0;
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
    return matched;
}
#endif

static int interface_matches_kind(const char *name, enum tb_lan_interface_kind kind) {
    if (!name || !*name) return 0;
#if defined(__APPLE__)
    CFArrayRef interfaces = SCNetworkInterfaceCopyAll();
    if (!interfaces) return 0;
    const int matched = interface_matches_kind_in(interfaces, name, kind);
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

int tb_net_get_addresses(struct tb_net_addresses *addresses) {
    if (!addresses) return -1;
    memset(addresses, 0, sizeof(*addresses));
    struct ifaddrs *ifap = NULL;
    if (getifaddrs(&ifap) != 0) return -1;
#if defined(__APPLE__)
    CFArrayRef interfaces = NULL;
    int queried_interfaces = 0;
#endif
    for (const struct ifaddrs *p = ifap; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET || !p->ifa_name) continue;
        char host[NI_MAXHOST];
        if (getnameinfo(p->ifa_addr, sizeof(struct sockaddr_in),
                        host, sizeof(host), NULL, 0, NI_NUMERICHOST) != 0) continue;
        if (tb_net_is_link_local_ipv4(host)) {
            if (!addresses->tb_ip[0] && strncmp(p->ifa_name, "bridge", 6) == 0)
                snprintf(addresses->tb_ip, sizeof(addresses->tb_ip), "%s", host);
            if (!addresses->link_local_ip[0] && is_likely_lan_interface_name(p->ifa_name))
                snprintf(addresses->link_local_ip, sizeof(addresses->link_local_ip), "%s", host);
        }
        if (!is_rfc1918_ipv4(host) ||
            (addresses->ethernet_ip[0] && addresses->wifi_ip[0])) continue;
#if defined(__APPLE__)
        /* Type discovery can be expensive. Share one result across all LAN
         * candidates, and do not retry a failed query for every interface. */
        if (!queried_interfaces) {
            queried_interfaces = 1;
            interfaces = SCNetworkInterfaceCopyAll();
        }
        const int ethernet = !addresses->ethernet_ip[0] &&
            interface_matches_kind_in(interfaces, p->ifa_name, TB_LAN_INTERFACE_ETHERNET);
        const int wifi = !addresses->wifi_ip[0] &&
            interface_matches_kind_in(interfaces, p->ifa_name, TB_LAN_INTERFACE_WIFI);
#else
        const int ethernet = !addresses->ethernet_ip[0] &&
            interface_matches_kind(p->ifa_name, TB_LAN_INTERFACE_ETHERNET);
        const int wifi = !addresses->wifi_ip[0] &&
            interface_matches_kind(p->ifa_name, TB_LAN_INTERFACE_WIFI);
#endif
        if (ethernet) snprintf(addresses->ethernet_ip, sizeof(addresses->ethernet_ip), "%s", host);
        if (wifi) snprintf(addresses->wifi_ip, sizeof(addresses->wifi_ip), "%s", host);
    }
#if defined(__APPLE__)
    if (interfaces) CFRelease(interfaces);
#endif
    freeifaddrs(ifap);
    snprintf(addresses->lan_ip, sizeof(addresses->lan_ip), "%s",
             addresses->ethernet_ip[0] ? addresses->ethernet_ip : addresses->wifi_ip);
    return 0;
}
