// spdf_sidebar.c — left side panel: Chapters / Comments / Search results.
// See spdf_sidebar.h for the widget-choice rationale (GtkPaned) and
// provenance. Pure grouping/tree/markup logic lives in
// spdf_sidebar_internal.h (tests/sidebar_test.c).
//
// Population always runs in a low-priority idle (GTK3 deferred sidebar
// metadata load, ShenzhenPDFGtk.c @2605): tab switches only schedule work,
// the paint path never loads outlines or builds rows.

#include <string.h>

#include "spdf_annot.h"
#include "spdf_app.h"
#include "spdf_search.h"
#include "spdf_sidebar.h"
#include "spdf_sidebar_internal.h"

// ---------------------------------------------------------------------------
// List item model. One GObject serves all three panes.

typedef enum {
    SPDF_SIDEBAR_ROW_CHAPTER, // outline entry (chapters tree)
    SPDF_SIDEBAR_ROW_HEADER,  // chapter divider (search results)
    SPDF_SIDEBAR_ROW_MATCH,   // search match (snippet row)
} SpdfSidebarRowKind;

#define SPDF_TYPE_SIDEBAR_ITEM (spdf_sidebar_item_get_type())
G_DECLARE_FINAL_TYPE(SpdfSidebarItem, spdf_sidebar_item, SPDF, SIDEBAR_ITEM, GObject)

struct _SpdfSidebarItem {
    GObject parent_instance;
    SpdfSidebarRowKind kind;
    char* text;           // chapters/headers: plain text; match rows: Pango markup
    char* subtitle;       // match rows: "Page N · match #i"; else NULL
    int page;             // jump target (chapters), match page (rows), -1 headers
    int index;            // chapter: pre-order outline index; match: match index
    GListStore* children; // chapters only; NULL for leaves and other kinds
};

G_DEFINE_FINAL_TYPE(SpdfSidebarItem, spdf_sidebar_item, G_TYPE_OBJECT)

static void spdf_sidebar_item_finalize(GObject* object) {
    SpdfSidebarItem* self = SPDF_SIDEBAR_ITEM(object);
    g_free(self->text);
    g_free(self->subtitle);
    g_clear_object(&self->children);
    G_OBJECT_CLASS(spdf_sidebar_item_parent_class)->finalize(object);
}

static void spdf_sidebar_item_class_init(SpdfSidebarItemClass* klass) {
    G_OBJECT_CLASS(klass)->finalize = spdf_sidebar_item_finalize;
}

static void spdf_sidebar_item_init(SpdfSidebarItem* self) {
    self->page = -1;
    self->index = -1;
}

/* Takes ownership of text and subtitle. */
static SpdfSidebarItem* sidebar_item_new(SpdfSidebarRowKind kind, char* text, char* subtitle, int page, int index) {
    SpdfSidebarItem* item = g_object_new(SPDF_TYPE_SIDEBAR_ITEM, NULL);
    item->kind = kind;
    item->text = text;
    item->subtitle = subtitle;
    item->page = page;
    item->index = index;
    return item;
}

// ---------------------------------------------------------------------------
// Per-window sidebar state, stored as qdata on the GtkPaned (freed with it)
// and pointed to from the window for lookups.

typedef struct {
    SpdfWindow* win; // weak pointer
    GtkPaned* paned; // borrowed; owns this struct
    GtkWidget* panel;
    AdwViewStack* stack;

    // Filter field (Mac _sidebarFilterField): filters the chapters tree and
    // the comments list; hidden on the search-results pane.
    GtkWidget* filter_entry;
    char* filter_text; // casefolded; NULL/empty = no filtering

    // Pane switcher (Mac segmented control): linked text-only toggles —
    // AdwViewSwitcher stacks icon over label (too tall) or ellipsizes.
    GtkToggleButton* pane_buttons[3]; // chapters, comments, search

    // Chapters pane
    GtkListView* chapters_view;
    GtkSingleSelection* chapters_sel; // owned; over a GtkTreeListModel
    GtkStack* chapters_pane;
    SpdfTab* chapters_tab; // tab the tree was built for

    // Chapter attribution cache (borrowed title pointers into tab->outline)
    SpdfTab* cache_tab;
    int cache_count;
    int* cache_pages;
    int* cache_levels; // normalized
    const char** cache_titles;

    // Comments pane
    GtkListBox* comments_list;
    SpdfTab* comments_tab;

    // Search results pane
    GtkListView* results_view;
    GtkSingleSelection* results_sel; // owned; over results_store
    GListStore* results_store;       // owned
    GtkStack* results_pane;
    GtkLabel* results_empty;
    GArray* match_rows;       // guint store position per match index
    guint results_built;      // matches already turned into rows
    guint results_total;      // match count stamped in the row subtitles
    int results_prev_chapter; // grouping state (SPDF_SIDEBAR_NO_CHAPTER)
    char* results_query;      // query the store was built for
    SpdfSearchController* connected; // weak pointer

    SpdfDocView* page_view; // weak pointer; view whose page-changed we track
    guint sync_idle_id;
    gboolean suppress; // programmatic selection guard
} SpdfSidebar;

static GQuark sidebar_quark(void) {
    static GQuark quark;
    if (!quark) quark = g_quark_from_static_string("spdf-sidebar");
    return quark;
}

static SpdfSidebar* sidebar_for_window(SpdfWindow* win) {
    return win ? g_object_get_qdata(G_OBJECT(win), sidebar_quark()) : NULL;
}

static SpdfSidebar* sidebar_for_paned(gpointer paned) {
    return g_object_get_qdata(G_OBJECT(paned), sidebar_quark());
}

static void sidebar_page_changed(SpdfDocView* view, int page, gpointer user_data);

static void sidebar_free(gpointer data) {
    SpdfSidebar* sb = data;
    if (sb->win) {
        g_object_set_qdata(G_OBJECT(sb->win), sidebar_quark(), NULL);
        g_object_remove_weak_pointer(G_OBJECT(sb->win), (gpointer*)&sb->win);
    }
    if (sb->connected) g_object_remove_weak_pointer(G_OBJECT(sb->connected), (gpointer*)&sb->connected);
    if (sb->page_view) {
        g_signal_handlers_disconnect_by_func(sb->page_view, sidebar_page_changed, sb->paned);
        g_object_remove_weak_pointer(G_OBJECT(sb->page_view), (gpointer*)&sb->page_view);
    }
    if (sb->sync_idle_id) g_source_remove(sb->sync_idle_id);
    g_clear_object(&sb->chapters_sel);
    g_clear_object(&sb->results_sel);
    g_clear_object(&sb->results_store);
    if (sb->match_rows) g_array_free(sb->match_rows, TRUE);
    g_free(sb->cache_pages);
    g_free(sb->cache_levels);
    g_free(sb->cache_titles);
    g_free(sb->results_query);
    g_free(sb->filter_text);
    g_free(sb);
}

static SpdfApp* app_for_window(SpdfWindow* win) {
    GtkApplication* app = win ? gtk_window_get_application(GTK_WINDOW(win)) : NULL;
    return app && SPDF_IS_APP(app) ? SPDF_APP(app) : NULL;
}

static SpdfState* state_for_sidebar(SpdfSidebar* sb) {
    SpdfApp* app = app_for_window(sb->win);
    return app ? spdf_app_get_state(app) : NULL;
}

// ---------------------------------------------------------------------------
// Outline cache (SpdfTab appended fields). Loaded at most once per tab, off
// the paint path (all callers run inside the sync idle or worker deliveries).

static gboolean tab_ensure_outline(SpdfTab* tab) {
    char err[512] = "";
    if (!tab) return FALSE;
    if (!tab->outline_loaded) {
        if (tab->doc && !spdf_load_outline(tab->doc, &tab->outline, err, sizeof(err))) {
            g_warning("shenzhenpdf: could not load outline: %s", err[0] ? err : "unknown error");
            tab->outline.items = NULL;
            tab->outline.count = 0;
        }
        tab->outline_loaded = TRUE;
    }
    return tab->outline.count > 0;
}

static void sidebar_cache_clear(SpdfSidebar* sb) {
    g_clear_pointer(&sb->cache_pages, g_free);
    g_clear_pointer(&sb->cache_levels, g_free);
    g_clear_pointer(&sb->cache_titles, g_free);
    sb->cache_count = 0;
    sb->cache_tab = NULL;
}

static void sidebar_cache_ensure(SpdfSidebar* sb, SpdfTab* tab) {
    if (sb->cache_tab == tab) return;
    sidebar_cache_clear(sb);
    sb->cache_tab = tab;
    if (!tab_ensure_outline(tab)) return;
    sb->cache_count = tab->outline.count;
    sb->cache_pages = g_new(int, sb->cache_count);
    sb->cache_levels = g_new(int, sb->cache_count);
    sb->cache_titles = g_new(const char*, sb->cache_count);
    for (int i = 0; i < sb->cache_count; ++i) {
        sb->cache_pages[i] = tab->outline.items[i].page_index;
        sb->cache_levels[i] = tab->outline.items[i].level;
        sb->cache_titles[i] = tab->outline.items[i].title;
    }
    spdf_sidebar_outline_normalize_levels(sb->cache_levels, sb->cache_count);
}

// ---------------------------------------------------------------------------
// Per-document visibility (state API showSidebar). Resolution order:
// documents.json entry for the path, else the defaultSidebarVisible setting.
// Resolved lazily into the SpdfTab appended fields.

static gboolean sidebar_tab_visible(SpdfSidebar* sb, SpdfTab* tab) {
    SpdfState* state;
    if (!tab) return FALSE;
    if (tab->sidebar_resolved) return tab->sidebar_visible;
    state = state_for_sidebar(sb);
    if (state) {
        const SpdfDocState* doc_state = spdf_state_document_lookup(state, tab->path);
        if (doc_state && doc_state->has_show_sidebar) tab->sidebar_visible = doc_state->show_sidebar;
        else tab->sidebar_visible = spdf_state_settings(state)->default_sidebar_visible;
        tab->sidebar_resolved = TRUE;
    }
    return tab->sidebar_visible;
}

static void sidebar_persist_visibility(SpdfSidebar* sb, SpdfTab* tab, gboolean visible) {
    SpdfState* state = state_for_sidebar(sb);
    const SpdfDocState* previous;
    SpdfDocState doc_state;
    char* title;

    if (!state || !tab || !tab->path) return;
    previous = spdf_state_document_lookup(state, tab->path);
    title = spdf_tab_display_name(tab);
    memset(&doc_state, 0, sizeof(doc_state));
    doc_state.path = tab->path;
    doc_state.title = title;
    doc_state.show_sidebar = visible;
    doc_state.has_show_sidebar = TRUE;
    // document_update stamps has_show_minimap too, so carry the stored (or
    // default) minimap preference instead of clobbering it with FALSE.
    doc_state.show_minimap = previous && previous->has_show_minimap
                                 ? previous->show_minimap
                                 : spdf_state_settings(state)->default_minimap_visible;
    doc_state.has_show_minimap = TRUE;
    spdf_state_document_update(state, &doc_state);
    g_free(title);
}

// ---------------------------------------------------------------------------
// Deferred sync (GTK3 idle pattern @2605)

static gboolean sidebar_sync_idle(gpointer user_data);

static void sidebar_schedule_sync(SpdfSidebar* sb) {
    if (sb->sync_idle_id) return;
    sb->sync_idle_id = g_idle_add_full(G_PRIORITY_LOW, sidebar_sync_idle, g_object_ref(sb->paned), g_object_unref);
}

// ---------------------------------------------------------------------------
// Chapters pane

static void chapters_row_clicked(GtkGestureClick* gesture, int n_press, double x, double y, gpointer user_data);

static void chapters_factory_setup(GtkSignalListItemFactory* factory, GtkListItem* list_item, gpointer user_data) {
    GtkWidget* expander = gtk_tree_expander_new();
    GtkWidget* label = gtk_label_new("");
    GtkGesture* click = gtk_gesture_click_new();
    (void)factory;
    gtk_label_set_xalign(GTK_LABEL(label), 0.0f);
    gtk_label_set_ellipsize(GTK_LABEL(label), PANGO_ELLIPSIZE_END);
    gtk_tree_expander_set_child(GTK_TREE_EXPANDER(expander), label);
    gtk_list_item_set_child(list_item, expander);
    // Click-to-jump even when the row is already selected (Mac
    // activateSidebarRow): notify::selected misses that case, and
    // single-click-activate is not an option — it makes GtkListView move the
    // SELECTION on pointer hover. Bubble-phase per-row gesture instead; the
    // expander arrow sits outside the label, so expansion clicks don't jump.
    g_object_set_data(G_OBJECT(label), "chapter-expander", expander);
    g_signal_connect(click, "released", G_CALLBACK(chapters_row_clicked), user_data);
    gtk_widget_add_controller(label, GTK_EVENT_CONTROLLER(click));
}

static void chapters_factory_bind(GtkSignalListItemFactory* factory, GtkListItem* list_item, gpointer user_data) {
    GtkTreeListRow* row = gtk_list_item_get_item(list_item);
    GtkTreeExpander* expander = GTK_TREE_EXPANDER(gtk_list_item_get_child(list_item));
    SpdfSidebarItem* item = gtk_tree_list_row_get_item(row);
    GtkLabel* label = GTK_LABEL(gtk_tree_expander_get_child(expander));

    (void)factory;
    (void)user_data;
    gtk_tree_expander_set_list_row(expander, row);
    gtk_label_set_text(label, item->text ? item->text : "");
    gtk_widget_set_tooltip_text(GTK_WIDGET(label), item->text);
    g_object_unref(item);
}

static GListModel* chapters_child_model(gpointer item, gpointer user_data) {
    SpdfSidebarItem* node = item;
    (void)user_data;
    return node->children ? G_LIST_MODEL(g_object_ref(node->children)) : NULL;
}

/* Builds the nested stores for the outline tree using the normalized-level
 * edges from spdf_sidebar_internal.h. Pre-order (document) order is kept:
 * with autoexpand, the flattened row order equals the outline order. */
static GListStore* chapters_build_root(SpdfSidebar* sb, SpdfTab* tab) {
    GListStore* root = g_list_store_new(SPDF_TYPE_SIDEBAR_ITEM);
    GPtrArray* stack = g_ptr_array_new(); // SpdfSidebarItem* per depth, borrowed

    sidebar_cache_ensure(sb, tab);
    for (int i = 0; i < sb->cache_count; ++i) {
        const spdf_outline_item* entry = &tab->outline.items[i];
        int level = sb->cache_levels[i]; // normalized: 0 <= level <= depth
        SpdfSidebarItem* item;
        SpdfSidebarItem* parent;

        g_ptr_array_set_size(stack, level);
        parent = level > 0 ? g_ptr_array_index(stack, level - 1) : NULL;
        item = sidebar_item_new(SPDF_SIDEBAR_ROW_CHAPTER,
                                g_strdup(entry->title && *entry->title ? entry->title : "Untitled"), NULL,
                                entry->page_index, i);
        if (parent) {
            if (!parent->children) parent->children = g_list_store_new(SPDF_TYPE_SIDEBAR_ITEM);
            g_list_store_append(parent->children, item);
        } else {
            g_list_store_append(root, item);
        }
        g_ptr_array_add(stack, item);
        g_object_unref(item);
    }
    g_ptr_array_free(stack, TRUE);
    return root;
}

static void chapters_selection_changed(GObject* selection, GParamSpec* pspec, gpointer user_data) {
    SpdfSidebar* sb = sidebar_for_paned(user_data);
    GtkTreeListRow* row;
    SpdfSidebarItem* item;
    SpdfTab* tab;

    (void)pspec;
    if (!sb || sb->suppress || !sb->win) return;
    row = gtk_single_selection_get_selected_item(GTK_SINGLE_SELECTION(selection));
    if (!row) return;
    item = gtk_tree_list_row_get_item(row);
    tab = spdf_window_current_tab(sb->win);
    if (item && tab && tab->view && item->page >= 0) spdf_doc_view_goto_page(tab->view, item->page);
    g_clear_object(&item);
}

/* Filtered chapters: a FLAT store of the outline entries whose title matches
 * the filter text (Mac filters the flattened sidebar table the same way). */
static GListStore* chapters_build_filtered(SpdfSidebar* sb, SpdfTab* tab) {
    GListStore* root = g_list_store_new(SPDF_TYPE_SIDEBAR_ITEM);

    sidebar_cache_ensure(sb, tab);
    for (int i = 0; i < sb->cache_count; ++i) {
        const spdf_outline_item* entry = &tab->outline.items[i];
        SpdfSidebarItem* item;

        if (!spdf_sidebar_filter_matches(entry->title, sb->filter_text)) continue;
        item = sidebar_item_new(SPDF_SIDEBAR_ROW_CHAPTER,
                                g_strdup(entry->title && *entry->title ? entry->title : "Untitled"), NULL,
                                entry->page_index, i);
        g_list_store_append(root, item);
        g_object_unref(item);
    }
    return root;
}

/* Click-to-jump regardless of selection state (Mac activateSidebarRow):
 * notify::selected alone misses clicks on the row that is ALREADY selected —
 * chapters_follow_page keeps the current chapter highlighted, so "click the
 * chapter I'm in to go back to its start" was a dead click. */
static void chapters_row_activated(GtkListView* view, guint position, gpointer user_data) {
    SpdfSidebar* sb = sidebar_for_paned(user_data);
    GtkTreeListRow* row;
    SpdfSidebarItem* item;
    SpdfTab* tab;

    (void)view;
    if (!sb || !sb->win || !sb->chapters_sel) return;
    row = g_list_model_get_item(G_LIST_MODEL(sb->chapters_sel), position);
    if (!row) return;
    item = gtk_tree_list_row_get_item(row);
    tab = spdf_window_current_tab(sb->win);
    if (item && tab && tab->view && item->page >= 0) spdf_doc_view_goto_page(tab->view, item->page);
    g_clear_object(&item);
    g_object_unref(row);
}

/* Per-row bubble-phase click: fires whether or not the click changed the
 * selection, covering the already-selected row (see chapters_factory_setup). */
static void chapters_row_clicked(GtkGestureClick* gesture, int n_press, double x, double y, gpointer user_data) {
    GtkWidget* label = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(gesture));
    GtkTreeExpander* expander = g_object_get_data(G_OBJECT(label), "chapter-expander");
    SpdfSidebar* sb = sidebar_for_paned(user_data);
    GtkTreeListRow* row;
    SpdfSidebarItem* item;
    SpdfTab* tab;

    (void)n_press;
    (void)x;
    (void)y;
    if (!sb || !sb->win || !expander) return;
    row = gtk_tree_expander_get_list_row(expander);
    if (!row) return;
    item = gtk_tree_list_row_get_item(row);
    tab = spdf_window_current_tab(sb->win);
    if (item && tab && tab->view && item->page >= 0) spdf_doc_view_goto_page(tab->view, item->page);
    g_clear_object(&item);
}

static void chapters_rebuild(SpdfSidebar* sb, SpdfTab* tab) {
    GListStore* root;
    GtkTreeListModel* tree;
    gboolean filtering = sb->filter_text && *sb->filter_text;

    sb->chapters_tab = tab;
    g_clear_object(&sb->chapters_sel);
    if (!tab || !tab_ensure_outline(tab)) {
        gtk_list_view_set_model(sb->chapters_view, NULL);
        gtk_stack_set_visible_child_name(sb->chapters_pane, "empty");
        return;
    }
    root = filtering ? chapters_build_filtered(sb, tab) : chapters_build_root(sb, tab);
    tree = gtk_tree_list_model_new(G_LIST_MODEL(root), FALSE, TRUE, chapters_child_model, NULL, NULL);
    sb->chapters_sel = gtk_single_selection_new(G_LIST_MODEL(tree));
    gtk_single_selection_set_autoselect(sb->chapters_sel, FALSE);
    gtk_single_selection_set_can_unselect(sb->chapters_sel, TRUE);
    gtk_single_selection_set_selected(sb->chapters_sel, GTK_INVALID_LIST_POSITION);
    g_signal_connect_object(sb->chapters_sel, "notify::selected", G_CALLBACK(chapters_selection_changed), sb->paned,
                            0);
    gtk_list_view_set_model(sb->chapters_view, GTK_SELECTION_MODEL(sb->chapters_sel));
    gtk_stack_set_visible_child_name(sb->chapters_pane, "list");
}

/* Follow the reading position: select (and reveal) the chapter the page falls
 * under. Collapsed subtrees are left alone — the row is simply not found. */
static void chapters_follow_page(SpdfSidebar* sb, SpdfTab* tab, int page) {
    int target;
    guint n;

    if (!sb->chapters_sel || sb->chapters_tab != tab) return;
    sidebar_cache_ensure(sb, tab);
    if (sb->cache_count <= 0) return;
    target = spdf_sidebar_outline_index_for_page(sb->cache_pages, sb->cache_levels, sb->cache_count, page);
    if (target < 0) {
        sb->suppress = TRUE;
        gtk_single_selection_set_selected(sb->chapters_sel, GTK_INVALID_LIST_POSITION);
        sb->suppress = FALSE;
        return;
    }
    n = g_list_model_get_n_items(G_LIST_MODEL(sb->chapters_sel));
    for (guint pos = 0; pos < n; ++pos) {
        GtkTreeListRow* row = g_list_model_get_item(G_LIST_MODEL(sb->chapters_sel), pos);
        SpdfSidebarItem* item = gtk_tree_list_row_get_item(row);
        gboolean hit = item && item->index == target;
        g_clear_object(&item);
        g_object_unref(row);
        if (hit) {
            sb->suppress = TRUE;
            gtk_single_selection_set_selected(sb->chapters_sel, pos);
            gtk_list_view_scroll_to(sb->chapters_view, pos, GTK_LIST_SCROLL_NONE, NULL);
            sb->suppress = FALSE;
            return;
        }
    }
}

static void sidebar_page_changed(SpdfDocView* view, int page, gpointer user_data) {
    SpdfSidebar* sb = sidebar_for_paned(user_data);
    SpdfTab* tab;
    (void)view;
    if (!sb || !sb->win || !gtk_widget_get_visible(sb->panel)) return;
    tab = spdf_window_current_tab(sb->win);
    if (tab && tab->view == view) chapters_follow_page(sb, tab, page);
}

// ---------------------------------------------------------------------------
// Comments pane

static void comments_row_activated(GtkListBox* list, GtkListBoxRow* row, gpointer user_data) {
    SpdfSidebar* sb = sidebar_for_paned(user_data);
    SpdfTab* tab;
    int page;
    spdf_rect* bounds;

    (void)list;
    if (!sb || !sb->win) return;
    tab = spdf_window_current_tab(sb->win);
    if (!tab || !tab->view) return;
    page = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(row), "comment-page"));
    bounds = g_object_get_data(G_OBJECT(row), "comment-bounds");
    if (page < 0) return;
    if (bounds) spdf_doc_view_scroll_to_match(tab->view, page, bounds); // centers the annotation
    else spdf_doc_view_goto_page(tab->view, page);
}

static void comments_rebuild(SpdfSidebar* sb, SpdfTab* tab) {
    sb->comments_tab = tab;
    gtk_list_box_remove_all(sb->comments_list);
    if (!tab || !tab->comments_loaded) return; // placeholder shows; annot hook re-fires once loaded
    for (int i = 0; i < tab->comments.count; ++i) {
        const spdf_comment_item* item = &tab->comments.items[i];
        const char* body = item->text && *item->text ? item->text : (item->type && *item->type ? item->type : "Comment");
        char* title = item->author && *item->author ? g_strdup_printf("%s: %s", item->author, body) : g_strdup(body);
        char* subtitle = g_strdup_printf("Page %d", item->page_index + 1);
        GtkWidget* row = gtk_list_box_row_new();
        GtkWidget* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
        GtkWidget* title_label = gtk_label_new(title);
        GtkWidget* subtitle_label = gtk_label_new(subtitle);
        float w = item->bounds.x1 - item->bounds.x0;
        float h = item->bounds.y1 - item->bounds.y0;

        gtk_label_set_xalign(GTK_LABEL(title_label), 0.0f);
        gtk_label_set_ellipsize(GTK_LABEL(title_label), PANGO_ELLIPSIZE_END);
        gtk_widget_set_tooltip_text(title_label, title);
        gtk_label_set_xalign(GTK_LABEL(subtitle_label), 0.0f);
        gtk_widget_add_css_class(subtitle_label, "dim-label");
        gtk_widget_add_css_class(subtitle_label, "caption");
        gtk_widget_set_margin_top(box, 4);
        gtk_widget_set_margin_bottom(box, 4);
        gtk_box_append(GTK_BOX(box), title_label);
        gtk_box_append(GTK_BOX(box), subtitle_label);
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), box);
        g_object_set_data(G_OBJECT(row), "comment-page", GINT_TO_POINTER(item->page_index));
        g_object_set_data_full(G_OBJECT(row), "comment-filter-text", g_strdup(title), g_free);
        if (w > 0 && h > 0)
            g_object_set_data_full(G_OBJECT(row), "comment-bounds", g_memdup2(&item->bounds, sizeof(item->bounds)),
                                   g_free);
        gtk_list_box_append(sb->comments_list, row);
        g_free(subtitle);
        g_free(title);
    }
}

/* Mac filters comments through the same field ("Filter Comments"). */
static gboolean comments_filter_func(GtkListBoxRow* row, gpointer user_data) {
    SpdfSidebar* sb = sidebar_for_paned(user_data);
    const char* text = g_object_get_data(G_OBJECT(row), "comment-filter-text");
    if (!sb) return TRUE;
    return spdf_sidebar_filter_matches(text, sb->filter_text);
}

/* spdf_annot.h comments-changed hook: fired after any (re)load of a tab's
 * comment cache — initial idle load, CRUD, save-as retarget, reload. */
static void sidebar_comments_changed(SpdfTab* tab, gpointer user_data) {
    SpdfSidebar* sb = tab && tab->win ? sidebar_for_window(tab->win) : NULL;
    (void)user_data;
    if (!sb || !sb->win) return;
    if (spdf_window_current_tab(sb->win) == tab && gtk_widget_get_visible(sb->panel)) comments_rebuild(sb, tab);
    else if (sb->comments_tab == tab) sb->comments_tab = NULL; // stale; rebuilt on next sync
}

// ---------------------------------------------------------------------------
// Search results pane

static void results_row_clicked(GtkGestureClick* gesture, int n_press, double x, double y, gpointer user_data);

static void results_factory_setup(GtkSignalListItemFactory* factory, GtkListItem* list_item, gpointer user_data) {
    GtkWidget* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    GtkWidget* title = gtk_label_new("");
    GtkWidget* subtitle = gtk_label_new("");
    GtkGesture* click = gtk_gesture_click_new();

    (void)factory;
    // Same already-selected-row click handling as the chapters pane (the
    // bound item is stored on the box in results_factory_bind).
    g_signal_connect(click, "released", G_CALLBACK(results_row_clicked), user_data);
    gtk_widget_add_controller(box, GTK_EVENT_CONTROLLER(click));
    gtk_label_set_xalign(GTK_LABEL(title), 0.0f);
    gtk_label_set_ellipsize(GTK_LABEL(title), PANGO_ELLIPSIZE_END);
    gtk_label_set_xalign(GTK_LABEL(subtitle), 0.0f);
    gtk_label_set_ellipsize(GTK_LABEL(subtitle), PANGO_ELLIPSIZE_END);
    gtk_widget_add_css_class(subtitle, "dim-label");
    gtk_widget_add_css_class(subtitle, "caption");
    gtk_widget_set_margin_top(box, 3);
    gtk_widget_set_margin_bottom(box, 3);
    gtk_box_append(GTK_BOX(box), title);
    gtk_box_append(GTK_BOX(box), subtitle);
    gtk_list_item_set_child(list_item, box);
    g_object_set_data(G_OBJECT(box), "title-label", title);
    g_object_set_data(G_OBJECT(box), "subtitle-label", subtitle);
}

static void results_factory_bind(GtkSignalListItemFactory* factory, GtkListItem* list_item, gpointer user_data) {
    SpdfSidebarItem* item = gtk_list_item_get_item(list_item);
    GtkWidget* box = gtk_list_item_get_child(list_item);
    GtkLabel* title = g_object_get_data(G_OBJECT(box), "title-label");
    GtkLabel* subtitle = g_object_get_data(G_OBJECT(box), "subtitle-label");
    gboolean header = item->kind == SPDF_SIDEBAR_ROW_HEADER;

    (void)factory;
    (void)user_data;
    gtk_list_item_set_selectable(list_item, !header);
    gtk_list_item_set_activatable(list_item, !header);
    // Borrowed pointer for results_row_clicked; rebinding overwrites it and
    // headers clear it (their clicks must not navigate).
    g_object_set_data(G_OBJECT(box), "result-item", header ? NULL : item);
    if (header) {
        gtk_label_set_text(title, item->text ? item->text : "");
        gtk_widget_add_css_class(GTK_WIDGET(title), "heading");
        gtk_widget_set_margin_top(box, 8);
    } else {
        gtk_label_set_markup(title, item->text ? item->text : "");
        gtk_widget_remove_css_class(GTK_WIDGET(title), "heading");
        gtk_widget_set_margin_top(box, 3);
    }
    gtk_label_set_text(subtitle, item->subtitle ? item->subtitle : "");
    gtk_widget_set_visible(GTK_WIDGET(subtitle), !header && item->subtitle != NULL);
}

static void results_selection_changed(GObject* selection, GParamSpec* pspec, gpointer user_data) {
    SpdfSidebar* sb = sidebar_for_paned(user_data);
    SpdfSidebarItem* item;
    SpdfTab* tab;

    (void)pspec;
    if (!sb || sb->suppress || !sb->win) return;
    item = gtk_single_selection_get_selected_item(GTK_SINGLE_SELECTION(selection));
    if (!item || item->kind != SPDF_SIDEBAR_ROW_MATCH) return;
    tab = spdf_window_current_tab(sb->win);
    if (tab && tab->search) spdf_search_controller_set_current(tab->search, item->index);
}

/* Same click-to-jump rule as the chapters pane: re-clicking the currently
 * selected match re-centers it. */
static void results_row_activated(GtkListView* view, guint position, gpointer user_data) {
    SpdfSidebar* sb = sidebar_for_paned(user_data);
    SpdfSidebarItem* item;
    SpdfTab* tab;

    (void)view;
    if (!sb || !sb->win || !sb->results_store) return;
    item = g_list_model_get_item(G_LIST_MODEL(sb->results_store), position);
    if (item && item->kind == SPDF_SIDEBAR_ROW_MATCH) {
        tab = spdf_window_current_tab(sb->win);
        if (tab && tab->search) spdf_search_controller_set_current(tab->search, item->index);
    }
    g_clear_object(&item);
}

/* Per-row bubble-phase click (see results_factory_setup). */
static void results_row_clicked(GtkGestureClick* gesture, int n_press, double x, double y, gpointer user_data) {
    GtkWidget* box = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(gesture));
    SpdfSidebarItem* item = g_object_get_data(G_OBJECT(box), "result-item");
    SpdfSidebar* sb = sidebar_for_paned(user_data);
    SpdfTab* tab;

    (void)n_press;
    (void)x;
    (void)y;
    if (!sb || !sb->win || !item || item->kind != SPDF_SIDEBAR_ROW_MATCH) return;
    tab = spdf_window_current_tab(sb->win);
    if (tab && tab->search) spdf_search_controller_set_current(tab->search, item->index);
}

static void results_reset(SpdfSidebar* sb) {
    g_list_store_remove_all(sb->results_store);
    g_array_set_size(sb->match_rows, 0);
    sb->results_built = 0;
    sb->results_total = 0;
    sb->results_prev_chapter = SPDF_SIDEBAR_NO_CHAPTER;
}

static void results_show_status(SpdfSidebar* sb, const char* text) {
    gtk_label_set_text(sb->results_empty, text);
    gtk_stack_set_visible_child_name(sb->results_pane, "empty");
}

static void results_select_current(SpdfSidebar* sb, int current) {
    guint pos;
    if (!sb->results_sel) return;
    sb->suppress = TRUE;
    if (current < 0 || (guint)current >= sb->match_rows->len) {
        gtk_single_selection_set_selected(sb->results_sel, GTK_INVALID_LIST_POSITION);
    } else {
        pos = g_array_index(sb->match_rows, guint, current);
        gtk_single_selection_set_selected(sb->results_sel, pos);
        gtk_list_view_scroll_to(sb->results_view, pos, GTK_LIST_SCROLL_NONE, NULL);
    }
    sb->suppress = FALSE;
}

/* Rebuild or extend the results list from the controller's match list.
 * Append-only while a search streams batches in; a changed query or a
 * shrunken list rebuilds from scratch. A freshly changed query also switches
 * the panel to the search pane (Mac sidebar auto-enters search mode). */
/* Append match rows [sb->results_built, count). Title: the match line cut to
 * the Mac's word window (2 words each side, spdf_sidebar_snippet_window) with
 * the query bolded; subtitle: Mac's "Page N - match I of TOTAL". */
static void results_append(SpdfSidebar* sb, SpdfSearchController* ctrl, const char* query, guint count,
                           gboolean has_outline) {
    // Building from scratch stamps every subtitle with the same total; later
    // appends leave results_total at the older value, which flags the list
    // for the settle-time rebuild in results_sync.
    if (sb->results_built == 0) sb->results_total = count;
    for (guint i = sb->results_built; i < count; ++i) {
        SpdfSearchMatch match;
        GArray* rows;
        if (!spdf_search_controller_match(ctrl, i, &match)) break;
        rows = g_array_new(FALSE, FALSE, sizeof(SpdfSidebarGroupRow));
        spdf_sidebar_group_append(rows, &sb->results_prev_chapter, match.chapter_index, has_outline, (int)i);
        for (guint r = 0; r < rows->len; ++r) {
            const SpdfSidebarGroupRow* row = &g_array_index(rows, SpdfSidebarGroupRow, r);
            SpdfSidebarItem* item;
            if (row->is_header) {
                const char* title = spdf_sidebar_chapter_title(sb->cache_titles, sb->cache_count, row->value);
                item = sidebar_item_new(SPDF_SIDEBAR_ROW_HEADER, g_strdup(title), NULL, -1, row->value);
            } else {
                guint pos = g_list_model_get_n_items(G_LIST_MODEL(sb->results_store));
                char* window = spdf_sidebar_snippet_window(match.snippet, query);
                item = sidebar_item_new(SPDF_SIDEBAR_ROW_MATCH, spdf_sidebar_snippet_markup(window, query),
                                        g_strdup_printf("Page %d - match %d of %d", match.page + 1, row->value + 1,
                                                        (int)count),
                                        match.page, row->value);
                g_free(window);
                g_array_append_val(sb->match_rows, pos);
            }
            g_list_store_append(sb->results_store, item);
            g_object_unref(item);
        }
        g_array_free(rows, TRUE);
    }
    sb->results_built = count;
}

static void results_sync(SpdfSidebar* sb, SpdfTab* tab, SpdfSearchController* ctrl) {
    const char* query = ctrl ? spdf_search_controller_get_query(ctrl) : "";
    gboolean switch_to_search = FALSE;
    gboolean has_outline;
    guint count;

    if (!ctrl || !*query) {
        results_reset(sb);
        g_clear_pointer(&sb->results_query, g_free);
        results_show_status(sb, "No search results");
        if (g_strcmp0(adw_view_stack_get_visible_child_name(sb->stack), "search") == 0)
            adw_view_stack_set_visible_child_name(sb->stack, "chapters");
        return;
    }
    if (g_strcmp0(query, sb->results_query) != 0) {
        results_reset(sb);
        g_free(sb->results_query);
        sb->results_query = g_strdup(query);
        switch_to_search = TRUE;
    }
    count = spdf_search_controller_match_count(ctrl);
    if (count < sb->results_built) results_reset(sb); // same query re-ran
    sidebar_cache_ensure(sb, tab);
    has_outline = sb->cache_count > 0;

    results_append(sb, ctrl, query, count, has_outline);
    // Mac subtitles read "match i of N" with N rebuilt on every update; rows
    // appended mid-stream carry the count as of their batch, so once the
    // search settles rebuild the list with the final total stamped on all.
    if (!spdf_search_controller_is_searching(ctrl) && count > 0 && sb->results_total != count) {
        results_reset(sb);
        results_append(sb, ctrl, query, count, has_outline);
    }

    if (count == 0) {
        char* status;
        if (spdf_search_controller_is_searching(ctrl)) status = g_strdup_printf("Searching for “%s”…", query);
        else if (spdf_search_controller_error(ctrl)) status = g_strdup(spdf_search_controller_error(ctrl));
        else status = g_strdup_printf("No matches for “%s”", query);
        results_show_status(sb, status);
        g_free(status);
    } else {
        gtk_stack_set_visible_child_name(sb->results_pane, "list");
        results_select_current(sb, spdf_search_controller_current(ctrl));
    }
    if (switch_to_search) adw_view_stack_set_visible_child_name(sb->stack, "search");
}

static void sidebar_on_matches(SpdfSearchController* ctrl, gpointer user_data) {
    SpdfSidebar* sb = sidebar_for_paned(user_data);
    SpdfTab* tab;
    if (!sb || !sb->win || !gtk_widget_get_visible(sb->panel)) return;
    tab = spdf_window_current_tab(sb->win);
    if (tab && tab->search == ctrl) results_sync(sb, tab, ctrl);
}

static void sidebar_on_current(SpdfSearchController* ctrl, int index, gpointer user_data) {
    SpdfSidebar* sb = sidebar_for_paned(user_data);
    SpdfTab* tab;
    if (!sb || !sb->win || !gtk_widget_get_visible(sb->panel)) return;
    tab = spdf_window_current_tab(sb->win);
    if (tab && tab->search == ctrl) results_select_current(sb, index);
}

// ---------------------------------------------------------------------------
// Panel width persistence (settings "sidebarWidth", clamped 140–560)

static void sidebar_apply_width(SpdfSidebar* sb) {
    SpdfState* state = state_for_sidebar(sb);
    int width = state ? spdf_state_settings(state)->sidebar_width : SPDF_SIDEBAR_MIN_WIDTH;
    gtk_paned_set_position(sb->paned, CLAMP(width, SPDF_SIDEBAR_MIN_WIDTH, SPDF_SIDEBAR_MAX_WIDTH));
}

static void sidebar_position_changed(GObject* paned, GParamSpec* pspec, gpointer user_data) {
    SpdfSidebar* sb = sidebar_for_paned(paned);
    SpdfState* state;
    int position;
    int clamped;

    (void)pspec;
    (void)user_data;
    if (!sb || !gtk_widget_get_visible(sb->panel)) return; // collapsed: position is not a width
    position = gtk_paned_get_position(sb->paned);
    clamped = CLAMP(position, SPDF_SIDEBAR_MIN_WIDTH, SPDF_SIDEBAR_MAX_WIDTH);
    if (clamped != position) {
        gtk_paned_set_position(sb->paned, clamped); // re-enters once, then equal
        return;
    }
    state = state_for_sidebar(sb);
    if (state && spdf_state_settings(state)->sidebar_width != clamped) {
        spdf_state_settings(state)->sidebar_width = clamped;
        spdf_state_save_settings(state); // coalesced write
    }
}

// ---------------------------------------------------------------------------
// win.sidebar action + sync

static void sidebar_set_action_state(SpdfSidebar* sb, gboolean visible) {
    GAction* action = sb->win ? g_action_map_lookup_action(G_ACTION_MAP(sb->win), "sidebar") : NULL;
    if (action) g_simple_action_set_state(G_SIMPLE_ACTION(action), g_variant_new_boolean(visible));
}

static void sidebar_change_state(GSimpleAction* action, GVariant* value, gpointer user_data) {
    SpdfSidebar* sb = sidebar_for_paned(user_data);
    gboolean visible = g_variant_get_boolean(value);
    SpdfTab* tab;

    if (!sb || !sb->win) return;
    tab = spdf_window_current_tab(sb->win);
    if (!tab) {
        g_simple_action_set_state(action, g_variant_new_boolean(FALSE));
        return;
    }
    g_simple_action_set_state(action, value);
    tab->sidebar_visible = visible;
    tab->sidebar_resolved = TRUE;
    sidebar_persist_visibility(sb, tab, visible);
    gtk_widget_set_visible(sb->panel, visible && !spdf_window_get_presentation(sb->win));
    if (visible) sidebar_apply_width(sb);
    sidebar_schedule_sync(sb); // populate off the toggle's paint path
}

static gboolean sidebar_sync_idle(gpointer user_data) {
    SpdfSidebar* sb = sidebar_for_paned(user_data);
    SpdfTab* tab;
    SpdfSearchController* ctrl;
    SpdfDocView* view;
    gboolean visible;

    if (!sb) return G_SOURCE_REMOVE; // paned outlived its window teardown
    sb->sync_idle_id = 0;
    if (!sb->win) return G_SOURCE_REMOVE;

    tab = spdf_window_current_tab(sb->win);
    visible = tab && sidebar_tab_visible(sb, tab) && !spdf_window_get_presentation(sb->win);
    sidebar_set_action_state(sb, tab ? sidebar_tab_visible(sb, tab) : FALSE);
    if (visible) sidebar_apply_width(sb);
    gtk_widget_set_visible(sb->panel, visible);

    // Track the current doc view's page-changed for the chapters pane.
    view = tab ? tab->view : NULL;
    if (sb->page_view != view) {
        if (sb->page_view) {
            g_signal_handlers_disconnect_by_func(sb->page_view, sidebar_page_changed, sb->paned);
            g_object_remove_weak_pointer(G_OBJECT(sb->page_view), (gpointer*)&sb->page_view);
        }
        sb->page_view = view;
        if (view) {
            g_object_add_weak_pointer(G_OBJECT(view), (gpointer*)&sb->page_view);
            g_signal_connect_object(view, "page-changed", G_CALLBACK(sidebar_page_changed), sb->paned, 0);
        }
    }

    // Track the current tab's search controller (SearchUi pattern).
    ctrl = tab ? tab->search : NULL;
    if (sb->connected != ctrl) {
        if (sb->connected) {
            g_signal_handlers_disconnect_by_data(sb->connected, sb->paned);
            g_object_remove_weak_pointer(G_OBJECT(sb->connected), (gpointer*)&sb->connected);
        }
        sb->connected = ctrl;
        if (ctrl) {
            g_object_add_weak_pointer(G_OBJECT(ctrl), (gpointer*)&sb->connected);
            g_signal_connect_object(ctrl, "matches-changed", G_CALLBACK(sidebar_on_matches), sb->paned, 0);
            g_signal_connect_object(ctrl, "current-changed", G_CALLBACK(sidebar_on_current), sb->paned, 0);
        }
        // Force a results rebuild for the new controller.
        g_clear_pointer(&sb->results_query, g_free);
        results_reset(sb);
    }

    if (!visible) {
        if (!tab) { // window emptied: drop stale pane content
            chapters_rebuild(sb, NULL);
            comments_rebuild(sb, NULL);
            results_sync(sb, NULL, NULL);
            sidebar_cache_clear(sb);
        }
        return G_SOURCE_REMOVE;
    }

    if (sb->chapters_tab != tab) chapters_rebuild(sb, tab);
    if (sb->comments_tab != tab) comments_rebuild(sb, tab);
    results_sync(sb, tab, ctrl);
    if (tab && tab->view) chapters_follow_page(sb, tab, spdf_doc_view_current_page(tab->view));
    return G_SOURCE_REMOVE;
}

static void sidebar_tabs_changed(GObject* object, GParamSpec* pspec, gpointer user_data) {
    SpdfSidebar* sb = sidebar_for_paned(user_data);
    (void)object;
    (void)pspec;
    if (sb) sidebar_schedule_sync(sb);
}

// "page-attached" has its own signature (view, page, position, user_data) —
// it must NOT share the notify:: handler above or user_data lands on the
// position argument.
static void sidebar_page_attached(AdwTabView* view, AdwTabPage* page, int position, gpointer user_data) {
    SpdfSidebar* sb = sidebar_for_paned(user_data);
    (void)view;
    (void)page;
    (void)position;
    if (sb) sidebar_schedule_sync(sb);
}

static void sidebar_fullscreen_changed(GObject* object, GParamSpec* pspec, gpointer user_data) {
    SpdfSidebar* sb = sidebar_for_paned(user_data);
    (void)object;
    (void)pspec;
    if (sb) sidebar_schedule_sync(sb); // presentation mode hides the panel
}

// ---------------------------------------------------------------------------
// Filter field (Mac _sidebarFilterField)

static void sidebar_filter_changed(GtkSearchEntry* entry, gpointer user_data) {
    SpdfSidebar* sb = sidebar_for_paned(user_data);
    const char* text;

    if (!sb) return;
    text = gtk_editable_get_text(GTK_EDITABLE(entry));
    g_free(sb->filter_text);
    sb->filter_text = text && *text ? g_utf8_casefold(text, -1) : NULL;
    // Chapters get a rebuilt (flat) model; comments just re-run the filter.
    chapters_rebuild(sb, sb->win ? spdf_window_current_tab(sb->win) : NULL);
    gtk_list_box_invalidate_filter(sb->comments_list);
}

/* Placeholder follows the visible pane (Mac swaps "Filter Chapters" /
 * "Filter Comments"); the search-results pane has its own query, so the
 * filter row hides there. Also keeps the segmented switcher in sync when the
 * pane changes programmatically (search opening the results pane). */
static void sidebar_filter_pane_changed(GObject* stack, GParamSpec* pspec, gpointer user_data) {
    SpdfSidebar* sb = sidebar_for_paned(user_data);
    const char* name;

    (void)pspec;
    if (!sb || !sb->filter_entry) return;
    name = adw_view_stack_get_visible_child_name(ADW_VIEW_STACK(stack));
    gtk_widget_set_visible(sb->filter_entry, g_strcmp0(name, "search") != 0);
    g_object_set(sb->filter_entry, "placeholder-text",
                 g_strcmp0(name, "comments") == 0 ? "Filter Comments" : "Filter Chapters", NULL);
    for (int i = 0; i < 3; ++i) {
        GtkToggleButton* btn = sb->pane_buttons[i];
        if (!btn) continue;
        if (g_strcmp0(g_object_get_data(G_OBJECT(btn), "pane-name"), name) == 0 &&
            !gtk_toggle_button_get_active(btn))
            gtk_toggle_button_set_active(btn, TRUE);
    }
}

/* Segmented-control toggle -> stack pane. Setting the same visible child
 * twice is a no-op, so the sync back through the notify handler above cannot
 * recurse. */
static void sidebar_pane_button_toggled(GtkToggleButton* btn, gpointer user_data) {
    SpdfSidebar* sb = sidebar_for_paned(user_data);

    if (!sb || !gtk_toggle_button_get_active(btn)) return;
    adw_view_stack_set_visible_child_name(sb->stack, g_object_get_data(G_OBJECT(btn), "pane-name"));
}

// ---------------------------------------------------------------------------
// Construction

/* GtkStack pane: "list" = scrolled list widget, "empty" = dim status label.
 * *empty_out receives the label so panes can update their status text. */
static GtkWidget* sidebar_pane_new(GtkWidget* list, const char* empty_text, GtkLabel** empty_out) {
    GtkWidget* stack = gtk_stack_new();
    GtkWidget* scroller = gtk_scrolled_window_new();
    GtkWidget* empty = gtk_label_new(empty_text);

    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroller), list);
    gtk_label_set_wrap(GTK_LABEL(empty), TRUE);
    gtk_label_set_justify(GTK_LABEL(empty), GTK_JUSTIFY_CENTER);
    gtk_widget_add_css_class(empty, "dim-label");
    gtk_widget_set_margin_start(empty, 12);
    gtk_widget_set_margin_end(empty, 12);
    gtk_widget_set_valign(empty, GTK_ALIGN_CENTER);
    gtk_stack_add_named(GTK_STACK(stack), scroller, "list");
    gtk_stack_add_named(GTK_STACK(stack), empty, "empty");
    gtk_stack_set_visible_child_name(GTK_STACK(stack), "empty");
    if (empty_out) *empty_out = GTK_LABEL(empty);
    return stack;
}

static void sidebar_install_css(void) {
    static gboolean installed = FALSE;
    GtkCssProvider* provider;

    if (installed) return;
    installed = TRUE;
    provider = gtk_css_provider_new();
    // Tighten the block under the Chapters/Comments/Results switcher (user
    // report): Adwaita gives .navigation-sidebar lists 6px top padding and
    // 36px-minimum rows, which pushes the first row far below the filter
    // field and double-spaces the list next to the Mac sidebar (25px rows).
    // NOTE: GTK's CSS parser rejects unitless lengths — keep the "px" on
    // zeroes or the whole declaration is silently dropped.
    gtk_css_provider_load_from_string(provider,
                                      ".spdf-sidebar .navigation-sidebar { padding: 2px 0px; }"
                                      ".spdf-sidebar .navigation-sidebar > row {"
                                      "  min-height: 25px; margin: 0px 6px; }");
    gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(provider),
                                               GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(provider);
}

GtkWidget* spdf_sidebar_new(SpdfWindow* win, GtkWidget* content) {
    SpdfSidebar* sb;
    GtkWidget* paned;
    GtkWidget* panel_view;
    GtkWidget* switcher;
    GtkListItemFactory* chapters_factory;
    GtkListItemFactory* results_factory;
    GtkLabel* chapters_empty; // fixed text; pointer unused past construction
    GSimpleAction* action;
    AdwTabView* tab_view;

    g_return_val_if_fail(SPDF_IS_WINDOW(win), content);

    sb = g_new0(SpdfSidebar, 1);
    paned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
    sb->win = win;
    sb->paned = GTK_PANED(paned);
    sb->match_rows = g_array_new(FALSE, FALSE, sizeof(guint));
    sb->results_prev_chapter = SPDF_SIDEBAR_NO_CHAPTER;
    g_object_add_weak_pointer(G_OBJECT(win), (gpointer*)&sb->win);
    g_object_set_qdata_full(G_OBJECT(paned), sidebar_quark(), sb, sidebar_free);
    g_object_set_qdata(G_OBJECT(win), sidebar_quark(), sb);

    // Chapters: outline tree (GtkTreeListModel + GtkListView; GtkTreeView is
    // deprecated in GTK 4.10+).
    chapters_factory = gtk_signal_list_item_factory_new();
    g_signal_connect(chapters_factory, "setup", G_CALLBACK(chapters_factory_setup), paned);
    g_signal_connect(chapters_factory, "bind", G_CALLBACK(chapters_factory_bind), NULL);
    sb->chapters_view = GTK_LIST_VIEW(gtk_list_view_new(NULL, chapters_factory));
    gtk_widget_add_css_class(GTK_WIDGET(sb->chapters_view), "navigation-sidebar");
    // No single-click-activate: it moves the selection on HOVER. Clicks are
    // handled per row (chapters_row_clicked); "activate" covers Enter.
    g_signal_connect_object(sb->chapters_view, "activate", G_CALLBACK(chapters_row_activated), paned, 0);
    sb->chapters_pane =
        GTK_STACK(sidebar_pane_new(GTK_WIDGET(sb->chapters_view), "No chapters in this document", &chapters_empty));

    // Comments: plain list from the tab's comment cache (spdf_annot).
    sb->comments_list = GTK_LIST_BOX(gtk_list_box_new());
    gtk_list_box_set_selection_mode(sb->comments_list, GTK_SELECTION_NONE);
    gtk_widget_add_css_class(GTK_WIDGET(sb->comments_list), "navigation-sidebar");
    gtk_list_box_set_filter_func(sb->comments_list, comments_filter_func, paned, NULL);
    {
        GtkWidget* placeholder = gtk_label_new("No comments in this document");
        gtk_label_set_wrap(GTK_LABEL(placeholder), TRUE);
        gtk_widget_add_css_class(placeholder, "dim-label");
        gtk_widget_set_margin_top(placeholder, 24);
        gtk_widget_set_margin_start(placeholder, 12);
        gtk_widget_set_margin_end(placeholder, 12);
        gtk_list_box_set_placeholder(sb->comments_list, placeholder);
    }
    g_signal_connect(sb->comments_list, "row-activated", G_CALLBACK(comments_row_activated), paned);

    // Search results: chapter-grouped snippets, recycled rows (GtkListView —
    // the match list can hold up to SPDF_SEARCH_MAX_MATCHES rows).
    results_factory = gtk_signal_list_item_factory_new();
    g_signal_connect(results_factory, "setup", G_CALLBACK(results_factory_setup), paned);
    g_signal_connect(results_factory, "bind", G_CALLBACK(results_factory_bind), NULL);
    sb->results_store = g_list_store_new(SPDF_TYPE_SIDEBAR_ITEM);
    sb->results_sel = gtk_single_selection_new(G_LIST_MODEL(g_object_ref(sb->results_store)));
    gtk_single_selection_set_autoselect(sb->results_sel, FALSE);
    gtk_single_selection_set_can_unselect(sb->results_sel, TRUE);
    gtk_single_selection_set_selected(sb->results_sel, GTK_INVALID_LIST_POSITION);
    g_signal_connect_object(sb->results_sel, "notify::selected", G_CALLBACK(results_selection_changed), paned, 0);
    sb->results_view =
        GTK_LIST_VIEW(gtk_list_view_new(GTK_SELECTION_MODEL(g_object_ref(sb->results_sel)), results_factory));
    gtk_widget_add_css_class(GTK_WIDGET(sb->results_view), "navigation-sidebar");
    g_signal_connect_object(sb->results_view, "activate", G_CALLBACK(results_row_activated), paned, 0);
    sb->results_pane =
        GTK_STACK(sidebar_pane_new(GTK_WIDGET(sb->results_view), "No search results", &sb->results_empty));

    // Comments pane needs its own scroller (it is not a GtkListView pane).
    {
        GtkWidget* comments_scroller = gtk_scrolled_window_new();
        gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(comments_scroller), GTK_POLICY_NEVER,
                                       GTK_POLICY_AUTOMATIC);
        gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(comments_scroller), GTK_WIDGET(sb->comments_list));

        sb->stack = ADW_VIEW_STACK(adw_view_stack_new());
        // Text-only pages (like the Mac segmented control): with icons the
        // WIDE switcher ellipsizes all three labels at sidebar width.
        adw_view_stack_add_titled(sb->stack, GTK_WIDGET(sb->chapters_pane), "chapters", "Chapters");
        adw_view_stack_add_titled(sb->stack, comments_scroller, "comments", "Comments");
        adw_view_stack_add_titled(sb->stack, GTK_WIDGET(sb->results_pane), "search", "Results");
    }

    // Mac-style segmented control (linked text-only toggles). AdwViewSwitcher
    // is unusable here: NARROW stacks icon over label (twice the height, the
    // gap the user reported), WIDE ellipsizes labels / shows an icon slot.
    {
        static const struct {
            const char* name;
            const char* label;
        } k_tabs[] = {{"chapters", "Chapters"}, {"comments", "Comments"}, {"search", "Results"}};
        GtkToggleButton* group = NULL;

        switcher = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
        gtk_widget_add_css_class(switcher, "linked");
        gtk_widget_set_halign(switcher, GTK_ALIGN_CENTER);
        for (int i = 0; i < 3; ++i) {
            GtkWidget* btn = gtk_toggle_button_new_with_label(k_tabs[i].label);
            g_object_set_data(G_OBJECT(btn), "pane-name", (gpointer)k_tabs[i].name);
            if (group)
                gtk_toggle_button_set_group(GTK_TOGGLE_BUTTON(btn), group);
            else
                group = GTK_TOGGLE_BUTTON(btn);
            g_signal_connect(btn, "toggled", G_CALLBACK(sidebar_pane_button_toggled), paned);
            gtk_box_append(GTK_BOX(switcher), btn);
            sb->pane_buttons[i] = GTK_TOGGLE_BUTTON(btn);
        }
        gtk_toggle_button_set_active(sb->pane_buttons[0], TRUE); // chapters, like Mac
    }
    gtk_widget_set_margin_top(switcher, 3);
    gtk_widget_set_margin_bottom(switcher, 3);

    sidebar_install_css();
    panel_view = adw_toolbar_view_new();
    gtk_widget_add_css_class(panel_view, "spdf-sidebar");
    adw_toolbar_view_add_top_bar(ADW_TOOLBAR_VIEW(panel_view), switcher);

    // Filter row (Mac _sidebarFilterField under the mode control).
    sb->filter_entry = gtk_search_entry_new();
    g_object_set(sb->filter_entry, "placeholder-text", "Filter Chapters", NULL);
    gtk_widget_set_margin_start(sb->filter_entry, 6);
    gtk_widget_set_margin_end(sb->filter_entry, 6);
    gtk_widget_set_margin_bottom(sb->filter_entry, 3); // list starts right below (Mac)
    g_signal_connect(sb->filter_entry, "search-changed", G_CALLBACK(sidebar_filter_changed), paned);
    g_signal_connect_object(sb->stack, "notify::visible-child", G_CALLBACK(sidebar_filter_pane_changed), paned, 0);
    adw_toolbar_view_add_top_bar(ADW_TOOLBAR_VIEW(panel_view), sb->filter_entry);

    adw_toolbar_view_set_content(ADW_TOOLBAR_VIEW(panel_view), GTK_WIDGET(sb->stack));
    sb->panel = panel_view;
    gtk_widget_set_size_request(sb->panel, SPDF_SIDEBAR_MIN_WIDTH, -1);
    gtk_widget_set_visible(sb->panel, FALSE); // per-document state applies in the sync idle

    gtk_paned_set_start_child(sb->paned, sb->panel);
    gtk_paned_set_end_child(sb->paned, content);
    gtk_paned_set_resize_start_child(sb->paned, FALSE);
    gtk_paned_set_shrink_start_child(sb->paned, FALSE);
    gtk_paned_set_resize_end_child(sb->paned, TRUE);
    gtk_paned_set_shrink_end_child(sb->paned, FALSE);
    g_signal_connect(paned, "notify::position", G_CALLBACK(sidebar_position_changed), NULL);

    // win.sidebar (F9 / header toggle): replaces the Wave A stub.
    action = g_simple_action_new_stateful("sidebar", NULL, g_variant_new_boolean(FALSE));
    g_signal_connect_object(action, "change-state", G_CALLBACK(sidebar_change_state), paned, 0);
    g_action_map_add_action(G_ACTION_MAP(win), G_ACTION(action));
    g_object_unref(action);

    tab_view = spdf_window_get_tab_view(win);
    if (tab_view) {
        g_signal_connect_object(tab_view, "notify::selected-page", G_CALLBACK(sidebar_tabs_changed), paned, 0);
        g_signal_connect_object(tab_view, "page-attached", G_CALLBACK(sidebar_page_attached), paned, 0);
    }
    g_signal_connect_object(win, "notify::fullscreened", G_CALLBACK(sidebar_fullscreen_changed), paned, 0);

    // Live comment refresh after CRUD (spdf_annot.h hook; idempotent).
    spdf_annot_set_comments_changed_hook(sidebar_comments_changed, NULL);

    sidebar_schedule_sync(sb);
    return paned;
}

void spdf_sidebar_tab_closing(SpdfTab* tab) {
    SpdfSidebar* sb;

    if (!tab) return;
    sb = tab->win ? sidebar_for_window(tab->win) : NULL;
    if (sb) {
        if (sb->chapters_tab == tab) {
            gtk_list_view_set_model(sb->chapters_view, NULL);
            g_clear_object(&sb->chapters_sel);
            sb->chapters_tab = NULL;
        }
        if (sb->comments_tab == tab) {
            gtk_list_box_remove_all(sb->comments_list);
            sb->comments_tab = NULL;
        }
        if (sb->cache_tab == tab) sidebar_cache_clear(sb);
        if (sb->page_view && tab->view == sb->page_view) {
            g_signal_handlers_disconnect_by_func(sb->page_view, sidebar_page_changed, sb->paned);
            g_object_remove_weak_pointer(G_OBJECT(sb->page_view), (gpointer*)&sb->page_view);
            sb->page_view = NULL;
        }
        if (sb->connected && tab->search == sb->connected) {
            g_signal_handlers_disconnect_by_data(sb->connected, sb->paned);
            g_object_remove_weak_pointer(G_OBJECT(sb->connected), (gpointer*)&sb->connected);
            sb->connected = NULL;
            results_reset(sb);
            g_clear_pointer(&sb->results_query, g_free);
        }
        sidebar_schedule_sync(sb);
    }
    spdf_free_outline(&tab->outline);
    tab->outline.items = NULL;
    tab->outline.count = 0;
    tab->outline_loaded = FALSE;
}
