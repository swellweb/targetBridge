#ifndef TB_GESTURE_BRIDGE_H
#define TB_GESTURE_BRIDGE_H

#include <stddef.h>

typedef void (*tb_gesture_space_switch_callback)(int direction, void *context);

void tb_gesture_bridge_install(tb_gesture_space_switch_callback callback, void *context);
void tb_gesture_bridge_set_active(int active);

/* Returns 1 if the given SDL_Window's Cocoa window is on the active macOS
 * Space (or can't be determined), 0 if it is on a different Space. */
int tb_window_on_active_space(void *sdl_window);

/* Local UI safety gate for receiverMaster mode. The first function reports
 * whether TargetBridge is the active local application. The second reports a
 * visible foreign window (Notification Center, System Settings, an alert,
 * menu bar, etc.) above the Receiver at a Quartz-global pointer location. */
int tb_receiver_app_is_active(void);

/* Keep the fullscreen monitor surface above Notification Center while a
 * session is active, restoring the normal window level on Stop/disconnect. */
void tb_receiver_set_monitor_shield(int active);

int tb_local_ui_above_receiver_at_point(void *sdl_window,
                                        double x,
                                        double y,
                                        char *owner_name,
                                        size_t owner_name_size);

#endif
