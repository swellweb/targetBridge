/* A second listener on the receiver's port must fail with EADDRINUSE, so a
 * second copy of the receiver leaves instead of running beside the first. */
#include "net.h"
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <unistd.h>

int main(void) {
    int first = -1;
    uint16_t port = 0;
    for (uint16_t candidate = 54800; candidate < 54900 && first < 0; candidate++) {
        first = tb_net_listen(candidate);
        if (first >= 0) port = candidate;
    }
    assert(first >= 0);

    errno = 0;
    int second = tb_net_listen(port);
    if (second >= 0) {
        fprintf(stderr, "a second listener bound port %u\n", (unsigned)port);
        return 1;
    }
    assert(errno == EADDRINUSE);

    close(first);
    printf("second listener on port %u refused with EADDRINUSE\n", (unsigned)port);
    return 0;
}
