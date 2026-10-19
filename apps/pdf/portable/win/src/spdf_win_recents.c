/* spdf_win_recents.c — see spdf_win_recents.h. */
#include "spdf_win_recents.h"

#include "spdf_win_recents_json.h"
#include "spdf_win_state.h"
#include "spdf_win_watcher.h" /* spdf_win_watcher_is_shadow_path: a copy is not a document */

#include <stdlib.h>
#include <string.h>
#include <time.h>

/* A member of a documents.yaml record this build does not model, kept as raw
 * JSON so it survives a rewrite (the mac's pageGeometry cache, say). */
typedef struct doc_extra {
    char key[64];
    char* raw; /* the value, verbatim */
} doc_extra;

#define DOC_EXTRA_MAX 8

typedef struct doc_entry {
    SpdfWinDocRecord rec;
    doc_extra extra[DOC_EXTRA_MAX];
    int extra_count;
} doc_entry;

static doc_entry* g_docs;
static int g_doc_count;
static int g_doc_cap;
static int g_loaded;

static char g_recent[SPDF_WIN_RECENTS_MAX][SPDF_WIN_RECENTS_PATH_MAX];
static int g_recent_count;

static char g_closed[SPDF_WIN_RECENTS_CLOSED_MAX][SPDF_WIN_RECENTS_PATH_MAX];
static int g_closed_count;

/* --- paths ------------------------------------------------------------------ */

static int fold(unsigned char c) {
    if (c == '/') return '\\';
    if (c >= 'A' && c <= 'Z') return c + ('a' - 'A');
    return c;
}

int spdf_win_recents_path_equal(const char* a, const char* b) {
    size_t i = 0;
    if (!a || !b) return a == b;
    for (;; ++i) {
        int ca = fold((unsigned char)a[i]);
        int cb = fold((unsigned char)b[i]);
        if (ca != cb) return 0;
        if (!ca) return 1;
    }
}

static const char* leaf(const char* path) {
    const char* p = path;
    const char* last = path;
    for (; *p; ++p)
        if (*p == '\\' || *p == '/') last = p + 1;
    return last;
}

static void copy_bounded(char* out, size_t cap, const char* text) {
    size_t n = text ? strlen(text) : 0;
    if (n >= cap) n = cap - 1;
    memcpy(out, text ? text : "", n);
    out[n] = '\0';
}

/* --- records --------------------------------------------------------------- */

static void entry_clear(doc_entry* e) {
    int i;
    for (i = 0; i < e->extra_count; ++i) free(e->extra[i].raw);
    memset(e, 0, sizeof(*e));
}

static doc_entry* find_entry(const char* path) {
    int i;
    for (i = 0; i < g_doc_count; ++i)
        if (spdf_win_recents_path_equal(g_docs[i].rec.path, path)) return &g_docs[i];
    return NULL;
}

static doc_entry* add_entry(const char* path) {
    doc_entry* e;
    if (g_doc_count == g_doc_cap) {
        int want = g_doc_cap ? g_doc_cap * 2 : 16;
        doc_entry* grown = (doc_entry*)realloc(g_docs, (size_t)want * sizeof(*grown));
        if (!grown) return NULL;
        g_docs = grown;
        g_doc_cap = want;
    }
    e = &g_docs[g_doc_count++];
    memset(e, 0, sizeof(*e));
    copy_bounded(e->rec.path, sizeof(e->rec.path), path);
    return e;
}

static int is_modelled_key(const char* key) {
    return strcmp(key, "path") == 0 || strcmp(key, "title") == 0 || strcmp(key, "showSidebar") == 0 ||
           strcmp(key, "showMinimap") == 0 || strcmp(key, "updatedAt") == 0;
}

static void parse_record(const char* key_path, const char* obj) {
    char key[64];
    const char *value, *end;
    const char* cursor = obj;
    doc_entry* e = find_entry(key_path);
    if (!e) e = add_entry(key_path);
    if (!e) return;
    while ((cursor = rj_member(cursor, key, sizeof(key), &value, &end)) != NULL) {
        if (strcmp(key, "path") == 0) {
            char path[SPDF_WIN_RECENTS_PATH_MAX];
            if (rj_string(value, path, sizeof(path)) && path[0]) copy_bounded(e->rec.path, sizeof(e->rec.path), path);
        } else if (strcmp(key, "title") == 0) {
            rj_string(value, e->rec.title, sizeof(e->rec.title));
        } else if (strcmp(key, "showSidebar") == 0) {
            e->rec.has_show_sidebar = 1;
            e->rec.show_sidebar = rj_bool(value, 1);
        } else if (strcmp(key, "showMinimap") == 0) {
            e->rec.has_show_minimap = 1;
            e->rec.show_minimap = rj_bool(value, 1);
        } else if (strcmp(key, "updatedAt") == 0) {
            e->rec.updated_at = rj_int(value, 0);
        } else if (e->extra_count < DOC_EXTRA_MAX) {
            size_t n = (size_t)(end - value);
            doc_extra* x = &e->extra[e->extra_count];
            x->raw = (char*)malloc(n + 1);
            if (!x->raw) continue;
            memcpy(x->raw, value, n);
            x->raw[n] = '\0';
            copy_bounded(x->key, sizeof(x->key), key);
            e->extra_count++;
        }
    }
}

/* --- the MRU list ------------------------------------------------------------- */

static int recent_index(const char* path) {
    int i;
    for (i = 0; i < g_recent_count; ++i)
        if (spdf_win_recents_path_equal(g_recent[i], path)) return i;
    return -1;
}

static void recent_erase(int index) {
    if (index < 0 || index >= g_recent_count) return;
    memmove(g_recent[index], g_recent[index + 1], (size_t)(g_recent_count - index - 1) * sizeof(g_recent[0]));
    g_recent_count--;
}

static void recent_push_front(const char* path) {
    int existing = recent_index(path);
    if (existing >= 0) recent_erase(existing);
    if (g_recent_count == SPDF_WIN_RECENTS_MAX) g_recent_count--;
    memmove(g_recent[1], g_recent[0], (size_t)g_recent_count * sizeof(g_recent[0]));
    copy_bounded(g_recent[0], sizeof(g_recent[0]), path);
    g_recent_count++;
}

static void recent_append(const char* path) {
    if (g_recent_count == SPDF_WIN_RECENTS_MAX || recent_index(path) >= 0) return;
    copy_bounded(g_recent[g_recent_count++], sizeof(g_recent[0]), path);
}

/* --- load ----------------------------------------------------------------- */

static int by_updated_desc(const void* a, const void* b) {
    const doc_entry* const* ea = (const doc_entry* const*)a;
    const doc_entry* const* eb = (const doc_entry* const*)b;
    if ((*ea)->rec.updated_at != (*eb)->rec.updated_at) return (*ea)->rec.updated_at > (*eb)->rec.updated_at ? -1 : 1;
    return strcmp((*ea)->rec.path, (*eb)->rec.path);
}

static void load(void) {
    char* json;
    if (g_loaded) return;
    g_loaded = 1;

    json = spdf_win_state_read_json(SPDF_WIN_STATE_DOCUMENTS);
    if (json) {
        char key[SPDF_WIN_RECENTS_PATH_MAX];
        const char *value, *end;
        const char* cursor = rj_skip_ws(json);
        if (*cursor == '{') {
            while ((cursor = rj_member(cursor, key, sizeof(key), &value, &end)) != NULL)
                if (key[0] && *rj_skip_ws(value) == '{') parse_record(key, value);
        }
        free(json);
    }

    /* The list the other frontends wrote, in their order, first. */
    json = spdf_win_state_read_json(SPDF_WIN_STATE_SETTINGS);
    if (json) {
        const char *array, *array_end;
        array = *rj_skip_ws(json) == '{' ? rj_find(json, "recentlyOpened", &array_end) : NULL;
        if (array && *rj_skip_ws(array) == '[') {
            const char *value, *end;
            const char* cursor = array;
            while ((cursor = rj_element(cursor, &value, &end)) != NULL) {
                char path[SPDF_WIN_RECENTS_PATH_MAX];
                if (rj_string(value, path, sizeof(path)) && path[0]) recent_append(path);
            }
        }
        free(json);
    }

    /* Then this machine's own opens, newest first, behind them. */
    if (g_doc_count > 0) {
        doc_entry** order = (doc_entry**)malloc((size_t)g_doc_count * sizeof(*order));
        int i;
        if (order) {
            for (i = 0; i < g_doc_count; ++i) order[i] = &g_docs[i];
            qsort(order, (size_t)g_doc_count, sizeof(*order), by_updated_desc);
            for (i = 0; i < g_doc_count && order[i]->rec.updated_at > 0; ++i) recent_append(order[i]->rec.path);
            free(order);
        }
    }
}

void spdf_win_recents_reset(void) {
    int i;
    for (i = 0; i < g_doc_count; ++i) entry_clear(&g_docs[i]);
    free(g_docs);
    g_docs = NULL;
    g_doc_count = g_doc_cap = 0;
    g_recent_count = 0;
    g_closed_count = 0;
    g_loaded = 0;
}

/* --- write ----------------------------------------------------------------- */

static int by_path(const void* a, const void* b) {
    return strcmp((*(const doc_entry* const*)a)->rec.path, (*(const doc_entry* const*)b)->rec.path);
}

/* Members sorted by key, like NSJSONWritingSortedKeys and spdf_state.c's fixed
 * order (which is alphabetical). Extras are merged in by key. */
static void emit_record(rj_buf* b, const doc_entry* e) {
    static const char* const known[] = {"path", "showMinimap", "showSidebar", "title", "updatedAt"};
    int k = 0, x = 0, first = 1;
    int extra_order[DOC_EXTRA_MAX];
    int i, j;
    for (i = 0; i < e->extra_count; ++i) extra_order[i] = i;
    for (i = 1; i < e->extra_count; ++i)
        for (j = i; j > 0 && strcmp(e->extra[extra_order[j - 1]].key, e->extra[extra_order[j]].key) > 0; --j) {
            int t = extra_order[j];
            extra_order[j] = extra_order[j - 1];
            extra_order[j - 1] = t;
        }
    rj_puts(b, "{");
    while (k < 5 || x < e->extra_count) {
        const char* key;
        int take_extra = x < e->extra_count && (k >= 5 || strcmp(e->extra[extra_order[x]].key, known[k]) < 0);
        if (!first) rj_puts(b, ",");
        first = 0;
        if (take_extra) {
            const doc_extra* ex = &e->extra[extra_order[x++]];
            rj_emit_string(b, ex->key);
            rj_puts(b, ":");
            rj_puts(b, ex->raw);
            continue;
        }
        key = known[k++];
        rj_emit_string(b, key);
        rj_puts(b, ":");
        if (strcmp(key, "path") == 0) rj_emit_string(b, e->rec.path);
        else if (strcmp(key, "title") == 0) rj_emit_string(b, e->rec.title);
        else if (strcmp(key, "showMinimap") == 0) rj_puts(b, !e->rec.has_show_minimap || e->rec.show_minimap ? "true" : "false");
        else if (strcmp(key, "showSidebar") == 0) rj_puts(b, !e->rec.has_show_sidebar || e->rec.show_sidebar ? "true" : "false");
        else rj_emit_int(b, e->rec.updated_at);
    }
    rj_puts(b, "}");
}

char* spdf_win_recents_documents_json(void) {
    rj_buf b;
    doc_entry** order;
    int i;
    load();
    memset(&b, 0, sizeof(b));
    if (g_doc_count == 0) {
        rj_puts(&b, "{}");
        return b.failed ? NULL : b.data;
    }
    order = (doc_entry**)malloc((size_t)g_doc_count * sizeof(*order));
    if (!order) return NULL;
    for (i = 0; i < g_doc_count; ++i) order[i] = &g_docs[i];
    qsort(order, (size_t)g_doc_count, sizeof(*order), by_path);
    rj_puts(&b, "{");
    for (i = 0; i < g_doc_count; ++i) {
        if (i) rj_puts(&b, ",");
        rj_emit_string(&b, order[i]->rec.path);
        rj_puts(&b, ":");
        emit_record(&b, order[i]);
    }
    rj_puts(&b, "}");
    free(order);
    if (b.failed) {
        free(b.data);
        return NULL;
    }
    return b.data;
}

static void save_documents(void) {
    char* json = spdf_win_recents_documents_json();
    if (!json) return;
    spdf_win_state_write_json(SPDF_WIN_STATE_DOCUMENTS, json);
    free(json);
}

/* --- public ------------------------------------------------------------------ */

int spdf_win_recents_count(void) {
    load();
    return g_recent_count;
}

const char* spdf_win_recents_path(int index) {
    load();
    if (index < 0 || index >= g_recent_count) return NULL;
    return g_recent[index];
}

static doc_entry* stamp(const char* path, const char* title) {
    doc_entry* e = find_entry(path);
    if (!e) e = add_entry(path);
    if (!e) return NULL;
    if (title && *title) copy_bounded(e->rec.title, sizeof(e->rec.title), title);
    else if (!e->rec.title[0]) copy_bounded(e->rec.title, sizeof(e->rec.title), leaf(path));
    e->rec.updated_at = (long long)time(NULL);
    return e;
}

void spdf_win_recents_note_opened(const char* path, const char* title) {
    if (!path || !*path) return;
    /* THE READ-ONLY SHADOW COPY IS NOT A DOCUMENT THE READER OPENED. When the
     * source is not writable the app opens a copy under
     * %APPDATA%\ShenzhenPDF\ReadOnlyCopies instead (spdf_win_watcher.h), and
     * every by-path open funnels through here -- so without this test the MRU
     * filled up with `ro-<hex>.pdf` entries pointing at files the orphan sweep
     * deletes, and File > Open Recent offered the reader a path that would be
     * gone by the time they chose it. This header has promised the refusal
     * since it was written; it was never implemented. */
    if (spdf_win_watcher_is_shadow_path(path)) return;
    load();
    recent_push_front(path);
    if (stamp(path, title)) save_documents();
}

void spdf_win_recents_remove(const char* path) {
    if (!path || !*path) return;
    load();
    recent_erase(recent_index(path));
}

void spdf_win_recents_note_closed(const char* path) {
    if (!path || !*path) return;
    if (g_closed_count == SPDF_WIN_RECENTS_CLOSED_MAX) {
        memmove(g_closed[0], g_closed[1], (SPDF_WIN_RECENTS_CLOSED_MAX - 1) * sizeof(g_closed[0]));
        g_closed_count--;
    }
    copy_bounded(g_closed[g_closed_count++], sizeof(g_closed[0]), path);
}

int spdf_win_recents_pop_closed(char* out, size_t out_cap) {
    if (g_closed_count == 0 || !out || !out_cap) return 0;
    copy_bounded(out, out_cap, g_closed[--g_closed_count]);
    return 1;
}

int spdf_win_recents_closed_count(void) { return g_closed_count; }

int spdf_win_recents_document_lookup(const char* path, SpdfWinDocRecord* out) {
    doc_entry* e;
    if (!path || !*path || !out) return 0;
    load();
    e = find_entry(path);
    if (!e) return 0;
    *out = e->rec;
    return 1;
}

void spdf_win_recents_document_update(const char* path, const char* title, int show_sidebar, int show_minimap) {
    doc_entry* e;
    if (!path || !*path) return;
    load();
    e = stamp(path, title);
    if (!e) return;
    e->rec.has_show_sidebar = e->rec.has_show_minimap = 1;
    e->rec.show_sidebar = show_sidebar != 0;
    e->rec.show_minimap = show_minimap != 0;
    save_documents();
}

/* --- the settings merge ---------------------------------------------------- */

static void emit_recent_array(rj_buf* b) {
    int i;
    rj_puts(b, "[");
    for (i = 0; i < g_recent_count; ++i) {
        if (i) rj_puts(b, ",");
        rj_emit_string(b, g_recent[i]);
    }
    rj_puts(b, "]");
}

char* spdf_win_recents_merge_recently_opened(const char* settings_json) {
    rj_buf b;
    char key[256];
    const char *value, *end;
    const char* cursor;
    const char* p;
    int inserted = 0, any = 0;

    load();
    if (!settings_json || !*rj_skip_ws(settings_json)) settings_json = "{}";
    p = rj_skip_ws(settings_json);
    if (*p != '{') return NULL;
    memset(&b, 0, sizeof(b));
    rj_puts(&b, "{");
    cursor = p;
    while ((cursor = rj_member(cursor, key, sizeof(key), &value, &end)) != NULL) {
        if (strcmp(key, "recentlyOpened") == 0) continue; /* replaced below, in order */
        if (!inserted && strcmp(key, "recentlyOpened") > 0) {
            if (any) rj_puts(&b, ",");
            rj_puts(&b, "\"recentlyOpened\":");
            emit_recent_array(&b);
            inserted = any = 1;
        }
        if (any) rj_puts(&b, ",");
        rj_emit_string(&b, key);
        rj_puts(&b, ":");
        rj_put(&b, value, (size_t)(end - value));
        any = 1;
    }
    if (!inserted) {
        if (any) rj_puts(&b, ",");
        rj_puts(&b, "\"recentlyOpened\":");
        emit_recent_array(&b);
    }
    rj_puts(&b, "}");
    if (b.failed) {
        free(b.data);
        return NULL;
    }
    return b.data;
}
