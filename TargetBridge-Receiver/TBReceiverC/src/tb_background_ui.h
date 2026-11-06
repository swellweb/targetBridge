#ifndef TB_BACKGROUND_UI_H
#define TB_BACKGROUND_UI_H

/* Menu bar icon and the "Run in background" controls of the receiver. */

enum tb_background_ui_action {
    TB_BACKGROUND_UI_SHOW_WINDOW = 1 << 0,
    TB_BACKGROUND_UI_TOGGLE = 1 << 1,
    TB_BACKGROUND_UI_QUIT = 1 << 2,
    TB_BACKGROUND_UI_TOGGLE_SHOW_AT_START = 1 << 3
};

int  tb_background_mode_load(void);
void tb_background_mode_save(int enabled);
int  tb_show_window_at_start_load(void);
void tb_show_window_at_start_save(int enabled);

void tb_background_ui_install(void);

/* Keeps the Dock presence, menu and window checkbox in step with the app. */
void tb_background_ui_update(int background_mode,
                             int show_at_start,
                             int window_visible,
                             int session_active,
                             const char *status);

/* Returns and clears the actions requested since the last call. */
unsigned int tb_background_ui_take_actions(void);

#endif
