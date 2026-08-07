/* tb_display_tweaks.h — Night Shift / True Tone on the receiver's own panel.
 * Implemented over the private CoreBrightness framework; every entry point is
 * safe to call on a Mac that lacks the feature (returns unsupported / -1). */

#ifndef TB_DISPLAY_TWEAKS_H
#define TB_DISPLAY_TWEAKS_H

#ifdef __cplusplus
extern "C" {
#endif

/* 1 if the panel can do it, 0 otherwise. */
int tb_night_shift_supported(void);
int tb_true_tone_supported(void);

/* Current state, so the sender's UI can follow changes made on this Mac. */
int tb_true_tone_enabled(void);
int tb_night_shift_enabled(void);

/* 0 on success, -1 when unavailable. */
int tb_night_shift_set(int enabled);
int tb_true_tone_set(int enabled);

#ifdef __cplusplus
}
#endif

#endif
