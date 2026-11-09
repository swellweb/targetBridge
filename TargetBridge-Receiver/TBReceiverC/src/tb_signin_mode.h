/* tb_signin_mode.h — experimental sign-in screen mode.
 *
 * With the mode installed, macOS starts a second Receiver ("--login-window")
 * while the sign-in window is shown, before anyone has logged in. It shows a
 * Mac's picture above the sign-in window only while a session runs; the
 * iMac's keyboard and mouse never control the Mac, and Esc or a double-click
 * on the iMac ends the session. When someone logs in, the instance quits and
 * the normal Receiver takes over.
 *
 * Nothing is installed by default: the Receiver menu installs one LaunchAgent
 * plist (LimitLoadToSessionType LoginWindow) in /Library/LaunchAgents after
 * an administrator password prompt, and removes it again on Uninstall. */

#ifndef TB_SIGNIN_MODE_H
#define TB_SIGNIN_MODE_H

#include <stddef.h>

#define TB_SIGNIN_LAUNCH_AGENT_LABEL "com.targetbridge.receiver.signin"
#define TB_SIGNIN_LAUNCH_AGENT_PATH  "/Library/LaunchAgents/" TB_SIGNIN_LAUNCH_AGENT_LABEL ".plist"
#define TB_SIGNIN_LOG_PATH           "/private/tmp/TargetBridge-SignInScreen.log"

/* This process runs as the sign-in screen instance. */
void tb_signin_set_active(int active);
int  tb_signin_active(void);

/* Lets the Receiver's windows appear above the sign-in window. Call after
 * the window was created and whenever it is shown again. */
void tb_signin_prepare_windows(void);

/* 1 while a user is logged in at the console (not the sign-in window). */
int  tb_signin_console_user_logged_in(void);

/* The LaunchAgent plist exists. */
int  tb_signin_installed(void);

/* Install / uninstall with an administrator password prompt. Return 0 on
 * success, 1 if the user cancelled, -1 on an error (message in `error`). */
int  tb_signin_install(char *error, size_t error_size);
int  tb_signin_uninstall(char *error, size_t error_size);

#endif
