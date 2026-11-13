#include <stdint.h>
#include <stddef.h>
#include "../TargetBridge-Receiver/TBReceiverC/src/idle_watchdog.h"

int tb_heartbeat_loopback(int sockets[2]);
int tb_heartbeat_write(int socket);
int tb_heartbeat_write_data(int socket, const void *data, size_t size);
int tb_heartbeat_read(int socket);
