/* sender_control.h — asynchronous, receiver-integrated Mac mini control. */

#ifndef TB_SENDER_CONTROL_H
#define TB_SENDER_CONTROL_H

#include <limits.h>
#include <stddef.h>
#include <sys/types.h>

enum tb_sender_control_state {
    TB_SENDER_CONTROL_IDLE = 0,
    TB_SENDER_CONTROL_RUNNING,
    TB_SENDER_CONTROL_SUCCEEDED,
    TB_SENDER_CONTROL_FAILED
};

struct tb_sender_control {
    pid_t pid;
    int output_fd;
    enum tb_sender_control_state state;
    int exit_status;
    char action[32];
    char output[1024];
    size_t output_len;
    char helper_path[PATH_MAX];
};

void tb_sender_control_init(struct tb_sender_control *control);
void tb_sender_control_destroy(struct tb_sender_control *control);
int  tb_sender_control_start(struct tb_sender_control *control, const char *action);
void tb_sender_control_cancel(struct tb_sender_control *control);
int  tb_sender_control_poll(struct tb_sender_control *control);
int  tb_sender_control_busy(const struct tb_sender_control *control);

#endif
