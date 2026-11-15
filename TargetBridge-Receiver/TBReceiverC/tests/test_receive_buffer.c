#include "net.h"
#include <arpa/inet.h>
#include <assert.h>
#include <fcntl.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <sys/socket.h>
#include <unistd.h>

int main(void) {
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    assert(listener >= 0);
    struct sockaddr_in address = { .sin_family = AF_INET };
    assert(inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1);
    assert(bind(listener, (void *)&address, sizeof(address)) == 0);
    socklen_t length = sizeof(address);
    assert(getsockname(listener, (void *)&address, &length) == 0);
    assert(listen(listener, 1) == 0);
    int peer = socket(AF_INET, SOCK_STREAM, 0);
    assert(peer >= 0 && connect(peer, (void *)&address, sizeof(address)) == 0);
    int client = tb_net_accept(listener);
    assert(client >= 0);
    int buffer = 0, option = 0;
    length = sizeof(buffer);
    assert(getsockopt(client, SOL_SOCKET, SO_RCVBUF, &buffer, &length) == 0);
    if (buffer <= 0 || buffer > 4 * 1024 * 1024) {
        fprintf(stderr, "receive window exceeds restored budget: %d\n", buffer);
        return 1;
    }
    assert((fcntl(client, F_GETFL) & O_NONBLOCK) != 0);
    length = sizeof(option);
    assert(getsockopt(client, IPPROTO_TCP, TCP_NODELAY, &option, &length) == 0 && option != 0);
    length = sizeof(option);
    assert(getsockopt(client, SOL_SOCKET, SO_KEEPALIVE, &option, &length) == 0 && option != 0);
    close(client); close(peer); close(listener);
    printf("receive window: %d bytes; nonblocking, NODELAY and keepalive preserved\n", buffer);
    return 0;
}
