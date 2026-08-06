#include "tb_i18n.h"

#include <ctype.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef TB_LANGUAGE_SOURCE_DIR
#define TB_LANGUAGE_SOURCE_DIR ""
#endif

struct tb_i18n_entry {
    char *key;
    char *value;
};

static struct tb_i18n_entry *g_active_entries = NULL;
static size_t g_active_count = 0;
static struct tb_i18n_entry *g_fallback_entries = NULL;
static size_t g_fallback_count = 0;
static int g_i18n_ready = 0;
static char g_runtime_language[8] = "";
static char g_current_language[8] = "en";

static void tb_i18n_free_entries(struct tb_i18n_entry *entries, size_t count) {
    if (!entries) return;
    for (size_t i = 0; i < count; i++) {
        free(entries[i].key);
        free(entries[i].value);
    }
    free(entries);
}

static void tb_i18n_skip_ws(const char **p) {
    while (**p && isspace((unsigned char)**p)) (*p)++;
}

static char *tb_i18n_parse_string(const char **p) {
    if (!p || **p != '"') return NULL;
    (*p)++;

    size_t cap = 64;
    size_t len = 0;
    char *out = (char *)calloc(cap, 1);
    if (!out) return NULL;

    while (**p) {
        char c = *(*p)++;

        if (c == '"') {
            out[len] = '\0';
            return out;
        }

        if (c == '\\') {
            char esc = **p;
            if (!esc) break;
            (*p)++;
            switch (esc) {
            case '"': c = '"'; break;
            case '\\': c = '\\'; break;
            case '/': c = '/'; break;
            case 'b': c = '\b'; break;
            case 'f': c = '\f'; break;
            case 'n': c = '\n'; break;
            case 'r': c = '\r'; break;
            case 't': c = '\t'; break;
            case 'u':
                c = '?';
                for (int i = 0; i < 4 && **p; i++) (*p)++;
                break;
            default:
                c = esc;
                break;
            }
        }

        if (len + 2 >= cap) {
            cap *= 2;
            char *grown = (char *)realloc(out, cap);
            if (!grown) {
                free(out);
                return NULL;
            }
            out = grown;
        }
        out[len++] = c;
    }

    free(out);
    return NULL;
}

static int tb_i18n_parse_flat_json(const char *json,
                                   struct tb_i18n_entry **entries_out,
                                   size_t *count_out) {
    const char *p = json;
    struct tb_i18n_entry *entries = NULL;
    size_t count = 0;
    size_t cap = 0;

    tb_i18n_skip_ws(&p);
    if (*p != '{') return -1;
    p++;

    for (;;) {
        tb_i18n_skip_ws(&p);
        if (*p == '}') break;

        char *key = tb_i18n_parse_string(&p);
        if (!key) goto fail;

        tb_i18n_skip_ws(&p);
        if (*p != ':') {
            free(key);
            goto fail;
        }
        p++;
        tb_i18n_skip_ws(&p);

        char *value = tb_i18n_parse_string(&p);
        if (!value) {
            free(key);
            goto fail;
        }

        if (count == cap) {
            cap = cap ? cap * 2 : 32;
            struct tb_i18n_entry *grown =
                (struct tb_i18n_entry *)realloc(entries, cap * sizeof(*entries));
            if (!grown) {
                free(key);
                free(value);
                goto fail;
            }
            entries = grown;
        }

        entries[count].key = key;
        entries[count].value = value;
        count++;

        tb_i18n_skip_ws(&p);
        if (*p == ',') {
            p++;
            continue;
        }
        if (*p == '}') break;
        goto fail;
    }

    *entries_out = entries;
    *count_out = count;
    return 0;

fail:
    tb_i18n_free_entries(entries, count);
    return -1;
}

static int tb_i18n_read_file(const char *path, char **contents_out) {
    FILE *fp = fopen(path, "rb");
    if (!fp) return -1;

    if (fseek(fp, 0, SEEK_END) != 0) {
        fclose(fp);
        return -1;
    }
    long size = ftell(fp);
    if (size < 0) {
        fclose(fp);
        return -1;
    }
    if (fseek(fp, 0, SEEK_SET) != 0) {
        fclose(fp);
        return -1;
    }

    char *buf = (char *)calloc((size_t)size + 1, 1);
    if (!buf) {
        fclose(fp);
        return -1;
    }

    if (size > 0 && fread(buf, 1, (size_t)size, fp) != (size_t)size) {
        free(buf);
        fclose(fp);
        return -1;
    }

    fclose(fp);
    *contents_out = buf;
    return 0;
}

static int tb_i18n_load_language_file(const char *path,
                                      struct tb_i18n_entry **entries_out,
                                      size_t *count_out) {
    char *contents = NULL;
    if (tb_i18n_read_file(path, &contents) != 0) return -1;
    int rc = tb_i18n_parse_flat_json(contents, entries_out, count_out);
    free(contents);
    return rc;
}

static void tb_i18n_normalize_language(const char *input, char lang_out[8]) {
    snprintf(lang_out, 8, "%s", "en");
    if (!input || !*input) return;

    size_t j = 0;
    for (size_t i = 0; input[i] && j + 1 < 8; i++) {
        char c = (char)tolower((unsigned char)input[i]);
        if (c == '_' || c == '-' || c == '.') break;
        lang_out[j++] = c;
    }
    lang_out[j] = '\0';
    if (!lang_out[0]) snprintf(lang_out, 8, "%s", "en");
}

static void tb_i18n_bundle_languages_dir(char path_out[PATH_MAX]) {
    path_out[0] = '\0';

    char exe_path[PATH_MAX];
    uint32_t size = (uint32_t)sizeof(exe_path);
    if (_NSGetExecutablePath(exe_path, &size) != 0) return;

    char resolved[PATH_MAX];
    if (!realpath(exe_path, resolved)) return;

    char *slash = strrchr(resolved, '/');
    if (!slash) return;
    *slash = '\0';
    slash = strrchr(resolved, '/');
    if (!slash) return;
    *slash = '\0';

    snprintf(path_out, PATH_MAX, "%s/Resources/Languages", resolved);
}

static int tb_i18n_try_load(const char *base_dir,
                            const char *lang,
                            struct tb_i18n_entry **entries_out,
                            size_t *count_out) {
    if (!base_dir || !*base_dir || !lang || !*lang) return -1;

    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/%s.json", base_dir, lang);
    return tb_i18n_load_language_file(path, entries_out, count_out);
}

static const char *tb_i18n_find_in(struct tb_i18n_entry *entries, size_t count, const char *key) {
    if (!entries || !key) return NULL;
    for (size_t i = 0; i < count; i++) {
        if (strcmp(entries[i].key, key) == 0) return entries[i].value;
    }
    return NULL;
}

static void tb_i18n_reset_loaded_state(void) {
    tb_i18n_free_entries(g_active_entries, g_active_count);
    tb_i18n_free_entries(g_fallback_entries, g_fallback_count);
    g_active_entries = NULL;
    g_active_count = 0;
    g_fallback_entries = NULL;
    g_fallback_count = 0;
    g_i18n_ready = 0;
}

void tb_i18n_set_runtime_language(const char *language_code) {
    if (!language_code || !*language_code || strcmp(language_code, "auto") == 0) {
        if (g_runtime_language[0] != '\0') {
            g_runtime_language[0] = '\0';
            tb_i18n_reset_loaded_state();
        }
        return;
    }

    char normalized[8];
    tb_i18n_normalize_language(language_code, normalized);
    if (normalized[0] == '\0') return;
    if (strcmp(g_runtime_language, normalized) == 0) return;

    snprintf(g_runtime_language, sizeof(g_runtime_language), "%s", normalized);
    tb_i18n_reset_loaded_state();
}

int tb_i18n_init(void) {
    if (g_i18n_ready) return 0;

    char lang[8];
    if (g_runtime_language[0] != '\0') {
        snprintf(lang, sizeof(lang), "%s", g_runtime_language);
    } else {
        tb_i18n_normalize_language(getenv("TB_LANG"), lang);
    }
    if (strcmp(lang, "en") == 0 && g_runtime_language[0] == '\0') {
        char lang_from_env[8];
        tb_i18n_normalize_language(getenv("LANG"), lang_from_env);
        if (lang_from_env[0]) snprintf(lang, sizeof(lang), "%s", lang_from_env);
    }

    char bundle_dir[PATH_MAX];
    tb_i18n_bundle_languages_dir(bundle_dir);

    if (tb_i18n_try_load(bundle_dir, lang, &g_active_entries, &g_active_count) != 0 &&
        tb_i18n_try_load(TB_LANGUAGE_SOURCE_DIR, lang, &g_active_entries, &g_active_count) != 0 &&
        strcmp(lang, "en") != 0 &&
        tb_i18n_try_load(bundle_dir, "en", &g_active_entries, &g_active_count) != 0 &&
        tb_i18n_try_load(TB_LANGUAGE_SOURCE_DIR, "en", &g_active_entries, &g_active_count) != 0) {
        return -1;
    }

    if (g_active_count > 0) {
        snprintf(g_current_language, sizeof(g_current_language), "%s", lang);
    } else {
        snprintf(g_current_language, sizeof(g_current_language), "%s", "en");
    }

    if (strcmp(lang, "en") != 0) {
        if (tb_i18n_try_load(bundle_dir, "en", &g_fallback_entries, &g_fallback_count) != 0) {
            (void)tb_i18n_try_load(TB_LANGUAGE_SOURCE_DIR, "en", &g_fallback_entries, &g_fallback_count);
        }
    }

    g_i18n_ready = 1;
    return 0;
}

const char *tb_i18n_current_language(void) {
    if (!g_i18n_ready) (void)tb_i18n_init();
    return g_current_language;
}

const char *tb_i18n_get(const char *key) {
    static char missing[256];

    if (!key) return "";
    if (!g_i18n_ready) (void)tb_i18n_init();

    const char *value = tb_i18n_find_in(g_active_entries, g_active_count, key);
    if (!value) value = tb_i18n_find_in(g_fallback_entries, g_fallback_count, key);
    if (value) return value;

    snprintf(missing, sizeof(missing), "[[%s]]", key);
    return missing;
}

static const char *tb_i18n_lookup_pair(const struct tb_i18n_pair *pairs,
                                       size_t pair_count,
                                       const char *name,
                                       size_t name_len) {
    if (!pairs || !name) return NULL;
    for (size_t i = 0; i < pair_count; i++) {
        if (!pairs[i].name) continue;
        if (strlen(pairs[i].name) == name_len &&
            strncmp(pairs[i].name, name, name_len) == 0) {
            return pairs[i].value ? pairs[i].value : "";
        }
    }
    return NULL;
}

static void tb_i18n_append(char *dest, size_t size, size_t *offset, const char *text) {
    while (*text && *offset + 1 < size) {
        dest[*offset] = *text++;
        (*offset)++;
    }
    dest[*offset] = '\0';
}

void tb_i18n_format(char *dest,
                    size_t size,
                    const char *key,
                    const struct tb_i18n_pair *pairs,
                    size_t pair_count) {
    if (!dest || size == 0) return;
    dest[0] = '\0';

    const char *tmpl = tb_i18n_get(key);
    size_t out = 0;

    for (size_t i = 0; tmpl[i] && out + 1 < size; i++) {
        if (tmpl[i] == '%' && tmpl[i + 1] == '{') {
            size_t start = i + 2;
            size_t end = start;
            while (tmpl[end] && tmpl[end] != '}') end++;
            if (tmpl[end] == '}') {
                const char *replacement = tb_i18n_lookup_pair(pairs, pair_count, tmpl + start, end - start);
                if (replacement) {
                    tb_i18n_append(dest, size, &out, replacement);
                } else {
                    while (i <= end && out + 1 < size) {
                        dest[out++] = tmpl[i++];
                    }
                    dest[out] = '\0';
                    i--;
                }
                i = end;
                continue;
            }
        }

        dest[out++] = tmpl[i];
        dest[out] = '\0';
    }
}
