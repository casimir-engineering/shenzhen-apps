/* spdf_win_session.cpp — see spdf_win_session.h for the schema, its sources in
 * the two shipping frontends, and the three things this file refuses to do.
 *
 * The JSON marshalling this leans on lives in spdf_win_session_json.h, which
 * explains why hand-written scanning and formatting are the right answer here.
 * Nothing in either file writes YAML: the on-disk format has one codec and it
 * is the shared one.
 */
#include "spdf_win_session.h"

#include "spdf_win_compat.h" /* spdf_compat_getpid */
#include "spdf_win_paths.h"
#include "spdf_win_session_json.h"
#include "spdf_win_state.h"
#include "spdf_win_session_window.h" /* the window object's keys; after the two above */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* --- restore -------------------------------------------------------------- */

void spdf_win_session_new_window_id(char* out, size_t out_len) {
    static unsigned long sequence = 0;
    if (!out || out_len == 0) return;
    snprintf(out, out_len, "win-%ld-%llu-%lu", spdf_compat_getpid(), (unsigned long long)time(NULL), ++sequence);
}

static void apply_tab(spdf_win_tabs* tabs, const char* obj) {
    char* path = json_str(obj, "path");
    char* title;
    spdf_win_tab_view* view;
    int index;

    if (!path || !*path) {
        free(path);
        return;
    }
    title = json_str(obj, "title");
    index = spdf_win_tabs_append(tabs, path, title);
    free(path);
    free(title);
    if (index < 0) return;

    view = spdf_win_tabs_view(tabs, index);
    view->page = json_int(obj, "page", 0);
    /* A tab with no "viewMode" was written by a pre-multi-view GTK3 build,
     * whose pages were 1-based. Same migration the GTK reader performs. */
    if (!obj_value(obj, "viewMode", NULL)) view->page -= 1;
    if (view->page < 0) view->page = 0;
    view->zoom = json_num(obj, "zoom", 1.0);
    if (!(view->zoom > 0.0)) view->zoom = 1.0;
    view->custom_zoom = json_num(obj, "customZoom", view->zoom);
    if (!(view->custom_zoom > 0.0)) view->custom_zoom = view->zoom;
    view->fit_mode = json_int(obj, "fitMode", SPDF_WIN_TAB_FIT_PAGE);
    if (view->fit_mode < 0 || view->fit_mode > SPDF_WIN_TAB_FIT_PAGE) view->fit_mode = SPDF_WIN_TAB_FIT_PAGE;
    view->scroll_x = json_num(obj, "scrollX", 0.0);
    view->scroll_y = json_num(obj, "scrollY", 0.0);
    view->has_scroll_origin = obj_value(obj, "hasScrollOrigin", NULL)
                                  ? json_bool(obj, "hasScrollOrigin", 0)
                                  : (obj_value(obj, "scrollX", NULL) || obj_value(obj, "scrollY", NULL)) != 0;
    /* The tab's live query, restored into the find field on show. Truncated on
     * a character boundary if a mac file carries more than the field holds. */
    {
        char* search = json_str(obj, "searchText");
        if (search) {
            size_t n = strlen(search);
            if (n >= sizeof(view->search_text)) {
                n = sizeof(view->search_text) - 1;
                while (n > 0 && ((unsigned char)search[n] & 0xC0) == 0x80) --n;
            }
            memcpy(view->search_text, search, n);
            view->search_text[n] = '\0';
            free(search);
        }
    }
    /* The read-only binding (spdf_win_watcher.h), taken back here and handed to
     * the watcher by the tabs glue before the tab is first shown. Absent keys
     * read as "not read-only", which is what the mac writes for a plain file. */
    view->read_only = json_bool(obj, "readOnly", 0);
    {
        char* working = json_str(obj, "workingPath");
        if (working) {
            strncpy_s(view->working_path, sizeof(view->working_path), working, _TRUNCATE);
            free(working);
        }
    }
    view->ro_copy_file_size = (unsigned long long)json_num(obj, "roCopyFileSize", 0.0);
    view->ro_copy_modified_at = json_num(obj, "roCopyModifiedAt", 0.0);
    /* This document's own Keep Image Colors (the mac's per-tab key, 42e8c9ca7).
     * A tab written before the choice was per-document has no key and reads
     * as -1: the frontend seeds it with the settings default, which this file
     * does not read (spdf_win_tabs_app_seed_views). */
    view->preserves_image_colors =
        obj_value(obj, "preservesImageColors", NULL) ? json_bool(obj, "preservesImageColors", 1) : -1;
}

/* The window object to restore, or NULL. A root with "tabs" and no "windows"
 * is a pre-multi-window file and counts as one window. With no id wanted it is
 * the window the reader was last using (focused_window, spdf_win_session_window.h). */
static const char* find_window(const char* root, const char* want_id) {
    const char* windows;
    const char* end = NULL;
    const char* element;

    root = skip_ws(root);
    windows = obj_value(root, "windows", NULL);
    if (!windows || *windows != '[') return obj_value(root, "tabs", NULL) ? root : NULL;
    if (!(want_id && *want_id)) return focused_window(windows);
    for (element = array_first(windows, &end); element; element = array_next(end, &end)) {
        char* id;
        int hit;
        if (*element != '{') continue;
        id = json_str(element, "id");
        hit = id && strcmp(id, want_id) == 0;
        free(id);
        if (hit) return element;
    }
    return NULL;
}

spdf_win_session_status spdf_win_session_restore(spdf_win_tabs* tabs, const char* window_id, char* out_window_id,
                                                 size_t out_len) {
    return spdf_win_session_restore_ex(tabs, window_id, out_window_id, out_len, NULL);
}

spdf_win_session_status spdf_win_session_restore_ex(spdf_win_tabs* tabs, const char* window_id, char* out_window_id,
                                                    size_t out_len, spdf_win_session_frame* out_frame) {
    spdf_win_state_read_status status = SPDF_WIN_STATE_READ_ABSENT;
    char* json;
    const char* window;
    const char* tab_array;
    const char* end = NULL;
    const char* element;
    int before, added, selected;

    if (out_frame) memset(out_frame, 0, sizeof(*out_frame));
    if (!tabs) return SPDF_WIN_SESSION_ABSENT;
    json = spdf_win_state_read_json_checked(SPDF_WIN_STATE_SESSION, &status);
    if (status == SPDF_WIN_STATE_READ_FAILED) {
        free(json);
        return SPDF_WIN_SESSION_UNREADABLE;
    }
    if (!json) return SPDF_WIN_SESSION_ABSENT;

    before = spdf_win_tabs_count(tabs);
    window = find_window(json, window_id);
    tab_array = window ? obj_value(window, "tabs", NULL) : NULL;
    for (element = array_first(tab_array, &end); element; element = array_next(end, &end))
        if (*element == '{') apply_tab(tabs, element);

    added = spdf_win_tabs_count(tabs) - before;
    if (added > 0) {
        selected = json_int(window, "selectedTab", 0);
        if (selected < 0) selected = 0;
        if (selected >= added) selected = added - 1;
        /* DEFERRED on purpose: this is the whole lazy-restore promise. */
        spdf_win_tabs_select_deferred(tabs, before + selected);
        if (out_window_id && out_len > 0) {
            char* id = json_str(window, "id");
            if (id && *id) snprintf(out_window_id, out_len, "%s", id);
            else spdf_win_session_new_window_id(out_window_id, out_len);
            free(id);
        }
        if (out_frame) read_window_frame(window, out_frame);
    }
    free(json);
    return added > 0 ? SPDF_WIN_SESSION_RESTORED : SPDF_WIN_SESSION_ABSENT;
}

/* --- save ----------------------------------------------------------------- */

/* Keys this port owns and rewrites. Everything else in an existing tab object
 * is carried through untouched — including "viewMode", so a markdown or
 * two-page view recorded by another frontend survives a Windows session. */
static int key_is_owned(const member* m) {
    static const char* const owned[] = {"path",     "title",       "page",           "zoom",
                                        "customZoom", "fitMode",   "scrollX",        "scrollY",
                                        "hasScrollOrigin", "searchText", "readOnly", "workingPath",
                                        "roCopyFileSize", "roCopyModifiedAt", "preservesImageColors"};
    size_t i;
    for (i = 0; i < sizeof(owned) / sizeof(owned[0]); ++i)
        if (key_is(m, owned[i])) return 1;
    return 0;
}

static const char* find_disk_tab(const char* window_obj, const char* path) {
    const char* tab_array = window_obj ? obj_value(window_obj, "tabs", NULL) : NULL;
    const char* end = NULL;
    const char* element;
    for (element = array_first(tab_array, &end); element; element = array_next(end, &end)) {
        char* candidate = json_str(element, "path");
        int hit = candidate && path && strcmp(candidate, path) == 0;
        free(candidate);
        if (hit) return element;
    }
    return NULL;
}

static void emit_tab(out_buf* out, const spdf_win_tabs* tabs, int index, const char* window_obj) {
    const char* path = spdf_win_tabs_path(tabs, index);
    const spdf_win_tab_view* view = spdf_win_tabs_view_const(tabs, index);
    const char* disk = find_disk_tab(window_obj, path);
    int has_view_mode = 0, ok;
    member m;

    buf_puts(out, "{\"path\":");
    emit_string(out, path);
    emit_key(out, "title");
    emit_string(out, spdf_win_tabs_title(tabs, index));
    emit_key(out, "page");
    emit_int(out, view->page);
    emit_key(out, "zoom");
    emit_fixed(out, view->zoom, 4);
    emit_key(out, "customZoom");
    emit_fixed(out, view->custom_zoom, 4);
    emit_key(out, "fitMode");
    emit_int(out, view->fit_mode);
    emit_key(out, "scrollX");
    emit_fixed(out, view->scroll_x, 4);
    emit_key(out, "scrollY");
    emit_fixed(out, view->scroll_y, 4);
    emit_key(out, "hasScrollOrigin");
    buf_puts(out, view->has_scroll_origin ? "true" : "false");
    /* Only when there is one: the mac writer omits the key for an empty query,
     * and a tab without a search must read back as a tab without a search. */
    if (view->search_text[0]) {
        emit_key(out, "searchText");
        emit_string(out, view->search_text);
    }
    /* The read-only binding, only for a tab that has one (the mac omits the
     * keys otherwise): what lets a relaunch reopen the shadow copy without
     * reading the source (spdf_win_watcher_prime_restore). The mtime keeps the
     * stat's 100 ns resolution, or the comparison on restore would never hold. */
    if (view->read_only) {
        emit_key(out, "readOnly");
        buf_puts(out, "true");
        if (view->working_path[0]) {
            emit_key(out, "workingPath");
            emit_string(out, view->working_path);
        }
        emit_key(out, "roCopyFileSize");
        emit_int(out, (long long)view->ro_copy_file_size);
        emit_key(out, "roCopyModifiedAt");
        emit_fixed(out, view->ro_copy_modified_at, 7);
    }
    /* Always, as the mac writes it, once the tab has a choice at all. */
    if (view->preserves_image_colors >= 0) {
        emit_key(out, "preservesImageColors");
        buf_puts(out, view->preserves_image_colors ? "true" : "false");
    }

    for (ok = object_first(disk, &m); ok; ok = object_next(&m)) {
        if (key_is_owned(&m)) continue;
        if (key_is(&m, "viewMode")) has_view_mode = 1;
        buf_puts(out, ",\"");
        buf_put(out, m.key, m.key_len);
        buf_puts(out, "\":");
        buf_put(out, m.val, (size_t)(m.val_end - m.val));
    }
    /* Without this the GTK reader would treat our 0-based page as 1-based. */
    if (!has_view_mode) buf_puts(out, ",\"viewMode\":1");
    buf_puts(out, "}");
}

static void emit_window(out_buf* out, const spdf_win_tabs* tabs, const char* window_id, const char* disk_window,
                        const spdf_win_session_frame* frame, int focused_now) {
    int selected = spdf_win_tabs_selected_index(tabs);
    int i, count = spdf_win_tabs_count(tabs);

    buf_puts(out, "{\"id\":");
    emit_string(out, window_id);
    /* The window's own keys -- frame, display, focusedAt -- spdf_win_session_window.h. */
    emit_window_frame(out, frame, disk_window);
    emit_focused_at(out, disk_window, focused_now);
    buf_puts(out, ",\"selectedTab\":");
    emit_int(out, selected < 0 ? 0 : selected);
    buf_puts(out, ",\"tabs\":[");
    for (i = 0; i < count; ++i) {
        if (i) buf_puts(out, ",");
        emit_tab(out, tabs, i, disk_window);
    }
    buf_puts(out, "]}");
}

int spdf_win_session_save(const spdf_win_tabs* tabs, const char* window_id) {
    return spdf_win_session_save_ex(tabs, window_id, NULL);
}

int spdf_win_session_save_ex(const spdf_win_tabs* tabs, const char* window_id, const spdf_win_session_frame* frame) {
    return spdf_win_session_save_focused(tabs, window_id, frame, 0);
}

int spdf_win_session_save_focused(const spdf_win_tabs* tabs, const char* window_id,
                                  const spdf_win_session_frame* frame, int focused_now) {
    char dir[SPDF_WIN_PATH_MAX];
    spdf_win_state_session_lock* lock;
    spdf_win_state_read_status status = SPDF_WIN_STATE_READ_ABSENT;
    char* existing;
    const char* disk_window = NULL;
    out_buf out;
    int written = 0, ok;

    if (!tabs || !window_id || !*window_id) return 0;
    if (!spdf_win_paths_state_dir(dir, sizeof(dir))) return 0;

    lock = spdf_win_state_session_lock_acquire(dir);
    existing = spdf_win_state_read_json_checked(SPDF_WIN_STATE_SESSION, &status);
    if (status == SPDF_WIN_STATE_READ_FAILED) {
        /* Present and unreadable. Write NOTHING: see the header. */
        free(existing);
        spdf_win_state_session_lock_release(lock);
        return 0;
    }

    memset(&out, 0, sizeof(out));
    buf_puts(&out, "{\"version\":2,\"windows\":[");
    if (existing) {
        const char* windows = obj_value(existing, "windows", NULL);
        const char* end = NULL;
        const char* element;
        for (element = array_first(windows, &end); element; element = array_next(end, &end)) {
            char* id = json_str(element, "id");
            int mine = id && strcmp(id, window_id) == 0;
            free(id);
            if (mine) {
                disk_window = element;
                continue;
            }
            if (written >= SPDF_WIN_SESSION_MAX_WINDOWS - 1) break;
            if (written++) buf_puts(&out, ",");
            buf_put(&out, element, (size_t)(end - element)); /* another process's window, verbatim */
        }
    }
    /* A window with no tabs is REMOVED from the file, matching the mac app's
     * -removeSessionStateForCurrentWindow when its last tab closes. */
    if (spdf_win_tabs_count(tabs) > 0) {
        if (written++) buf_puts(&out, ",");
        emit_window(&out, tabs, window_id, disk_window, frame, focused_now);
    }
    buf_puts(&out, "]}");

    ok = !out.failed && out.data && spdf_win_state_write_json(SPDF_WIN_STATE_SESSION, out.data);
    free(out.data);
    free(existing);
    spdf_win_state_session_lock_release(lock);
    return ok;
}

/* --- detach --------------------------------------------------------------- */

int spdf_win_session_detach_tab_as(const spdf_win_tabs* tabs, int index, const spdf_win_session_frame* frame,
                                   const char* window_id) {
    spdf_win_tabs* one;
    spdf_win_tab_view* view;
    const spdf_win_tab_view* source;
    int ok;

    if (!tabs || !window_id || !*window_id) return 0;
    source = spdf_win_tabs_view_const(tabs, index);
    if (!source) return 0;
    /* A one-tab model, so the hand-over goes through the SAME emit path a
     * window's own save does -- one schema, one writer. No hooks: nothing may
     * open the document here, it is the other process's to open. */
    one = spdf_win_tabs_create();
    if (!one) return 0;
    if (spdf_win_tabs_append(one, spdf_win_tabs_path(tabs, index), spdf_win_tabs_title(tabs, index)) < 0) {
        spdf_win_tabs_destroy(one);
        return 0;
    }
    view = spdf_win_tabs_view(one, 0);
    *view = *source;
    spdf_win_tabs_select_deferred(one, 0);
    ok = spdf_win_session_save_ex(one, window_id, frame);
    spdf_win_tabs_destroy(one);
    return ok;
}

int spdf_win_session_detach_tab(const spdf_win_tabs* tabs, int index, const spdf_win_session_frame* frame,
                                char* out_new_id, size_t out_len) {
    char id[SPDF_WIN_SESSION_ID_MAX];
    if (!out_new_id || out_len == 0) return 0;
    spdf_win_session_new_window_id(id, sizeof(id));
    if (!spdf_win_session_detach_tab_as(tabs, index, frame, id)) return 0;
    snprintf(out_new_id, out_len, "%s", id);
    return 1;
}

/* --- the hand-off parking spot -------------------------------------------- */

void spdf_win_session_handoff_discard(void) {
    /* A model with no tabs REMOVES its window from the file, which is exactly
     * what "the entry is gone" means -- no second code path, and no write at
     * all when the file cannot be read. */
    spdf_win_tabs* empty = spdf_win_tabs_create();
    if (!empty) return;
    spdf_win_session_save(empty, SPDF_WIN_SESSION_HANDOFF_ID);
    spdf_win_tabs_destroy(empty);
}

int spdf_win_session_handoff_take(char* out_path, size_t path_len, char* out_title, size_t title_len,
                                  spdf_win_tab_view* out_view) {
    spdf_win_tabs* parked = spdf_win_tabs_create();
    const char* path;
    int got = 0;

    if (!parked) return 0;
    /* The ordinary restore, asked for the one id a launch never asks for. It
     * opens nothing -- restore is metadata only -- so taking a tab back costs
     * a file read and no document. */
    if (spdf_win_session_restore(parked, SPDF_WIN_SESSION_HANDOFF_ID, NULL, 0) == SPDF_WIN_SESSION_RESTORED &&
        spdf_win_tabs_count(parked) > 0) {
        path = spdf_win_tabs_path(parked, 0);
        if (path && *path) {
            if (out_path && path_len) snprintf(out_path, path_len, "%s", path);
            if (out_title && title_len) snprintf(out_title, title_len, "%s", spdf_win_tabs_title(parked, 0));
            if (out_view) *out_view = *spdf_win_tabs_view_const(parked, 0);
            got = 1;
        }
    }
    spdf_win_tabs_destroy(parked);
    /* Taken or unusable, the entry goes: leaving it would let the next drop
     * adopt a stale tab. */
    if (got) spdf_win_session_handoff_discard();
    return got;
}

int spdf_win_session_other_windows(const char* window_id) {
    char* json = spdf_win_state_read_json(SPDF_WIN_STATE_SESSION);
    const char* windows;
    const char* end = NULL;
    const char* element;
    int count = 0;
    if (!json) return 0;
    windows = obj_value(skip_ws(json), "windows", NULL);
    for (element = array_first(windows, &end); element; element = array_next(end, &end)) {
        char* id;
        if (*element != '{') continue;
        id = json_str(element, "id");
        /* A tab in flight is not another window (spdf_win_session.h): counting
         * it would keep an emptied window open waiting for a sibling that is
         * a parking spot, not a process. */
        if (!(id && window_id && strcmp(id, window_id) == 0) &&
            !(id && strcmp(id, SPDF_WIN_SESSION_HANDOFF_ID) == 0))
            count++;
        free(id);
    }
    free(json);
    return count;
}
