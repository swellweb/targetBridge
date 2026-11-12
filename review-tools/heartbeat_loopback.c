#include "heartbeat_loopback.h"
#include <arpa/inet.h>
#include <errno.h>
#include <sys/socket.h>
#include <unistd.h>

int tb_heartbeat_loopback(int sockets[2]) {
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) return -1;
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t size = sizeof(address);
    sockets[0] = sockets[1] = -1;
    if (bind(listener, (struct sockaddr *)&address, size) < 0 ||
        getsockname(listener, (struct sockaddr *)&address, &size) < 0 ||
        listen(listener, 1) < 0) goto fail;
    sockets[0] = socket(AF_INET, SOCK_STREAM, 0);
    if (sockets[0] < 0 || connect(sockets[0], (struct sockaddr *)&address, size) < 0) goto fail;
    sockets[1] = accept(listener, NULL, NULL);
    if (sockets[1] < 0) goto fail;
    close(listener);
    return 0;
fail:
    close(listener);
    if (sockets[0] >= 0) close(sockets[0]);
    if (sockets[1] >= 0) close(sockets[1]);
    return -1;
}

int tb_heartbeat_write(int socket) {
    const char packet[] = "\0\0\0\x0f\x30{\"sequence\":0}";
    ssize_t count;
    do { count = send(socket, packet, sizeof(packet) - 1, 0); } while (count < 0 && errno == EINTR);
    return count == sizeof(packet) - 1 ? 0 : -1;
}

int tb_heartbeat_read(int socket) {
    char buffer[256];
    ssize_t count;
    do { count = recv(socket, buffer, sizeof(buffer), MSG_DONTWAIT); } while (count < 0 && errno == EINTR);
    return count > 0 ? (int)count : 0;
}
