// spdf_palette.c — Ctrl+K command palette + favorites actions.
//
// The palette is an AdwDialog (GNOME-native, closes on Escape, dims the
// parent) holding a GtkSearchEntry over a GtkListBox with per-section headers
// via gtk_list_box_set_header_func. GtkListBox over GtkListView is a
// deliberate choice: the result set is small (a few hundred rows at most,
// rebuilt wholesale per keystroke), section headers and mixed row kinds are
// native to GtkListBox, and it is the pattern libadwaita itself styles
// (.navigation-sidebar) — GtkListView's factory + GtkSectionModel machinery
// buys virtualization this list does not need.
//
// Sections (hidden when empty, Mac refreshPaletteResults order):
//   Open documents — every open tab in every window except the palette
//                window's active one; substring-matched by title/file name,
//                deduped by canonical path; Enter focuses the live tab.
//   Favorites  — favorites.json via spdf_state; icon distinguishes page vs
//                document favorites; Enter opens the doc and jumps. Document
//                favorites already shown in Open documents are hidden; the
//                "fav"/"favo"/… keyword reveals all of them unfiltered.
//   Commands   — every entry of the spdf_shortcuts.c table (minus the palette
//                itself and target-taking actions), fuzzy-filtered by label
//                and menu breadcrumb (shown as the subtitle), accel
//                right-aligned, "✓" prefix on toggled-on stateful actions;
//                disabled actions are skipped (Mac behavior: invalid menu
//                commands are hidden, 30be87712).
//   Recents    — settings.json "recentlyOpened"; Enter opens.
//   Text in open documents — every open tab's document searched on a worker
//                thread (fresh spdf_open per doc, like the Mac palette), page
//                cap SPDF_PALETTE_MAX_SEARCH_PAGES across all docs, results
//                appended from an idle, cancelled by generation when the
//                query changes or the palette closes.
//
// The pure filter/snippet helpers at the top compile with glib only
// (SPDF_PALETTE_TESTING) for tests/palette_filter_test.c.

#include <stdlib.h>
#include <string.h>

#include "spdf_palette.h"
#include "spdf_password.h"

// ---------------------------------------------------------------------------
// Pure logic (glib only — unit-tested standalone).

static gboolean palette_ascii_word_boundary(const char* haystack, int index) {
    return index == 0 || !g_ascii_isalnum((guchar)haystack[index - 1]);
}

int spdf_palette_fuzzy_score(const char* query, const char* haystack) {
    const char* q;
    int score = 0;
    int gap = 0;
    int lead = 0;
    int index = 0;
    int last_match = -2; // never adjacent to a real index

    if (!query || !*query) return 0; // empty query matches everything, neutrally
    if (!haystack || !*haystack) return -1;
    q = query;
    for (const char* h = haystack; *h && *q; ++h, ++index) {
        if (g_ascii_tolower((guchar)*h) == g_ascii_tolower((guchar)*q)) {
            score += 1;
            if (palette_ascii_word_boundary(haystack, index)) score += 3;
            if (index == last_match + 1) score += 2;
            last_match = index;
            ++q;
        } else if (last_match >= 0) {
            ++gap;
        } else {
            ++lead;
        }
    }
    if (*q) return -1; // not a subsequence
    score -= MIN(gap, 8);
    score -= MIN(lead, 3);
    return MAX(score, 0);
}

static int palette_match_compare(const void* a, const void* b) {
    const SpdfPaletteMatch* match_a = a;
    const SpdfPaletteMatch* match_b = b;

    if (match_a->score != match_b->score) return match_b->score - match_a->score;
    return match_a->index - match_b->index; // stable: keep table order on ties
}

int spdf_palette_filter_commands(const SpdfPaletteCommand* commands, int count, const char* query,
                                 SpdfPaletteMatch* out, int out_max) {
    gboolean filtered = query && *query;
    int n = 0;

    if (!commands || !out || out_max <= 0) return 0;
    for (int i = 0; i < count && n < out_max; ++i) {
        int score = 0;

        if (!commands[i].enabled || !commands[i].title || !*commands[i].title) continue;
        if (filtered) {
            // Title or breadcrumb, whichever matches better — the Mac palette
            // matches menu commands against the title OR the menu breadcrumb
            // (SPDFMacPaletteResults.mm spdf_palette_menu_command_matches_query
            // @103-108), so searching by menu name finds the commands in it.
            int crumb_score = spdf_palette_fuzzy_score(query, commands[i].breadcrumb);
            score = spdf_palette_fuzzy_score(query, commands[i].title);
            score = MAX(score, crumb_score);
            if (score < 0) continue;
        }
        out[n].index = i;
        out[n].score = score;
        n++;
    }
    if (filtered) qsort(out, (size_t)n, sizeof *out, palette_match_compare);
    return n;
}

static const char* palette_ascii_ci_strstr(const char* haystack, const char* needle) {
    size_t needle_len = strlen(needle);

    if (needle_len == 0) return haystack;
    for (const char* h = haystack; *h; ++h) {
        size_t i = 0;
        while (i < needle_len && h[i] && g_ascii_tolower((guchar)h[i]) == g_ascii_tolower((guchar)needle[i])) ++i;
        if (i == needle_len) return h;
    }
    return NULL;
}

char* spdf_palette_menu_breadcrumb(const char* group, const char* title) {
    // SPDFMacPaletteResults.mm spdf_palette_menu_breadcrumb (@94-101): join
    // the non-empty components with " ▸ ". The GTK4 shortcuts table has one
    // menu level (the group), so the path is at most "group ▸ title".
    gboolean has_group = group && *group;
    gboolean has_title = title && *title;

    if (has_group && has_title) return g_strdup_printf("%s \xE2\x96\xB8 %s", group, title);
    if (has_group) return g_strdup(group);
    if (has_title) return g_strdup(title);
    return NULL;
}

gboolean spdf_palette_open_document_matches_query(const char* query, const char* title, const char* path) {
    // SPDFMacPaletteResults.mm spdf_palette_open_document_matches_query
    // (@10-16): empty query matches; otherwise substring of the title or of
    // the file name (never the directory). ASCII case folding stands in for
    // the Mac's case+diacritic-insensitive compare, like the rest of the
    // palette's matching.
    const char* base;

    if (!query || !*query) return TRUE;
    if (title && *title && palette_ascii_ci_strstr(title, query)) return TRUE;
    if (!path || !*path) return FALSE;
    base = strrchr(path, '/');
    base = base ? base + 1 : path;
    return *base && palette_ascii_ci_strstr(base, query) != NULL;
}

// The dedup key: same canonical form for tab paths and favorite paths (the
// Mac's stringByStandardizingPath, SPDFMacPaletteResults.mm @5-8).
static char* palette_canonical_path(const char* path) {
    return g_canonicalize_filename(path, "/");
}

int spdf_palette_filter_open_documents(const SpdfPaletteOpenDoc* docs, int count, const char* query, int* out,
                                       int out_max) {
    // SPDFMacPaletteResults.mm spdf_palette_open_document_results (@18-32):
    // keep candidate order, skip blank paths, list each document once (the
    // canonical path of a shown row blocks later duplicates), filter by the
    // query. A duplicate is only recorded as seen when it matched, exactly
    // like the Mac's seenPaths bookkeeping.
    GHashTable* seen;
    int n = 0;

    if (!docs || !out || out_max <= 0) return 0;
    seen = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    for (int i = 0; i < count && n < out_max; ++i) {
        char* key;

        if (!docs[i].path || !*docs[i].path) continue;
        key = palette_canonical_path(docs[i].path);
        if (g_hash_table_contains(seen, key) ||
            !spdf_palette_open_document_matches_query(query, docs[i].title, docs[i].path)) {
            g_free(key);
            continue;
        }
        g_hash_table_add(seen, key); // hash owns the key
        out[n++] = i;
    }
    g_hash_table_unref(seen);
    return n;
}

gboolean spdf_palette_query_reveals_all_favorites(const char* query) {
    // SPDFMacPaletteResults.mm spdf_palette_query_reveals_all_favorites
    // (@122-128): the trimmed query must be an anchored, case-insensitive
    // prefix of "favorites" at least 3 characters long.
    const char* keyword = "favorites";
    char* trimmed;
    size_t len;
    gboolean reveals;

    if (!query) return FALSE;
    trimmed = g_strstrip(g_strdup(query));
    len = strlen(trimmed);
    reveals = len >= 3 && len <= strlen(keyword) && g_ascii_strncasecmp(trimmed, keyword, len) == 0;
    g_free(trimmed);
    return reveals;
}

gboolean spdf_palette_favorite_shadowed_by_open_doc(const char* favorite_type, const char* favorite_path,
                                                    GHashTable* open_paths) {
    // SPDFMacPaletteResults.mm spdf_palette_favorites_without_open_documents
    // (@130-145): only document-level favorites dedupe against the open
    // section (a page favorite is a distinct jump target and stays listed).
    char* key;
    gboolean shadowed;

    if (!open_paths || g_hash_table_size(open_paths) == 0) return FALSE;
    if (g_strcmp0(favorite_type, "document") != 0) return FALSE;
    if (!favorite_path || !*favorite_path) return FALSE;
    key = palette_canonical_path(favorite_path);
    shadowed = g_hash_table_contains(open_paths, key);
    g_free(key);
    return shadowed;
}

#define SPDF_PALETTE_SNIPPET_CONTEXT_BYTES 24

char* spdf_palette_snippet_from_line(const char* line, const char* query) {
    const char* hit;
    size_t start;
    size_t end;
    size_t len;
    GString* out;

    if (!line || !*line || !query || !*query) return NULL;
    hit = palette_ascii_ci_strstr(line, query);
    if (!hit) return NULL;
    len = strlen(line);
    start = (size_t)(hit - line);
    end = MIN(len, start + strlen(query) + SPDF_PALETTE_SNIPPET_CONTEXT_BYTES);
    start = start > SPDF_PALETTE_SNIPPET_CONTEXT_BYTES ? start - SPDF_PALETTE_SNIPPET_CONTEXT_BYTES : 0;
    // Never cut a UTF-8 sequence in half.
    while (start > 0 && ((guchar)line[start] & 0xC0) == 0x80) start--;
    while (end < len && ((guchar)line[end] & 0xC0) == 0x80) end++;
    while (start < end && g_ascii_isspace((guchar)line[start])) start++;
    while (end > start && g_ascii_isspace((guchar)line[end - 1])) end--;
    if (end <= start) return NULL;
    out = g_string_new(start > 0 ? "\xE2\x80\xA6" : "");
    g_string_append_len(out, line + start, (gssize)(end - start));
    if (end < len) g_string_append(out, "\xE2\x80\xA6");
    return g_string_free(out, FALSE);
}

#ifndef SPDF_PALETTE_TESTING

#include "spdf_palette_open.h"
// ===========================================================================
// GTK implementation.

// SpdfPaletteSection (display order) lives in spdf_palette.h with the rest of
// the pure ordering semantics.

typedef enum {
    SPDF_PALETTE_ROW_COMMAND = 0,
    SPDF_PALETTE_ROW_OPEN_DOC,
    SPDF_PALETTE_ROW_FAVORITE,
    SPDF_PALETTE_ROW_RECENT,
    SPDF_PALETTE_ROW_MATCH,
    SPDF_PALETTE_ROW_STATUS, // not selectable/activatable
} SpdfPaletteRowKind;

typedef struct {
    int kind;     // SpdfPaletteRowKind
    int section;  // SpdfPaletteSection, drives the header func
    char* action; // command rows: detailed action name
    char* path;   // favorite/recent/match rows
    char* query;  // match rows: query to stash as the tab's search text
    int page;     // 0-based target page; -1 = just open/select
} SpdfPaletteRowData;

// Shared cancellation token between the palette and one in-flight search
// worker; the query generation is the token's identity (a new query mints a
// new token and cancels the old one).
typedef struct {
    gint refs;
    gint cancelled;
} SpdfPaletteCancel;

typedef struct {
    SpdfWindow* win; // borrowed; the dialog is presented on it and dies with it
    AdwDialog* dialog;
    GtkSearchEntry* entry;
    GtkListBox* list;
    GtkScrolledWindow* scroll;
    SpdfPaletteCancel* cancel; // current search generation, NULL when idle
    GtkListBoxRow* status_row; // "Searching…" placeholder, owned by list
} SpdfPalette;

typedef struct {
    SpdfPasswordSource source;
    char* title;
} SpdfPaletteSearchDoc;

typedef struct {
    char* path;
    char* title;
    char* snippet; // may be NULL
    int page;
    int hits;
} SpdfPaletteSearchResult;

typedef struct {
    SpdfPaletteCancel* cancel; // owned ref
    AdwDialog* dialog;         // owned ref; palette recovered via object data
    char* query;
    GPtrArray* docs;    // SpdfPaletteSearchDoc*, snapshot taken on the main thread
    GPtrArray* results; // SpdfPaletteSearchResult*, filled by the worker
} SpdfPaletteSearchJob;

// ---------------------------------------------------------------------------
// Small helpers

static SpdfPaletteCancel* palette_cancel_new(void) {
    SpdfPaletteCancel* cancel = g_new0(SpdfPaletteCancel, 1);
    cancel->refs = 1;
    return cancel;
}

static SpdfPaletteCancel* palette_cancel_ref(SpdfPaletteCancel* cancel) {
    g_atomic_int_inc(&cancel->refs);
    return cancel;
}

static void palette_cancel_unref(SpdfPaletteCancel* cancel) {
    if (cancel && g_atomic_int_dec_and_test(&cancel->refs)) g_free(cancel);
}

static void palette_row_data_free(SpdfPaletteRowData* data) {
    if (!data) return;
    g_free(data->action);
    g_free(data->path);
    g_free(data->query);
    g_free(data);
}

static SpdfPaletteRowData* palette_row_data(GtkListBoxRow* row) {
    return row ? g_object_get_data(G_OBJECT(row), "spdf-palette-row") : NULL;
}

static void palette_search_doc_free(gpointer item) {
    SpdfPaletteSearchDoc* doc = item;
    spdf_password_source_clear(&doc->source);
    g_free(doc->title);
    g_free(doc);
}

static void palette_search_result_free(gpointer item) {
    SpdfPaletteSearchResult* result = item;
    g_free(result->path);
    g_free(result->title);
    g_free(result->snippet);
    g_free(result);
}

static void palette_search_job_free(SpdfPaletteSearchJob* job) {
    palette_cancel_unref(job->cancel);
    g_clear_object(&job->dialog);
    g_free(job->query);
    if (job->docs) g_ptr_array_unref(job->docs);
    if (job->results) g_ptr_array_unref(job->results);
    g_free(job);
}

static SpdfApp* palette_window_app(SpdfWindow* win) {
    GtkApplication* app = gtk_window_get_application(GTK_WINDOW(win));
    return app && SPDF_IS_APP(app) ? SPDF_APP(app) : NULL;
}

static void palette_install_css(void) {
    static gboolean installed = FALSE;
    GtkCssProvider* provider;

    if (installed) return;
    installed = TRUE;
    provider = gtk_css_provider_new();
    // Everything else uses stock libadwaita classes (dim-label, caption,
    // heading, numeric, navigation-sidebar); only the row/header breathing
    // room is ours — the GTK4 counterpart of GTK3's install_palette_css.
    gtk_css_provider_load_from_string(provider,
                                      ".spdf-palette-row { padding: 6px 12px; }"
                                      ".spdf-palette-header { padding: 10px 14px 2px 14px; }");
    gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(provider),
                                               GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(provider);
}

// ---------------------------------------------------------------------------
// Rows and sections

static const char* palette_section_title(int section) {
    switch (section) {
        case SPDF_PALETTE_SECTION_OPEN_DOCS:
            return "Open Documents";
        case SPDF_PALETTE_SECTION_COMMANDS:
            return "Commands";
        case SPDF_PALETTE_SECTION_FAVORITES:
            return "Favorites";
        case SPDF_PALETTE_SECTION_RECENTS:
            return "Recently Opened";
        case SPDF_PALETTE_SECTION_MATCHES:
            return "Text in Open Documents";
        default:
            return "";
    }
}

static void palette_header_func(GtkListBoxRow* row, GtkListBoxRow* before, gpointer user_data) {
    SpdfPaletteRowData* data = palette_row_data(row);
    SpdfPaletteRowData* prev = before ? palette_row_data(before) : NULL;
    GtkWidget* label;

    (void)user_data;
    if (!data || (prev && prev->section == data->section)) {
        gtk_list_box_row_set_header(row, NULL);
        return;
    }
    label = gtk_label_new(palette_section_title(data->section));
    gtk_label_set_xalign(GTK_LABEL(label), 0.0f);
    gtk_widget_add_css_class(label, "heading");
    gtk_widget_add_css_class(label, "dim-label");
    gtk_widget_add_css_class(label, "spdf-palette-header");
    gtk_list_box_row_set_header(row, label);
}

static char* palette_accel_display(const char* accel) {
    guint key = 0;
    GdkModifierType mods = 0;

    if (!accel || !gtk_accelerator_parse(accel, &key, &mods) || !key) return NULL;
    return gtk_accelerator_get_label(key, mods);
}

// Takes ownership of data. icon_name / subtitle / accel may be NULL.
static GtkListBoxRow* palette_append_row(SpdfPalette* palette, SpdfPaletteRowData* data, const char* icon_name,
                                         const char* title, const char* subtitle, const char* accel) {
    GtkWidget* row = gtk_list_box_row_new();
    GtkWidget* box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
    GtkWidget* text = gtk_box_new(GTK_ORIENTATION_VERTICAL, 1);
    GtkWidget* title_label = gtk_label_new(title);

    gtk_widget_add_css_class(row, "spdf-palette-row");
    if (icon_name) {
        GtkWidget* icon = gtk_image_new_from_icon_name(icon_name);
        gtk_widget_add_css_class(icon, "dim-label");
        gtk_widget_set_valign(icon, GTK_ALIGN_CENTER);
        gtk_box_append(GTK_BOX(box), icon);
    }
    gtk_label_set_xalign(GTK_LABEL(title_label), 0.0f);
    gtk_label_set_ellipsize(GTK_LABEL(title_label), PANGO_ELLIPSIZE_END);
    gtk_box_append(GTK_BOX(text), title_label);
    if (subtitle && *subtitle) {
        GtkWidget* subtitle_label = gtk_label_new(subtitle);
        gtk_label_set_xalign(GTK_LABEL(subtitle_label), 0.0f);
        gtk_label_set_ellipsize(GTK_LABEL(subtitle_label), PANGO_ELLIPSIZE_END);
        gtk_widget_add_css_class(subtitle_label, "dim-label");
        gtk_widget_add_css_class(subtitle_label, "caption");
        gtk_box_append(GTK_BOX(text), subtitle_label);
    }
    gtk_widget_set_hexpand(text, TRUE);
    gtk_widget_set_valign(text, GTK_ALIGN_CENTER);
    gtk_box_append(GTK_BOX(box), text);
    if (accel) {
        char* accel_text = palette_accel_display(accel);
        if (accel_text) {
            GtkWidget* accel_label = gtk_label_new(accel_text);
            gtk_widget_add_css_class(accel_label, "dim-label");
            gtk_widget_add_css_class(accel_label, "numeric");
            gtk_widget_set_valign(accel_label, GTK_ALIGN_CENTER);
            gtk_box_append(GTK_BOX(box), accel_label);
            g_free(accel_text);
        }
    }
    gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), box);
    if (data->kind == SPDF_PALETTE_ROW_STATUS) {
        gtk_list_box_row_set_selectable(GTK_LIST_BOX_ROW(row), FALSE);
        gtk_list_box_row_set_activatable(GTK_LIST_BOX_ROW(row), FALSE);
    }
    g_object_set_data_full(G_OBJECT(row), "spdf-palette-row", data, (GDestroyNotify)palette_row_data_free);
    gtk_list_box_append(palette->list, row);
    return GTK_LIST_BOX_ROW(row);
}

static GtkListBoxRow* palette_append_status_row(SpdfPalette* palette, int section, const char* text) {
    SpdfPaletteRowData* data = g_new0(SpdfPaletteRowData, 1);
    data->kind = SPDF_PALETTE_ROW_STATUS;
    data->section = section;
    data->page = -1;
    return palette_append_row(palette, data, NULL, text, NULL, NULL);
}

// ---------------------------------------------------------------------------
// Selection and keyboard navigation (focus stays in the search entry)

static void palette_scroll_to_row(SpdfPalette* palette, GtkListBoxRow* row) {
    graphene_rect_t bounds;
    GtkAdjustment* vadj = gtk_scrolled_window_get_vadjustment(palette->scroll);
    double value;
    double page;

    if (!vadj || !gtk_widget_compute_bounds(GTK_WIDGET(row), GTK_WIDGET(palette->list), &bounds)) return;
    value = gtk_adjustment_get_value(vadj);
    page = gtk_adjustment_get_page_size(vadj);
    // 36px of headroom keeps the section header above the row in view.
    if (bounds.origin.y - 36.0 < value)
        gtk_adjustment_set_value(vadj, MAX(0.0, bounds.origin.y - 36.0));
    else if (bounds.origin.y + bounds.size.height > value + page)
        gtk_adjustment_set_value(vadj, bounds.origin.y + bounds.size.height - page);
}

static GtkListBoxRow* palette_selectable_row_from(SpdfPalette* palette, int start, int step) {
    for (int i = start; i >= 0; i += step) {
        GtkListBoxRow* row = gtk_list_box_get_row_at_index(palette->list, i);
        if (!row) break;
        if (gtk_list_box_row_get_selectable(row)) return row;
    }
    return NULL;
}

static int palette_last_row_index(SpdfPalette* palette) {
    int i = 0;
    while (gtk_list_box_get_row_at_index(palette->list, i)) i++;
    return i - 1;
}

static void palette_select_row(SpdfPalette* palette, GtkListBoxRow* row) {
    if (!row) return;
    gtk_list_box_select_row(palette->list, row);
    palette_scroll_to_row(palette, row);
}

static void palette_select_first(SpdfPalette* palette) {
    palette_select_row(palette, palette_selectable_row_from(palette, 0, 1));
}

static void palette_move_selection(SpdfPalette* palette, int step) {
    GtkListBoxRow* selected = gtk_list_box_get_selected_row(palette->list);
    int start;

    if (selected)
        start = gtk_list_box_row_get_index(selected) + step;
    else
        start = step > 0 ? 0 : palette_last_row_index(palette);
    palette_select_row(palette, palette_selectable_row_from(palette, start, step));
}

// ---------------------------------------------------------------------------
// Row activation

static void palette_jump_to_document(SpdfWindow* win, const char* path, int page, const char* search_text,
                                     gboolean remember_recent) {
    spdf_palette_open_document(win, path, page, search_text, remember_recent);
}

static void palette_activate_command(SpdfWindow* win, const char* detailed) {
    GActionMap* map = NULL;
    const char* name = NULL;

    if (!detailed) return;
    if (g_str_has_prefix(detailed, "win.")) {
        map = G_ACTION_MAP(win);
        name = detailed + 4;
    } else if (g_str_has_prefix(detailed, "app.")) {
        GtkApplication* app = gtk_window_get_application(GTK_WINDOW(win));
        if (app) map = G_ACTION_MAP(app);
        name = detailed + 4;
    }
    if (map && name) {
        GAction* action = g_action_map_lookup_action(map, name);
        if (action && g_action_get_enabled(action)) g_action_activate(action, NULL);
    }
}

static void palette_activate_row(SpdfPalette* palette, GtkListBoxRow* row) {
    SpdfPaletteRowData* data = palette_row_data(row);
    SpdfWindow* win;
    char* action;
    char* path;
    char* query;
    int kind;
    int page;

    if (!data || data->kind == SPDF_PALETTE_ROW_STATUS) return;
    // Copy everything out before closing: closing can finalize the dialog,
    // which frees both the palette struct and the row widgets.
    kind = data->kind;
    page = data->page;
    action = g_strdup(data->action);
    path = g_strdup(data->path);
    query = g_strdup(data->query);
    win = g_object_ref(palette->win);
    adw_dialog_close(palette->dialog); // `palette` may be dangling from here on

    switch (kind) {
        case SPDF_PALETTE_ROW_COMMAND:
            palette_activate_command(win, action);
            break;
        case SPDF_PALETTE_ROW_OPEN_DOC:
            // The document is already open somewhere; this just focuses its
            // tab (Mac focusOpenDocumentTabForPath), so no recents churn.
            palette_jump_to_document(win, path, -1, NULL, FALSE);
            break;
        case SPDF_PALETTE_ROW_FAVORITE:
        case SPDF_PALETTE_ROW_RECENT:
            palette_jump_to_document(win, path, page, NULL, TRUE);
            break;
        case SPDF_PALETTE_ROW_MATCH:
            palette_jump_to_document(win, path, page, query, FALSE);
            break;
        default:
            break;
    }
    g_object_unref(win);
    g_free(action);
    g_free(path);
    g_free(query);
}

// ---------------------------------------------------------------------------
// Cross-document text search (worker thread + idle handoff)

static void palette_cancel_search(SpdfPalette* palette) {
    if (!palette->cancel) return;
    g_atomic_int_set(&palette->cancel->cancelled, 1);
    palette_cancel_unref(palette->cancel);
    palette->cancel = NULL;
}

static char* palette_page_snippet(spdf_document* doc, int page, const char* query) {
    char err[512];
    spdf_text_lines lines;
    GString* out = NULL;
    int found = 0;

    memset(&lines, 0, sizeof(lines));
    if (!spdf_extract_page_text_lines(doc, page, &lines, err, sizeof(err))) return NULL;
    for (int i = 0; i < lines.count && found < SPDF_PALETTE_MAX_SNIPPETS_PER_PAGE; ++i) {
        char* snippet = spdf_palette_snippet_from_line(lines.items[i].text, query);
        if (!snippet) continue;
        if (!out)
            out = g_string_new("");
        else
            g_string_append(out, "  |  ");
        g_string_append(out, snippet);
        g_free(snippet);
        found++;
    }
    spdf_free_text_lines(&lines);
    return out ? g_string_free(out, FALSE) : NULL;
}

static gboolean palette_search_finished(gpointer user_data) {
    SpdfPaletteSearchJob* job = user_data;

    if (!g_atomic_int_get(&job->cancel->cancelled)) {
        // Not cancelled => the dialog was neither closed nor re-queried, so
        // the palette struct behind it is still alive.
        SpdfPalette* palette = g_object_get_data(G_OBJECT(job->dialog), "spdf-palette");
        if (palette) {
            gboolean had_selection = gtk_list_box_get_selected_row(palette->list) != NULL;

            if (palette->status_row) {
                gtk_list_box_remove(palette->list, GTK_WIDGET(palette->status_row));
                palette->status_row = NULL;
            }
            if (job->results->len == 0) {
                palette->status_row =
                    palette_append_status_row(palette, SPDF_PALETTE_SECTION_MATCHES, "No matches in open documents");
            }
            for (guint i = 0; i < job->results->len; ++i) {
                const SpdfPaletteSearchResult* result = g_ptr_array_index(job->results, i);
                SpdfPaletteRowData* data = g_new0(SpdfPaletteRowData, 1);
                char* title = g_strdup_printf("%s — page %d (%d match%s)", result->title, result->page + 1,
                                              result->hits, result->hits == 1 ? "" : "es");

                data->kind = SPDF_PALETTE_ROW_MATCH;
                data->section = SPDF_PALETTE_SECTION_MATCHES;
                data->path = g_strdup(result->path);
                data->query = g_strdup(job->query);
                data->page = result->page;
                palette_append_row(palette, data, "edit-find-symbolic", title,
                                   result->snippet ? result->snippet : result->path, NULL);
                g_free(title);
            }
            if (!had_selection) palette_select_first(palette);
        }
    }
    palette_search_job_free(job);
    return G_SOURCE_REMOVE;
}

static gpointer palette_search_worker(gpointer user_data) {
    SpdfPaletteSearchJob* job = user_data;
    int searched_pages = 0;

    job->results = g_ptr_array_new_with_free_func(palette_search_result_free);
    for (guint d = 0; d < job->docs->len && searched_pages < SPDF_PALETTE_MAX_SEARCH_PAGES; ++d) {
        const SpdfPaletteSearchDoc* search_doc = g_ptr_array_index(job->docs, d);
        char err[512];
        spdf_document* doc;
        int pages;

        if (g_atomic_int_get(&job->cancel->cancelled)) break;
        // A fresh document per worker pass: the tabs' main-thread docs are
        // not shareable across threads (same rule as the Mac palette).
        doc = spdf_password_source_open(&search_doc->source, err, sizeof(err));
        if (!doc) continue;
        pages = spdf_page_count(doc);
        for (int page = 0; page < pages && searched_pages < SPDF_PALETTE_MAX_SEARCH_PAGES; ++page) {
            int hits;

            if (g_atomic_int_get(&job->cancel->cancelled)) break;
            hits = spdf_search_page(doc, page, job->query, err, sizeof(err));
            searched_pages++;
            if (hits <= 0) continue;
            {
                SpdfPaletteSearchResult* result = g_new0(SpdfPaletteSearchResult, 1);
                result->path = g_strdup(search_doc->source.path);
                result->title = g_strdup(search_doc->title);
                result->page = page;
                result->hits = hits;
                result->snippet = palette_page_snippet(doc, page, job->query);
                g_ptr_array_add(job->results, result);
            }
        }
        spdf_close(doc);
    }
    g_idle_add(palette_search_finished, job);
    return NULL;
}

// Snapshot of every open tab (all windows), deduplicated by path, taken on
// the main thread — the worker never touches widget or tab state.
static GPtrArray* palette_open_docs_snapshot(SpdfWindow* win) {
    GtkApplication* app = gtk_window_get_application(GTK_WINDOW(win));
    GPtrArray* docs = g_ptr_array_new_with_free_func(palette_search_doc_free);
    GHashTable* seen = g_hash_table_new(g_str_hash, g_str_equal);

    for (GList* it = app ? gtk_application_get_windows(app) : NULL; it; it = it->next) {
        SpdfWindow* window;
        int count;

        if (!SPDF_IS_WINDOW(it->data)) continue;
        window = SPDF_WINDOW(it->data);
        count = spdf_window_tab_count(window);
        for (int t = 0; t < count; ++t) {
            SpdfTab* tab = spdf_window_tab_at(window, t);
            SpdfPaletteSearchDoc* doc;

            if (!tab || !tab->path || !*tab->path) continue;
            if (g_hash_table_contains(seen, tab->path)) continue;
            doc = g_new0(SpdfPaletteSearchDoc, 1);
            spdf_password_source_init(&doc->source, tab->path, tab->credential);
            doc->title = spdf_tab_display_name(tab);
            g_ptr_array_add(docs, doc);
            g_hash_table_add(seen, doc->source.path); // key owned by the doc entry
        }
    }
    g_hash_table_unref(seen);
    return docs;
}

static void palette_start_search(SpdfPalette* palette, const char* query) {
    GPtrArray* docs = palette_open_docs_snapshot(palette->win);
    SpdfPaletteSearchJob* job;
    GThread* thread;

    if (docs->len == 0) {
        g_ptr_array_unref(docs);
        return;
    }
    palette->status_row = palette_append_status_row(palette, SPDF_PALETTE_SECTION_MATCHES, "Searching open documents…");
    palette->cancel = palette_cancel_new();
    job = g_new0(SpdfPaletteSearchJob, 1);
    job->cancel = palette_cancel_ref(palette->cancel);
    job->dialog = g_object_ref(palette->dialog);
    job->query = g_strdup(query);
    job->docs = docs;
    thread = g_thread_new("spdf-palette-search", palette_search_worker, job);
    g_thread_unref(thread);
}

// ---------------------------------------------------------------------------
// Section assembly

// Appends the Open documents section: one row per open tab in every window,
// in window/tab order, the palette window's own active tab skipped (the group
// lists switch targets; the frontmost document would be a no-op) — Mac
// openDocumentPaletteCandidates (ShenzhenPDFMac.mm @12575-12589) over the
// pure spdf_palette_filter_open_documents. Returns the set of canonical
// paths actually shown, for the favorites dedup (Mac openShownPaths,
// @12458-12463); caller unrefs.
static GHashTable* palette_append_open_docs(SpdfPalette* palette, const char* query) {
    GtkApplication* app = gtk_window_get_application(GTK_WINDOW(palette->win));
    SpdfTab* active = spdf_window_current_tab(palette->win);
    GPtrArray* paths = g_ptr_array_new_with_free_func(g_free);
    GPtrArray* titles = g_ptr_array_new_with_free_func(g_free);
    GHashTable* shown = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    SpdfPaletteOpenDoc* docs;
    int* picks;
    int pick_count;

    for (GList* it = app ? gtk_application_get_windows(app) : NULL; it; it = it->next) {
        SpdfWindow* window;
        int count;

        if (!SPDF_IS_WINDOW(it->data)) continue;
        window = SPDF_WINDOW(it->data);
        count = spdf_window_tab_count(window);
        for (int t = 0; t < count; ++t) {
            SpdfTab* tab = spdf_window_tab_at(window, t);

            if (!tab || !tab->path || !*tab->path) continue;
            if (window == palette->win && tab == active) continue;
            g_ptr_array_add(paths, g_strdup(tab->path));
            g_ptr_array_add(titles, spdf_tab_display_name(tab));
        }
    }
    docs = g_new0(SpdfPaletteOpenDoc, MAX(paths->len, 1));
    picks = g_new0(int, MAX(paths->len, 1));
    for (guint i = 0; i < paths->len; ++i) {
        docs[i].path = g_ptr_array_index(paths, i);
        docs[i].title = g_ptr_array_index(titles, i);
    }
    pick_count = spdf_palette_filter_open_documents(docs, (int)paths->len, query, picks, (int)paths->len);
    for (int i = 0; i < pick_count; ++i) {
        const SpdfPaletteOpenDoc* doc = &docs[picks[i]];
        SpdfPaletteRowData* data = g_new0(SpdfPaletteRowData, 1);

        data->kind = SPDF_PALETTE_ROW_OPEN_DOC;
        data->section = SPDF_PALETTE_SECTION_OPEN_DOCS;
        data->path = g_strdup(doc->path);
        data->page = -1;
        palette_append_row(palette, data, "document-open-symbolic", doc->title, doc->path, NULL);
        g_hash_table_add(shown, palette_canonical_path(doc->path));
    }
    g_free(picks);
    g_free(docs);
    g_ptr_array_unref(titles);
    g_ptr_array_unref(paths);
    return shown;
}

static void palette_append_commands(SpdfPalette* palette, const char* query) {
    int table_count = 0;
    const SpdfShortcutEntry* table = spdf_shortcuts_table(&table_count);
    SpdfPaletteCommand* commands = g_new0(SpdfPaletteCommand, (gsize)MAX(table_count, 1));
    SpdfPaletteMatch* matches = g_new0(SpdfPaletteMatch, (gsize)MAX(table_count, 1));
    char** breadcrumbs = g_new0(char*, (gsize)MAX(table_count, 1)); // owned, parallel to commands
    int command_count = 0;
    int match_count;

    for (int i = 0; i < table_count; ++i) {
        const SpdfShortcutEntry* entry = &table[i];
        GActionMap* map = NULL;
        const char* name = NULL;
        GAction* action;
        GVariant* state;
        gboolean toggled = FALSE;

        // The palette is itself the favorites search; a row that reopens it
        // would be a no-op loop (Mac parity).
        if (g_strcmp0(entry->action, "win.palette") == 0) continue;
        if (g_str_has_prefix(entry->action, "win.")) {
            map = G_ACTION_MAP(palette->win);
            name = entry->action + 4;
        } else if (g_str_has_prefix(entry->action, "app.")) {
            GtkApplication* app = gtk_window_get_application(GTK_WINDOW(palette->win));
            if (app) map = G_ACTION_MAP(app);
            name = entry->action + 4;
        }
        if (!map || !name) continue;
        action = g_action_map_lookup_action(map, name);
        if (!action) continue;
        if (g_action_get_parameter_type(action)) continue; // needs a target
        // Stateful boolean actions are the menus' check items; the palette
        // row mirrors the checkmark (Mac collectPaletteMenuCommandsFromMenu,
        // ShenzhenPDFMac.mm @12416-12418).
        state = g_action_get_state(action);
        if (state) {
            toggled = g_variant_is_of_type(state, G_VARIANT_TYPE_BOOLEAN) && g_variant_get_boolean(state);
            g_variant_unref(state);
        }
        // Group = the entry's menu; entries without one (context-menu
        // actions) have no menu path to show or match.
        breadcrumbs[command_count] = entry->group ? spdf_palette_menu_breadcrumb(entry->group, entry->title) : NULL;
        commands[command_count].action = entry->action;
        commands[command_count].title = entry->title;
        commands[command_count].accel = entry->accels[0];
        commands[command_count].breadcrumb = breadcrumbs[command_count];
        commands[command_count].enabled = g_action_get_enabled(action);
        commands[command_count].toggled = toggled;
        command_count++;
    }
    match_count = spdf_palette_filter_commands(commands, command_count, query, matches, command_count);
    for (int i = 0; i < match_count; ++i) {
        const SpdfPaletteCommand* command = &commands[matches[i].index];
        SpdfPaletteRowData* data = g_new0(SpdfPaletteRowData, 1);
        // Display-only checkmark: the Mac folds it into the matched title,
        // but the fuzzy ranking must not penalize toggled-on commands with
        // two bytes of leading skip.
        char* title = command->toggled ? g_strdup_printf("\xE2\x9C\x93 %s", command->title) : NULL;

        data->kind = SPDF_PALETTE_ROW_COMMAND;
        data->section = SPDF_PALETTE_SECTION_COMMANDS;
        data->action = g_strdup(command->action);
        data->page = -1;
        palette_append_row(palette, data, "system-run-symbolic", title ? title : command->title, command->breadcrumb,
                           command->accel);
        g_free(title);
    }
    for (int i = 0; i < command_count; ++i) g_free(breadcrumbs[i]);
    g_free(breadcrumbs);
    g_free(matches);
    g_free(commands);
}

#define SPDF_PALETTE_MAX_FAVORITE_ROWS 100

static void palette_append_favorites(SpdfPalette* palette, SpdfState* state, const char* query,
                                     GHashTable* open_paths) {
    guint count = spdf_state_favorite_count(state);
    // "fav" (any >= 3 character prefix of "favorites") is a browse keyword:
    // reveal every favorite, bypassing the matching and the open-document
    // dedupe so the group is complete rather than filtered by the keyword
    // (Mac refreshPaletteResults, ShenzhenPDFMac.mm @12474-12479).
    gboolean reveal_all = spdf_palette_query_reveals_all_favorites(query);
    SpdfPaletteMatch* matches;
    int match_count = 0;

    if (reveal_all) query = NULL;
    if (count == 0) return;
    matches = g_new0(SpdfPaletteMatch, count);
    for (guint i = 0; i < count; ++i) {
        const SpdfFavorite* favorite = spdf_state_favorite(state, i);
        int score = 0;

        if (!favorite) continue;
        // A document that is both open and a favorite lists once, in the
        // open section (Mac spdf_palette_favorites_without_open_documents).
        if (!reveal_all && spdf_palette_favorite_shadowed_by_open_doc(favorite->type, favorite->path, open_paths))
            continue;
        if (query && *query) {
            // Same haystack the Mac palette matches: name, title, path, labels.
            char* labels = favorite->labels ? g_strjoinv(" ", favorite->labels) : NULL;
            char* haystack = g_strdup_printf("%s %s %s %s", favorite->name ? favorite->name : "",
                                             favorite->title ? favorite->title : "",
                                             favorite->path ? favorite->path : "", labels ? labels : "");
            score = spdf_palette_fuzzy_score(query, haystack);
            g_free(haystack);
            g_free(labels);
            if (score < 0) continue;
        }
        matches[match_count].index = (int)i;
        matches[match_count].score = score;
        match_count++;
    }
    if (query && *query) qsort(matches, (size_t)match_count, sizeof *matches, palette_match_compare);
    if (match_count > SPDF_PALETTE_MAX_FAVORITE_ROWS) match_count = SPDF_PALETTE_MAX_FAVORITE_ROWS;
    for (int i = 0; i < match_count; ++i) {
        const SpdfFavorite* favorite = spdf_state_favorite(state, (guint)matches[i].index);
        gboolean is_document = g_strcmp0(favorite->type, "document") == 0;
        const char* title = favorite->name && *favorite->name     ? favorite->name
                            : favorite->title && *favorite->title ? favorite->title
                                                                  : "Favorite";
        char* subtitle = is_document
                             ? g_strdup(favorite->path)
                             : g_strdup_printf("p.%d · %s", favorite->page + 1, favorite->path ? favorite->path : "");
        SpdfPaletteRowData* data = g_new0(SpdfPaletteRowData, 1);

        data->kind = SPDF_PALETTE_ROW_FAVORITE;
        data->section = SPDF_PALETTE_SECTION_FAVORITES;
        data->path = g_strdup(favorite->path);
        data->page = is_document ? -1 : favorite->page;
        // The icon is the page/document distinction: a bookmark marks a page,
        // a star marks the whole document.
        palette_append_row(palette, data, is_document ? "starred-symbolic" : "user-bookmark-symbolic", title, subtitle,
                           NULL);
        g_free(subtitle);
    }
    g_free(matches);
}

static void palette_append_recents(SpdfPalette* palette, SpdfState* state, const char* query) {
    int count = spdf_state_recent_count(state);

    for (int i = 0; i < count; ++i) {
        const char* path = spdf_state_recent_path(state, i);
        char* base;
        SpdfPaletteRowData* data;

        if (!path || !*path) continue;
        if (query && *query && spdf_palette_fuzzy_score(query, path) < 0) continue; // MRU order kept
        base = g_path_get_basename(path);
        data = g_new0(SpdfPaletteRowData, 1);
        data->kind = SPDF_PALETTE_ROW_RECENT;
        data->section = SPDF_PALETTE_SECTION_RECENTS;
        data->path = g_strdup(path);
        data->page = -1;
        palette_append_row(palette, data, "document-open-recent-symbolic", base, path, NULL);
        g_free(base);
    }
}

static void palette_rebuild(SpdfPalette* palette) {
    const char* query = gtk_editable_get_text(GTK_EDITABLE(palette->entry));
    SpdfApp* app = palette_window_app(palette->win);
    SpdfState* state = app ? spdf_app_get_state(app) : NULL;

    palette_cancel_search(palette);
    palette->status_row = NULL;
    gtk_list_box_remove_all(palette->list);

    // Mac section order (refreshPaletteResults, ShenzhenPDFMac.mm
    // @12452-12526): Open documents, Favorites, Commands ("Actions"),
    // then the GTK4-only Recents, then the async text matches.
    {
        GHashTable* open_paths = palette_append_open_docs(palette, query);
        if (state) palette_append_favorites(palette, state, query, open_paths);
        g_hash_table_unref(open_paths);
    }
    palette_append_commands(palette, query);
    if (state) palette_append_recents(palette, state, query);
    if (query && strlen(query) >= SPDF_PALETTE_MIN_TEXT_QUERY_BYTES && strlen(query) < SPDF_STATE_MAX_FIND_QUERY_BYTES)
        palette_start_search(palette, query);

    if (!gtk_list_box_get_row_at_index(palette->list, 0))
        palette_append_status_row(palette, SPDF_PALETTE_SECTION_COMMANDS, "No results");
    palette_select_first(palette);
}

// ---------------------------------------------------------------------------
// Signals

static void palette_search_changed(GtkSearchEntry* entry, gpointer user_data) {
    (void)entry;
    palette_rebuild((SpdfPalette*)user_data);
}

static void palette_entry_activated(GtkSearchEntry* entry, gpointer user_data) {
    SpdfPalette* palette = user_data;
    GtkListBoxRow* row = gtk_list_box_get_selected_row(palette->list);

    (void)entry;
    if (!row) row = palette_selectable_row_from(palette, 0, 1);
    if (row) palette_activate_row(palette, row);
}

static void palette_stop_search(GtkSearchEntry* entry, gpointer user_data) {
    SpdfPalette* palette = user_data;
    (void)entry;
    adw_dialog_close(palette->dialog);
}

static gboolean palette_entry_key_pressed(GtkEventControllerKey* controller, guint keyval, guint keycode,
                                          GdkModifierType state, gpointer user_data) {
    SpdfPalette* palette = user_data;

    (void)controller;
    (void)keycode;
    (void)state;
    if (keyval == GDK_KEY_Down || keyval == GDK_KEY_KP_Down) {
        palette_move_selection(palette, 1);
        return GDK_EVENT_STOP;
    }
    if (keyval == GDK_KEY_Up || keyval == GDK_KEY_KP_Up) {
        palette_move_selection(palette, -1);
        return GDK_EVENT_STOP;
    }
    return GDK_EVENT_PROPAGATE;
}

static void palette_row_activated(GtkListBox* list, GtkListBoxRow* row, gpointer user_data) {
    (void)list;
    palette_activate_row((SpdfPalette*)user_data, row);
}

static void palette_closed(AdwDialog* dialog, gpointer user_data) {
    SpdfPalette* palette = user_data;

    // Any in-flight worker must never touch the dying widget tree; the
    // result idle checks this flag before dereferencing the palette.
    palette_cancel_search(palette);
    // Drop the per-window singleton marker (Ctrl+K while open re-presents).
    if (g_object_get_data(G_OBJECT(palette->win), "spdf-palette-dialog") == dialog)
        g_object_set_data(G_OBJECT(palette->win), "spdf-palette-dialog", NULL);
}

static void palette_free(gpointer data) {
    SpdfPalette* palette = data;
    palette_cancel_search(palette); // defensive; palette_closed already ran
    g_free(palette);
}

// ---------------------------------------------------------------------------
// Entry points

void spdf_palette_open(SpdfWindow* win) {
    SpdfPalette* palette;
    AdwDialog* dialog;
    GtkWidget* box;
    GtkWidget* entry;
    GtkWidget* scroll;
    GtkWidget* list;
    GtkEventController* keys;

    g_return_if_fail(SPDF_IS_WINDOW(win));
    // Ctrl+K with the palette already up refocuses it instead of stacking a
    // second dialog (the window accel still fires while the dialog is shown).
    {
        AdwDialog* existing = g_object_get_data(G_OBJECT(win), "spdf-palette-dialog");
        if (existing) {
            adw_dialog_present(existing, GTK_WIDGET(win));
            return;
        }
    }
    palette_install_css();

    palette = g_new0(SpdfPalette, 1);
    palette->win = win;

    dialog = adw_dialog_new();
    adw_dialog_set_title(dialog, "Command");
    adw_dialog_set_content_width(dialog, 620);
    adw_dialog_set_content_height(dialog, 460); // max height; the dialog never outgrows this
    palette->dialog = dialog;

    box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);

    entry = gtk_search_entry_new();
    gtk_search_entry_set_placeholder_text(GTK_SEARCH_ENTRY(entry), "Commands, favorites, and open documents");
    gtk_widget_set_margin_start(entry, 12);
    gtk_widget_set_margin_end(entry, 12);
    gtk_widget_set_margin_top(entry, 12);
    gtk_widget_set_margin_bottom(entry, 8);
    palette->entry = GTK_SEARCH_ENTRY(entry);
    gtk_box_append(GTK_BOX(box), entry);
    gtk_box_append(GTK_BOX(box), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));

    list = gtk_list_box_new();
    gtk_list_box_set_selection_mode(GTK_LIST_BOX(list), GTK_SELECTION_BROWSE);
    gtk_list_box_set_header_func(GTK_LIST_BOX(list), palette_header_func, NULL, NULL);
    gtk_widget_add_css_class(list, "navigation-sidebar"); // flat rows, adw hover/selection styling
    palette->list = GTK_LIST_BOX(list);

    scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), list);
    gtk_widget_set_vexpand(scroll, TRUE);
    palette->scroll = GTK_SCROLLED_WINDOW(scroll);
    gtk_box_append(GTK_BOX(box), scroll);

    adw_dialog_set_child(dialog, box);

    g_signal_connect(entry, "search-changed", G_CALLBACK(palette_search_changed), palette);
    g_signal_connect(entry, "activate", G_CALLBACK(palette_entry_activated), palette);
    g_signal_connect(entry, "stop-search", G_CALLBACK(palette_stop_search), palette);
    keys = gtk_event_controller_key_new();
    // Capture phase: the entry's internal GtkText must never swallow Up/Down
    // before the list navigation sees them.
    gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
    g_signal_connect(keys, "key-pressed", G_CALLBACK(palette_entry_key_pressed), palette);
    gtk_widget_add_controller(entry, keys);
    g_signal_connect(list, "row-activated", G_CALLBACK(palette_row_activated), palette);
    g_signal_connect(dialog, "closed", G_CALLBACK(palette_closed), palette);
    g_object_set_data_full(G_OBJECT(dialog), "spdf-palette", palette, palette_free);
    g_object_set_data(G_OBJECT(win), "spdf-palette-dialog", dialog);

    palette_rebuild(palette);
    adw_dialog_set_focus(dialog, entry);
    adw_dialog_present(dialog, GTK_WIDGET(win));
}

// ---------------------------------------------------------------------------
// Favorite toggles (win.favorite-page / win.favorite-document)

static int palette_find_favorite(SpdfState* state, const char* type, const char* path, int page) {
    guint count = spdf_state_favorite_count(state);

    for (guint i = 0; i < count; ++i) {
        const SpdfFavorite* favorite = spdf_state_favorite(state, i);
        if (!favorite) continue;
        if (g_strcmp0(favorite->type ? favorite->type : "page", type) != 0) continue;
        if (g_strcmp0(favorite->path, path) != 0) continue;
        if (strcmp(type, "page") == 0 && favorite->page != page) continue;
        return (int)i;
    }
    return -1;
}

// Toggle semantics (add when absent, remove when present); the default name
// is the Mac prompt's default ("<doc title> p.<n>") without the prompt — the
// palette itself is where favorites get renamed/relabeled later.
void spdf_palette_toggle_favorite_page(SpdfWindow* win) {
    SpdfApp* app;
    SpdfTab* tab;
    SpdfState* state;
    char* display;
    int page;
    int existing;

    g_return_if_fail(SPDF_IS_WINDOW(win));
    app = palette_window_app(win);
    tab = spdf_window_current_tab(win);
    if (!app || !tab || !tab->path || !*tab->path || !tab->view) return;
    state = spdf_app_get_state(app);
    page = spdf_doc_view_current_page(tab->view);
    existing = palette_find_favorite(state, "page", tab->path, page);
    if (existing >= 0) {
        spdf_state_remove_favorite(state, (guint)existing);
        return;
    }
    display = spdf_tab_display_name(tab);
    {
        SpdfFavorite favorite = {0};
        favorite.type = (char*)"page";
        favorite.path = tab->path;
        favorite.title = display;
        favorite.name = g_strdup_printf("%s p.%d", display, page + 1);
        favorite.page = page;
        favorite.created = g_get_real_time() / G_USEC_PER_SEC;
        spdf_state_add_favorite(state, &favorite); // copies + dedupes + saves
        g_free(favorite.name);
    }
    g_free(display);
}

void spdf_palette_toggle_favorite_document(SpdfWindow* win) {
    SpdfApp* app;
    SpdfTab* tab;
    SpdfState* state;
    char* display;
    int existing;

    g_return_if_fail(SPDF_IS_WINDOW(win));
    app = palette_window_app(win);
    tab = spdf_window_current_tab(win);
    if (!app || !tab || !tab->path || !*tab->path) return;
    state = spdf_app_get_state(app);
    existing = palette_find_favorite(state, "document", tab->path, 0);
    if (existing >= 0) {
        spdf_state_remove_favorite(state, (guint)existing);
        return;
    }
    display = spdf_tab_display_name(tab);
    {
        SpdfFavorite favorite = {0};
        favorite.type = (char*)"document";
        favorite.path = tab->path;
        favorite.title = display;
        favorite.name = display;
        favorite.page = 0;
        favorite.created = g_get_real_time() / G_USEC_PER_SEC;
        spdf_state_add_favorite(state, &favorite);
    }
    g_free(display);
}

#endif // !SPDF_PALETTE_TESTING
