#define _POSIX_C_SOURCE 200809L
#include "net.h"
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define FRAMES 192
#define NORMAL_BYTES 312500
#ifndef KEY_BYTES
#define KEY_BYTES 2000000
#endif
struct header { uint64_t sequence, created_ns, bytes; };
static uint16_t port;
static uint64_t ages[FRAMES];
static uint64_t clock_ns(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}
static void pause_ns(uint64_t ns) {
    struct timespec t = { ns / 1000000000, ns % 1000000000 };
    while (nanosleep(&t, &t) < 0 && errno == EINTR) {}
}
static void transfer(int fd, void *data, size_t bytes, int writing) {
    size_t offset = 0;
    while (offset < bytes) {
        ssize_t n = writing ? write(fd, (char *)data + offset, bytes - offset)
                            : read(fd, (char *)data + offset, bytes - offset);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) { pause_ns(100000); continue; }
        if (n <= 0) { perror("isolated transfer"); exit(2); }
        offset += (size_t)n;
    }
}
static void *produce(void *unused) {
    (void)unused;
    int fd = socket(AF_INET, SOCK_STREAM, 0), send_buffer = 4 * 1024 * 1024;
    int no_delay = 1; setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &no_delay, sizeof(no_delay));
    if (setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &send_buffer, sizeof(send_buffer))) exit(2);
    int actual_send = 0; socklen_t size = sizeof(actual_send);
    if (getsockopt(fd, SOL_SOCKET, SO_SNDBUF, &actual_send, &size) || actual_send != send_buffer) exit(2);
    struct sockaddr_in address = { .sin_family = AF_INET, .sin_port = port };
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);
    if (connect(fd, (void *)&address, sizeof(address)) != 0) { perror("connect"); exit(2); }
    unsigned char *payload = malloc(KEY_BYTES);
    for (uint64_t i = 0; i < FRAMES; i++) {
        uint64_t start = clock_ns();
        size_t bytes = i % 48 == 0 ? KEY_BYTES : NORMAL_BYTES;
        memset(payload, (int)(i % 251), bytes);
        struct header header = { i, start, bytes };
        transfer(fd, &header, sizeof(header), 1); transfer(fd, payload, bytes, 1);
        uint64_t elapsed = clock_ns() - start;
        if (elapsed < 1000000000 / 48) pause_ns(1000000000 / 48 - elapsed);
    }
    free(payload); close(fd); return NULL;
}
static int compare(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return (x > y) - (x < y);
}
int main(void) {
    int server = socket(AF_INET, SOCK_STREAM, 0); if (server < 0) return 2;
    struct sockaddr_in address = { .sin_family = AF_INET };
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);
    if (bind(server, (void *)&address, sizeof(address)) || listen(server, 1)) return 2;
    socklen_t size = sizeof(address);
    getsockname(server, (void *)&address, &size); port = address.sin_port;
    pthread_t thread; if (pthread_create(&thread, NULL, produce, NULL)) return 2;
    int client; while ((client = tb_net_accept(server)) < 0) pause_ns(100000);
    int receive_buffer = 0; size = sizeof(receive_buffer);
    getsockopt(client, SOL_SOCKET, SO_RCVBUF, &receive_buffer, &size);
    unsigned char *payload = malloc(KEY_BYTES);
    uint64_t started = clock_ns(), total = 0;
    for (uint64_t i = 0; i < FRAMES; i++) {
        struct header header; transfer(client, &header, sizeof(header), 0);
        if (header.sequence != i || header.bytes > KEY_BYTES) return 3;
        transfer(client, payload, header.bytes, 0);
        for (size_t b = 0; b < header.bytes; b++) if (payload[b] != i % 251) return 3;
        ages[i] = clock_ns() - header.created_ns; total += header.bytes;
        pause_ns(26000000); /* Simulated decode: about 38 fps, no GUI or decoder. */
    }
    qsort(ages, FRAMES, sizeof(*ages), compare);
    printf("rcvbuf=%d frames=%d bytes=%llu p50_ms=%.1f p95_ms=%.1f max_ms=%.1f fps=%.1f\n",
           receive_buffer, FRAMES, (unsigned long long)total, ages[FRAMES/2]/1e6,
           ages[FRAMES*95/100]/1e6, ages[FRAMES-1]/1e6, FRAMES*1e9/(clock_ns()-started));
    free(payload); close(client); close(server); pthread_join(thread, NULL); return 0;
}
