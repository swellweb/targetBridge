#include "sender_control.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int checks = 0;
static int failures = 0;

#define CHECK(condition, message) do { \
    checks++; \
    if (!(condition)) { \
        fprintf(stderr, "FAIL: %s\n", message); \
        failures++; \
    } \
} while (0)

static int wait_for_completion(struct tb_sender_control *control) {
    for (int i = 0; i < 300; i++) {
        if (tb_sender_control_poll(control)) return 1;
        struct timespec pause = {0, 10000000};
        nanosleep(&pause, NULL);
    }
    return 0;
}

int main(void) {
    char helper[4096];
    if (!getcwd(helper, sizeof(helper))) return 2;
    size_t length = strlen(helper);
    snprintf(helper + length, sizeof(helper) - length, "%s", "/tests/mock_sender_control.sh");
    setenv("TB_SENDER_CONTROL_HELPER", helper, 1);

    struct tb_sender_control control;
    tb_sender_control_init(&control);
    CHECK(!tb_sender_control_busy(&control), "new controller is idle");

    CHECK(tb_sender_control_start(&control, "activate") == 0, "start activate helper");
    CHECK(tb_sender_control_busy(&control), "controller reports running");
    CHECK(wait_for_completion(&control), "activate completes asynchronously");
    CHECK(control.state == TB_SENDER_CONTROL_SUCCEEDED, "activate succeeds");
    CHECK(strstr(control.output, "SENDER_STARTED") != NULL, "activate output retained");

    CHECK(tb_sender_control_start(&control, "stop") == 0, "start stop helper");
    CHECK(wait_for_completion(&control), "stop completes asynchronously");
    CHECK(control.state == TB_SENDER_CONTROL_SUCCEEDED, "stop succeeds");
    CHECK(strstr(control.output, "SENDER_STOPPED") != NULL, "stop output retained");

    CHECK(tb_sender_control_start(&control, "invalid") != 0, "invalid action rejected");
    CHECK(tb_sender_control_start(&control, "path wifi") == 0, "start cancellable helper");
    tb_sender_control_cancel(&control);
    CHECK(!tb_sender_control_busy(&control), "cancel returns controller to idle");

    tb_sender_control_destroy(&control);
    printf("sender control tests: %d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
