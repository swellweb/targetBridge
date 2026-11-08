#ifndef TB_BACKGROUND_UI_H
#define TB_BACKGROUND_UI_H

/* Menu bar icon and the "Run in background" controls of the receiver. */

enum tb_background_ui_action {
    TB_BACKGROUND_UI_SHOW_WINDOW = 1 << 0,
    TB_BACKGROUND_UI_TOGGLE = 1 << 1,
    TB_BACKGROUND_UI_QUIT = 1 << 2,
    TB_BACKGROUND_UI_TOGGLE_SHOW_AT_START = 1 << 3,
    TB_BACKGROUND_UI_TOGGLE_NEWEST_FRAME = 1 << 4,
    TB_BACKGROUND_UI_TOGGLE_WAKE_ON_DATA = 1 << 5,
    TB_BACKGROUND_UI_TOGGLE_METAL = 1 << 6,
    TB_BACKGROUND_UI_TOGGLE_STATS = 1 << 7
};

/* Where "Download update" in the menu bar points. */
#define TB_RECEIVER_DOWNLOAD_URL "https://github.com/mjfrank/targetBridge/releases/latest"

int  tb_background_mode_load(void);
void tb_background_mode_save(int enabled);
int  tb_show_window_at_start_load(void);
void tb_show_window_at_start_save(int enabled);

void tb_background_ui_install(void);

/* Stored receiver preference; default_value applies when it was never set. */
int  tb_pref_get(const char *key, int default_value);
void tb_pref_set(const char *key, int value);

void tb_background_ui_set_performance(int newest_frame, int wake_on_data, int metal, int stats);

/* Keeps the Dock presence, menu and window checkbox in step with the app. */
void tb_background_ui_update(int background_mode,
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
