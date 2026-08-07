#include "tb_logship.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* 256 KB holds several seconds of the receiver's chattiest output, which is far
 * more than the main loop needs to fall behind by — it drains every iteration. */
#define TB_LOGSHIP_RING (256u * 1024u)

static struct {
    int             started;
    int             real_stderr;     /* dup of the original fd, for local output */
    int             pipe_r;
    pthread_t       thread;

    pthread_mutex_t lock;
    uint8_t         ring[TB_LOGSHIP_RING];
    size_t          head;            /* read position  */
    size_t          count;           /* bytes buffered */
    size_t          dropped;         /* bytes lost since the last report */
} g;

/* Append under the lock, dropping what does not fit. The alternative — evicting
 * the oldest bytes — would cut a line in half at an arbitrary point, and half a
 * line at the START of a drain is harder to read than a gap with a count. */
static void ring_put(const uint8_t *p, size_t n) {
    pthread_mutex_lock(&g.lock);

    /* Announce a gap before the text that follows it, so the log says where the
     * hole is instead of quietly closing over it. */
    if (g.dropped > 0 && TB_LOGSHIP_RING - g.count > 64) {
        char note[64];
        const int len = snprintf(note, sizeof(note),
                                 "[logship] dropped %zu bytes\n", g.dropped);
        if (len > 0 && (size_t)len <= TB_LOGSHIP_RING - g.count) {
            for (int i = 0; i < len; ++i)
                g.ring[(g.head + g.count + (size_t)i) % TB_LOGSHIP_RING] = (uint8_t)note[i];
            g.count += (size_t)len;
            g.dropped = 0;
        }
    }

    const size_t space = TB_LOGSHIP_RING - g.count;
    if (n > space) {
        g.dropped += n - space;
        n = space;
    }
    for (size_t i = 0; i < n; ++i)
        g.ring[(g.head + g.count + i) % TB_LOGSHIP_RING] = p[i];
    g.count += n;

    pthread_mutex_unlock(&g.lock);
}

static void *reader_main(void *unused) {
    (void)unused;
    uint8_t buf[8192];
    for (;;) {
        const ssize_t n = read(g.pipe_r, buf, sizeof(buf));
        if (n > 0) {
            /* Local console first: if the socket is down or the ring is full,
             * the person at the receiver still sees everything. */
            ssize_t off = 0;
            while (off < n) {
                const ssize_t w = write(g.real_stderr, buf + off, (size_t)(n - off));
                if (w <= 0) break;
                off += w;
            }
            ring_put(buf, (size_t)n);
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        break;   /* write end closed, or an unrecoverable error */
    }
    return NULL;
}

int tb_logship_start(void) {
    if (g.started) return 0;

    int fds[2];
    if (pipe(fds) != 0) return -1;

    /* The write end must never block: everything that logs runs on threads this
     * feature has no business stalling, the render path among them. */
    const int fl = fcntl(fds[1], F_GETFL, 0);
    if (fl < 0 || fcntl(fds[1], F_SETFL, fl | O_NONBLOCK) != 0) {
        close(fds[0]); close(fds[1]);
        return -1;
    }

    g.real_stderr = dup(STDERR_FILENO);
    if (g.real_stderr < 0) {
        close(fds[0]); close(fds[1]);
        return -1;
    }

    if (pthread_mutex_init(&g.lock, NULL) != 0) {
        close(g.real_stderr); close(fds[0]); close(fds[1]);
        return -1;
    }

    if (dup2(fds[1], STDERR_FILENO) < 0) {
        pthread_mutex_destroy(&g.lock);
        close(g.real_stderr); close(fds[0]); close(fds[1]);
        return -1;
    }
    close(fds[1]);            /* STDERR_FILENO is the write end now */
    g.pipe_r = fds[0];

    /* stderr is unbuffered by default, which is what makes a per-line redirect
     * work at all; say so explicitly rather than rely on it. */
    setvbuf(stderr, NULL, _IONBF, 0);

    if (pthread_create(&g.thread, NULL, reader_main, NULL) != 0) {
        dup2(g.real_stderr, STDERR_FILENO);
        pthread_mutex_destroy(&g.lock);
        close(g.real_stderr); close(g.pipe_r);
        return -1;
    }
    pthread_detach(g.thread);

    g.started = 1;
    fprintf(stderr, "[logship] receiver stderr is being shipped to the sender\n");
    return 0;
}

size_t tb_logship_drain(uint8_t *out, size_t cap) {
    if (!g.started || !out || cap == 0) return 0;

    pthread_mutex_lock(&g.lock);
    size_t n = g.count < cap ? g.count : cap;
    for (size_t i = 0; i < n; ++i)
        out[i] = g.ring[(g.head + i) % TB_LOGSHIP_RING];
    g.head = (g.head + n) % TB_LOGSHIP_RING;
    g.count -= n;
    pthread_mutex_unlock(&g.lock);

    return n;
}
