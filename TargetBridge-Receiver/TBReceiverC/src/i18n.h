/* i18n.h — Lightweight runtime locale switch for the C receiver.
 *
 * Header-only (inline) so it does not change the Makefile.
 *
 * The receiver reads its preferred language once and then renders all UI
 * strings (banner, status messages, window title) in that language.
 *
 * Selection priority:
 *   1. TBR_LANG environment variable: "zh" (or "zh-*") -> Chinese,
 *      anything else (e.g. "en") -> English.
 *   2. LC_ALL / LANG / LC_MESSAGES: starts with "zh" / "ZH" -> Chinese.
 *   3. Fallback: English.
 *
 * The result is cached after the first call.
 */
#ifndef TB_I18N_H
#define TB_I18N_H

#include <stdlib.h>
#include <string.h>

static inline int tb_i18n__match_zh(const char *value) {
    if (!value || !*value) return 0;
    return (strncmp(value, "zh", 2) == 0) || (strncmp(value, "ZH", 2) == 0);
}

/* Returns 1 when the receiver should render Chinese text, 0 for English. */
static inline int tb_locale_is_chinese(void) {
    static int cached = -1;
    if (cached != -1) return cached;

    const char *override = getenv("TBR_LANG");
    if (override && *override) {
        if (tb_i18n__match_zh(override)) {
            cached = 1;
            return 1;
        }
        /* Explicit non-zh override (e.g. "en") forces English. */
        cached = 0;
        return 0;
    }

    const char *vars[] = { "LC_ALL", "LC_MESSAGES", "LANG", NULL };
    for (int i = 0; vars[i]; ++i) {
        const char *v = getenv(vars[i]);
        if (tb_i18n__match_zh(v)) {
            cached = 1;
            return 1;
        }
    }

    cached = 0;
    return 0;
}

/* Convenience: pick between an English and a Chinese literal at runtime. */
static inline const char *tb_tr(const char *en, const char *zh) {
    return tb_locale_is_chinese() ? zh : en;
}

#endif /* TB_I18N_H */
