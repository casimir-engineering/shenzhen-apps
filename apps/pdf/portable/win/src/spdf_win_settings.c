/* spdf_win_settings.c — see spdf_win_settings.h for the schema and its
 * sources in the two shipping frontends.
 *
 * The JSON marshalling is spdf_win_session_json.h's -- the same hand-written
 * reader over the codec's compact output and the same locale-independent
 * emitter the session uses, included here as a second copy of a few static
 * functions rather than promoted to a module, for the reason that header gives
 * for existing at all. Nothing here writes YAML: the on-disk format has one
 * codec and it is the shared one.
 *
 * Plain C, like spdf_win_state.c beside it, so the native test drives the real
 * parse/emit pair with a C compiler.
 */
#include "spdf_win_settings.h"

#include "spdf_win_recents.h" /* "recentlyOpened" is its list, written by this file's one writer */
#include "spdf_win_session_json.h"
#include "spdf_win_state.h"

#include <stdlib.h>
#include <string.h>

/* --- defaults and clamps -------------------------------------------------- */

void spdf_win_settings_init_defaults(spdf_win_settings* s) {
    if (!s) return;
    memset(s, 0, sizeof(*s));
    s->fit_mode = 4; /* fit page, both apps' default */
    s->zoom = 1.0;
    s->sidebar_width = 240;
    s->minimap_width = 126.5;
    s->default_sidebar_visible = 1;
    s->default_minimap_visible = 1;
    s->search_jumps_to_nearest_result = 1;
    s->prevent_sleep_in_presentation = 1;
    s->print_scaling_mode = 0;
    s->print_custom_scale = 1.0;
    s->window_width = SPDF_WIN_SETTINGS_DEFAULT_WINDOW_W;
    s->window_height = SPDF_WIN_SETTINGS_DEFAULT_WINDOW_H;
    s->theme = SPDF_WIN_THEME_SYSTEM;
    s->dark_theme_preserves_images = 1; /* ShenzhenPDFMac.mm:1153, default ON */
    s->setup_prompt_answered = 0;       /* the first-run question has not been asked yet */
}

static int clamp_i(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

static double clamp_d(double v, double lo, double hi) {
    if (!(v == v)) return lo; /* NaN */
    return v < lo ? lo : (v > hi ? hi : v);
}

/* The mac writer emits NSNumber bools, which the codec renders as true/false;
 * a hand-edited file may say 1/0. Both frontends accept both. */
static int read_bool(const char* obj, const char* key, int fallback, int* found) {
    const char* v = obj_value(obj, key, NULL);
    if (!v) return fallback;
    if (found) *found += 1;
    if (*v == 't') return 1;
    if (*v == 'f') return 0;
    if (*v == '1') return 1;
    if (*v == '0') return 0;
    return fallback;
}

static int has_key(const char* obj, const char* key) { return obj_value(obj, key, NULL) != NULL; }

/* --- parse ---------------------------------------------------------------- */

int spdf_win_settings_parse_json(spdf_win_settings* s, const char* json) {
    int found = 0;
    const char* root;
    const char* size;
    char* theme;

    if (!s || !json) return 0;
    root = skip_ws(json);
    if (*root != '{') return 0;

    if (has_key(root, "fitMode")) {
        s->fit_mode = clamp_i(json_int(root, "fitMode", s->fit_mode), 0, 4);
        found++;
    }
    if (has_key(root, "zoom")) {
        s->zoom = clamp_d(json_num(root, "zoom", s->zoom), SPDF_WIN_SETTINGS_MIN_ZOOM, SPDF_WIN_SETTINGS_MAX_ZOOM);
        found++;
    }
    if (has_key(root, "sidebarWidth")) {
        s->sidebar_width = clamp_i(json_int(root, "sidebarWidth", s->sidebar_width), SPDF_WIN_SETTINGS_MIN_SIDEBAR_W,
                                   SPDF_WIN_SETTINGS_MAX_SIDEBAR_W);
        found++;
    }
    if (has_key(root, "minimapWidth")) {
        s->minimap_width = clamp_d(json_num(root, "minimapWidth", s->minimap_width), SPDF_WIN_SETTINGS_MIN_MINIMAP_W,
                                   SPDF_WIN_SETTINGS_MAX_MINIMAP_W);
        found++;
    }
    s->default_sidebar_visible = read_bool(root, "defaultSidebarVisibleForNewDocuments", s->default_sidebar_visible, &found);
    s->default_minimap_visible = read_bool(root, "defaultMinimapVisibleForNewDocuments", s->default_minimap_visible, &found);
    s->search_jumps_to_nearest_result =
        read_bool(root, "searchJumpsToNearestResult", s->search_jumps_to_nearest_result, &found);
    s->prevent_sleep_in_presentation =
        read_bool(root, "preventSleepInPresentation", s->prevent_sleep_in_presentation, &found);
    s->dark_theme_preserves_images = read_bool(root, "darkThemePreservesImages", s->dark_theme_preserves_images, &found);
    s->setup_prompt_answered = read_bool(root, "setupPromptAnswered", s->setup_prompt_answered, &found);
    if (has_key(root, "printScalingMode")) {
        s->print_scaling_mode = clamp_i(json_int(root, "printScalingMode", s->print_scaling_mode), 0, 2);
        found++;
    }
    if (has_key(root, "printCustomScale")) {
        double v = json_num(root, "printCustomScale", s->print_custom_scale);
        /* SPDFClampPrintCustomScale: non-positive is 1.0, else clamped. */
        s->print_custom_scale = v > 0.0 ? clamp_d(v, SPDF_WIN_SETTINGS_MIN_ZOOM, SPDF_WIN_SETTINGS_MAX_ZOOM) : 1.0;
        found++;
    }
    size = obj_value(root, "windowSize", NULL);
    if (size && *size == '{') {
        int w = json_int(size, "width", s->window_width);
        int h = json_int(size, "height", s->window_height);
        if (w > 0 && h > 0) {
            s->window_width = w;
            s->window_height = h;
        }
        found++;
    }
    theme = json_str(root, "markdownTheme");
    if (theme) {
        s->theme = strcmp(theme, "dark") == 0 ? SPDF_WIN_THEME_DARK : SPDF_WIN_THEME_LIGHT;
        free(theme);
        found++;
    }
    theme = json_str(root, "commentAuthor");
    if (theme) {
        strncpy_s(s->comment_author, sizeof(s->comment_author), theme, _TRUNCATE);
        free(theme);
        found++;
    }
    theme = json_str(root, "printerName");
    if (theme) {
        strncpy_s(s->printer_name, sizeof(s->printer_name), theme, _TRUNCATE);
        free(theme);
        found++;
    }
    return found;
}

/* --- emit ----------------------------------------------------------------- */

static int key_is_owned(const member* m) {
    static const char* const owned[] = {"fitMode",
                                        "zoom",
                                        "sidebarWidth",
                                        "minimapWidth",
                                        "defaultSidebarVisibleForNewDocuments",
                                        "defaultMinimapVisibleForNewDocuments",
                                        "searchJumpsToNearestResult",
                                        "preventSleepInPresentation",
                                        "printScalingMode",
                                        "printCustomScale",
                                        "windowSize",
                                        "markdownTheme",
                                        "darkThemePreservesImages",
                                        "setupPromptAnswered",
                                        "commentAuthor",
                                        "printerName"};
    size_t i;
    for (i = 0; i < sizeof(owned) / sizeof(owned[0]); ++i)
        if (key_is(m, owned[i])) return 1;
    return 0;
}

static void emit_bool_key(out_buf* out, const char* key, int value) {
    emit_key(out, key);
    buf_puts(out, value ? "true" : "false");
}

char* spdf_win_settings_to_json(const spdf_win_settings* s, const char* existing_json) {
    out_buf out;
    const char* root = existing_json ? skip_ws(existing_json) : NULL;
    member m;
    int ok;

    if (!s) return NULL;
    memset(&out, 0, sizeof(out));
    buf_puts(&out, "{\"fitMode\":");
    emit_int(&out, s->fit_mode);
    emit_key(&out, "zoom");
    emit_fixed(&out, s->zoom, 4);
    emit_key(&out, "sidebarWidth");
    emit_int(&out, s->sidebar_width);
    emit_key(&out, "minimapWidth");
    emit_fixed(&out, s->minimap_width, 4);
    emit_bool_key(&out, "defaultSidebarVisibleForNewDocuments", s->default_sidebar_visible);
    emit_bool_key(&out, "defaultMinimapVisibleForNewDocuments", s->default_minimap_visible);
    emit_bool_key(&out, "searchJumpsToNearestResult", s->search_jumps_to_nearest_result);
    emit_bool_key(&out, "preventSleepInPresentation", s->prevent_sleep_in_presentation);
    emit_bool_key(&out, "setupPromptAnswered", s->setup_prompt_answered);
    emit_key(&out, "printScalingMode");
    emit_int(&out, s->print_scaling_mode);
    emit_key(&out, "printCustomScale");
    emit_fixed(&out, s->print_custom_scale, 4);
    emit_key(&out, "windowSize");
    buf_puts(&out, "{\"width\":");
    emit_int(&out, s->window_width);
    buf_puts(&out, ",\"height\":");
    emit_int(&out, s->window_height);
    buf_puts(&out, "}");
    /* Absent means "the system's" and stays absent: see the header. */
    if (s->theme == SPDF_WIN_THEME_DARK || s->theme == SPDF_WIN_THEME_LIGHT) {
        emit_key(&out, "markdownTheme");
        emit_string(&out, s->theme == SPDF_WIN_THEME_DARK ? "dark" : "light");
    }
    emit_bool_key(&out, "darkThemePreservesImages", s->dark_theme_preserves_images);
    /* Always, and "" when unset: ShenzhenPDFMac.mm:1799 writes `_commentAuthor
     * ?: @""`, spdf_state.c:631 the same. */
    emit_key(&out, "commentAuthor");
    emit_string(&out, s->comment_author);
    /* Only when there is one: a reader who has never printed should not find a
     * key in their settings.yaml saying so. See the header. */
    if (s->printer_name[0]) {
        emit_key(&out, "printerName");
        emit_string(&out, s->printer_name);
    }

    /* Everything on disk this file does not model, verbatim. */
    if (root && *root == '{') {
        for (ok = object_first(root, &m); ok; ok = object_next(&m)) {
            if (key_is_owned(&m)) continue;
            buf_puts(&out, ",\"");
            buf_put(&out, m.key, m.key_len);
            buf_puts(&out, "\":");
            buf_put(&out, m.val, (size_t)(m.val_end - m.val));
        }
    }
    buf_puts(&out, "}");
    if (out.failed) {
        free(out.data);
        return NULL;
    }
    return out.data;
}

/* --- the file ------------------------------------------------------------- */

spdf_win_settings_status spdf_win_settings_load(spdf_win_settings* s) {
    spdf_win_state_read_status status = SPDF_WIN_STATE_READ_ABSENT;
    char* json;
    if (!s) return SPDF_WIN_SETTINGS_ABSENT;
    spdf_win_settings_init_defaults(s);
    json = spdf_win_state_read_json_checked(SPDF_WIN_STATE_SETTINGS, &status);
    if (status == SPDF_WIN_STATE_READ_FAILED) {
        free(json);
        return SPDF_WIN_SETTINGS_UNREADABLE;
    }
    if (!json) return SPDF_WIN_SETTINGS_ABSENT;
    spdf_win_settings_parse_json(s, json);
    free(json);
    return SPDF_WIN_SETTINGS_LOADED;
}

int spdf_win_settings_save(const spdf_win_settings* s) {
    spdf_win_state_read_status status = SPDF_WIN_STATE_READ_ABSENT;
    char* existing;
    char* json;
    char* merged;
    int ok;
    if (!s) return 0;
    existing = spdf_win_state_read_json_checked(SPDF_WIN_STATE_SETTINGS, &status);
    if (status == SPDF_WIN_STATE_READ_FAILED) {
        /* Present and unreadable. Write NOTHING: see the header. */
        free(existing);
        return 0;
    }
    json = spdf_win_settings_to_json(s, existing);
    free(existing);
    if (!json) return 0;
    /* "recentlyOpened" belongs to the recents module, which keeps the order in
     * memory and hands it over here so the shared key is written once, by the
     * file's one writer (spdf_win_recents.h, "WHERE THE MRU LIST LIVES"). A
     * failed merge (allocation) writes the document as it was, key carried
     * through from disk. */
    merged = spdf_win_recents_merge_recently_opened(json);
    ok = spdf_win_state_write_json(SPDF_WIN_STATE_SETTINGS, merged ? merged : json);
    free(merged);
    free(json);
    return ok;
}

/* --- the process-wide copy ------------------------------------------------ */

static spdf_win_settings g_shared;
static int g_shared_loaded;
static spdf_win_settings_status g_shared_status = SPDF_WIN_SETTINGS_ABSENT;

spdf_win_settings* spdf_win_settings_shared(void) {
    if (!g_shared_loaded) {
        g_shared_status = spdf_win_settings_load(&g_shared);
        g_shared_loaded = 1;
    }
    return &g_shared;
}

spdf_win_settings_status spdf_win_settings_shared_status(void) {
    spdf_win_settings_shared();
    return g_shared_status;
}

int spdf_win_settings_commit(void) {
    spdf_win_settings_shared();
    if (g_shared_status == SPDF_WIN_SETTINGS_UNREADABLE) return 0;
    return spdf_win_settings_save(&g_shared);
}

void spdf_win_settings_reset_shared(void) {
    g_shared_loaded = 0;
    g_shared_status = SPDF_WIN_SETTINGS_ABSENT;
}
