/* sender_control.c — run the bundled restricted SSH helper without blocking
 * the SDL/network loop. The Receiver remains the only user-facing app. */

#include "sender_control.h"

#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static int tb_sender_control_valid_action(const char *action) {
    return action &&
           (strcmp(action, "activate") == 0 ||
            strcmp(action, "stop") == 0 ||
            strcmp(action, "path auto") == 0 ||
            strcmp(action, "path thunderbolt") == 0 ||
            strcmp(action, "path usb") == 0 ||
            strcmp(action, "path ethernet") == 0 ||
            strcmp(action, "path wifi") == 0 ||
            strcmp(action, "input on") == 0 ||
            strcmp(action, "input off") == 0);
}

static int tb_sender_control_find_helper(char *dest, size_t size) {
    if (!dest || size == 0) return -1;
    dest[0] = '\0';

    const char *override = getenv("TB_SENDER_CONTROL_HELPER");
    if (override && *override) {
        int written = snprintf(dest, size, "%s", override);
        if (written > 0 && (size_t)written < size && access(dest, R_OK) == 0) {
            return 0;
        }
        dest[0] = '\0';
        return -1;
    }

    uint32_t executable_size = PATH_MAX;
    char executable[PATH_MAX];
    if (_NSGetExecutablePath(executable, &executable_size) == 0) {
        char *slash = strrchr(executable, '/');
        if (slash) {
            *slash = '\0';
            int written = snprintf(dest, size,
                                   "%s/../Resources/Recovery/activate-sender.sh",
                                   executable);
            if (written > 0 && (size_t)written < size && access(dest, R_OK) == 0) {
                return 0;
            }
        }
    }

    const char *home = getenv("HOME");
    if (home && *home) {
        int written = snprintf(dest, size,
                               "%s/Library/Application Support/TargetBridge/Recovery/activate-sender.sh",
                               home);
        if (written > 0 && (size_t)written < size && access(dest, R_OK) == 0) {
            return 0;
        }
    }

    dest[0] = '\0';
    return -1;
}

void tb_sender_control_init(struct tb_sender_control *control) {
    if (!control) return;
    memset(control, 0, sizeof(*control));
    control->pid = -1;
    control->output_fd = -1;
    control->state = TB_SENDER_CONTROL_IDLE;
}

int tb_sender_control_busy(const struct tb_sender_control *control) {
    return control && control->state == TB_SENDER_CONTROL_RUNNING && control->pid > 0;
}

void tb_sender_control_cancel(struct tb_sender_control *control) {
    if (!control) return;
    if (control->pid > 0) {
        /* The helper and its current ssh child share a dedicated process
         * group, so Stop can pre-empt an in-flight automatic retry. */
        kill(-control->pid, SIGTERM);
        kill(control->pid, SIGTERM);
        int reaped = 0;
        for (int attempt = 0; attempt < 25; attempt++) {
            pid_t result = waitpid(control->pid, NULL, WNOHANG);
            if (result == control->pid || (result < 0 && errno == ECHILD)) {
                reaped = 1;
                break;
            }
            struct timespec pause = {0, 10000000};
            nanosleep(&pause, NULL);
        }
        if (!reaped) {
            kill(-control->pid, SIGKILL);
            kill(control->pid, SIGKILL);
            (void)waitpid(control->pid, NULL, 0);
        }
    }
    if (control->output_fd >= 0) close(control->output_fd);
    control->pid = -1;
    control->output_fd = -1;
    control->state = TB_SENDER_CONTROL_IDLE;
    control->output_len = 0;
    control->output[0] = '\0';
}

void tb_sender_control_destroy(struct tb_sender_control *control) {
    tb_sender_control_cancel(control);
}

int tb_sender_control_start(struct tb_sender_control *control, const char *action) {
    if (!control || !tb_sender_control_valid_action(action)) return -1;
    if (tb_sender_control_busy(control)) return -2;
    if (control->output_fd >= 0) {
        close(control->output_fd);
        control->output_fd = -1;
    }

    if (tb_sender_control_find_helper(control->helper_path,
                                      sizeof(control->helper_path)) != 0) {
        control->state = TB_SENDER_CONTROL_FAILED;
        snprintf(control->output, sizeof(control->output), "%s", "RECOVERY_NOT_INSTALLED");
        control->output_len = strlen(control->output);
        return -3;
    }

    int output_pipe[2];
    if (pipe(output_pipe) != 0) {
        control->state = TB_SENDER_CONTROL_FAILED;
        snprintf(control->output, sizeof(control->output), "PIPE_ERROR:%d", errno);
        control->output_len = strlen(control->output);
        return -4;
    }
    (void)fcntl(output_pipe[0], F_SETFL, fcntl(output_pipe[0], F_GETFL) | O_NONBLOCK);

    posix_spawn_file_actions_t file_actions;
    posix_spawn_file_actions_init(&file_actions);
    posix_spawn_file_actions_addclose(&file_actions, output_pipe[0]);
    posix_spawn_file_actions_adddup2(&file_actions, output_pipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&file_actions, output_pipe[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&file_actions, output_pipe[1]);

    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP);
    posix_spawnattr_setpgroup(&attributes, 0);

    char *spawn_argv[] = {
        "/bin/zsh",
        control->helper_path,
        (char *)action,
        NULL
    };
    pid_t pid = -1;
    int spawn_status = posix_spawn(&pid,
                                   "/bin/zsh",
                                   &file_actions,
                                   &attributes,
                                   spawn_argv,
                                   environ);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&file_actions);
    close(output_pipe[1]);

    if (spawn_status != 0) {
        close(output_pipe[0]);
        control->state = TB_SENDER_CONTROL_FAILED;
        snprintf(control->output, sizeof(control->output), "SPAWN_ERROR:%d", spawn_status);
        control->output_len = strlen(control->output);
        return -5;
    }

    control->pid = pid;
    control->output_fd = output_pipe[0];
    control->state = TB_SENDER_CONTROL_RUNNING;
    control->exit_status = -1;
    control->output_len = 0;
    control->output[0] = '\0';
    snprintf(control->action, sizeof(control->action), "%s", action);
    return 0;
}

static void tb_sender_control_read_output(struct tb_sender_control *control) {
    if (!control || control->output_fd < 0) return;
    while (control->output_len + 1 < sizeof(control->output)) {
        ssize_t count = read(control->output_fd,
                             control->output + control->output_len,
                             sizeof(control->output) - control->output_len - 1);
        if (count > 0) {
            control->output_len += (size_t)count;
            control->output[control->output_len] = '\0';
            continue;
        }
        if (count < 0 && errno == EINTR) continue;
        break;
    }
}

int tb_sender_control_poll(struct tb_sender_control *control) {
    if (!tb_sender_control_busy(control)) return 0;
    tb_sender_control_read_output(control);

    int status = 0;
    pid_t result = waitpid(control->pid, &status, WNOHANG);
    if (result == 0) return 0;
    if (result < 0 && errno == EINTR) return 0;

    tb_sender_control_read_output(control);
    if (control->output_fd >= 0) close(control->output_fd);
    control->output_fd = -1;
    control->pid = -1;
    control->exit_status = status;

    const int exited_cleanly = result > 0 && WIFEXITED(status) && WEXITSTATUS(status) == 0;
    const int reported_success =
        strstr(control->output, "SENDER_STARTED") != NULL ||
        strstr(control->output, "SENDER_STOPPED") != NULL ||
        strstr(control->output, "INPUT_SET:") != NULL;
    control->state = (exited_cleanly && reported_success)
        ? TB_SENDER_CONTROL_SUCCEEDED
        : TB_SENDER_CONTROL_FAILED;
    return 1;
}
