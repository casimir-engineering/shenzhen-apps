/* spdf_win_tabs.cpp — see spdf_win_tabs.h for the contract and for where each
 * rule below was taken from in the macOS app.
 *
 * Written as flat C over fixed-size arrays even though the file is .cpp: the
 * ceiling is SPDF_WIN_TABS_MAX (64, the shared session cap), so 64 pointers is
 * the whole storage problem, and keeping the implementation allocation-light
 * means the close policy has nowhere to fail for reasons that are not about
 * the policy.
 */
#include "spdf_win_tabs.h"

#include <stdlib.h>
#include <string.h>

struct spdf_win_tab {
    char* path;
    char* title;
    spdf_win_tab_view view;
    void* document; /* NULL until somebody looks at this tab */
};

struct spdf_win_tabs {
    spdf_win_tab* items[SPDF_WIN_TABS_MAX];
    int count;
    int selected; /* -1 when empty */
    /* Activation history, most recent first, holding the same pointers as
     * `items`. Identity is the key; see the header. */
    spdf_win_tab* history[SPDF_WIN_TABS_MAX];
    int history_count;
    spdf_win_tab_open_fn open_fn;
    spdf_win_tab_close_fn close_fn;
    void* user;
    unsigned long long materialize_count;
};

/* --- small helpers -------------------------------------------------------- */

static char* dup_string(const char* text) {
    size_t len;
    char* out;
    if (!text) return NULL;
    len = strlen(text);
    out = (char*)malloc(len + 1);
    if (!out) return NULL;
    memcpy(out, text, len + 1);
    return out;
}

/* Splits on BOTH separators: a session file written on another platform can
 * carry '/' paths, and a Windows path carries '\'. */
static const char* last_component(const char* path) {
    const char* name = path;
    const char* p;
    for (p = path; *p; ++p)
        if (*p == '\\' || *p == '/') name = p + 1;
    return name;
}

static void set_error(char* err, size_t err_len, const char* text) {
    if (!err || err_len == 0) return;
    size_t len = strlen(text);
    if (len >= err_len) len = err_len - 1;
    memcpy(err, text, len);
    err[len] = '\0';
}

void spdf_win_tab_view_init(spdf_win_tab_view* view) {
    if (!view) return;
    memset(view, 0, sizeof(*view));
    view->zoom = 1.0;
    view->custom_zoom = 1.0;
    view->fit_mode = SPDF_WIN_TAB_FIT_PAGE;
    view->preserves_image_colors = 1; /* the mac's default (SPDFMacModels.mm: _preservesImageColors = YES) */
}

static int valid_index(const spdf_win_tabs* tabs, int index) {
    return tabs && index >= 0 && index < tabs->count;
}

/* --- activation history --------------------------------------------------- */

static int history_index_of(const spdf_win_tabs* tabs, const spdf_win_tab* tab) {
    int i;
    for (i = 0; i < tabs->history_count; ++i)
        if (tabs->history[i] == tab) return i;
    return -1;
}

static void history_remove_at(spdf_win_tabs* tabs, int index) {
    int i;
    for (i = index; i + 1 < tabs->history_count; ++i) tabs->history[i] = tabs->history[i + 1];
    tabs->history_count--;
}

static void record_activation(spdf_win_tabs* tabs, spdf_win_tab* tab) {
    int existing, i;
    if (!tab) return;
    existing = history_index_of(tabs, tab);
    if (existing >= 0) history_remove_at(tabs, existing);
    if (tabs->history_count >= SPDF_WIN_TABS_MAX) tabs->history_count = SPDF_WIN_TABS_MAX - 1;
    for (i = tabs->history_count; i > 0; --i) tabs->history[i] = tabs->history[i - 1];
    tabs->history[0] = tab;
    tabs->history_count++;
}

static int is_live_tab(const spdf_win_tabs* tabs, const spdf_win_tab* tab) {
    int i;
    for (i = 0; i < tabs->count; ++i)
        if (tabs->items[i] == tab) return 1;
    return 0;
}

/* Drops `going` and anything that is no longer a live tab, the same sweep
 * -removeIdentifier:fromOrderedIdentifiers: performs before it picks a
 * replacement. Without it a stale entry would be handed back as the MRU
 * survivor. */
static void history_purge(spdf_win_tabs* tabs, const spdf_win_tab* going) {
    int i;
    for (i = tabs->history_count - 1; i >= 0; --i) {
        const spdf_win_tab* candidate = tabs->history[i];
        if (candidate == going || !is_live_tab(tabs, candidate)) history_remove_at(tabs, i);
    }
}

/* --- lifetime ------------------------------------------------------------- */

spdf_win_tabs* spdf_win_tabs_create(void) {
    spdf_win_tabs* tabs = (spdf_win_tabs*)calloc(1, sizeof(*tabs));
    if (!tabs) return NULL;
    tabs->selected = -1;
    return tabs;
}

static void free_tab(spdf_win_tabs* tabs, spdf_win_tab* tab) {
    if (!tab) return;
    if (tab->document && tabs->close_fn) tabs->close_fn(tabs->user, tab->document);
    free(tab->path);
    free(tab->title);
    free(tab);
}

void spdf_win_tabs_destroy(spdf_win_tabs* tabs) {
    int i;
    if (!tabs) return;
    for (i = 0; i < tabs->count; ++i) free_tab(tabs, tabs->items[i]);
    free(tabs);
}

void spdf_win_tabs_set_document_hooks(spdf_win_tabs* tabs, spdf_win_tab_open_fn open_fn, spdf_win_tab_close_fn close_fn,
                                      void* user) {
    if (!tabs) return;
    tabs->open_fn = open_fn;
    tabs->close_fn = close_fn;
    tabs->user = user;
}

int spdf_win_tabs_count(const spdf_win_tabs* tabs) { return tabs ? tabs->count : 0; }

int spdf_win_tabs_selected_index(const spdf_win_tabs* tabs) { return tabs ? tabs->selected : -1; }

unsigned long long spdf_win_tabs_materialize_count(const spdf_win_tabs* tabs) {
    return tabs ? tabs->materialize_count : 0;
}

/* --- adding --------------------------------------------------------------- */

int spdf_win_tabs_insert(spdf_win_tabs* tabs, int index, const char* path, const char* title) {
    spdf_win_tab* tab;
    int i;

    if (!tabs || !path || !*path) return -1;
    if (tabs->count >= SPDF_WIN_TABS_MAX) return -1;
    if (index < 0) index = 0;
    if (index > tabs->count) index = tabs->count;

    tab = (spdf_win_tab*)calloc(1, sizeof(*tab));
    if (!tab) return -1;
    tab->path = dup_string(path);
    tab->title = dup_string(title && *title ? title : last_component(path));
    if (!tab->path || !tab->title) {
        free(tab->path);
        free(tab->title);
        free(tab);
        return -1;
    }
    spdf_win_tab_view_init(&tab->view);

    for (i = tabs->count; i > index; --i) tabs->items[i] = tabs->items[i - 1];
    tabs->items[index] = tab;
    tabs->count++;
    /* Inserting to the left of the selection moves it along; the SELECTED TAB
     * does not change, only where it sits. */
    if (tabs->selected >= index) tabs->selected++;
    return index;
}

int spdf_win_tabs_append(spdf_win_tabs* tabs, const char* path, const char* title) {
    return spdf_win_tabs_insert(tabs, tabs ? tabs->count : 0, path, title);
}

int spdf_win_tabs_index_of_path(const spdf_win_tabs* tabs, const char* path) {
    int i;
    if (!tabs || !path) return -1;
    for (i = 0; i < tabs->count; ++i)
        if (strcmp(tabs->items[i]->path, path) == 0) return i;
    return -1;
}

/* --- accessors ------------------------------------------------------------ */

const char* spdf_win_tabs_path(const spdf_win_tabs* tabs, int index) {
    return valid_index(tabs, index) ? tabs->items[index]->path : NULL;
}

const char* spdf_win_tabs_title(const spdf_win_tabs* tabs, int index) {
    return valid_index(tabs, index) ? tabs->items[index]->title : NULL;
}

int spdf_win_tabs_set_title(spdf_win_tabs* tabs, int index, const char* title) {
    char* copy;
    if (!valid_index(tabs, index)) return 0;
    copy = dup_string(title && *title ? title : last_component(tabs->items[index]->path));
    if (!copy) return 0;
    free(tabs->items[index]->title);
    tabs->items[index]->title = copy;
    return 1;
}

spdf_win_tab_view* spdf_win_tabs_view(spdf_win_tabs* tabs, int index) {
    return valid_index(tabs, index) ? &tabs->items[index]->view : NULL;
}

const spdf_win_tab_view* spdf_win_tabs_view_const(const spdf_win_tabs* tabs, int index) {
    return valid_index(tabs, index) ? &tabs->items[index]->view : NULL;
}

/* --- materialisation ------------------------------------------------------ */

void* spdf_win_tabs_document(spdf_win_tabs* tabs, int index, char* err, size_t err_len) {
    spdf_win_tab* tab;
    if (!valid_index(tabs, index)) {
        set_error(err, err_len, "no such tab");
        return NULL;
    }
    tab = tabs->items[index];
    if (tab->document) return tab->document;
    if (!tabs->open_fn) {
        set_error(err, err_len, "no document hook is installed");
        return NULL;
    }
    /* Counted before the call, not after: a hook that fails still cost the
     * user the open attempt, and a test asserting "nothing was opened" must
     * see an attempt that failed just as loudly as one that succeeded. */
    tabs->materialize_count++;
    tab->document = tabs->open_fn(tabs->user, tab->path, err, err_len);
    return tab->document;
}

int spdf_win_tabs_is_materialized(const spdf_win_tabs* tabs, int index) {
    return valid_index(tabs, index) && tabs->items[index]->document != NULL;
}

void spdf_win_tabs_release_document(spdf_win_tabs* tabs, int index) {
    spdf_win_tab* tab;
    if (!valid_index(tabs, index)) return;
    tab = tabs->items[index];
    if (!tab->document) return;
    if (tabs->close_fn) tabs->close_fn(tabs->user, tab->document);
    tab->document = NULL;
}

/* --- selection ------------------------------------------------------------ */

int spdf_win_tabs_select_deferred(spdf_win_tabs* tabs, int index) {
    int changed;
    if (!valid_index(tabs, index)) return 0;
    changed = index != tabs->selected;
    tabs->selected = index;
    record_activation(tabs, tabs->items[index]);
    return changed;
}

int spdf_win_tabs_select(spdf_win_tabs* tabs, int index) {
    int changed = spdf_win_tabs_select_deferred(tabs, index);
    if (valid_index(tabs, index)) spdf_win_tabs_document(tabs, index, NULL, 0);
    return changed;
}

int spdf_win_tabs_select_relative(spdf_win_tabs* tabs, int delta) {
    int base, target;
    if (!tabs || tabs->count == 0) return 0;
    base = tabs->selected >= 0 ? tabs->selected : 0;
    target = (base + delta) % tabs->count;
    if (target < 0) target += tabs->count;
    return spdf_win_tabs_select(tabs, target);
}

int spdf_win_tabs_move(spdf_win_tabs* tabs, int from, int to) {
    spdf_win_tab* moving;
    spdf_win_tab* selected_tab;
    int i;

    if (!valid_index(tabs, from)) return 0;
    if (to < 0) to = 0;
    if (to >= tabs->count) to = tabs->count - 1;
    if (from == to) return 0;

    selected_tab = tabs->selected >= 0 ? tabs->items[tabs->selected] : NULL;
    moving = tabs->items[from];
    for (i = from; i + 1 < tabs->count; ++i) tabs->items[i] = tabs->items[i + 1];
    for (i = tabs->count - 1; i > to; --i) tabs->items[i] = tabs->items[i - 1];
    tabs->items[to] = moving;

    /* The selection follows the tab. Re-deriving it from the pointer rather
     * than patching indices is what makes reordering safe next to a history
     * that is keyed on identity. */
    if (selected_tab) {
        for (i = 0; i < tabs->count; ++i)
            if (tabs->items[i] == selected_tab) {
                tabs->selected = i;
                break;
            }
    }
    return 1;
}

/* --- closing -------------------------------------------------------------- */

int spdf_win_tabs_close(spdf_win_tabs* tabs, int index, int prefer_most_recent_active) {
    spdf_win_tab* going;
    spdf_win_tab* replacement = NULL;
    int removing_selected, adjacent, i;

    if (!valid_index(tabs, index)) return tabs ? tabs->selected : -1;
    going = tabs->items[index];
    removing_selected = index == tabs->selected;

    for (i = index; i + 1 < tabs->count; ++i) tabs->items[i] = tabs->items[i + 1];
    tabs->count--;
    history_purge(tabs, going);

    if (!removing_selected) {
        /* ShenzhenPDFMac.mm:9140 — same tab stays selected, its index shifts. */
        if (index < tabs->selected) tabs->selected--;
        free_tab(tabs, going);
        return tabs->selected;
    }

    tabs->selected = -1;
    if (prefer_most_recent_active && tabs->history_count > 0) replacement = tabs->history[0];
    if (!replacement && tabs->count > 0) {
        /* The pre-removal neighbour to the right, else the one to the left. */
        adjacent = index < tabs->count ? index : tabs->count - 1;
        replacement = tabs->items[adjacent];
    }
    if (replacement) {
        for (i = 0; i < tabs->count; ++i)
            if (tabs->items[i] == replacement) {
                tabs->selected = i;
                break;
            }
        record_activation(tabs, replacement);
    }
    free_tab(tabs, going);
    return tabs->selected;
}

int spdf_win_tabs_close_enabled(int tab_count, int selected_index, int has_open_document) {
    return has_open_document || (selected_index >= 0 && selected_index < tab_count);
}
