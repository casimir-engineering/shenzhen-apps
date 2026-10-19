/* spdf_win_favorites.c — see spdf_win_favorites.h. */
#include "spdf_win_favorites.h"

#include "spdf_win_recents.h" /* spdf_win_recents_path_equal: the one dedupe rule */
#include "spdf_win_recents_json.h"
#include "spdf_win_state.h"
#include "spdf_win_watcher.h" /* spdf_win_watcher_is_shadow_path: a copy is not a document */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static SpdfWinFavorite* g_items;
static int g_count;
static int g_cap;
static int g_loaded;

static void copy_bounded(char* out, size_t cap, const char* text) {
    size_t n = text ? strlen(text) : 0;
    if (n >= cap) n = cap - 1;
    memcpy(out, text ? text : "", n);
    out[n] = '\0';
}

static const char* leaf(const char* path) {
    const char* p = path;
    const char* last = path;
    for (; *p; ++p)
        if (*p == '\\' || *p == '/') last = p + 1;
    return last;
}

static SpdfWinFavorite* grow(void) {
    if (g_count == g_cap) {
        int want = g_cap ? g_cap * 2 : 16;
        SpdfWinFavorite* grown = (SpdfWinFavorite*)realloc(g_items, (size_t)want * sizeof(*grown));
        if (!grown) return NULL;
        g_items = grown;
        g_cap = want;
    }
    memset(&g_items[g_count], 0, sizeof(g_items[0]));
    return &g_items[g_count++];
}

/* One object of the array. `legacy` is the GTK3 shape: 1-based "page", a
 * boolean "document", no name or labels -- spdf_state.c parse_favorite_object. */
static void parse_one(const char* obj, int legacy) {
    char key[64];
    const char *value, *end;
    const char* cursor = obj;
    SpdfWinFavorite f;
    int is_document = 0, has_name = 0;

    memset(&f, 0, sizeof(f));
    copy_bounded(f.labels, sizeof(f.labels), "[]");
    while ((cursor = rj_member(cursor, key, sizeof(key), &value, &end)) != NULL) {
        if (strcmp(key, "path") == 0) rj_string(value, f.path, sizeof(f.path));
        else if (strcmp(key, "title") == 0) rj_string(value, f.title, sizeof(f.title));
        else if (strcmp(key, "name") == 0) has_name = rj_string(value, f.name, sizeof(f.name)) != NULL;
        else if (strcmp(key, "type") == 0) rj_string(value, f.type, sizeof(f.type));
        else if (strcmp(key, "page") == 0) f.page = (int)rj_int(value, legacy ? 1 : 0);
        else if (strcmp(key, "created") == 0) f.created = rj_int(value, 0);
        else if (strcmp(key, "document") == 0) is_document = rj_bool(value, 0);
        else if (strcmp(key, "labels") == 0 && *rj_skip_ws(value) == '[' && (size_t)(end - value) < sizeof(f.labels)) {
            memcpy(f.labels, value, (size_t)(end - value));
            f.labels[end - value] = '\0';
        }
    }
    if (!f.path[0]) return;
    if (legacy) {
        copy_bounded(f.type, sizeof(f.type), is_document ? "document" : "page");
        f.page = f.page - 1;
        copy_bounded(f.name, sizeof(f.name), f.title);
        f.created = 0;
    } else {
        if (!f.type[0]) copy_bounded(f.type, sizeof(f.type), "page");
        if (!has_name) copy_bounded(f.name, sizeof(f.name), f.title);
    }
    if (f.page < 0) f.page = 0;
    if (g_count >= SPDF_WIN_FAVORITES_MAX) return;
    {
        SpdfWinFavorite* slot = grow();
        if (slot) *slot = f;
    }
}

static void load(void) {
    char* json;
    const char* p;
    const char* array = NULL;
    int legacy = 0;
    if (g_loaded) return;
    g_loaded = 1;
    json = spdf_win_state_read_json(SPDF_WIN_STATE_FAVORITES);
    if (!json) return;
    p = rj_skip_ws(json);
    if (*p == '{') {
        const char* end;
        array = rj_find(p, "favorites", &end);
        legacy = 1;
    } else if (*p == '[') {
        array = p;
    }
    if (array && *rj_skip_ws(array) == '[') {
        const char *value, *end;
        const char* cursor = array;
        while ((cursor = rj_element(cursor, &value, &end)) != NULL)
            if (*rj_skip_ws(value) == '{') parse_one(value, legacy);
    }
    free(json);
}

void spdf_win_favorites_reset(void) {
    free(g_items);
    g_items = NULL;
    g_count = g_cap = 0;
    g_loaded = 0;
}

char* spdf_win_favorites_json(void) {
    rj_buf b;
    int i;
    load();
    memset(&b, 0, sizeof(b));
    rj_puts(&b, "[");
    for (i = 0; i < g_count; ++i) {
        const SpdfWinFavorite* f = &g_items[i];
        if (i) rj_puts(&b, ",");
        rj_puts(&b, "{\"created\":");
        rj_emit_int(&b, f->created);
        rj_puts(&b, ",\"labels\":");
        rj_puts(&b, f->labels[0] ? f->labels : "[]");
        rj_puts(&b, ",\"name\":");
        rj_emit_string(&b, f->name);
        rj_puts(&b, ",\"page\":");
        rj_emit_int(&b, f->page < 0 ? 0 : f->page);
        rj_puts(&b, ",\"path\":");
        rj_emit_string(&b, f->path);
        rj_puts(&b, ",\"title\":");
        rj_emit_string(&b, f->title);
        rj_puts(&b, ",\"type\":");
        rj_emit_string(&b, f->type[0] ? f->type : "page");
        rj_puts(&b, "}");
    }
    rj_puts(&b, "]");
    if (b.failed) {
        free(b.data);
        return NULL;
    }
    return b.data;
}

static void save(void) {
    char* json = spdf_win_favorites_json();
    if (!json) return;
    spdf_win_state_write_json(SPDF_WIN_STATE_FAVORITES, json);
    free(json);
}

int spdf_win_favorites_count(void) {
    load();
    return g_count;
}

const SpdfWinFavorite* spdf_win_favorites_at(int index) {
    load();
    if (index < 0 || index >= g_count) return NULL;
    return &g_items[index];
}

static int same_favorite(const SpdfWinFavorite* f, const char* type, const char* path, int page) {
    const char* ftype = f->type[0] ? f->type : "page";
    if (strcmp(ftype, type) != 0) return 0;
    if (!spdf_win_recents_path_equal(f->path, path)) return 0;
    return strcmp(type, "page") != 0 || f->page == page;
}

int spdf_win_favorites_find(const char* type, const char* path, int page) {
    int i;
    if (!path || !*path) return -1;
    if (!type || !*type) type = "page";
    load();
    for (i = 0; i < g_count; ++i)
        if (same_favorite(&g_items[i], type, path, page)) return i;
    return -1;
}

static void erase(int index) {
    memmove(&g_items[index], &g_items[index + 1], (size_t)(g_count - index - 1) * sizeof(g_items[0]));
    g_count--;
}

int spdf_win_favorites_add(const SpdfWinFavorite* favorite) {
    const char* type;
    SpdfWinFavorite* slot;
    int i;
    if (!favorite || !favorite->path[0]) return -1;
    /* A read-only shadow copy is refused here for the same reason recents
     * refuses it (spdf_win_recents_note_opened) and with more at stake: a
     * favorite outlives the session, and the copy it would name is deleted by
     * the next launch's orphan sweep, so the bookmark would be broken by the
     * time anyone used it. spdf_win_recents.h has promised this refusal for
     * both stores since it was written and neither implemented it.
     *
     * Today's Ctrl+D already hands over the tab's SOURCE path rather than its
     * working_path (spdf_win_cmd_docs.h docs_toggle_favorite, spdf_win_tabs.h),
     * so this is the store refusing to be given the wrong one -- which is where
     * the check belongs: the next caller does not have to know the rule. */
    if (spdf_win_watcher_is_shadow_path(favorite->path)) return -1;
    load();
    type = favorite->type[0] ? favorite->type : "page";
    for (i = 0; i < g_count;) {
        if (same_favorite(&g_items[i], type, favorite->path, favorite->page)) erase(i);
        else i++;
    }
    if (g_count >= SPDF_WIN_FAVORITES_MAX) erase(0);
    slot = grow();
    if (!slot) return -1;
    *slot = *favorite;
    copy_bounded(slot->type, sizeof(slot->type), type);
    if (!slot->labels[0]) copy_bounded(slot->labels, sizeof(slot->labels), "[]");
    if (slot->page < 0) slot->page = 0;
    save();
    return g_count - 1;
}

int spdf_win_favorites_remove(int index) {
    load();
    if (index < 0 || index >= g_count) return 0;
    erase(index);
    save();
    return 1;
}

static int toggle(const char* type, const char* path, const char* title, int page) {
    SpdfWinFavorite f;
    const char* display;
    int existing;
    if (!path || !*path) return -1;
    existing = spdf_win_favorites_find(type, path, page);
    if (existing >= 0) {
        spdf_win_favorites_remove(existing);
        return 0;
    }
    display = title && *title ? title : leaf(path);
    memset(&f, 0, sizeof(f));
    copy_bounded(f.type, sizeof(f.type), type);
    copy_bounded(f.path, sizeof(f.path), path);
    copy_bounded(f.title, sizeof(f.title), display);
    /* The default name is the mac prompt's default ("<title> p.<n>") without
     * the prompt -- spdf_palette.c's toggle does the same. */
    if (strcmp(type, "page") == 0) snprintf(f.name, sizeof(f.name), "%s p.%d", display, page + 1);
    else copy_bounded(f.name, sizeof(f.name), display);
    copy_bounded(f.labels, sizeof(f.labels), "[]");
    f.page = strcmp(type, "page") == 0 ? page : 0;
    f.created = (long long)time(NULL);
    return spdf_win_favorites_add(&f) >= 0 ? 1 : -1;
}

int spdf_win_favorites_toggle_page(const char* path, const char* title, int page) {
    if (page < 0) return -1;
    return toggle("page", path, title, page);
}

int spdf_win_favorites_toggle_document(const char* path, const char* title) {
    return toggle("document", path, title, 0);
}
