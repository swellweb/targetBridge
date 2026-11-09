#ifndef TB_BACKGROUND_UI_H
#define TB_BACKGROUND_UI_H

/* Menu bar icon and the "Run in background" controls of the receiver. */

enum tb_background_ui_action {
    TB_BACKGROUND_UI_SHOW_WINDOW = 1 << 0,
    TB_BACKGROUND_UI_TOGGLE = 1 << 1,          /* app mode changed */
    TB_BACKGROUND_UI_QUIT = 1 << 2,
    TB_BACKGROUND_UI_TOGGLE_SHOW_AT_START = 1 << 3,
    TB_BACKGROUND_UI_TOGGLE_NEWEST_FRAME = 1 << 4,
    TB_BACKGROUND_UI_TOGGLE_WAKE_ON_DATA = 1 << 5,
    TB_BACKGROUND_UI_RENDERER_TARGETBRIDGE = 1 << 6,
    TB_BACKGROUND_UI_TOGGLE_STATS = 1 << 7,
    TB_BACKGROUND_UI_RENDERER_SDL_METAL = 1 << 8,
    TB_BACKGROUND_UI_RENDERER_SDL_OPENGL = 1 << 9,
    TB_BACKGROUND_UI_TOGGLE_DISPLAY_SYNC = 1 << 10,
    TB_BACKGROUND_UI_SIGNIN_INSTALL = 1 << 11,
    TB_BACKGROUND_UI_SIGNIN_UNINSTALL = 1 << 12,
    TB_BACKGROUND_UI_SIGNIN_HELP = 1 << 13
};

/* Where "Download update" in the menu bar points. */
#define TB_RECEIVER_DOWNLOAD_URL "https://github.com/mjfrank/targetBridge/releases/latest"

/* How the Receiver presents itself when no session runs. */
enum tb_app_presentation {
    TB_APP_PRESENTATION_STANDARD = 0,   /* window and Dock icon */
    TB_APP_PRESENTATION_BACKGROUND = 1, /* menu bar icon only */
    TB_APP_PRESENTATION_FACELESS = 2    /* no window, Dock or menu bar icon */
};

int  tb_app_presentation_load(void);
void tb_app_presentation_save(int presentation);
/* The app mode picked in the menu or window since the last call, or -1. */
int  tb_background_ui_take_presentation_request(void);
int  tb_show_window_at_start_load(void);
void tb_show_window_at_start_save(int enabled);

void tb_background_ui_install(void);

/* Stored receiver preference; default_value applies when it was never set. */
int  tb_pref_get(const char *key, int default_value);
void tb_pref_set(const char *key, int value);
int  tb_pref_get_int(const char *key, int default_value);

/* Sign-in screen mode submenu: shows whether the mode is installed. */
void tb_background_ui_set_signin_installed(int installed);
/* A simple alert (title + text), e.g. after installing the sign-in mode. */
void tb_background_ui_show_message(const char *title, const char *text);
void tb_pref_set_int(const char *key, int value);

/* renderer: enum tb_disp_renderer (0 TargetBridge Metal, 1 SDL Metal,
 * 2 SDL OpenGL). */
void tb_background_ui_set_performance(int newest_frame, int wake_on_data, int renderer,
                                      int display_sync, int stats);

/* Keeps the Dock presence, menu and window checkbox in step with the app. */
void tb_background_ui_update(int presentation,
                             int show_at_start,
                             int window_visible,
                             int session_active,
                             const char *status);

/* Shows a version notice and a "Download update" item in the menu bar;
 * NULL or "" hides both. */
void tb_background_ui_set_update_notice(const char *text);

/* Returns and clears the actions requested since the last call. */
unsigned int tb_background_ui_take_actions(void);

#endif
