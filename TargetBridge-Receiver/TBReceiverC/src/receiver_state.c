/* receiver_state.c — durable Receiver authority.
 *
 * "Usa iMac" must survive an app crash, a launchd restart and a new login.
 * A small atomic state file records whether the Receiver is allowed to accept
 * or start a Sender. A separate advisory lock prevents two Receiver processes
 * from sharing the listening port and presenting contradictory UI state. */

#include "receiver_state.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif

static const char *tb_receiver_state_home(void) {
    const char *override = getenv("TB_RECEIVER_STATE_HOME");
    if (override && *override) return override;
    return getenv("HOME");
}

static int tb_receiver_mkdir(const char *path, mode_t mode) {
    if (mkdir(path, mode) == 0) return 0;
    if (errno != EEXIST) return -1;

    struct stat info;
    return stat(path, &info) == 0 && S_ISDIR(info.st_mode) ? 0 : -1;
}

static int tb_receiver_state_dir(char *dest, size_t size, int create) {
    if (!dest || size == 0) return -1;
    dest[0] = '\0';

    const char *home = tb_receiver_state_home();
    if (!home || !*home) return -1;

    char path[PATH_MAX];
    int written = snprintf(path, sizeof(path), "%s/Library", home);
    if (written <= 0 || (size_t)written >= sizeof(path)) return -1;
    if (create && tb_receiver_mkdir(path, 0755) != 0) return -1;

    written = snprintf(path, sizeof(path), "%s/Library/Application Support", home);
    if (written <= 0 || (size_t)written >= sizeof(path)) return -1;
    if (create && tb_receiver_mkdir(path, 0755) != 0) return -1;

    written = snprintf(path, sizeof(path), "%s/Library/Application Support/TargetBridge", home);
    if (written <= 0 || (size_t)written >= sizeof(path)) return -1;
    if (create && tb_receiver_mkdir(path, 0700) != 0) return -1;

    written = snprintf(dest, size, "%s/Library/Application Support/TargetBridge/Receiver", home);
    if (written <= 0 || (size_t)written >= size) {
        dest[0] = '\0';
        return -1;
    }
    if (create && tb_receiver_mkdir(dest, 0700) != 0) {
        dest[0] = '\0';
        return -1;
    }
    return 0;
}

static int tb_receiver_state_path(char *dest, size_t size, const char *name, int create) {
    char dir[PATH_MAX];
    if (!name || tb_receiver_state_dir(dir, sizeof(dir), create) != 0) return -1;
    int written = snprintf(dest, size, "%s/%s", dir, name);
    if (written <= 0 || (size_t)written >= size) {
        if (dest && size > 0) dest[0] = '\0';
        return -1;
    }
    return 0;
}

int tb_receiver_monitor_action_is_valid(const char *action) {
    return action &&
           (strcmp(action, "activate") == 0 ||
            strcmp(action, "path auto") == 0 ||
            strcmp(action, "path thunderbolt") == 0 ||
            strcmp(action, "path usb") == 0 ||
            strcmp(action, "path ethernet") == 0 ||
            strcmp(action, "path wifi") == 0);
}

int tb_receiver_teardown_requests_suspend(const char *reason) {
    /* Only the explicit user action suspends monitor mode. Network failures,
     * capture restarts and automatic path re-evaluation must keep retrying. */
    return reason && strcmp(reason, "sender_user_stop") == 0;
}

void tb_receiver_monitor_state_default(struct tb_receiver_monitor_state *state) {
    if (!state) return;
    state->auto_sender_enabled = 1;
    state->input_enabled = 0;
    snprintf(state->preferred_action, sizeof(state->preferred_action), "%s", "path auto");
}

int tb_receiver_monitor_state_load(struct tb_receiver_monitor_state *state) {
    if (!state) return -1;
    tb_receiver_monitor_state_default(state);

    char path[PATH_MAX];
    if (tb_receiver_state_path(path, sizeof(path), "monitor-mode.state", 0) != 0) return -1;

    FILE *fp = fopen(path, "rb");
    if (!fp) return errno == ENOENT ? 0 : -1;

    int enabled = state->auto_sender_enabled;
    int input_enabled = state->input_enabled;
    int input_setting_seen = 0;
    char action[sizeof(state->preferred_action)];
    snprintf(action, sizeof(action), "%s", state->preferred_action);

    char line[128];
    while (fgets(line, sizeof(line), fp)) {
        size_t length = strlen(line);
        while (length > 0 && (line[length - 1] == '\n' || line[length - 1] == '\r')) {
            line[--length] = '\0';
        }
        if (strcmp(line, "enabled=0") == 0) {
            enabled = 0;
        } else if (strcmp(line, "enabled=1") == 0) {
            enabled = 1;
        } else if (strcmp(line, "input=0") == 0) {
            input_enabled = 0;
            input_setting_seen = 1;
        } else if (strcmp(line, "input=1") == 0) {
            input_enabled = 1;
            input_setting_seen = 1;
        } else if (strncmp(line, "action=", 7) == 0 &&
                   tb_receiver_monitor_action_is_valid(line + 7)) {
            snprintf(action, sizeof(action), "%s", line + 7);
        }
    }
    int read_error = ferror(fp);
    fclose(fp);
    if (read_error) return -1;

    state->auto_sender_enabled = enabled;
    /* Version 1 always launched the Sender with `--input receiver`; preserve
     * that explicit legacy behavior during an upgrade. A fresh install has no
     * state file and therefore keeps the safer optional default (off). */
    state->input_enabled = input_setting_seen ? input_enabled : 1;
    snprintf(state->preferred_action, sizeof(state->preferred_action), "%s", action);
    return 0;
}

int tb_receiver_monitor_state_save(const struct tb_receiver_monitor_state *state) {
    if (!state || !tb_receiver_monitor_action_is_valid(state->preferred_action)) return -1;
    if (state->auto_sender_enabled != 0 && state->auto_sender_enabled != 1) return -1;
    if (state->input_enabled != 0 && state->input_enabled != 1) return -1;

    char path[PATH_MAX];
    if (tb_receiver_state_path(path, sizeof(path), "monitor-mode.state", 1) != 0) return -1;

    char temp_path[PATH_MAX];
    int written = snprintf(temp_path, sizeof(temp_path), "%s.tmp.XXXXXX", path);
    if (written <= 0 || (size_t)written >= sizeof(temp_path)) return -1;

    int fd = mkstemp(temp_path);
    if (fd < 0) return -1;
    (void)fchmod(fd, 0600);

    FILE *fp = fdopen(fd, "wb");
    if (!fp) {
        close(fd);
        unlink(temp_path);
        return -1;
    }

    int failed = fprintf(fp, "version=2\nenabled=%d\ninput=%d\naction=%s\n",
                         state->auto_sender_enabled,
                         state->input_enabled,
                         state->preferred_action) < 0;
    if (!failed && fflush(fp) != 0) failed = 1;
    if (!failed && fsync(fd) != 0) failed = 1;
    if (fclose(fp) != 0) failed = 1;
    if (!failed && rename(temp_path, path) != 0) failed = 1;
    if (failed) {
        unlink(temp_path);
        return -1;
    }
    return 0;
}

int tb_receiver_single_instance_lock(void) {
    char path[PATH_MAX];
    if (tb_receiver_state_path(path, sizeof(path), "receiver.lock", 1) != 0) return -1;

    int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        int lock_error = errno;
        close(fd);
        return lock_error == EWOULDBLOCK || lock_error == EAGAIN ? -2 : -1;
    }

    (void)ftruncate(fd, 0);
    (void)dprintf(fd, "%ld\n", (long)getpid());
    return fd;
}
