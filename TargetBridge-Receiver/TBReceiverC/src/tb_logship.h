/* tb_logship.h — ship the receiver's stderr to the sender.
 *
 * WHY
 *
 * The receiver runs on the other Mac. Every measurement so far has meant asking
 * whoever is sitting there to copy a log out of a terminal, which is slow enough
 * that it discourages measuring — and this project has repeatedly lost hours to
 * theories that one log would have killed in a minute. The sender's own logs are
 * already readable locally through `log show`; this puts the receiver's next to
 * them.
 *
 * HOW
 *
 * stderr is redirected into a pipe at startup, so all the existing
 * fprintf(stderr, ...) calls are captured without touching a single call site. A
 * reader thread copies what comes out to the REAL stderr (the local console
 * keeps working exactly as before) and into a ring buffer. The main loop drains
 * that ring and sends it as TB_PKT_LOG.
 *
 * The main loop does the sending on purpose. The socket already has one
 * off-thread writer in the mic callback; adding a second would interleave two
 * partial packets on the same fd. Draining from the loop keeps all packet
 * framing on one thread.
 *
 * TWO WAYS THIS COULD HURT THE THING IT IS MEASURING, AND WHAT STOPS THEM
 *
 *   - A full pipe would block whoever called fprintf, which at 60 fps is the
 *     render path. The write end is therefore non-blocking: when the pipe is
 *     full the line is DROPPED. Losing log lines is always better than stalling
 *     the receiver, and dropping is counted so a gap is never silent.
 *   - A full ring would do the same via the reader thread. It also drops, and
 *     reports how much when space returns.
 */

#ifndef TB_LOGSHIP_H
#define TB_LOGSHIP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Redirect stderr and start the reader thread. Returns 0 on success; on failure
 * stderr is left exactly as it was, which is a degraded but working receiver.
 * Safe to call once; later calls are no-ops. */
int tb_logship_start(void);

/* Copy up to `cap` bytes of pending log text into `out`. Returns the number of
 * bytes copied, 0 when there is nothing waiting. Never blocks. */
size_t tb_logship_drain(uint8_t *out, size_t cap);

#ifdef __cplusplus
}
#endif

#endif
