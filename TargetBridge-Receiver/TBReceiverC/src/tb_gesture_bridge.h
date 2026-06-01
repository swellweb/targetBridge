#ifndef TB_GESTURE_BRIDGE_H
#define TB_GESTURE_BRIDGE_H

typedef void (*tb_gesture_space_switch_callback)(int direction, void *context);

void tb_gesture_bridge_install(tb_gesture_space_switch_callback callback, void *context);
void tb_gesture_bridge_set_active(int active);

#endif
