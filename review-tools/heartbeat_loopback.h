#include <stdint.h>
#include "../TargetBridge-Receiver/TBReceiverC/src/idle_watchdog.h"

int tb_heartbeat_loopback(int sockets[2]);
int tb_heartbeat_write(int socket);
int tb_heartbeat_read(int socket);
