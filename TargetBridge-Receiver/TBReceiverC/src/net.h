/* net.h — POSIX socket server + packet parser.
 * No ObjC, no ARC, no autoreleasepool. Pure C.
 */

#ifndef TB_NET_H
#define TB_NET_H

#include <stdint.h>
#include <stddef.h>

/* Packet callback: called for each complete packet except discard-only
 * TB_PKT_TEST_DATA. Delivered payloads have a NUL sentinel at payload[len]. */
typedef void (*tb_pkt_cb)(uint8_t type, const uint8_t *payload, size_t len, void *ud);

/* Streaming packet parser (handles fragmented TCP reads). */
struct tb_parser {
    uint8_t   *buf;
    size_t     len;     /* used bytes */
    size_t     cap;     /* allocated capacity */
    size_t     discard_remaining; /* validated TEST_DATA payload not yet read */
    size_t     write_capacity; /* outstanding direct-read offer, 0 if none */
    tb_pkt_cb  cb;
    void      *ud;
};

void tb_parser_init  (struct tb_parser *p, tb_pkt_cb cb, void *ud);
void tb_parser_free  (struct tb_parser *p);
int  tb_parser_feed  (struct tb_parser *p, const uint8_t *data, size_t n);

/* Borrow a writable tail for a nonblocking socket read. The offer is bounded
 * by limit and the current header/payload boundary; TEST_DATA uses at most
 * 1 MiB of reusable scratch. No full-packet allocation is made from a header.
 * Commit only the actual bytes read; commit(0) cancels an EINTR/EAGAIN/EOF read.
 * Every offer is invalidated by commit, prepare, feed or free. Never retain the
 * pointer across those operations or call these APIs concurrently/reentrantly.
 * Both return 0 on success, -1 on invalid framing, allocation/API error. */
int tb_parser_prepare_write(struct tb_parser *p, size_t limit,
                            uint8_t **dst, size_t *capacity);
int tb_parser_commit_write(struct tb_parser *p, size_t n);

/* Server: returns listening fd (>=0) or -1 on failure. Non-blocking. */
int  tb_net_listen   (uint16_t port);

/* Accept one client. Returns client fd or -1. Sets non-blocking. */
int  tb_net_accept   (int server_fd);

struct tb_net_addresses {
    char tb_ip[64];
    char link_local_ip[64];
    char lan_ip[64];
    char ethernet_ip[64];
    char wifi_ip[64];
};

/* One interface snapshot for UI/Bonjour refresh: at most one getifaddrs and
 * one macOS interface-type enumeration (only for RFC1918 candidates).
 * Each field selects the same first matching address as the getter below;
 * LAN prefers Ethernet, then Wi-Fi. All fields are cleared before querying.
 * Returns -1 for NULL output/getifaddrs failure, otherwise 0. Missing addresses
 * stay empty; unavailable type information leaves LAN fields empty without
 * losing independently discovered bridge/link-local addresses. */
int tb_net_get_addresses(struct tb_net_addresses *addresses);

/* Returns IP address of first bridge* interface (Thunderbolt Bridge) in buf.
 * buf size must be at least INET_ADDRSTRLEN (16) bytes. Returns 0 on success. */
int  tb_net_get_tb_ip(char *buf, size_t bufsz);

/* Returns IP address of the first non-Thunderbolt enX/ethX interface using
 * IPv4 link-local addressing (169.254/16). macOS exposes direct USB-NCM
 * Mac-to-Mac links this way. Returns 0 on success. */
int  tb_net_get_link_local_ip(char *buf, size_t bufsz);

/* Returns IP address of a likely local LAN interface (for example en0/eth0, RFC1918 IPv4).
 * buf size must be at least INET_ADDRSTRLEN (16) bytes. Returns 0 on success. */
int  tb_net_get_lan_ip(char *buf, size_t bufsz);

/* Returns RFC1918 IPv4 addresses for the physical Ethernet and Wi-Fi
 * interfaces independently. Interface roles are resolved from macOS
 * SystemConfiguration instead of assuming en0/en1 numbering. */
int  tb_net_get_ethernet_ip(char *buf, size_t bufsz);
int  tb_net_get_wifi_ip(char *buf, size_t bufsz);

/* Address classifier exposed for hardware-free unit tests. */
int  tb_net_is_link_local_ipv4(const char *host);

#endif
