/* net.h — POSIX socket server + packet parser.
 * No ObjC, no ARC, no autoreleasepool. Pure C.
 */

#ifndef TB_NET_H
#define TB_NET_H

#include <stdint.h>
#include <stddef.h>

/* Packet callback: called for each complete packet parsed from the stream. */
typedef void (*tb_pkt_cb)(uint8_t type, const uint8_t *payload, size_t len, void *ud);

/* Streaming packet parser (handles fragmented TCP reads). */
struct tb_parser {
    uint8_t   *buf;
    size_t     len;     /* used bytes */
    size_t     cap;     /* allocated capacity */
    tb_pkt_cb  cb;
    void      *ud;
};

void tb_parser_init  (struct tb_parser *p, tb_pkt_cb cb, void *ud);
void tb_parser_free  (struct tb_parser *p);
int  tb_parser_feed  (struct tb_parser *p, const uint8_t *data, size_t n);

/* Server: returns listening fd (>=0) or -1 on failure. Non-blocking. */
int  tb_net_listen   (uint16_t port);

/* Accept one client. Returns client fd or -1. Sets non-blocking. */
int  tb_net_accept   (int server_fd);

/* Returns IP address of first bridge* interface (Thunderbolt Bridge) in buf.
 * buf size must be at least INET_ADDRSTRLEN (16) bytes. Returns 0 on success. */
int  tb_net_get_tb_ip(char *buf, size_t bufsz);

#endif
