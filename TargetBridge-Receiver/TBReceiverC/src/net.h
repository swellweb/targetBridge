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
    /* Valid data is buf[off .. len). `off` exists so dispatching a packet does
     * not have to shuffle everything behind it to the front.
     *
     * It used to: every packet ended with a memmove of the whole unconsumed
     * tail, so handling one packet cost O(bytes still buffered). That is fine
     * until the reader falls behind — and then it is quadratic, and it feeds
     * itself. A backlog makes each packet more expensive to parse, which grows
     * the backlog. Measured on a wedged 5K link: the reader thread was at 100%
     * CPU inside that memmove, the receive buffer sat at its 4 MiB cap with the
     * data unread, and the sender's send buffer filled behind it. It never
     * recovered on its own; only a reconnect cleared it.
     *
     * Advancing an offset is O(1). The buffer is compacted only when the move
     * is paid for by what it reclaims (see parser_maybe_compact). */
    size_t     off;     /* first unconsumed byte */
    size_t     len;     /* end of valid data */
    size_t     cap;     /* allocated capacity */
    tb_pkt_cb  cb;
    void      *ud;
    /* Zero-copy handoff state — see tb_parser_hold_current(). */
    int        hold;
    uint8_t   *spare;      /* recycled buffer to swap in, may be NULL */
    size_t     spare_cap;
    uint8_t   *held;       /* buffer yielded to the caller */
    size_t     held_cap;
    /* Bytes this parser has shuffled around internally (compaction + the hold
     * handoff). The stall this offset exists to prevent is invisible to the
     * packet counters -- every packet still parsed correctly, just slower and
     * slower -- so the cost itself is what has to be measured. Asserted against
     * a budget in tests/test_net_parser.c. */
    size_t     moved_bytes;
    size_t     compact_bytes;  /* of moved_bytes: buffer compaction */
    size_t     hold_bytes;     /* of moved_bytes: the hold handoff */
};

void tb_parser_init  (struct tb_parser *p, tb_pkt_cb cb, void *ud);
void tb_parser_free  (struct tb_parser *p);
int  tb_parser_feed  (struct tb_parser *p, const uint8_t *data, size_t n);

/* Zero-copy ingest: read(2) straight into the parser's buffer instead of
 * bouncing through a caller-owned staging buffer. At raw 4:4:4 rates a 5K
 * frame is ~59 MB, so the avoided memcpy is a third of the receiver's total
 * per-frame memory traffic.
 *
 *   tb_parser_reserve_space() returns a writable region of at least `want`
 *   bytes; write into it (e.g. with read(2)), then hand the byte count to
 *   tb_parser_commit(), which runs the same packet-dispatch loop as feed().
 *
 * Returns 0 on success, -1 on allocation failure / malformed stream. */
int  tb_parser_reserve_space(struct tb_parser *p, size_t want, uint8_t **out, size_t *avail);
int  tb_parser_commit       (struct tb_parser *p, size_t n);

/* Zero-copy frame handoff. A callback that needs its packet to outlive the
 * call — e.g. to render it on another thread — calls tb_parser_hold_current().
 * Instead of compacting (which would overwrite the packet), the parser swaps to
 * a fresh buffer, moves only the few trailing bytes of the next packet into it,
 * and yields ownership of the old buffer. The `payload` pointer the callback
 * received stays valid, because that buffer is handed over rather than freed.
 *
 * At 5K a frame is ~59 MB, so this is the difference between transferring a
 * pointer and copying 59 MB per frame — the latter measurably slows the
 * concurrent GPU upload. Feed buffers back with tb_parser_set_spare() to avoid
 * reallocating (and re-faulting) 59 MB every frame. */
void     tb_parser_hold_current(struct tb_parser *p);
void     tb_parser_set_spare   (struct tb_parser *p, uint8_t *buf, size_t cap);
uint8_t *tb_parser_take_held   (struct tb_parser *p, size_t *cap_out);

/* Server: returns listening fd (>=0) or -1 on failure. Non-blocking. */
int  tb_net_listen   (uint16_t port);

/* Accept one client. Returns client fd or -1. Sets non-blocking. */
int  tb_net_accept   (int server_fd);

/* Returns IP address of first bridge* interface (Thunderbolt Bridge) in buf.
 * buf size must be at least INET_ADDRSTRLEN (16) bytes. Returns 0 on success. */
int  tb_net_get_tb_ip(char *buf, size_t bufsz);

/* Returns IP address of a likely local LAN interface (for example en0/eth0, RFC1918 IPv4).
 * buf size must be at least INET_ADDRSTRLEN (16) bytes. Returns 0 on success. */
int  tb_net_get_lan_ip(char *buf, size_t bufsz);

#endif
