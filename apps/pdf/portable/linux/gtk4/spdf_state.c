// spdf_state.c — state persistence for the GTK4 frontend.
//
// Files live in $XDG_CONFIG_HOME/shenzhenpdf (same directory the GTK3 app
// used, so upgrading users keep their state) and follow the Mac app's state
// schemas: settings.yaml, session.yaml, favorites.yaml, documents.yaml. On
// disk the files are YAML (shared codec in core/spdf_yaml.h); internally this
// module keeps building and scanning JSON text, converting at the file
// boundary. Legacy .json files are auto-migrated (flock-guarded, originals
// kept as <name>.json.migrated-backup) on load. The reader also accepts the
// GTK3 frontend's legacy shapes (1-based session pages, {"favorites": [...]}
// wrapper, windowWidth/windowHeight settings) and migrates them on the next
// write.
//
// Launch speed: spdf_state_load() performs exactly two stat+read pairs
// (settings.yaml + session.yaml, both size-capped) and hand-rolled string
// parsing — no json-glib, no new dependencies. favorites.yaml and
// documents.yaml load lazily on first use.
//
// Writes are coalesced (dirty flags + one 1s timer — the June 2026 batching
// fix, so scroll ticks never hit the disk) and executed off the main thread
// with atomic-rename semantics via g_file_set_contents_full. session.yaml is
// merged under an flock on session.lock, the same protocol the Mac app
// uses, so concurrent windows/processes never clobber each other.
#ifdef SPDF_STATE_TESTING
#include <glib.h>
#include <glib/gstdio.h>
#else
#include "spdf_internal.h"

#include <glib/gstdio.h>
#endif

#include "spdf_state_internal.h"

#include "spdf_yaml.h"

#include <ctype.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#define SPDF_STATE_MIN_SIDEBAR_WIDTH 140
#define SPDF_STATE_MAX_SIDEBAR_WIDTH 560
#define SPDF_STATE_MIN_MINIMAP_WIDTH 72.0
#define SPDF_STATE_MAX_MINIMAP_WIDTH 260.0
#define SPDF_STATE_MIN_ZOOM 0.10
#define SPDF_STATE_MAX_ZOOM 8.0
#define SPDF_STATE_MIN_PRINT_SCALE 0.10
#define SPDF_STATE_MAX_PRINT_SCALE 8.0

struct _SpdfState {
    char* config_dir;
    char* settings_path;
    char* session_path;
    char* session_lock_path;
    char* favorites_path;
    char* documents_path;

    SpdfSettings settings;
    char* recent_paths[SPDF_STATE_MAX_RECENT_DOCUMENTS];
    int recent_count;
    char* closed_paths[SPDF_STATE_MAX_CLOSED_DOCUMENTS];
    int closed_count;

    GPtrArray* loaded_windows;    // SpdfSessionWindow*, snapshot read at launch
    GPtrArray* live_windows;      // SpdfSessionWindow*, pushed by the window agent
    GHashTable* removed_window_ids; // set of ids deliberately closed this run

    GPtrArray* favorites;         // SpdfFavorite*, lazy
    gboolean favorites_loaded;
    GHashTable* documents;        // canonical path -> SpdfDocState*, lazy
    gboolean documents_loaded;

    guint write_timeout_id;
    GThread* writer;
    gboolean settings_dirty;
    gboolean session_dirty;
    gboolean favorites_dirty;
    gboolean documents_dirty;
    gboolean suppress_session_write;
};

// --- hand-rolled JSON helpers (ported from the GTK3 frontend) ----------------

static char* json_escape(const char* text) {
    GString* out = g_string_new("");
    for (const unsigned char* p = (const unsigned char*)(text ? text : ""); *p; ++p) {
        if (*p == '"' || *p == '\\') g_string_append_c(out, '\\');
        if (*p == '\n') g_string_append(out, "\\n");
        else if (*p == '\r') g_string_append(out, "\\r");
        else if (*p == '\t') g_string_append(out, "\\t");
        else if (*p < 0x20) g_string_append_printf(out, "\\u%04x", (unsigned int)*p);
        else g_string_append_c(out, (char)*p);
    }
    return g_string_free(out, FALSE);
}

static char* json_find_key(const char* json, const char* key) {
    char pattern[96];
    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    return strstr((char*)json, pattern);
}

static char* json_get_string(const char* json, const char* key) {
    char pattern[96];
    char* pos;
    char* start;
    GString* out;

    snprintf(pattern, sizeof(pattern), "\"%s\"", key);
    pos = strstr((char*)json, pattern);
    if (!pos) return NULL;
    pos = strchr(pos + strlen(pattern), ':');
    if (!pos) return NULL;
    pos++;
    while (*pos && isspace((unsigned char)*pos)) pos++;
    if (*pos != '"') return NULL;
    start = ++pos;
    out = g_string_new("");
    while (*start) {
        if (*start == '"') return g_string_free(out, FALSE);
        if (*start == '\\' && start[1]) {
            start++;
            if (*start == 'n') g_string_append_c(out, '\n');
            else if (*start == 'r') g_string_append_c(out, '\r');
            else if (*start == 't') g_string_append_c(out, '\t');
            else g_string_append_c(out, *start);
        } else {
            g_string_append_c(out, *start);
        }
        start++;
    }
    g_string_free(out, TRUE);
    return NULL;
}

static char* json_read_string_value(char** cursor) {
    char* pos = *cursor;
    GString* out;

    while (*pos && isspace((unsigned char)*pos)) pos++;
    if (*pos != '"') return NULL;
    pos++;
    out = g_string_new("");
    while (*pos) {
        if (*pos == '"') {
            *cursor = pos + 1;
            return g_string_free(out, FALSE);
        }
        if (*pos == '\\' && pos[1]) {
            pos++;
            if (*pos == 'n') g_string_append_c(out, '\n');
            else if (*pos == 'r') g_string_append_c(out, '\r');
            else if (*pos == 't') g_string_append_c(out, '\t');
            else g_string_append_c(out, *pos);
        } else {
            g_string_append_c(out, *pos);
        }
        pos++;
    }
    g_string_free(out, TRUE);
    return NULL;
}

static const char* json_value_start(const char* json, const char* key) {
    char* pos = json_find_key(json, key);
    if (!pos) return NULL;
    pos = strchr(pos + strlen(key) + 2, ':');
    if (!pos) return NULL;
    pos++;
    while (*pos && isspace((unsigned char)*pos)) pos++;
    return pos;
}

static int json_get_int(const char* json, const char* key, int fallback) {
    const char* pos = json_value_start(json, key);
    return pos ? atoi(pos) : fallback;
}

static gint64 json_get_int64(const char* json, const char* key, gint64 fallback) {
    const char* pos = json_value_start(json, key);
    return pos ? g_ascii_strtoll(pos, NULL, 10) : fallback;
}

static guint64 json_get_uint64(const char* json, const char* key, guint64 fallback) {
    const char* pos = json_value_start(json, key);
    return pos ? g_ascii_strtoull(pos, NULL, 10) : fallback;
}

static double json_get_double(const char* json, const char* key, double fallback) {
    const char* pos = json_value_start(json, key);
    return pos ? g_ascii_strtod(pos, NULL) : fallback;
}

static gboolean json_get_bool(const char* json, const char* key, gboolean fallback) {
    const char* pos = json_value_start(json, key);
    if (!pos) return fallback;
    if (strncmp(pos, "true", 4) == 0) return TRUE;
    if (strncmp(pos, "false", 5) == 0) return FALSE;
    return fallback;
}

static char* json_find_matching(const char* start, char open, char close) {
    int depth = 0;
    gboolean in_string = FALSE;
    gboolean escaped = FALSE;

    if (!start || *start != open) return NULL;
    for (char* pos = (char*)start; *pos; ++pos) {
        if (in_string) {
            if (escaped) {
                escaped = FALSE;
            } else if (*pos == '\\') {
                escaped = TRUE;
            } else if (*pos == '"') {
                in_string = FALSE;
            }
            continue;
        }

        if (*pos == '"') {
            in_string = TRUE;
        } else if (*pos == open) {
            depth++;
        } else if (*pos == close) {
            depth--;
            if (depth == 0) return pos;
        }
    }
    return NULL;
}

static char* json_get_array_contents(const char* json, const char* key) {
    char* pos = json_find_key(json, key);
    char* start;
    char* end;
    if (!pos) return NULL;
    pos = strchr(pos + strlen(key) + 2, ':');
    if (!pos) return NULL;
    start = strchr(pos, '[');
    if (!start) return NULL;
    end = json_find_matching(start, '[', ']');
    if (!end) return NULL;
    return g_strndup(start + 1, (gsize)(end - start - 1));
}

static char* json_get_object_contents(const char* json, const char* key) {
    char* pos = json_find_key(json, key);
    char* start;
    char* end;
    if (!pos) return NULL;
    pos = strchr(pos + strlen(key) + 2, ':');
    if (!pos) return NULL;
    start = strchr(pos, '{');
    if (!start) return NULL;
    end = json_find_matching(start, '{', '}');
    if (!end) return NULL;
    return g_strndup(start + 1, (gsize)(end - start - 1));
}

// Iterate the members of a top-level JSON object. pos starts just past the
// opening '{'. Returns the position after the consumed member and fills
// key_out (always) and object_out (only for object values; other value types
// are skipped with *object_out = NULL). Returns NULL at the end of input.
static const char* json_object_next_member(const char* pos, char** key_out, char** object_out) {
    char* cursor;
    char* key;
    char* end;

    *key_out = NULL;
    *object_out = NULL;
    if (!pos) return NULL;
    while (*pos && (isspace((unsigned char)*pos) || *pos == ',')) pos++;
    if (*pos != '"') return NULL;
    cursor = (char*)pos;
    key = json_read_string_value(&cursor);
    if (!key) return NULL;
    pos = cursor;
    while (*pos && isspace((unsigned char)*pos)) pos++;
    if (*pos != ':') {
        g_free(key);
        return NULL;
    }
    pos++;
    while (*pos && isspace((unsigned char)*pos)) pos++;
    if (*pos == '{') {
        end = json_find_matching(pos, '{', '}');
        if (!end) {
            g_free(key);
            return NULL;
        }
        *key_out = key;
        *object_out = g_strndup(pos, (gsize)(end - pos + 1));
        return end + 1;
    }
    if (*pos == '[') {
        end = json_find_matching(pos, '[', ']');
        if (!end) {
            g_free(key);
            return NULL;
        }
        *key_out = key;
        return end + 1;
    }
    if (*pos == '"') {
        cursor = (char*)pos;
        g_free(json_read_string_value(&cursor));
        *key_out = key;
        return cursor;
    }
    while (*pos && *pos != ',' && *pos != '}') pos++;
    *key_out = key;
    return pos;
}

static gboolean read_limited_text_file(const char* path, char** contents, gsize* len) {
    GStatBuf st;
    gboolean ok;
    gsize local_len = 0;

    if (contents) *contents = NULL;
    if (len) *len = 0;
    if (!path) return FALSE;
    if (g_stat(path, &st) == 0 && st.st_size > SPDF_STATE_MAX_CONFIG_JSON_BYTES) return FALSE;
    ok = g_file_get_contents(path, contents, &local_len, NULL);
    if (ok && local_len > SPDF_STATE_MAX_CONFIG_JSON_BYTES) {
        g_free(contents ? *contents : NULL);
        if (contents) *contents = NULL;
        return FALSE;
    }
    if (len) *len = local_len;
    return ok;
}

static gboolean write_text_file_atomic(const char* path, const char* text) {
    return g_file_set_contents_full(path, text, -1, G_FILE_SET_CONTENTS_CONSISTENT, 0600, NULL);
}

// State files are YAML on disk (shared codec in core/spdf_yaml.h); this
// frontend keeps building and scanning JSON text internally, converting at
// the file boundary. A YAML file that fails to parse behaves exactly like
// the old corrupt-JSON path: the file is ignored and defaults apply.
static gboolean read_state_file_as_json(const char* path, char** json_out) {
    char* yaml = NULL;
    gsize len = 0;
    char* json;

    if (json_out) *json_out = NULL;
    if (!json_out) return FALSE;
    if (!read_limited_text_file(path, &yaml, &len)) return FALSE;
    json = spdf_json_from_yaml(yaml);
    g_free(yaml);
    if (!json) return FALSE;
    /* Copy into glib-owned memory so callers keep using g_free. */
    *json_out = g_strdup(json);
    free(json);
    return TRUE;
}

/* Converts internally-built JSON text to YAML (with the standard header
 * comment) and writes it atomically to the state file. */
static gboolean write_state_file_from_json(const char* path, const char* json_text) {
    char header[128];
    char* yaml;
    gboolean ok;

    spdf_state_header_for_file(path, header, sizeof(header));
    yaml = spdf_yaml_from_json(json_text, header);
    if (!yaml) return FALSE;
    ok = write_text_file_atomic(path, yaml);
    free(yaml);
    return ok;
}

static char* dup_limited_utf8(const char* text, gsize max_bytes) {
    const char* end;
    gsize len;

    if (!text) return g_strdup("");
    len = strlen(text);
    if (len <= max_bytes) return g_strdup(text);

    end = text + max_bytes;
    while (end > text && (((const unsigned char*)end)[0] & 0xc0) == 0x80) end--;
    if (end == text) end = text + max_bytes;
    return g_strndup(text, (gsize)(end - text));
}

static int clamp_int(int value, int min_value, int max_value) {
    return MAX(min_value, MIN(max_value, value));
}

static double clamp_double(double value, double min_value, double max_value) {
    if (!isfinite(value)) return min_value;
    return MAX(min_value, MIN(max_value, value));
}

// Locale-independent fixed-point number output (the GTK3 writer used printf
// %f, which is locale-dependent once gtk_init calls setlocale; fixed here).
static void append_json_fixed(GString* out, double value, int decimals) {
    char format[8];
    char buf[G_ASCII_DTOSTR_BUF_SIZE];
    if (!isfinite(value)) value = 0.0;
    g_snprintf(format, sizeof(format), "%%.%df", decimals);
    g_ascii_formatd(buf, sizeof(buf), format, value);
    g_string_append(out, buf);
}

// --- struct lifecycles --------------------------------------------------------

static void session_tab_free(SpdfSessionTab* tab) {
    if (!tab) return;
    g_free(tab->path);
    g_free(tab->title);
    g_free(tab->search_text);
    g_free(tab->working_path);
    g_free(tab);
}

void spdf_session_window_free(SpdfSessionWindow* win) {
    if (!win) return;
    g_free(win->id);
    if (win->tabs) g_ptr_array_free(win->tabs, TRUE);
    g_free(win);
}

static char* new_window_session_id(void) {
    return g_strdup_printf("gtk-%ld-%lld", (long)getpid(), (long long)g_get_real_time());
}

SpdfSessionWindow* spdf_session_window_new(const char* id) {
    SpdfSessionWindow* win = g_new0(SpdfSessionWindow, 1);
    win->id = id && *id ? g_strdup(id) : new_window_session_id();
    win->tabs = g_ptr_array_new_with_free_func((GDestroyNotify)session_tab_free);
    return win;
}

SpdfSessionTab* spdf_session_window_add_tab(SpdfSessionWindow* win) {
    SpdfSessionTab* tab;
    if (!win) return NULL;
    tab = g_new0(SpdfSessionTab, 1);
    tab->zoom = 1.0;
    tab->custom_zoom = 1.0;
    tab->fit_mode = 4;
    tab->search_regex_multiline = TRUE;
    tab->find_match_index = -1;
    tab->show_sidebar = TRUE;
    tab->show_minimap = TRUE;
    g_ptr_array_add(win->tabs, tab);
    return tab;
}

static void favorite_free(SpdfFavorite* favorite) {
    if (!favorite) return;
    g_free(favorite->type);
    g_free(favorite->path);
    g_free(favorite->title);
    g_free(favorite->name);
    g_strfreev(favorite->labels);
    g_free(favorite);
}

static SpdfFavorite* favorite_copy(const SpdfFavorite* source) {
    SpdfFavorite* favorite = g_new0(SpdfFavorite, 1);
    favorite->type = g_strdup(source->type && *source->type ? source->type : "page");
    favorite->path = g_strdup(source->path ? source->path : "");
    favorite->title = g_strdup(source->title ? source->title : "");
    favorite->name = g_strdup(source->name ? source->name : "");
    favorite->labels = source->labels ? g_strdupv(source->labels) : NULL;
    favorite->page = MAX(0, source->page);
    favorite->created = source->created;
    return favorite;
}

static void doc_state_free(SpdfDocState* doc_state) {
    if (!doc_state) return;
    g_free(doc_state->path);
    g_free(doc_state->title);
    g_free(doc_state->page_geometry);
    g_free(doc_state);
}

// --- settings ------------------------------------------------------------------

static void settings_init_defaults(SpdfSettings* settings) {
    settings->fit_mode = 4; // fit page, both apps' default
    settings->zoom = 1.0;
    settings->sidebar_width = 240;
    settings->minimap_width = 126.5;
    settings->default_sidebar_visible = TRUE;
    settings->default_minimap_visible = TRUE;
    settings->collapse_whitespace_on_copy = TRUE;
    settings->search_jumps_to_nearest_result = TRUE;
    settings->show_find_markers = TRUE;
    settings->show_shortcut_help_on_launch = TRUE;
    settings->auto_update_enabled = TRUE;
    settings->prevent_sleep_in_presentation = TRUE;
    settings->default_reader_prompt_dismissed = FALSE;
    settings->print_scaling_mode = 0;
    settings->print_custom_scale = 1.0;
    settings->window_width = SPDF_STATE_DEFAULT_WINDOW_WIDTH;
    settings->window_height = SPDF_STATE_DEFAULT_WINDOW_HEIGHT;
    settings->comment_author = g_strdup("");
    settings->skipped_update_version = g_strdup("");
    settings->translate_source_language = g_strdup("zh");
    settings->translate_target_language = g_strdup("en");
    settings->ocr_language = g_strdup("chi_sim+eng"); // first OCR table entry (Wave C)
    settings->instant_launch_resident = TRUE;         // resident instant launch (Wave D)
}

static void settings_read_string(const char* json, const char* key, char** field, gboolean keep_when_empty) {
    char* value = json_get_string(json, key);
    if (!value) return;
    g_strstrip(value);
    if (*value || keep_when_empty) {
        g_free(*field);
        *field = value;
    } else {
        g_free(value);
    }
}

static void parse_settings(SpdfState* state, const char* json) {
    SpdfSettings* settings = &state->settings;
    char* window_size;
    char* recent_array;

    settings->fit_mode = json_get_int(json, "fitMode", settings->fit_mode);
    if (settings->fit_mode < 0 || settings->fit_mode > 4) settings->fit_mode = 4;
    settings->zoom = clamp_double(json_get_double(json, "zoom", settings->zoom), SPDF_STATE_MIN_ZOOM, SPDF_STATE_MAX_ZOOM);
    settings->sidebar_width = clamp_int(json_get_int(json, "sidebarWidth", settings->sidebar_width),
                                        SPDF_STATE_MIN_SIDEBAR_WIDTH, SPDF_STATE_MAX_SIDEBAR_WIDTH);
    settings->minimap_width = clamp_double(json_get_double(json, "minimapWidth", settings->minimap_width),
                                           SPDF_STATE_MIN_MINIMAP_WIDTH, SPDF_STATE_MAX_MINIMAP_WIDTH);
    // Mac keys, with the GTK3 spellings as fallback so upgrades keep the value.
    settings->default_sidebar_visible =
        json_get_bool(json, "defaultSidebarVisibleForNewDocuments",
                      json_get_bool(json, "showSidebar", settings->default_sidebar_visible));
    settings->default_minimap_visible =
        json_get_bool(json, "defaultMinimapVisibleForNewDocuments",
                      json_get_bool(json, "showMinimap", settings->default_minimap_visible));
    settings->collapse_whitespace_on_copy =
        json_get_bool(json, "collapseWhitespaceWhenCopyingText", settings->collapse_whitespace_on_copy);
    settings->search_jumps_to_nearest_result =
        json_get_bool(json, "searchJumpsToNearestResult", settings->search_jumps_to_nearest_result);
    settings->show_find_markers = json_get_bool(json, "showFindMarkers", settings->show_find_markers);
    settings->show_shortcut_help_on_launch =
        json_get_bool(json, "showShortcutHelpOnLaunch", settings->show_shortcut_help_on_launch);
    settings->auto_update_enabled = json_get_bool(json, "autoUpdateEnabled", settings->auto_update_enabled);
    settings->prevent_sleep_in_presentation =
        json_get_bool(json, "preventSleepInPresentation", settings->prevent_sleep_in_presentation);
    settings->default_reader_prompt_dismissed =
        json_get_bool(json, "defaultReaderPromptDismissed", settings->default_reader_prompt_dismissed);
    settings->instant_launch_resident =
        json_get_bool(json, "instantLaunchResident", settings->instant_launch_resident); // Wave D (GTK4 extra)
    // Mac-only permission flags: remember presence + value so the Linux
    // writer can round-trip a Mac settings.json without wiping them.
    settings->has_mac_full_disk_prompt_dismissed = json_find_key(json, "fullDiskAccessPromptDismissed") != NULL;
    settings->mac_full_disk_prompt_dismissed = json_get_bool(json, "fullDiskAccessPromptDismissed", FALSE);
    settings->has_mac_permissions_wizard_shown = json_find_key(json, "permissionsWizardShown") != NULL;
    settings->mac_permissions_wizard_shown = json_get_bool(json, "permissionsWizardShown", FALSE);
    settings->print_scaling_mode = clamp_int(json_get_int(json, "printScalingMode", settings->print_scaling_mode), 0, 2);
    settings->print_custom_scale = clamp_double(json_get_double(json, "printCustomScale", settings->print_custom_scale),
                                                SPDF_STATE_MIN_PRINT_SCALE, SPDF_STATE_MAX_PRINT_SCALE);

    window_size = json_get_object_contents(json, "windowSize");
    if (window_size) {
        settings->window_width = (int)json_get_double(window_size, "width", settings->window_width);
        settings->window_height = (int)json_get_double(window_size, "height", settings->window_height);
        g_free(window_size);
    } else {
        // GTK3 wrote flat windowWidth/windowHeight keys.
        settings->window_width = json_get_int(json, "windowWidth", settings->window_width);
        settings->window_height = json_get_int(json, "windowHeight", settings->window_height);
    }
    settings->window_width =
        clamp_int(settings->window_width, SPDF_STATE_MIN_WINDOW_WIDTH, SPDF_STATE_MAX_WINDOW_WIDTH);
    settings->window_height =
        clamp_int(settings->window_height, SPDF_STATE_MIN_WINDOW_HEIGHT, SPDF_STATE_MAX_WINDOW_HEIGHT);

    settings_read_string(json, "commentAuthor", &settings->comment_author, TRUE);
    settings_read_string(json, "skippedUpdateVersion", &settings->skipped_update_version, TRUE);
    settings_read_string(json, "translateSourceLanguage", &settings->translate_source_language, FALSE);
    settings_read_string(json, "translateTargetLanguage", &settings->translate_target_language, FALSE);
    settings_read_string(json, "ocrLanguage", &settings->ocr_language, FALSE); // Wave C (GTK4 extra)

    recent_array = json_get_array_contents(json, "recentlyOpened");
    if (recent_array) {
        char* pos = recent_array;
        while (*pos && state->recent_count < SPDF_STATE_MAX_RECENT_DOCUMENTS) {
            char* path;
            while (*pos && *pos != '"') pos++;
            if (!*pos) break;
            path = json_read_string_value(&pos);
            if (path && *path) {
                gboolean exists = FALSE;
                for (int i = 0; i < state->recent_count; ++i) {
                    if (g_strcmp0(state->recent_paths[i], path) == 0) exists = TRUE;
                }
                if (!exists) {
                    state->recent_paths[state->recent_count++] = path;
                    path = NULL;
                }
            }
            g_free(path);
        }
        g_free(recent_array);
    }
}

static char* settings_to_json(SpdfState* state) {
    SpdfSettings* settings = &state->settings;
    char* author = json_escape(settings->comment_author ? settings->comment_author : "");
    char* skipped = json_escape(settings->skipped_update_version ? settings->skipped_update_version : "");
    char* translate_source = json_escape(settings->translate_source_language ? settings->translate_source_language : "zh");
    char* translate_target = json_escape(settings->translate_target_language ? settings->translate_target_language : "en");
    char* ocr_language = json_escape(settings->ocr_language ? settings->ocr_language : "chi_sim+eng");
    GString* json = g_string_new("{\n");

    // Keys sorted alphabetically, mirroring the Mac writer
    // (NSJSONWritingSortedKeys). "showFindMarkers" and "zoom" are GTK3-era
    // extras the Linux app keeps; the Mac reader ignores unknown keys.
    g_string_append_printf(json, "  \"autoUpdateEnabled\": %s,\n", settings->auto_update_enabled ? "true" : "false");
    g_string_append_printf(json, "  \"collapseWhitespaceWhenCopyingText\": %s,\n",
                           settings->collapse_whitespace_on_copy ? "true" : "false");
    g_string_append_printf(json, "  \"commentAuthor\": \"%s\",\n", author);
    g_string_append_printf(json, "  \"defaultMinimapVisibleForNewDocuments\": %s,\n",
                           settings->default_minimap_visible ? "true" : "false");
    g_string_append_printf(json, "  \"defaultReaderPromptDismissed\": %s,\n",
                           settings->default_reader_prompt_dismissed ? "true" : "false");
    g_string_append_printf(json, "  \"defaultSidebarVisibleForNewDocuments\": %s,\n",
                           settings->default_sidebar_visible ? "true" : "false");
    g_string_append_printf(json, "  \"fitMode\": %d,\n",
                           settings->fit_mode >= 0 && settings->fit_mode <= 4 ? settings->fit_mode : 4);
    // Mac-only permission flags round-trip (only when the loaded file had
    // them) so a shared/copied Mac settings.json keeps its Mac state.
    if (settings->has_mac_full_disk_prompt_dismissed)
        g_string_append_printf(json, "  \"fullDiskAccessPromptDismissed\": %s,\n",
                               settings->mac_full_disk_prompt_dismissed ? "true" : "false");
    // "instantLaunchResident" is a Wave D GTK4/Linux-only extra (like
    // "ocrLanguage"); the Mac reader ignores unknown keys.
    g_string_append_printf(json, "  \"instantLaunchResident\": %s,\n",
                           settings->instant_launch_resident ? "true" : "false");
    g_string_append(json, "  \"minimapWidth\": ");
    append_json_fixed(json, clamp_double(settings->minimap_width, SPDF_STATE_MIN_MINIMAP_WIDTH, SPDF_STATE_MAX_MINIMAP_WIDTH), 4);
    g_string_append(json, ",\n");
    // "ocrLanguage" is a Wave C GTK4 extra; the Mac reader ignores unknown keys.
    g_string_append_printf(json, "  \"ocrLanguage\": \"%s\",\n", ocr_language);
    if (settings->has_mac_permissions_wizard_shown)
        g_string_append_printf(json, "  \"permissionsWizardShown\": %s,\n",
                               settings->mac_permissions_wizard_shown ? "true" : "false");
    g_string_append_printf(json, "  \"preventSleepInPresentation\": %s,\n",
                           settings->prevent_sleep_in_presentation ? "true" : "false");
    g_string_append(json, "  \"printCustomScale\": ");
    append_json_fixed(json, clamp_double(settings->print_custom_scale, SPDF_STATE_MIN_PRINT_SCALE, SPDF_STATE_MAX_PRINT_SCALE), 4);
    g_string_append(json, ",\n");
    g_string_append_printf(json, "  \"printScalingMode\": %d,\n", clamp_int(settings->print_scaling_mode, 0, 2));
    if (state->recent_count == 0) {
        g_string_append(json, "  \"recentlyOpened\": [],\n");
    } else {
        g_string_append(json, "  \"recentlyOpened\": [\n");
        for (int i = 0; i < state->recent_count; ++i) {
            char* path = json_escape(state->recent_paths[i] ? state->recent_paths[i] : "");
            g_string_append_printf(json, "    \"%s\"%s\n", path, i + 1 == state->recent_count ? "" : ",");
            g_free(path);
        }
        g_string_append(json, "  ],\n");
    }
    g_string_append_printf(json, "  \"searchJumpsToNearestResult\": %s,\n",
                           settings->search_jumps_to_nearest_result ? "true" : "false");
    g_string_append_printf(json, "  \"showFindMarkers\": %s,\n", settings->show_find_markers ? "true" : "false");
    g_string_append_printf(json, "  \"showShortcutHelpOnLaunch\": %s,\n",
                           settings->show_shortcut_help_on_launch ? "true" : "false");
    g_string_append_printf(json, "  \"sidebarWidth\": %d,\n",
                           clamp_int(settings->sidebar_width, SPDF_STATE_MIN_SIDEBAR_WIDTH, SPDF_STATE_MAX_SIDEBAR_WIDTH));
    g_string_append_printf(json, "  \"skippedUpdateVersion\": \"%s\",\n", skipped);
    g_string_append_printf(json, "  \"translateSourceLanguage\": \"%s\",\n", translate_source);
    g_string_append_printf(json, "  \"translateTargetLanguage\": \"%s\",\n", translate_target);
    g_string_append(json, "  \"version\": 1,\n");
    g_string_append(json, "  \"viewMode\": 1,\n");
    g_string_append_printf(json, "  \"windowSize\": { \"height\": %d, \"width\": %d },\n",
                           clamp_int(settings->window_height, SPDF_STATE_MIN_WINDOW_HEIGHT, SPDF_STATE_MAX_WINDOW_HEIGHT),
                           clamp_int(settings->window_width, SPDF_STATE_MIN_WINDOW_WIDTH, SPDF_STATE_MAX_WINDOW_WIDTH));
    g_string_append(json, "  \"zoom\": ");
    append_json_fixed(json, clamp_double(settings->zoom, SPDF_STATE_MIN_ZOOM, SPDF_STATE_MAX_ZOOM), 4);
    g_string_append(json, "\n}\n");

    g_free(ocr_language);
    g_free(translate_target);
    g_free(translate_source);
    g_free(skipped);
    g_free(author);
    return g_string_free(json, FALSE);
}

// --- session -------------------------------------------------------------------

static int lock_session_store(const char* lock_path) {
    int fd;
    if (!lock_path) return -1;
    fd = open(lock_path, O_CREAT | O_RDWR, 0600);
    if (fd >= 0) flock(fd, LOCK_EX);
    return fd;
}

static void unlock_session_store(int fd) {
    if (fd < 0) return;
    flock(fd, LOCK_UN);
    close(fd);
}

static gboolean for_each_session_window(const char* json,
                                        gboolean (*callback)(const char*, const char*, gpointer),
                                        gpointer user_data) {
    char* windows;
    char* pos;
    gboolean any = FALSE;

    if (!json || !callback) return FALSE;
    windows = json_get_array_contents(json, "windows");
    if (!windows) return FALSE;
    pos = windows;
    while ((pos = strchr(pos, '{')) != NULL) {
        char* end = json_find_matching(pos, '{', '}');
        char* object;
        char* id;
        gboolean keep_going;
        if (!end) break;
        object = g_strndup(pos, (gsize)(end - pos + 1));
        id = json_get_string(object, "id");
        any = TRUE;
        keep_going = callback(id ? id : "", object, user_data);
        g_free(id);
        g_free(object);
        if (!keep_going) break;
        pos = end + 1;
    }
    g_free(windows);
    return any;
}

static void parse_session_tab_into_window(SpdfSessionWindow* win, const char* object) {
    SpdfSessionTab* tab;
    char* path = json_get_string(object, "path");
    char* search_text;

    if (!path || !*path || win->tabs->len >= SPDF_STATE_MAX_SESSION_TABS) {
        g_free(path);
        return;
    }
    tab = spdf_session_window_add_tab(win);
    tab->path = path;
    tab->title = json_get_string(object, "title");
    tab->page = json_get_int(object, "page", 0);
    // The Mac app has always written 0-based "page" (alongside "viewMode");
    // the GTK3 app wrote 1-based and never wrote "viewMode". Migrate on read.
    if (!json_find_key(object, "viewMode")) tab->page -= 1;
    tab->page = MAX(0, tab->page);
    tab->zoom = json_get_double(object, "zoom", 1.0);
    if (!(tab->zoom > 0.0)) tab->zoom = 1.0;
    tab->custom_zoom = json_get_double(object, "customZoom", tab->zoom);
    if (!(tab->custom_zoom > 0.0)) tab->custom_zoom = tab->zoom;
    tab->fit_mode = json_get_int(object, "fitMode", 4);
    if (tab->fit_mode < 0 || tab->fit_mode > 4) tab->fit_mode = 4;
    tab->scroll_x = json_get_double(object, "scrollX", 0.0);
    tab->scroll_y = json_get_double(object, "scrollY", 0.0);
    if (json_find_key(object, "hasScrollOrigin"))
        tab->has_scroll_origin = json_get_bool(object, "hasScrollOrigin", FALSE);
    else
        tab->has_scroll_origin = json_find_key(object, "scrollX") != NULL || json_find_key(object, "scrollY") != NULL;
    search_text = json_get_string(object, "searchText");
    tab->search_text = dup_limited_utf8(search_text ? search_text : "", SPDF_STATE_MAX_FIND_QUERY_BYTES);
    g_free(search_text);
    tab->search_regex = json_get_bool(object, "searchRegex", FALSE);
    tab->search_regex_multiline = json_get_bool(object, "searchRegexMultiline", TRUE);
    tab->find_match_index = json_get_int(object, "findMatchIndex", -1);
    tab->has_show_sidebar = json_find_key(object, "showSidebar") != NULL;
    tab->has_show_minimap = json_find_key(object, "showMinimap") != NULL;
    tab->show_sidebar = json_get_bool(object, "showSidebar", TRUE);
    tab->show_minimap = json_get_bool(object, "showMinimap", TRUE);
    tab->read_only = json_get_bool(object, "readOnly", FALSE);
    tab->working_path = json_get_string(object, "workingPath");
    tab->ro_copy_file_size = json_get_uint64(object, "roCopyFileSize", 0);
    tab->ro_copy_modified_at = json_get_double(object, "roCopyModifiedAt", 0.0);
}

static SpdfSessionWindow* parse_session_window(const char* object) {
    SpdfSessionWindow* win;
    char* id = json_get_string(object, "id");
    char* frame;
    char* tabs;

    win = spdf_session_window_new(id && *id ? id : NULL);
    g_free(id);

    frame = json_get_object_contents(object, "frame");
    if (frame) {
        int width = (int)json_get_double(frame, "width", 0);
        int height = (int)json_get_double(frame, "height", 0);
        if (width >= SPDF_STATE_MIN_WINDOW_WIDTH && height >= SPDF_STATE_MIN_WINDOW_HEIGHT) {
            win->frame.x = (int)json_get_double(frame, "x", 0);
            win->frame.y = (int)json_get_double(frame, "y", 0);
            win->frame.width = MIN(width, SPDF_STATE_MAX_WINDOW_WIDTH);
            win->frame.height = MIN(height, SPDF_STATE_MAX_WINDOW_HEIGHT);
            win->has_frame = TRUE;
        }
        g_free(frame);
    }
    win->selected_tab = MAX(0, json_get_int(object, "selectedTab", 0));

    tabs = json_get_array_contents(object, "tabs");
    if (tabs) {
        char* pos = tabs;
        while ((pos = strchr(pos, '{')) != NULL) {
            char* end = json_find_matching(pos, '{', '}');
            char* tab_object;
            if (!end) break;
            tab_object = g_strndup(pos, (gsize)(end - pos + 1));
            parse_session_tab_into_window(win, tab_object);
            g_free(tab_object);
            pos = end + 1;
        }
        g_free(tabs);
    }
    return win;
}

static gboolean collect_session_window(const char* id, const char* object, gpointer user_data) {
    SpdfState* state = user_data;
    SpdfSessionWindow* win;
    (void)id;
    if (state->loaded_windows->len >= SPDF_STATE_MAX_SESSION_WINDOWS) return FALSE;
    win = parse_session_window(object);
    if (win->tabs->len > 0) g_ptr_array_add(state->loaded_windows, win);
    else spdf_session_window_free(win);
    return TRUE;
}

// GTK3 pre-multi-window sessions: a bare {"tabs": [...]} object, or older
// still a single {"path": ..., "page": ...} document record (1-based page).
static void parse_legacy_session(SpdfState* state, const char* json) {
    char* tabs = json_get_array_contents(json, "tabs");
    char* path;

    if (tabs) {
        SpdfSessionWindow* win = parse_session_window(json);
        if (win->tabs->len > 0) g_ptr_array_add(state->loaded_windows, win);
        else spdf_session_window_free(win);
        g_free(tabs);
        return;
    }

    path = json_get_string(json, "path");
    if (path && *path) {
        SpdfSessionWindow* win = spdf_session_window_new(NULL);
        SpdfSessionTab* tab = spdf_session_window_add_tab(win);
        char* search_text = json_get_string(json, "searchText");
        tab->path = g_strdup(path);
        tab->page = MAX(0, json_get_int(json, "page", 1) - 1);
        tab->search_text = dup_limited_utf8(search_text ? search_text : "", SPDF_STATE_MAX_FIND_QUERY_BYTES);
        tab->search_regex = json_get_bool(json, "searchRegex", FALSE);
        tab->search_regex_multiline = json_get_bool(json, "searchRegexMultiline", TRUE);
        tab->find_match_index = json_get_int(json, "findMatchIndex", -1);
        g_free(search_text);
        g_ptr_array_add(state->loaded_windows, win);
    }
    g_free(path);
}

static void parse_session(SpdfState* state, const char* json) {
    if (!for_each_session_window(json, collect_session_window, state)) parse_legacy_session(state, json);
}

static void append_session_tab_json(GString* json, const SpdfSessionTab* tab, gboolean last) {
    char* path = json_escape(tab->path ? tab->path : "");
    char* title = json_escape(tab->title ? tab->title : "");
    char* search = json_escape(tab->search_text ? tab->search_text : "");
    char* working = json_escape(tab->working_path ? tab->working_path : "");

    g_string_append_printf(json, "        { \"path\": \"%s\", \"title\": \"%s\", \"page\": %d, \"zoom\": ", path,
                           title, MAX(0, tab->page));
    append_json_fixed(json, tab->zoom > 0.0 ? tab->zoom : 1.0, 4);
    g_string_append(json, ", \"customZoom\": ");
    append_json_fixed(json, tab->custom_zoom > 0.0 ? tab->custom_zoom : 1.0, 4);
    g_string_append_printf(json, ", \"fitMode\": %d, \"viewMode\": 1, \"scrollX\": ",
                           tab->fit_mode >= 0 && tab->fit_mode <= 4 ? tab->fit_mode : 4);
    append_json_fixed(json, tab->scroll_x, 4);
    g_string_append(json, ", \"scrollY\": ");
    append_json_fixed(json, tab->scroll_y, 4);
    g_string_append_printf(json, ", \"hasScrollOrigin\": %s, \"searchText\": \"%s\", \"searchRegex\": %s, "
                                 "\"searchRegexMultiline\": %s, \"findMatchIndex\": %d, \"showSidebar\": %s, "
                                 "\"showMinimap\": %s, \"readOnly\": %s, \"workingPath\": \"%s\", "
                                 "\"roCopyFileSize\": %" G_GUINT64_FORMAT ", \"roCopyModifiedAt\": ",
                           tab->has_scroll_origin ? "true" : "false", search, tab->search_regex ? "true" : "false",
                           tab->search_regex_multiline ? "true" : "false", tab->find_match_index,
                           tab->show_sidebar ? "true" : "false", tab->show_minimap ? "true" : "false",
                           tab->read_only ? "true" : "false", working, tab->ro_copy_file_size);
    append_json_fixed(json, tab->ro_copy_modified_at, 6);
    g_string_append_printf(json, " }%s\n", last ? "" : ",");

    g_free(working);
    g_free(search);
    g_free(title);
    g_free(path);
}

static char* session_window_to_json(const SpdfSessionWindow* win) {
    GString* json = g_string_new("    {\n");
    char* id = json_escape(win->id ? win->id : "");

    g_string_append_printf(json, "      \"id\": \"%s\",\n", id);
    if (win->has_frame) {
        g_string_append_printf(json, "      \"frame\": { \"x\": %d, \"y\": %d, \"width\": %d, \"height\": %d },\n",
                               win->frame.x, win->frame.y,
                               clamp_int(win->frame.width, SPDF_STATE_MIN_WINDOW_WIDTH, SPDF_STATE_MAX_WINDOW_WIDTH),
                               clamp_int(win->frame.height, SPDF_STATE_MIN_WINDOW_HEIGHT, SPDF_STATE_MAX_WINDOW_HEIGHT));
    }
    g_string_append_printf(json, "      \"selectedTab\": %d,\n", MAX(0, win->selected_tab));
    if (win->tabs->len == 0) {
        g_string_append(json, "      \"tabs\": []\n");
    } else {
        g_string_append(json, "      \"tabs\": [\n");
        for (guint i = 0; i < win->tabs->len; ++i)
            append_session_tab_json(json, g_ptr_array_index(win->tabs, i), i + 1 == win->tabs->len);
        g_string_append(json, "      ]\n");
    }
    g_string_append(json, "    }");

    g_free(id);
    return g_string_free(json, FALSE);
}

typedef struct session_merge_context {
    GString* windows_json;
    GHashTable* skip_ids;
    gboolean wrote_any;
} session_merge_context;

static gboolean append_existing_session_window(const char* id, const char* object, gpointer user_data) {
    session_merge_context* context = user_data;
    if (id && *id && context->skip_ids && g_hash_table_contains(context->skip_ids, id)) return TRUE;
    if (context->wrote_any) g_string_append(context->windows_json, ",\n");
    g_string_append(context->windows_json, object);
    context->wrote_any = TRUE;
    return TRUE;
}

// Merge our windows into the on-disk session under the store lock: foreign
// windows (other processes / detached-tab launches) are preserved verbatim,
// windows whose ids we own are replaced or dropped. Runs on the writer thread.
static void merge_session_store(const char* session_path,
                                const char* lock_path,
                                GPtrArray* window_texts,
                                GHashTable* owned_ids) {
    char* existing = NULL;
    GString* out;
    session_merge_context context;
    int lock_fd;

    lock_fd = lock_session_store(lock_path);
    read_state_file_as_json(session_path, &existing);
    context.windows_json = g_string_new("");
    context.skip_ids = owned_ids;
    context.wrote_any = FALSE;
    for_each_session_window(existing, append_existing_session_window, &context);
    for (guint i = 0; i < window_texts->len; ++i) {
        if (context.wrote_any) g_string_append(context.windows_json, ",\n");
        g_string_append(context.windows_json, (const char*)g_ptr_array_index(window_texts, i));
        context.wrote_any = TRUE;
    }

    out = g_string_new("{\n  \"version\": 2,\n  \"windows\": [\n");
    g_string_append(out, context.windows_json->str);
    g_string_append(out, "\n  ]\n}\n");
    write_state_file_from_json(session_path, out->str);
    g_string_free(out, TRUE);
    g_string_free(context.windows_json, TRUE);
    g_free(existing);
    unlock_session_store(lock_fd);
}

// --- favorites -------------------------------------------------------------------

static void parse_favorite_object(SpdfState* state, const char* object, gboolean legacy) {
    SpdfFavorite* favorite;
    char* type;

    if (state->favorites->len >= SPDF_STATE_MAX_FAVORITES) return;
    favorite = g_new0(SpdfFavorite, 1);
    favorite->path = json_get_string(object, "path");
    if (!favorite->path || !*favorite->path) {
        favorite_free(favorite);
        return;
    }
    favorite->title = json_get_string(object, "title");
    if (!favorite->title) favorite->title = g_strdup("");
    if (legacy) {
        // GTK3 schema: 1-based "page", boolean "document", no name/labels.
        favorite->type = g_strdup(json_get_bool(object, "document", FALSE) ? "document" : "page");
        favorite->page = MAX(0, json_get_int(object, "page", 1) - 1);
        favorite->name = g_strdup(favorite->title);
        favorite->created = 0;
    } else {
        type = json_get_string(object, "type");
        if (type && *type) {
            favorite->type = type;
        } else {
            g_free(type);
            favorite->type = g_strdup("page");
        }
        favorite->page = MAX(0, json_get_int(object, "page", 0));
        favorite->name = json_get_string(object, "name");
        if (!favorite->name) favorite->name = g_strdup(favorite->title);
        favorite->created = json_get_int64(object, "created", 0);
        {
            char* labels = json_get_array_contents(object, "labels");
            if (labels) {
                GPtrArray* values = g_ptr_array_new();
                char* pos = labels;
                while (*pos) {
                    char* value;
                    while (*pos && *pos != '"') pos++;
                    if (!*pos) break;
                    value = json_read_string_value(&pos);
                    if (!value) break;
                    g_ptr_array_add(values, value);
                }
                if (values->len > 0) {
                    g_ptr_array_add(values, NULL);
                    favorite->labels = (char**)g_ptr_array_free(values, FALSE);
                } else {
                    g_ptr_array_free(values, TRUE);
                }
                g_free(labels);
            }
        }
    }
    g_ptr_array_add(state->favorites, favorite);
}

static void parse_favorites_payload(SpdfState* state, const char* json) {
    const char* pos = json;
    char* array = NULL;
    gboolean legacy = FALSE;

    while (*pos && isspace((unsigned char)*pos)) pos++;
    if (*pos == '{') {
        // GTK3 wrapper object {"favorites": [...]}.
        array = json_get_array_contents(json, "favorites");
        legacy = TRUE;
    } else if (*pos == '[') {
        char* end = json_find_matching(pos, '[', ']');
        if (end) array = g_strndup(pos + 1, (gsize)(end - pos - 1));
    }
    if (!array) return;
    pos = array;
    while ((pos = strchr(pos, '{')) != NULL) {
        char* end = json_find_matching(pos, '{', '}');
        char* object;
        if (!end) break;
        object = g_strndup(pos, (gsize)(end - pos + 1));
        parse_favorite_object(state, object, legacy);
        g_free(object);
        pos = end + 1;
    }
    g_free(array);
}

static void ensure_favorites_loaded(SpdfState* state) {
    char* json = NULL;

    if (state->favorites_loaded) return;
    state->favorites_loaded = TRUE;
    if (!read_state_file_as_json(state->favorites_path, &json)) return;
    parse_favorites_payload(state, json);
    g_free(json);
}

static char* favorites_to_json(SpdfState* state) {
    GString* json;

    if (state->favorites->len == 0) return g_strdup("[]\n");
    json = g_string_new("[\n");
    for (guint i = 0; i < state->favorites->len; ++i) {
        const SpdfFavorite* favorite = g_ptr_array_index(state->favorites, i);
        char* type = json_escape(favorite->type ? favorite->type : "page");
        char* path = json_escape(favorite->path ? favorite->path : "");
        char* title = json_escape(favorite->title ? favorite->title : "");
        char* name = json_escape(favorite->name ? favorite->name : "");

        g_string_append(json, "  {\n");
        g_string_append_printf(json, "    \"created\": %" G_GINT64_FORMAT ",\n", favorite->created);
        if (favorite->labels && favorite->labels[0]) {
            g_string_append(json, "    \"labels\": [ ");
            for (char** label = favorite->labels; *label; ++label) {
                char* escaped = json_escape(*label);
                g_string_append_printf(json, "\"%s\"%s", escaped, label[1] ? ", " : "");
                g_free(escaped);
            }
            g_string_append(json, " ],\n");
        } else {
            g_string_append(json, "    \"labels\": [],\n");
        }
        g_string_append_printf(json, "    \"name\": \"%s\",\n", name);
        g_string_append_printf(json, "    \"page\": %d,\n", MAX(0, favorite->page));
        g_string_append_printf(json, "    \"path\": \"%s\",\n", path);
        g_string_append_printf(json, "    \"title\": \"%s\",\n", title);
        g_string_append_printf(json, "    \"type\": \"%s\"\n", type);
        g_string_append_printf(json, "  }%s\n", i + 1 == state->favorites->len ? "" : ",");

        g_free(name);
        g_free(title);
        g_free(path);
        g_free(type);
    }
    g_string_append(json, "]\n");
    return g_string_free(json, FALSE);
}

// --- per-document view state (documents.json) --------------------------------------

static char* document_state_key(const char* path) {
    if (!path || !*path) return g_strdup("");
    return g_canonicalize_filename(path, NULL);
}

static void parse_document_object(SpdfState* state, const char* key, const char* object) {
    SpdfDocState* doc_state = g_new0(SpdfDocState, 1);
    char* geometry;

    doc_state->path = json_get_string(object, "path");
    if (!doc_state->path) doc_state->path = g_strdup(key);
    doc_state->title = json_get_string(object, "title");
    if (!doc_state->title) doc_state->title = g_strdup("");
    doc_state->has_show_sidebar = json_find_key(object, "showSidebar") != NULL;
    doc_state->has_show_minimap = json_find_key(object, "showMinimap") != NULL;
    doc_state->show_sidebar = json_get_bool(object, "showSidebar", TRUE);
    doc_state->show_minimap = json_get_bool(object, "showMinimap", TRUE);
    doc_state->updated_at = json_get_int64(object, "updatedAt", 0);
    doc_state->geometry_version = json_get_int(object, "geometryVersion", 0);
    doc_state->geometry_file_size = json_get_uint64(object, "geometryFileSize", 0);
    doc_state->geometry_modified_at = json_get_double(object, "geometryModifiedAt", 0.0);
    doc_state->geometry_page_count = json_get_int(object, "geometryPageCount", 0);

    geometry = json_get_array_contents(object, "pageGeometry");
    if (geometry && doc_state->geometry_page_count > 0) {
        int expected = doc_state->geometry_page_count * 2;
        double* values = g_new0(double, (gsize)expected);
        int count = 0;
        const char* pos = geometry;
        while (count < expected) {
            char* end = NULL;
            double value;
            while (*pos && (isspace((unsigned char)*pos) || *pos == ',')) pos++;
            if (!*pos) break;
            value = g_ascii_strtod(pos, &end);
            if (end == pos) break;
            values[count++] = value;
            pos = end;
        }
        if (count == expected) {
            doc_state->page_geometry = values;
        } else {
            g_free(values);
            doc_state->geometry_page_count = 0;
        }
    } else if (doc_state->geometry_page_count > 0) {
        doc_state->geometry_page_count = 0;
    }
    g_free(geometry);

    g_hash_table_replace(state->documents, g_strdup(key), doc_state);
}

static void ensure_documents_loaded(SpdfState* state) {
    char* json = NULL;
    const char* pos;

    if (state->documents_loaded) return;
    state->documents_loaded = TRUE;
    if (!read_state_file_as_json(state->documents_path, &json)) return;
    pos = json;
    while (*pos && isspace((unsigned char)*pos)) pos++;
    if (*pos == '{') {
        pos++;
        for (;;) {
            char* key = NULL;
            char* object = NULL;
            pos = json_object_next_member(pos, &key, &object);
            if (!pos) break;
            if (key && *key && object) parse_document_object(state, key, object);
            g_free(object);
            g_free(key);
        }
    }
    g_free(json);
}

static char* documents_to_json(SpdfState* state) {
    GString* json;
    GList* keys;
    GList* iter;

    if (g_hash_table_size(state->documents) == 0) return g_strdup("{}\n");
    keys = g_list_sort(g_hash_table_get_keys(state->documents), (GCompareFunc)strcmp);
    json = g_string_new("{\n");
    for (iter = keys; iter; iter = iter->next) {
        const char* key = iter->data;
        const SpdfDocState* doc_state = g_hash_table_lookup(state->documents, key);
        char* escaped_key = json_escape(key);
        char* path = json_escape(doc_state->path ? doc_state->path : key);
        char* title = json_escape(doc_state->title ? doc_state->title : "");

        g_string_append_printf(json, "  \"%s\": {\n", escaped_key);
        if (doc_state->geometry_page_count > 0 && doc_state->page_geometry) {
            g_string_append_printf(json, "    \"geometryFileSize\": %" G_GUINT64_FORMAT ",\n",
                                   doc_state->geometry_file_size);
            g_string_append(json, "    \"geometryModifiedAt\": ");
            append_json_fixed(json, doc_state->geometry_modified_at, 6);
            g_string_append(json, ",\n");
            g_string_append_printf(json, "    \"geometryPageCount\": %d,\n", doc_state->geometry_page_count);
            g_string_append_printf(json, "    \"geometryVersion\": %d,\n", doc_state->geometry_version);
            g_string_append(json, "    \"pageGeometry\": [ ");
            for (int i = 0; i < doc_state->geometry_page_count * 2; ++i) {
                append_json_fixed(json, doc_state->page_geometry[i], 4);
                if (i + 1 < doc_state->geometry_page_count * 2) g_string_append(json, ", ");
            }
            g_string_append(json, " ],\n");
        }
        g_string_append_printf(json, "    \"path\": \"%s\",\n", path);
        g_string_append_printf(json, "    \"showMinimap\": %s,\n", doc_state->show_minimap ? "true" : "false");
        g_string_append_printf(json, "    \"showSidebar\": %s,\n", doc_state->show_sidebar ? "true" : "false");
        g_string_append_printf(json, "    \"title\": \"%s\",\n", title);
        g_string_append_printf(json, "    \"updatedAt\": %" G_GINT64_FORMAT "\n", doc_state->updated_at);
        g_string_append_printf(json, "  }%s\n", iter->next ? "," : "");

        g_free(title);
        g_free(path);
        g_free(escaped_key);
    }
    g_string_append(json, "}\n");
    g_list_free(keys);
    return g_string_free(json, FALSE);
}

// --- coalesced asynchronous writes ---------------------------------------------

typedef struct write_job {
    char* path;
    char* contents;
} write_job;

typedef struct write_batch {
    GPtrArray* jobs;             // write_job*
    gboolean has_session;
    char* session_path;
    char* session_lock_path;
    GPtrArray* session_windows;  // char*, serialized window objects
    GHashTable* owned_ids;       // set of char*
} write_batch;

static void write_job_free(write_job* job) {
    if (!job) return;
    g_free(job->path);
    g_free(job->contents);
    g_free(job);
}

static void write_batch_free(write_batch* batch) {
    if (!batch) return;
    if (batch->jobs) g_ptr_array_free(batch->jobs, TRUE);
    if (batch->session_windows) g_ptr_array_free(batch->session_windows, TRUE);
    if (batch->owned_ids) g_hash_table_destroy(batch->owned_ids);
    g_free(batch->session_path);
    g_free(batch->session_lock_path);
    g_free(batch);
}

static void write_batch_run(write_batch* batch) {
    for (guint i = 0; i < batch->jobs->len; ++i) {
        write_job* job = g_ptr_array_index(batch->jobs, i);
        write_state_file_from_json(job->path, job->contents);
    }
    if (batch->has_session)
        merge_session_store(batch->session_path, batch->session_lock_path, batch->session_windows, batch->owned_ids);
}

static gpointer write_batch_thread(gpointer data) {
    write_batch* batch = data;
    write_batch_run(batch);
    write_batch_free(batch);
    return NULL;
}

static void write_batch_add_job(write_batch* batch, const char* path, char* contents /*takes ownership*/) {
    write_job* job = g_new0(write_job, 1);
    job->path = g_strdup(path);
    job->contents = contents;
    g_ptr_array_add(batch->jobs, job);
}

static void state_join_writer(SpdfState* state) {
    if (!state->writer) return;
    g_thread_join(state->writer);
    state->writer = NULL;
}

// Serialize everything dirty on the caller's thread (the model is main-thread
// owned) and clear the dirty flags. Returns NULL when nothing needs writing.
static write_batch* state_take_dirty_batch(SpdfState* state) {
    write_batch* batch;
    gboolean session = state->session_dirty && !state->suppress_session_write;

    if (!state->settings_dirty && !session && !state->favorites_dirty && !state->documents_dirty) {
        state->session_dirty = FALSE;
        return NULL;
    }

    batch = g_new0(write_batch, 1);
    batch->jobs = g_ptr_array_new_with_free_func((GDestroyNotify)write_job_free);

    if (state->settings_dirty) write_batch_add_job(batch, state->settings_path, settings_to_json(state));
    if (state->favorites_dirty) write_batch_add_job(batch, state->favorites_path, favorites_to_json(state));
    if (state->documents_dirty) write_batch_add_job(batch, state->documents_path, documents_to_json(state));
    if (session) {
        GHashTableIter iter;
        gpointer id;
        batch->has_session = TRUE;
        batch->session_path = g_strdup(state->session_path);
        batch->session_lock_path = g_strdup(state->session_lock_path);
        batch->session_windows = g_ptr_array_new_with_free_func(g_free);
        batch->owned_ids = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
        for (guint i = 0; i < state->live_windows->len; ++i) {
            SpdfSessionWindow* win = g_ptr_array_index(state->live_windows, i);
            g_ptr_array_add(batch->session_windows, session_window_to_json(win));
            if (win->id) g_hash_table_add(batch->owned_ids, g_strdup(win->id));
        }
        g_hash_table_iter_init(&iter, state->removed_window_ids);
        while (g_hash_table_iter_next(&iter, &id, NULL)) g_hash_table_add(batch->owned_ids, g_strdup(id));
    }

    state->settings_dirty = FALSE;
    state->session_dirty = FALSE;
    state->favorites_dirty = FALSE;
    state->documents_dirty = FALSE;
    return batch;
}

static gboolean state_write_timeout_cb(gpointer data) {
    SpdfState* state = data;
    write_batch* batch;

    state->write_timeout_id = 0;
    state_join_writer(state);
    batch = state_take_dirty_batch(state);
    if (batch) state->writer = g_thread_new("spdf-state-write", write_batch_thread, batch);
    return G_SOURCE_REMOVE;
}

static void state_schedule_write(SpdfState* state) {
    if (state->write_timeout_id) return;
    state->write_timeout_id = g_timeout_add(SPDF_STATE_WRITE_DELAY_MS, state_write_timeout_cb, state);
}

void spdf_state_flush(SpdfState* state) {
    write_batch* batch;

    if (!state) return;
    if (state->write_timeout_id) {
        g_source_remove(state->write_timeout_id);
        state->write_timeout_id = 0;
    }
    state_join_writer(state);
    batch = state_take_dirty_batch(state);
    if (batch) {
        write_batch_run(batch);
        write_batch_free(batch);
    }
}

// --- lifecycle -------------------------------------------------------------------

SpdfState* spdf_state_load_from_dir(const char* config_dir) {
    static const char* const migrate_stems[] = {"settings", "session", "documents", "favorites"};
    SpdfState* state = g_new0(SpdfState, 1);
    char* json = NULL;
    int lock_fd;

    state->config_dir = g_strdup(config_dir);
    state->settings_path = g_build_filename(config_dir, "settings.yaml", NULL);
    state->session_path = g_build_filename(config_dir, "session.yaml", NULL);
    state->session_lock_path = g_build_filename(config_dir, "session.lock", NULL);
    state->favorites_path = g_build_filename(config_dir, "favorites.yaml", NULL);
    state->documents_path = g_build_filename(config_dir, "documents.yaml", NULL);
    g_mkdir_with_parents(config_dir, 0700);
    /* One-time per-file JSON -> YAML migration, flock-guarded across the
     * app's window processes inside the codec (see core/spdf_yaml.h). Must
     * run before anything below reads state. */
    spdf_state_migrate_dir(config_dir, migrate_stems, 4);

    state->loaded_windows = g_ptr_array_new_with_free_func((GDestroyNotify)spdf_session_window_free);
    state->live_windows = g_ptr_array_new_with_free_func((GDestroyNotify)spdf_session_window_free);
    state->removed_window_ids = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    state->favorites = g_ptr_array_new_with_free_func((GDestroyNotify)favorite_free);
    state->documents = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, (GDestroyNotify)doc_state_free);

    settings_init_defaults(&state->settings);
    if (read_state_file_as_json(state->settings_path, &json)) {
        parse_settings(state, json);
        g_free(json);
        json = NULL;
    }

    lock_fd = lock_session_store(state->session_lock_path);
    if (read_state_file_as_json(state->session_path, &json)) {
        parse_session(state, json);
        g_free(json);
    }
    unlock_session_store(lock_fd);
    return state;
}

SpdfState* spdf_state_load(void) {
    char* config_dir = g_build_filename(g_get_user_config_dir(), "shenzhenpdf", NULL);
    SpdfState* state;
#ifndef SPDF_STATE_TESTING
    spdf_launch_mark("state: load begin");
#endif
    state = spdf_state_load_from_dir(config_dir);
#ifndef SPDF_STATE_TESTING
    spdf_launch_mark("state: settings+session loaded");
#endif
    g_free(config_dir);
    return state;
}

void spdf_state_free(SpdfState* state) {
    if (!state) return;
    spdf_state_flush(state);

    g_free(state->settings.comment_author);
    g_free(state->settings.skipped_update_version);
    g_free(state->settings.translate_source_language);
    g_free(state->settings.translate_target_language);
    g_free(state->settings.ocr_language);
    for (int i = 0; i < state->recent_count; ++i) g_free(state->recent_paths[i]);
    for (int i = 0; i < state->closed_count; ++i) g_free(state->closed_paths[i]);
    g_ptr_array_free(state->loaded_windows, TRUE);
    g_ptr_array_free(state->live_windows, TRUE);
    g_hash_table_destroy(state->removed_window_ids);
    g_ptr_array_free(state->favorites, TRUE);
    g_hash_table_destroy(state->documents);
    g_free(state->config_dir);
    g_free(state->settings_path);
    g_free(state->session_path);
    g_free(state->session_lock_path);
    g_free(state->favorites_path);
    g_free(state->documents_path);
    g_free(state);
}

const char* spdf_state_config_dir(SpdfState* state) {
    return state ? state->config_dir : NULL;
}

const char* spdf_state_file_path(SpdfState* state, const char* name) {
    if (!state) return NULL;
    /* Legacy .json names keep resolving to the (now YAML) live file. */
    if (!name || !*name || strcmp(name, "settings.yaml") == 0 || strcmp(name, "settings.json") == 0)
        return state->settings_path;
    if (strcmp(name, "session.yaml") == 0 || strcmp(name, "session.json") == 0) return state->session_path;
    if (strcmp(name, "favorites.yaml") == 0 || strcmp(name, "favorites.json") == 0) return state->favorites_path;
    if (strcmp(name, "documents.yaml") == 0 || strcmp(name, "documents.json") == 0) return state->documents_path;
    return state->settings_path;
}

// --- public save entry points (coalesced) -------------------------------------

SpdfSettings* spdf_state_settings(SpdfState* state) {
    return state ? &state->settings : NULL;
}

void spdf_state_set_string(char** field, const char* value) {
    if (!field) return;
    g_free(*field);
    *field = g_strdup(value ? value : "");
}

void spdf_state_save_settings(SpdfState* state) {
    if (!state) return;
    state->settings_dirty = TRUE;
    state_schedule_write(state);
}

void spdf_state_save_session(SpdfState* state) {
    if (!state || state->suppress_session_write) return;
    state->session_dirty = TRUE;
    state_schedule_write(state);
}

void spdf_state_save_favorites(SpdfState* state) {
    if (!state) return;
    ensure_favorites_loaded(state);
    state->favorites_dirty = TRUE;
    state_schedule_write(state);
}

void spdf_state_save_documents(SpdfState* state) {
    if (!state) return;
    ensure_documents_loaded(state);
    state->documents_dirty = TRUE;
    state_schedule_write(state);
}

void spdf_state_set_suppress_session_write(SpdfState* state, gboolean suppress) {
    if (!state) return;
    state->suppress_session_write = suppress;
}

// --- session accessors -----------------------------------------------------------

guint spdf_state_session_window_count(SpdfState* state) {
    return state ? state->loaded_windows->len : 0;
}

const SpdfSessionWindow* spdf_state_session_window(SpdfState* state, guint index) {
    if (!state || index >= state->loaded_windows->len) return NULL;
    return g_ptr_array_index(state->loaded_windows, index);
}

const SpdfSessionWindow* spdf_state_session_window_by_id(SpdfState* state, const char* id) {
    if (!state || !id || !*id) return NULL;
    for (guint i = 0; i < state->loaded_windows->len; ++i) {
        const SpdfSessionWindow* win = g_ptr_array_index(state->loaded_windows, i);
        if (g_strcmp0(win->id, id) == 0) return win;
    }
    return NULL;
}

void spdf_state_update_session_window(SpdfState* state, SpdfSessionWindow* win) {
    if (!state || !win) return;
    if (!win->id || !*win->id) {
        g_free(win->id);
        win->id = new_window_session_id();
    }
    for (guint i = 0; i < state->live_windows->len; ++i) {
        SpdfSessionWindow* existing = g_ptr_array_index(state->live_windows, i);
        if (g_strcmp0(existing->id, win->id) == 0) {
            g_ptr_array_index(state->live_windows, i) = win;
            spdf_session_window_free(existing);
            spdf_state_save_session(state);
            return;
        }
    }
    g_ptr_array_add(state->live_windows, win);
    g_hash_table_remove(state->removed_window_ids, win->id);
    spdf_state_save_session(state);
}

void spdf_state_remove_session_window(SpdfState* state, const char* id) {
    if (!state || !id || !*id) return;
    for (guint i = 0; i < state->live_windows->len; ++i) {
        SpdfSessionWindow* existing = g_ptr_array_index(state->live_windows, i);
        if (g_strcmp0(existing->id, id) == 0) {
            g_ptr_array_remove_index(state->live_windows, i);
            break;
        }
    }
    g_hash_table_add(state->removed_window_ids, g_strdup(id));
    state->session_dirty = TRUE; // removal must reach disk even with zero live windows
    if (!state->suppress_session_write) state_schedule_write(state);
}

// --- recents ---------------------------------------------------------------------

int spdf_state_recent_count(SpdfState* state) {
    return state ? state->recent_count : 0;
}

const char* spdf_state_recent_path(SpdfState* state, int index) {
    if (!state || index < 0 || index >= state->recent_count) return NULL;
    return state->recent_paths[index];
}

static gboolean paths_equal_canonical(const char* a, const char* b) {
    char* ca;
    char* cb;
    gboolean equal;
    if (g_strcmp0(a, b) == 0) return TRUE;
    if (!a || !b) return FALSE;
    ca = g_canonicalize_filename(a, NULL);
    cb = g_canonicalize_filename(b, NULL);
    equal = g_strcmp0(ca, cb) == 0;
    g_free(cb);
    g_free(ca);
    return equal;
}

void spdf_state_remove_recent(SpdfState* state, const char* path) {
    if (!state || !path || !*path) return;
    for (int i = 0; i < state->recent_count; ++i) {
        if (paths_equal_canonical(state->recent_paths[i], path)) {
            g_free(state->recent_paths[i]);
            memmove(&state->recent_paths[i], &state->recent_paths[i + 1],
                    (gsize)(state->recent_count - i - 1) * sizeof(char*));
            state->recent_count--;
            i--;
        }
    }
    spdf_state_save_settings(state);
}

void spdf_state_add_recent(SpdfState* state, const char* path) {
    if (!state || !path || !*path) return;
    for (int i = 0; i < state->recent_count; ++i) {
        if (paths_equal_canonical(state->recent_paths[i], path)) {
            g_free(state->recent_paths[i]);
            memmove(&state->recent_paths[i], &state->recent_paths[i + 1],
                    (gsize)(state->recent_count - i - 1) * sizeof(char*));
            state->recent_count--;
            break;
        }
    }
    if (state->recent_count == SPDF_STATE_MAX_RECENT_DOCUMENTS) {
        g_free(state->recent_paths[SPDF_STATE_MAX_RECENT_DOCUMENTS - 1]);
        state->recent_count--;
    }
    memmove(&state->recent_paths[1], &state->recent_paths[0], (gsize)state->recent_count * sizeof(char*));
    state->recent_paths[0] = g_strdup(path);
    state->recent_count++;
    spdf_state_save_settings(state);
}

// --- closed-documents ring (in-memory, like GTK3 + Mac) ----------------------------

void spdf_state_remember_closed(SpdfState* state, const char* path) {
    if (!state || !path || !*path) return;
    if (state->closed_count == SPDF_STATE_MAX_CLOSED_DOCUMENTS) {
        g_free(state->closed_paths[0]);
        memmove(&state->closed_paths[0], &state->closed_paths[1],
                (SPDF_STATE_MAX_CLOSED_DOCUMENTS - 1) * sizeof(char*));
        state->closed_count--;
    }
    state->closed_paths[state->closed_count++] = g_strdup(path);
}

char* spdf_state_pop_closed(SpdfState* state) {
    char* path;
    if (!state || state->closed_count == 0) return NULL;
    path = state->closed_paths[state->closed_count - 1];
    state->closed_paths[state->closed_count - 1] = NULL;
    state->closed_count--;
    return path;
}

int spdf_state_closed_count(SpdfState* state) {
    return state ? state->closed_count : 0;
}

// --- favorites ---------------------------------------------------------------------

guint spdf_state_favorite_count(SpdfState* state) {
    if (!state) return 0;
    ensure_favorites_loaded(state);
    return state->favorites->len;
}

const SpdfFavorite* spdf_state_favorite(SpdfState* state, guint index) {
    if (!state) return NULL;
    ensure_favorites_loaded(state);
    if (index >= state->favorites->len) return NULL;
    return g_ptr_array_index(state->favorites, index);
}

void spdf_state_add_favorite(SpdfState* state, const SpdfFavorite* favorite) {
    const char* type;
    if (!state || !favorite || !favorite->path || !*favorite->path) return;
    ensure_favorites_loaded(state);
    type = favorite->type && *favorite->type ? favorite->type : "page";
    // Same dedupe rule as the Mac app: one document favorite per path, one
    // page favorite per (path, page).
    for (guint i = 0; i < state->favorites->len;) {
        const SpdfFavorite* existing = g_ptr_array_index(state->favorites, i);
        gboolean same = g_strcmp0(existing->type ? existing->type : "page", type) == 0 &&
                        paths_equal_canonical(existing->path, favorite->path) &&
                        (strcmp(type, "page") != 0 || existing->page == favorite->page);
        if (same) g_ptr_array_remove_index(state->favorites, i);
        else i++;
    }
    if (state->favorites->len >= SPDF_STATE_MAX_FAVORITES) g_ptr_array_remove_index(state->favorites, 0);
    g_ptr_array_add(state->favorites, favorite_copy(favorite));
    spdf_state_save_favorites(state);
}

gboolean spdf_state_remove_favorite(SpdfState* state, guint index) {
    if (!state) return FALSE;
    ensure_favorites_loaded(state);
    if (index >= state->favorites->len) return FALSE;
    g_ptr_array_remove_index(state->favorites, index);
    spdf_state_save_favorites(state);
    return TRUE;
}

// --- per-document view state ---------------------------------------------------------

const SpdfDocState* spdf_state_document_lookup(SpdfState* state, const char* path) {
    char* key;
    const SpdfDocState* doc_state;
    if (!state || !path || !*path) return NULL;
    ensure_documents_loaded(state);
    key = document_state_key(path);
    doc_state = g_hash_table_lookup(state->documents, key);
    g_free(key);
    return doc_state;
}

void spdf_state_document_update(SpdfState* state, const SpdfDocState* source) {
    char* key;
    SpdfDocState* doc_state;

    if (!state || !source || !source->path || !*source->path) return;
    ensure_documents_loaded(state);
    key = document_state_key(source->path);
    doc_state = g_hash_table_lookup(state->documents, key);
    if (!doc_state) {
        doc_state = g_new0(SpdfDocState, 1);
        g_hash_table_replace(state->documents, g_strdup(key), doc_state);
    }
    g_free(key);

    spdf_state_set_string(&doc_state->path, source->path);
    spdf_state_set_string(&doc_state->title, source->title);
    doc_state->show_sidebar = source->show_sidebar;
    doc_state->show_minimap = source->show_minimap;
    doc_state->has_show_sidebar = TRUE;
    doc_state->has_show_minimap = TRUE;
    doc_state->updated_at = (gint64)(g_get_real_time() / G_USEC_PER_SEC);
    // A geometry_page_count of 0 keeps any previously stored geometry cache —
    // callers without a fully rendered document just update the view prefs
    // (mirrors the Mac saveDocumentStateForTab behavior).
    if (source->geometry_page_count > 0 && source->page_geometry) {
        g_free(doc_state->page_geometry);
        doc_state->geometry_page_count = source->geometry_page_count;
        doc_state->page_geometry = g_new(double, (gsize)source->geometry_page_count * 2);
        memcpy(doc_state->page_geometry, source->page_geometry,
               (gsize)source->geometry_page_count * 2 * sizeof(double));
        doc_state->geometry_version = SPDF_STATE_PAGE_GEOMETRY_VERSION;
        doc_state->geometry_file_size = source->geometry_file_size;
        doc_state->geometry_modified_at = source->geometry_modified_at;
    }
    spdf_state_save_documents(state);
}

gboolean spdf_doc_state_geometry_valid(const SpdfDocState* doc_state,
                                       guint64 file_size,
                                       double modified_at,
                                       int page_count) {
    if (!doc_state || doc_state->geometry_version != SPDF_STATE_PAGE_GEOMETRY_VERSION) return FALSE;
    if (file_size == 0 || doc_state->geometry_file_size != file_size) return FALSE;
    if (!isfinite(doc_state->geometry_modified_at) ||
        fabs(doc_state->geometry_modified_at - modified_at) > SPDF_STATE_PAGE_GEOMETRY_MTIME_TOLERANCE)
        return FALSE;
    if (page_count <= 0 || doc_state->geometry_page_count != page_count || !doc_state->page_geometry) return FALSE;
    for (int i = 0; i < page_count * 2; ++i) {
        if (!isfinite(doc_state->page_geometry[i]) || doc_state->page_geometry[i] <= 0.0) return FALSE;
    }
    return TRUE;
}

gboolean spdf_state_stat_file(const char* path, guint64* size, double* modified_at) {
    GStatBuf st;
    if (!path || !*path || g_stat(path, &st) != 0) return FALSE;
    if (size) *size = (guint64)st.st_size;
#ifdef __linux__
    if (modified_at) *modified_at = (double)st.st_mtim.tv_sec + (double)st.st_mtim.tv_nsec / 1e9;
#else
    if (modified_at) *modified_at = (double)st.st_mtime;
#endif
    return TRUE;
}

// --- window geometry clamp (June defect #3) ------------------------------------------

void spdf_state_clamp_geometry(const GdkRectangle* workarea, GdkRectangle* frame) {
    GdkRectangle wa;
    int ix;
    int iy;
    int iw;
    int ih;
    gint64 visible_area;

    if (!frame) return;
    frame->width = clamp_int(frame->width, SPDF_STATE_MIN_WINDOW_WIDTH, SPDF_STATE_MAX_WINDOW_WIDTH);
    frame->height = clamp_int(frame->height, SPDF_STATE_MIN_WINDOW_HEIGHT, SPDF_STATE_MAX_WINDOW_HEIGHT);
    if (!workarea || workarea->width <= 0 || workarea->height <= 0) return;
    wa = *workarea;

    frame->width = MAX(SPDF_STATE_MIN_WINDOW_WIDTH, MIN(frame->width, wa.width));
    frame->height = MAX(SPDF_STATE_MIN_WINDOW_HEIGHT, MIN(frame->height, wa.height));

    ix = MAX(frame->x, wa.x);
    iy = MAX(frame->y, wa.y);
    iw = MIN(frame->x + frame->width, wa.x + wa.width) - ix;
    ih = MIN(frame->y + frame->height, wa.y + wa.height) - iy;
    visible_area = (iw > 0 && ih > 0) ? (gint64)iw * (gint64)ih : 0;

    if (visible_area < 80 * 80) {
        // Not meaningfully on this workarea: center (same rule as the Mac app).
        frame->x = wa.x + (wa.width - frame->width) / 2;
        frame->y = wa.y + (wa.height - frame->height) / 2;
    } else {
        frame->x = MIN(MAX(frame->x, wa.x), wa.x + wa.width - frame->width);
        frame->y = MIN(MAX(frame->y, wa.y), wa.y + wa.height - frame->height);
    }
}

#ifndef SPDF_STATE_TESTING
void spdf_state_clamp_geometry_for_monitor(GdkMonitor* monitor, GdkRectangle* frame) {
    GdkRectangle geometry = {0, 0, 0, 0};
    // GTK4 dropped gdk_monitor_get_workarea; the monitor geometry is the best
    // available approximation (panels are subtracted by the compositor on
    // Wayland anyway when it places the window).
    if (monitor) gdk_monitor_get_geometry(monitor, &geometry);
    spdf_state_clamp_geometry(&geometry, frame);
}
#endif
