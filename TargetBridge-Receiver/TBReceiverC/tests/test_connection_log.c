#define _POSIX_C_SOURCE 200809L
#include "connection_log.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(void) {
    FILE *capture = tmpfile();
    assert(capture);
    int original = dup(STDERR_FILENO);
    assert(original >= 0 && dup2(fileno(capture), STDERR_FILENO) >= 0);
    tb_connection_log("fixture_idle_timeout_ms", 10000);
    tb_connection_log(NULL, 42);
    tb_connection_log("fixture_negative_code", -54);
    tb_connection_log("fixture_large_counter", INT64_C(4294967296));
    fflush(stderr);
    assert(dup2(original, STDERR_FILENO) >= 0);
    close(original);
    rewind(capture);
    char line[128];
    assert(fgets(line, sizeof(line), capture));
    assert(strcmp(line, "[connection] fixture_idle_timeout_ms value=10000\n") == 0);
    assert(fgets(line, sizeof(line), capture));
    assert(strcmp(line, "[connection] fixture_negative_code value=-54\n") == 0);
    assert(fgets(line, sizeof(line), capture));
    assert(strcmp(line, "[connection] fixture_large_counter value=4294967296\n") == 0);
    assert(!fgets(line, sizeof(line), capture));
    fclose(capture);
    puts("connection log: null event, lifecycle value, signed code and 64-bit counter passed");
    return 0;
}
