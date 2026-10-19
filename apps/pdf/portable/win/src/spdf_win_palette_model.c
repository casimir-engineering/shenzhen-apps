/* spdf_win_palette_model.c — see spdf_win_palette_model.h. */
#include "spdf_win_palette_model.h"

#include "spdf_win_favorites.h"
#include "spdf_win_paths.h" /* spdf_win_utf8_from_utf16, pure */
#include "spdf_win_recents.h"
#include "spdf_win_tabs.h" /* SPDF_WIN_TABS_MAX: the most documents a window can hold */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct SpdfWinPaletteModel {
    const SpdfWinPaletteOpenDoc* docs;
    int doc_count;
    int selected_doc;
    SpdfWinMenuState state;
    int has_state;
    char query[512];
    SpdfWinPaletteRow* rows;
    int row_count;
    int selected;
};

static void copy_bounded(char* out, size_t cap, const char* text) {
    size_t n = text ? strlen(text) : 0;
    if (n >= cap) n = cap - 1;
    memcpy(out, text ? text : "", n);
    out[n] = '\0';
}

int spdf_win_palette_menu_text(const wchar_t* text, char* out, size_t out_cap) {
    wchar_t stripped[256];
    size_t i, n = 0;
    if (!out || !out_cap) return 0;
    out[0] = '\0';
    if (!text) return 1;
    for (i = 0; text[i] && n + 1 < sizeof(stripped) / sizeof(stripped[0]); ++i) {
        if (text[i] == L'&') {
            if (text[i + 1] == L'&') stripped[n++] = L'&', ++i;
            continue;
        }
        stripped[n++] = text[i];
    }
    stripped[n] = 0;
    return spdf_win_utf8_from_utf16((const spdf_wchar*)stripped, out, out_cap) != SPDF_WIN_CONV_ERROR;
}

SpdfWinPaletteModel* spdf_win_palette_model_create(void) {
    SpdfWinPaletteModel* m = (SpdfWinPaletteModel*)calloc(1, sizeof(*m));
    if (!m) return NULL;
    m->rows = (SpdfWinPaletteRow*)calloc(SPDF_WIN_PALETTE_MAX_ROWS, sizeof(*m->rows));
    if (!m->rows) {
        free(m);
        return NULL;
    }
    m->selected_doc = -1;
    m->selected = -1;
    return m;
}

void spdf_win_palette_model_destroy(SpdfWinPaletteModel* m) {
    if (!m) return;
    free(m->rows);
    free(m);
}

void spdf_win_palette_model_set_documents(SpdfWinPaletteModel* m, const SpdfWinPaletteOpenDoc* docs, int count,
                                          int selected) {
    if (!m) return;
    m->docs = docs;
    m->doc_count = docs ? count : 0;
    m->selected_doc = selected;
}

void spdf_win_palette_model_set_menu_state(SpdfWinPaletteModel* m, const SpdfWinMenuState* state) {
    if (!m) return;
    m->has_state = state != NULL;
    if (state) m->state = *state;
}

/* --- rows -------------------------------------------------------------------- */

static SpdfWinPaletteRow* add_row(SpdfWinPaletteModel* m, int kind, int section) {
    SpdfWinPaletteRow* r;
    if (m->row_count >= SPDF_WIN_PALETTE_MAX_ROWS) return NULL;
    r = &m->rows[m->row_count++];
    memset(r, 0, sizeof(*r));
    r->kind = kind;
    r->section = section;
    r->command = SPDF_WIN_CMD_NONE;
    r->doc = -1;
    r->page = -1;
    return r;
}

static const char* leaf(const char* path) { return spdf_win_pf_basename(path); }

/* palette_append_open_docs: every tab but the selected one, through the pure
 * filter. Fills `keys` with the canonical paths shown, for the favorites dedupe. */
static int append_open_docs(SpdfWinPaletteModel* m, const char* query, char (*keys)[SPDF_WIN_PALETTE_PATH_MAX],
                            int keys_cap) {
    SpdfWinPaletteOpenDoc candidates[SPDF_WIN_TABS_MAX];
    int origin[SPDF_WIN_TABS_MAX];
    int picks[SPDF_WIN_TABS_MAX];
    int i, n = 0, count, shown = 0;
    for (i = 0; i < m->doc_count && n < SPDF_WIN_TABS_MAX; ++i) {
        if (i == m->selected_doc || !m->docs[i].path || !m->docs[i].path[0]) continue;
        candidates[n] = m->docs[i];
        origin[n++] = i;
    }
    count = spdf_win_palette_filter_open_documents(candidates, n, query, picks, n);
    for (i = 0; i < count; ++i) {
        const SpdfWinPaletteOpenDoc* d = &candidates[picks[i]];
        SpdfWinPaletteRow* r = add_row(m, SPDF_WIN_PALETTE_ROW_OPEN_DOC, SPDF_WIN_PALETTE_SECTION_OPEN_DOCS);
        if (!r) break;
        r->doc = origin[picks[i]];
        copy_bounded(r->path, sizeof(r->path), d->path);
        copy_bounded(r->title, sizeof(r->title), d->title && d->title[0] ? d->title : leaf(d->path));
        copy_bounded(r->subtitle, sizeof(r->subtitle), d->path);
        if (shown < keys_cap && spdf_win_palette_canonical_path(d->path, keys[shown], SPDF_WIN_PALETTE_PATH_MAX))
            shown++;
    }
    return shown;
}

/* palette_append_favorites */
static void append_favorites(SpdfWinPaletteModel* m, const char* query, const char* const* open_keys, int open_count) {
    int count = spdf_win_favorites_count();
    int reveal_all = spdf_win_palette_query_reveals_all_favorites(query);
    SpdfWinPaletteMatch* matches;
    int match_count = 0, i;
    if (reveal_all) query = NULL;
    if (count == 0) return;
    matches = (SpdfWinPaletteMatch*)calloc((size_t)count, sizeof(*matches));
    if (!matches) return;
    for (i = 0; i < count; ++i) {
        const SpdfWinFavorite* f = spdf_win_favorites_at(i);
        int score = 0;
        if (!f) continue;
        if (!reveal_all && spdf_win_palette_favorite_shadowed_by_open_doc(f->type, f->path, open_keys, open_count))
            continue;
        if (query && *query) {
            /* The same haystack the mac matches: name, title, path, labels. */
            char haystack[SPDF_WIN_FAVORITE_PATH_MAX + 3 * SPDF_WIN_FAVORITE_TEXT_MAX + SPDF_WIN_FAVORITE_LABELS_MAX];
            snprintf(haystack, sizeof(haystack), "%s %s %s %s", f->name, f->title, f->path,
                     strcmp(f->labels, "[]") == 0 ? "" : f->labels);
            score = spdf_win_palette_fuzzy_score(query, haystack);
            if (score < 0) continue;
        }
        matches[match_count].index = i;
        matches[match_count].score = score;
        match_count++;
    }
    if (query && *query) qsort(matches, (size_t)match_count, sizeof(*matches), spdf_win_pf_match_compare);
    if (match_count > SPDF_WIN_PALETTE_MAX_FAVORITE_ROWS) match_count = SPDF_WIN_PALETTE_MAX_FAVORITE_ROWS;
    for (i = 0; i < match_count; ++i) {
        const SpdfWinFavorite* f = spdf_win_favorites_at(matches[i].index);
        int is_document = strcmp(f->type, "document") == 0;
        SpdfWinPaletteRow* r = add_row(m, SPDF_WIN_PALETTE_ROW_FAVORITE, SPDF_WIN_PALETTE_SECTION_FAVORITES);
        if (!r) break;
        copy_bounded(r->path, sizeof(r->path), f->path);
        copy_bounded(r->title, sizeof(r->title), f->name[0] ? f->name : f->title[0] ? f->title : "Favorite");
        if (is_document) copy_bounded(r->subtitle, sizeof(r->subtitle), f->path);
        else snprintf(r->subtitle, sizeof(r->subtitle), "p.%d \xC2\xB7 %s", f->page + 1, f->path);
        r->page = is_document ? -1 : f->page;
    }
    free(matches);
}

/* palette_append_commands, over the menu table. */
static void append_commands(SpdfWinPaletteModel* m, const char* query) {
    int n = 0, i, count, match_count;
    const SpdfWinMenuItem* table = spdf_win_menu_table(&count);
    SpdfWinPaletteCommand* commands = (SpdfWinPaletteCommand*)calloc((size_t)count, sizeof(*commands));
    SpdfWinPaletteMatch* matches = (SpdfWinPaletteMatch*)calloc((size_t)count, sizeof(*matches));
    char (*titles)[256] = (char (*)[256])calloc((size_t)count, 256);
    char (*crumbs)[320] = (char (*)[320])calloc((size_t)count, 320);
    char (*accels)[32] = (char (*)[32])calloc((size_t)count, 32);
    if (!commands || !matches || !titles || !crumbs || !accels) goto done;
    for (i = 0; i < count; ++i) {
        const SpdfWinMenuItem* it = &table[i];
        char menu[64];
        if (it->command == SPDF_WIN_CMD_NONE || it->menu == SPDF_WIN_MENU_NONE) continue;
        /* The palette is itself the favorites search; a row that reopens it
         * would be a no-op loop (mac parity). Open Recent is a submenu anchor,
         * not a command. */
        if (it->command == SPDF_WIN_CMD_PALETTE || it->command == SPDF_WIN_CMD_OPEN_RECENT) continue;
        spdf_win_palette_menu_text(it->title, titles[n], 256);
        spdf_win_palette_menu_text(spdf_win_menu_title(it->menu), menu, sizeof(menu));
        spdf_win_palette_menu_breadcrumb(menu, titles[n], crumbs[n], 320);
        if (it->accel) spdf_win_utf8_from_utf16((const spdf_wchar*)it->accel, accels[n], 32);
        commands[n].command = it->command;
        commands[n].title = titles[n];
        commands[n].accel = it->accel ? accels[n] : NULL;
        commands[n].breadcrumb = crumbs[n];
        commands[n].enabled = m->has_state ? spdf_win_menu_command_enabled(it->command, &m->state) : 1;
        commands[n].toggled = it->checkable && m->has_state && spdf_win_menu_command_checked(it->command, &m->state);
        n++;
    }
    match_count = spdf_win_palette_filter_commands(commands, n, query, matches, n);
    for (i = 0; i < match_count; ++i) {
        const SpdfWinPaletteCommand* c = &commands[matches[i].index];
        SpdfWinPaletteRow* r = add_row(m, SPDF_WIN_PALETTE_ROW_COMMAND, SPDF_WIN_PALETTE_SECTION_COMMANDS);
        if (!r) break;
        r->command = c->command;
        r->toggled = c->toggled;
        copy_bounded(r->title, sizeof(r->title), c->title);
        copy_bounded(r->subtitle, sizeof(r->subtitle), c->breadcrumb);
        copy_bounded(r->accel, sizeof(r->accel), c->accel ? c->accel : "");
    }
done:
    free(accels);
    free(crumbs);
    free(titles);
    free(matches);
    free(commands);
}

/* palette_append_recents: MRU order kept, fuzzy-filtered on the path. */
static void append_recents(SpdfWinPaletteModel* m, const char* query) {
    int count = spdf_win_recents_count(), i;
    for (i = 0; i < count; ++i) {
        const char* path = spdf_win_recents_path(i);
        SpdfWinPaletteRow* r;
        if (!path || !*path) continue;
        if (query && *query && spdf_win_palette_fuzzy_score(query, path) < 0) continue;
        r = add_row(m, SPDF_WIN_PALETTE_ROW_RECENT, SPDF_WIN_PALETTE_SECTION_RECENTS);
        if (!r) break;
        copy_bounded(r->path, sizeof(r->path), path);
        copy_bounded(r->title, sizeof(r->title), leaf(path));
        copy_bounded(r->subtitle, sizeof(r->subtitle), path);
    }
}

static int selectable(const SpdfWinPaletteModel* m, int index) {
    return index >= 0 && index < m->row_count && m->rows[index].kind != SPDF_WIN_PALETTE_ROW_STATUS;
}

static void select_first(SpdfWinPaletteModel* m) {
    int i;
    m->selected = -1;
    for (i = 0; i < m->row_count; ++i)
        if (selectable(m, i)) {
            m->selected = i;
            return;
        }
}

void spdf_win_palette_model_set_query(SpdfWinPaletteModel* m, const char* utf8_query) {
    const char* query;
    int commands_only = 0;
    char keys[SPDF_WIN_TABS_MAX][SPDF_WIN_PALETTE_PATH_MAX];
    const char* key_ptrs[SPDF_WIN_TABS_MAX];
    int shown, i;
    if (!m) return;
    copy_bounded(m->query, sizeof(m->query), utf8_query ? utf8_query : "");
    m->row_count = 0;
    query = m->query;
    if (*query == '>') {
        commands_only = 1;
        query++;
        while (*query == ' ') query++;
    }
    if (!commands_only) {
        shown = append_open_docs(m, query, keys, SPDF_WIN_TABS_MAX);
        for (i = 0; i < shown; ++i) key_ptrs[i] = keys[i];
        append_favorites(m, query, key_ptrs, shown);
    }
    append_commands(m, query);
    if (!commands_only) append_recents(m, query);
    if (m->row_count == 0) {
        SpdfWinPaletteRow* r = add_row(m, SPDF_WIN_PALETTE_ROW_STATUS, SPDF_WIN_PALETTE_SECTION_COMMANDS);
        if (r) copy_bounded(r->title, sizeof(r->title), "No results");
    }
    select_first(m);
}

int spdf_win_palette_model_row_count(const SpdfWinPaletteModel* m) { return m ? m->row_count : 0; }

const SpdfWinPaletteRow* spdf_win_palette_model_row(const SpdfWinPaletteModel* m, int index) {
    if (!m || index < 0 || index >= m->row_count) return NULL;
    return &m->rows[index];
}

int spdf_win_palette_model_section_starts(const SpdfWinPaletteModel* m, int index) {
    if (!m || index < 0 || index >= m->row_count) return 0;
    if (m->rows[index].kind == SPDF_WIN_PALETTE_ROW_STATUS) return 0;
    return index == 0 || m->rows[index - 1].section != m->rows[index].section;
}

const char* spdf_win_palette_section_title(int section) {
    switch (section) {
        case SPDF_WIN_PALETTE_SECTION_OPEN_DOCS: return "Open Documents";
        case SPDF_WIN_PALETTE_SECTION_FAVORITES: return "Favorites";
        case SPDF_WIN_PALETTE_SECTION_COMMANDS: return "Commands";
        case SPDF_WIN_PALETTE_SECTION_RECENTS: return "Recently Opened";
        default: return "";
    }
}

int spdf_win_palette_model_selected(const SpdfWinPaletteModel* m) { return m ? m->selected : -1; }

void spdf_win_palette_model_move(SpdfWinPaletteModel* m, int delta) {
    int i;
    if (!m || delta == 0) return;
    i = m->selected < 0 ? (delta > 0 ? -1 : m->row_count) : m->selected;
    for (i += delta > 0 ? 1 : -1; i >= 0 && i < m->row_count; i += delta > 0 ? 1 : -1)
        if (selectable(m, i)) {
            m->selected = i;
            return;
        }
}

void spdf_win_palette_model_select(SpdfWinPaletteModel* m, int index) {
    if (m && selectable(m, index)) m->selected = index;
}
