/* receiver_state.h — persistent monitor-mode state and single-instance lock. */

#ifndef TB_RECEIVER_STATE_H
#define TB_RECEIVER_STATE_H

struct tb_receiver_monitor_state {
    int auto_sender_enabled;
    int input_enabled;
    char preferred_action[32];
};

void tb_receiver_monitor_state_default(struct tb_receiver_monitor_state *state);
int  tb_receiver_monitor_state_load(struct tb_receiver_monitor_state *state);
int  tb_receiver_monitor_state_save(const struct tb_receiver_monitor_state *state);
int  tb_receiver_monitor_action_is_valid(const char *action);
int  tb_receiver_teardown_requests_suspend(const char *reason);

/* Returns an open lock fd on success, -2 when another Receiver owns the lock,
 * or -1 when the lock could not be created. Keep the fd open for app lifetime. */
int tb_receiver_single_instance_lock(void);

#endif
