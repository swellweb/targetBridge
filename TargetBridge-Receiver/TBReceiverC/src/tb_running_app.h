/* tb_running_app.h — bring an already running copy of this app to the front. */

#ifndef TB_RUNNING_APP_H
#define TB_RUNNING_APP_H

#ifdef __cplusplus
extern "C" {
#endif

/* Activates another running process with this bundle identifier (never this
 * process). Returns 1 if one was found, 0 otherwise. */
int tb_running_app_activate(const char *bundle_id);

#ifdef __cplusplus
}
#endif

#endif
