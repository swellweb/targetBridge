#include <stdint.h>
void *tb_heartbeat_monitor_start(int socket, uint64_t timeout_ms);
int tb_heartbeat_monitor_expired(void *monitor);
int tb_heartbeat_monitor_received(void *monitor);
void tb_heartbeat_monitor_stop(void *monitor);
