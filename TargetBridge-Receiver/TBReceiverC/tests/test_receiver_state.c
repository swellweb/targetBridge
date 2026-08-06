#include "receiver_state.h"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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

int main(void) {
    char temp_home[] = "/private/tmp/targetbridge-receiver-state-test.XXXXXX";
    CHECK(mkdtemp(temp_home) != NULL, "temporary state home created");
    CHECK(setenv("TB_RECEIVER_STATE_HOME", temp_home, 1) == 0, "state home override set");

    struct tb_receiver_monitor_state state;
    CHECK(tb_receiver_monitor_state_load(&state) == 0, "missing state loads defaults");
    CHECK(state.auto_sender_enabled == 1, "default mode starts automatically");
    CHECK(state.input_enabled == 0, "input control is optional on a fresh install");
    CHECK(strcmp(state.preferred_action, "path auto") == 0, "default path is automatic");

    CHECK(tb_receiver_teardown_requests_suspend("sender_user_stop") == 1,
          "explicit Sender stop suspends automatic monitor mode");
    CHECK(tb_receiver_teardown_requests_suspend("sender_internal_stop") == 0,
          "internal Sender restart keeps automatic monitor mode");
    CHECK(tb_receiver_teardown_requests_suspend("connection_lost") == 0,
          "network loss keeps automatic monitor mode");
    CHECK(tb_receiver_teardown_requests_suspend(NULL) == 0,
          "missing teardown reason keeps automatic monitor mode");

    state.auto_sender_enabled = 0;
    state.input_enabled = 1;
    CHECK(tb_receiver_monitor_state_save(&state) == 0, "stopped state saved");
    tb_receiver_monitor_state_default(&state);
    CHECK(tb_receiver_monitor_state_load(&state) == 0, "stopped state reloaded");
    CHECK(state.auto_sender_enabled == 0, "stopped state survives restart");
    CHECK(state.input_enabled == 1, "input preference survives restart");

    state.auto_sender_enabled = 1;
    snprintf(state.preferred_action, sizeof(state.preferred_action), "%s", "path ethernet");
    CHECK(tb_receiver_monitor_state_save(&state) == 0, "manual path state saved");
    tb_receiver_monitor_state_default(&state);
    CHECK(tb_receiver_monitor_state_load(&state) == 0, "manual path state reloaded");
    CHECK(state.auto_sender_enabled == 1, "started state survives restart");
    CHECK(strcmp(state.preferred_action, "path ethernet") == 0, "manual path survives restart");

    snprintf(state.preferred_action, sizeof(state.preferred_action), "%s", "path unsafe");
    CHECK(tb_receiver_monitor_state_save(&state) != 0, "invalid action is rejected");

    snprintf(state.preferred_action, sizeof(state.preferred_action), "%s", "path auto");
    state.input_enabled = 2;
    CHECK(tb_receiver_monitor_state_save(&state) != 0, "invalid input preference is rejected");

    char legacy_state_file[PATH_MAX];
    snprintf(legacy_state_file, sizeof(legacy_state_file),
             "%s/Library/Application Support/TargetBridge/Receiver/monitor-mode.state",
             temp_home);
    FILE *legacy = fopen(legacy_state_file, "wb");
    CHECK(legacy != NULL, "legacy state file opened");
    if (legacy) {
        CHECK(fputs("version=1\nenabled=1\naction=path auto\n", legacy) >= 0,
              "legacy state written");
        CHECK(fclose(legacy) == 0, "legacy state closed");
    }
    tb_receiver_monitor_state_default(&state);
    CHECK(tb_receiver_monitor_state_load(&state) == 0, "legacy state reloaded");
    CHECK(state.input_enabled == 1, "legacy receiver input mode is preserved on upgrade");

    int first_lock = tb_receiver_single_instance_lock();
    CHECK(first_lock >= 0, "first instance owns lock");
    int second_lock = tb_receiver_single_instance_lock();
    CHECK(second_lock == -2, "second instance is rejected");
    if (first_lock >= 0) close(first_lock);
    int replacement_lock = tb_receiver_single_instance_lock();
    CHECK(replacement_lock >= 0, "lock is released when instance exits");
    if (replacement_lock >= 0) close(replacement_lock);

    char state_file[PATH_MAX];
    char lock_file[PATH_MAX];
    char receiver_dir[PATH_MAX];
    char targetbridge_dir[PATH_MAX];
    char support_dir[PATH_MAX];
    char library_dir[PATH_MAX];
    snprintf(state_file, sizeof(state_file), "%s/Library/Application Support/TargetBridge/Receiver/monitor-mode.state", temp_home);
    snprintf(lock_file, sizeof(lock_file), "%s/Library/Application Support/TargetBridge/Receiver/receiver.lock", temp_home);
    snprintf(receiver_dir, sizeof(receiver_dir), "%s/Library/Application Support/TargetBridge/Receiver", temp_home);
    snprintf(targetbridge_dir, sizeof(targetbridge_dir), "%s/Library/Application Support/TargetBridge", temp_home);
    snprintf(support_dir, sizeof(support_dir), "%s/Library/Application Support", temp_home);
    snprintf(library_dir, sizeof(library_dir), "%s/Library", temp_home);
    (void)unlink(state_file);
    (void)unlink(lock_file);
    (void)rmdir(receiver_dir);
    (void)rmdir(targetbridge_dir);
    (void)rmdir(support_dir);
    (void)rmdir(library_dir);
    (void)rmdir(temp_home);

    printf("receiver state tests: %d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
