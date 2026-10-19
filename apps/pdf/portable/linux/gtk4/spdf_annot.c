// spdf_annot.c — annotations + file operations for the GTK4 shell (Wave B).
// See spdf_annot.h for the module contract and provenance map.
//
// Structure:
//   1. Pure path/preflight logic (glib strings only) — also compiled alone by
//      tests/annot_preflight_test.c via SPDF_ANNOT_TESTING.
//   2. Probing wrappers (g_access) over the pure rules.
//   3. GTK module: comment cache + markers, async dialog flows (AdwAlertDialog
//      / GtkFileDialog — gtk_dialog_run is gone in GTK4), the write preflight
//      chain (journal item 35), Save As retargeting, rotation, single-page
//      export, the doc-view context menu, click-to-edit markers.

#include <string.h>
#include <unistd.h> /* W_OK / X_OK for the g_access probes */

#include <glib/gstdio.h>

#include "spdf_annot.h"

/* ---------------------------------------------------------------------------
 * 1. Pure path/preflight logic. Ports of the GTK3 helpers:
 *    path_has_pdf_extension (@1620), path_is_under_directory (@3410),
 *    path_is_in_temp_directory (@3428), filename_with_pdf_extension (@3444),
 *    copy_page_clicked's name build (@6392), and the verdicts inside
 *    pdf_path_allows_same_folder_write (@3434) /
 *    prompt_save_as_before_modification (@3537). */

gboolean spdf_annot_path_has_pdf_extension(const char* path) {
    const char* dot = path ? strrchr(path, '.') : NULL;
    return dot && g_ascii_strcasecmp(dot, ".pdf") == 0;
}

gboolean spdf_annot_path_is_under_directory(const char* path, const char* directory) {
    char* canonical_path;
    char* canonical_dir;
    gsize dir_len;
    gboolean under;

    if (!path || !*path || !directory || !*directory) return FALSE;
    canonical_path = g_canonicalize_filename(path, NULL);
    canonical_dir = g_canonicalize_filename(directory, NULL);
    dir_len = strlen(canonical_dir);
    under = strcmp(canonical_path, canonical_dir) == 0 ||
            (g_str_has_prefix(canonical_path, canonical_dir) && canonical_path[dir_len] == G_DIR_SEPARATOR);
    g_free(canonical_path);
    g_free(canonical_dir);
    return under;
}

gboolean spdf_annot_path_is_temp_in(const char* path, const char* tmp_dir, const char* runtime_dir) {
    return spdf_annot_path_is_under_directory(path, tmp_dir) || spdf_annot_path_is_under_directory(path, "/tmp") ||
           spdf_annot_path_is_under_directory(path, "/var/tmp") ||
           spdf_annot_path_is_under_directory(path, runtime_dir);
}

char* spdf_annot_filename_with_pdf_extension(const char* path) {
    if (!path || !*path) return NULL;
    if (spdf_annot_path_has_pdf_extension(path)) return g_strdup(path);
    return g_strdup_printf("%s.pdf", path);
}

char* spdf_annot_single_page_filename(const char* doc_path, int page_index) {
    char* base;
    char* dot;
    char* name;

    base = g_path_get_basename(doc_path && *doc_path ? doc_path : "Page");
    dot = strrchr(base, '.');
    if (dot && dot != base) *dot = '\0';
    name = g_strdup_printf("%s - page %d.pdf", base && *base ? base : "Page", page_index + 1);
    g_free(base);
    return name;
}

gboolean spdf_annot_same_folder_write_allowed(gboolean is_temp, gboolean file_writable, gboolean dir_writable) {
    return !is_temp && file_writable && dir_writable;
}

gboolean spdf_annot_save_target_acceptable(const char* path, const char* tmp_dir, const char* runtime_dir) {
    if (!path || !*path || !spdf_annot_path_has_pdf_extension(path)) return FALSE;
    return !spdf_annot_path_is_temp_in(path, tmp_dir, runtime_dir);
}

/* ---------------------------------------------------------------------------
 * 2. Probing wrappers. */

gboolean spdf_annot_path_is_in_temp_directory(const char* path) {
    return spdf_annot_path_is_temp_in(path, g_get_tmp_dir(), g_get_user_runtime_dir());
}

gboolean spdf_annot_pdf_path_allows_same_folder_write(const char* path) {
    char* dir;
    gboolean file_writable;
    gboolean dir_writable;

    if (!path || !*path) return FALSE;
    dir = g_path_get_dirname(path);
    file_writable = g_access(path, W_OK) == 0;
    dir_writable = dir && g_access(dir, W_OK | X_OK) == 0;
    g_free(dir);
    return spdf_annot_same_folder_write_allowed(spdf_annot_path_is_in_temp_directory(path), file_writable,
                                                dir_writable);
}

#ifndef SPDF_ANNOT_TESTING

#include "spdf_app.h"
#include "spdf_minimap.h" /* minimap module (wave B): thumbnail invalidation */
#include "spdf_password_prompt.h"
#include "spdf_watcher.h" /* self-save baseline + Save-As repoint (Wave C) */

#define ANNOT_SELECTION_RECT_MAX 256
#define ANNOT_COMMENT_HIT_SLOP_PT 3.0 /* GTK3 comment_index_at_page_point */
#define ANNOT_BADGE_HIT_SLOP_PT 2.0

/* ---------------------------------------------------------------------------
 * Small shared helpers. */

typedef struct {
    int context_page; /* page under the last right-click, -1 = none */
    double context_x; /* PDF points on context_page */
    double context_y;
    int context_comment_index; /* visible comment index under the click, -1 = none */
} AnnotWinState;

static AnnotWinState* annot_win_state(SpdfWindow* win) {
    AnnotWinState* st = (AnnotWinState*)g_object_get_data(G_OBJECT(win), "spdf-annot-state");
    if (!st) {
        st = g_new0(AnnotWinState, 1);
        st->context_page = -1;
        st->context_comment_index = -1;
        g_object_set_data_full(G_OBJECT(win), "spdf-annot-state", st, g_free);
    }
    return st;
}

static SpdfApp* annot_window_app(SpdfWindow* win) {
    GtkApplication* app = gtk_window_get_application(GTK_WINDOW(win));
    return app && SPDF_IS_APP(app) ? SPDF_APP(app) : NULL;
}

/* Async flows survive tab closes/drag-detaches; before touching a tab after a
 * dialog, verify it still lives in this window. */
static gboolean annot_tab_alive(SpdfWindow* win, SpdfTab* tab) {
    int count;

    if (!win || !tab || !SPDF_IS_WINDOW(win)) return FALSE;
    count = spdf_window_tab_count(win);
    for (int i = 0; i < count; ++i)
        if (spdf_window_tab_at(win, i) == tab) return TRUE;
    return FALSE;
}

static void annot_show_error(SpdfWindow* win, const char* heading, const char* detail) {
    GtkAlertDialog* alert = gtk_alert_dialog_new("%s", heading);
    gtk_alert_dialog_set_detail(alert, detail && *detail ? detail : "Unknown error.");
    gtk_alert_dialog_show(alert, GTK_WINDOW(win));
    g_object_unref(alert);
}

/* Port of current_comment_author + fallback_comment_author: the persisted
 * settings author, else the account's real name, else the login name. */
static const char* annot_current_author(SpdfWindow* win) {
    SpdfApp* app = annot_window_app(win);
    const char* author;

    if (app) {
        SpdfSettings* settings = spdf_state_settings(spdf_app_get_state(app));
        if (settings->comment_author && settings->comment_author[0]) return settings->comment_author;
    }
    author = g_get_real_name();
    if (!author || !*author || strcmp(author, "Unknown") == 0) author = g_get_user_name();
    return author ? author : "";
}

static void annot_set_enabled(SpdfWindow* win, const char* name, gboolean enabled) {
    GAction* action = g_action_map_lookup_action(G_ACTION_MAP(win), name);
    if (action && G_IS_SIMPLE_ACTION(action)) g_simple_action_set_enabled(G_SIMPLE_ACTION(action), enabled);
}

/* ---------------------------------------------------------------------------
 * Comment cache + markers. The tab caches spdf_load_comments output; the doc
 * view draws one badge per comment (snapshot overlay). */

static void annot_push_markers(SpdfTab* tab) {
    GArray* markers;

    if (!tab->view) return;
    markers = g_array_new(FALSE, FALSE, sizeof(SpdfCommentMarker));
    for (int i = 0; i < tab->comments.count; ++i) {
        const spdf_comment_item* item = &tab->comments.items[i];
        SpdfCommentMarker marker;
        if (item->index < 0) continue;
        marker.page = item->page_index;
        marker.bounds = item->bounds;
        g_array_append_val(markers, marker);
    }
    spdf_doc_view_set_comment_markers(tab->view, (const SpdfCommentMarker*)(gpointer)markers->data, (int)markers->len);
    g_array_free(markers, TRUE);
}

/* --- Wave B sidebar coordination (see spdf_annot.h) ----------------------- */
static SpdfAnnotCommentsChanged annot_comments_hook = NULL;
static gpointer annot_comments_hook_data = NULL;

void spdf_annot_set_comments_changed_hook(SpdfAnnotCommentsChanged hook, gpointer user_data) {
    annot_comments_hook = hook;
    annot_comments_hook_data = user_data;
}
/* --------------------------------------------------------------------------- */

static void annot_refresh_comments(SpdfTab* tab) {
    char err[1024] = "";

    spdf_free_comments(&tab->comments); /* zeroes the struct */
    tab->comments_loaded = FALSE;
    if (tab->doc) {
        if (spdf_load_comments(tab->doc, &tab->comments, err, sizeof(err)))
            tab->comments_loaded = TRUE;
        else
            g_warning("shenzhenpdf: could not load comments: %s", err[0] ? err : "unknown error");
    }
    annot_push_markers(tab);
    if (annot_comments_hook) annot_comments_hook(tab, annot_comments_hook_data); /* sidebar refresh */
}

/* Port of comment_index_at_page_point: annotation bounds inflated by 3pt. */
static int annot_comment_at_point(SpdfTab* tab, int page_index, double page_x, double page_y) {
    for (int i = 0; i < tab->comments.count; ++i) {
        const spdf_comment_item* item = &tab->comments.items[i];
        double x0;
        double x1;
        double y0;
        double y1;

        if (item->page_index != page_index || item->index < 0) continue;
        x0 = MIN(item->bounds.x0, item->bounds.x1) - ANNOT_COMMENT_HIT_SLOP_PT;
        x1 = MAX(item->bounds.x0, item->bounds.x1) + ANNOT_COMMENT_HIT_SLOP_PT;
        y0 = MIN(item->bounds.y0, item->bounds.y1) - ANNOT_COMMENT_HIT_SLOP_PT;
        y1 = MAX(item->bounds.y0, item->bounds.y1) + ANNOT_COMMENT_HIT_SLOP_PT;
        if (x1 <= x0 || y1 <= y0) continue;
        if (page_x >= x0 && page_x <= x1 && page_y >= y0 && page_y <= y1) return item->index;
    }
    return -1;
}

/* Click-to-edit hit test: only the marker badge (not the whole annotation, so
 * text selection over a highlight comment still works). */
static int annot_comment_at_badge(SpdfTab* tab, int page_index, double page_x, double page_y) {
    for (int i = 0; i < tab->comments.count; ++i) {
        const spdf_comment_item* item = &tab->comments.items[i];
        spdf_rect badge;
        if (item->page_index != page_index || item->index < 0) continue;
        badge = spdf_comment_marker_badge(&item->bounds);
        if (page_x >= badge.x0 - ANNOT_BADGE_HIT_SLOP_PT && page_x <= badge.x1 + ANNOT_BADGE_HIT_SLOP_PT &&
            page_y >= badge.y0 - ANNOT_BADGE_HIT_SLOP_PT && page_y <= badge.y1 + ANNOT_BADGE_HIT_SLOP_PT)
            return item->index;
    }
    return -1;
}

static const spdf_comment_item* annot_comment_item_for_index(SpdfTab* tab, int comment_index) {
    if (comment_index < 0) return NULL;
    for (int i = 0; i < tab->comments.count; ++i)
        if (tab->comments.items[i].index == comment_index) return &tab->comments.items[i];
    return NULL;
}

/* After any successful write into the document file: drop the render cache
 * (worker docs re-open, keyed on path+mtime+size), relayout the view, reload
 * the comment cache, persist the session. Port of the
 * refresh_comments_after_edit tail. */
static void annot_after_document_write(SpdfTab* tab) {
    SpdfApp* app;

    spdf_password_credential_refresh_source(tab->credential, tab->path);
    if (tab->render) spdf_render_service_invalidate(tab->render);
    if (tab->view) spdf_doc_view_document_changed(tab->view);
    spdf_minimap_document_changed(tab); // minimap module (wave B): stale thumbnails
    annot_refresh_comments(tab);
    /* --- watcher (Wave C): our own write must not read as an external
     * change (Mac refreshActiveTabCachedFileAttributesAfterSelfSave). */
    spdf_watcher_note_self_save(tab);
    app = tab->win ? annot_window_app(tab->win) : NULL;
    if (app) spdf_app_save_session(app);
}

/* --- watcher (Wave C): in-place reload tail --------------------------------
 * The watcher swapped tab->doc for a fresh open after a disk change; only the
 * comment cache/markers need refreshing here (render + view are the
 * watcher's job, and the session did not change). */
void spdf_annot_document_reloaded(SpdfTab* tab) {
    if (!tab) return;
    annot_refresh_comments(tab);
}

/* Full reload of the tab's main-thread document from disk. Rotation follows
 * the GTK3 open_path_at_page semantics (and journal item 39): after a
 * geometry-changing save, re-open rather than trust cached page objects. */
static void annot_reload_document(SpdfWindow* win, SpdfTab* tab, int page) {
    char err[512] = "";
    spdf_document* doc = spdf_password_reopen_after_write(tab->path, tab->path, tab->credential, err, sizeof(err));

    if (doc) {
        if (tab->doc) spdf_close(tab->doc);
        tab->doc = doc;
    } else {
        annot_show_error(win, "Could not reload document", err);
    }
    annot_after_document_write(tab);
    if (tab->view) spdf_doc_view_goto_page(tab->view, page);
}

/* ---------------------------------------------------------------------------
 * Save As + tab retargeting. Port of save_active_pdf_to_path: after a
 * successful save the ACTIVE TAB points at the saved file (path, render
 * pipeline, tab title/tooltip, window title, recents, session). */

static gboolean annot_save_active_pdf_to_path(SpdfWindow* win, SpdfTab* tab, const char* path) {
    char err[1024] = "";
    char* canonical;
    SpdfApp* app;

    if (!tab || !tab->doc || !tab->path || !path || !*path) return FALSE;
    if (!spdf_save_document(tab->doc, path, err, sizeof(err))) {
        annot_show_error(win, "Could not save PDF", err);
        return FALSE;
    }

    canonical = g_canonicalize_filename(path, NULL);
    g_free(tab->path);
    tab->path = canonical;
    spdf_password_credential_refresh_source(tab->credential, tab->path);

    /* Retarget the render pipeline: worker documents key on the service's
     * path, so the new file needs a new service. document_changed orphans the
     * view's in-flight contexts BEFORE the old service is freed — the old
     * service still delivers each done callback exactly once (with NULL),
     * which releases them without touching the view. */
    {
        SpdfRenderService* old = tab->render;
        char* render_error = NULL;
        tab->render = spdf_render_service_new(tab->path, tab->credential, &render_error);
        if (!tab->render)
            g_warning("shenzhenpdf: no render service for %s: %s", tab->path,
                      render_error && *render_error ? render_error : "unknown error");
        g_free(render_error);
        if (tab->view) spdf_doc_view_document_changed(tab->view);
        spdf_minimap_document_changed(tab); // minimap module (wave B): orphan before the old service dies
        if (old) spdf_render_service_free(old);
    }

    if (tab->page) {
        char* title = spdf_tab_display_name(tab);
        char* tooltip = g_markup_escape_text(tab->path, -1);
        adw_tab_page_set_title(tab->page, title);
        adw_tab_page_set_tooltip(tab->page, tooltip);
        g_free(tooltip);
        g_free(title);
    }
    /* --- watcher (Wave C): follow the retarget — the saved file is writable,
     * so any shadow-copy binding is dropped (orange dot cleared) and the
     * monitor re-points at the new path. */
    spdf_watcher_tab_repoint(tab);
    app = annot_window_app(win);
    if (app) spdf_app_remember_recent(app, tab->path);
    spdf_window_update_title(win);
    annot_refresh_comments(tab);
    if (app) spdf_app_save_session(app);
    return TRUE;
}

static GtkFileDialog* annot_pdf_save_dialog(const char* title, const char* current_path) {
    GtkFileDialog* dialog = gtk_file_dialog_new();
    GtkFileFilter* pdf = gtk_file_filter_new();
    GListStore* filters = g_list_store_new(GTK_TYPE_FILE_FILTER);

    gtk_file_dialog_set_title(dialog, title);
    gtk_file_filter_set_name(pdf, "PDF files");
    gtk_file_filter_add_mime_type(pdf, "application/pdf");
    gtk_file_filter_add_suffix(pdf, "pdf");
    g_list_store_append(filters, pdf);
    gtk_file_dialog_set_filters(dialog, G_LIST_MODEL(filters));
    gtk_file_dialog_set_default_filter(dialog, pdf);
    if (current_path && *current_path) {
        char* base = g_path_get_basename(current_path);
        char* dir = g_path_get_dirname(current_path);
        GFile* folder = g_file_new_for_path(dir);
        gtk_file_dialog_set_initial_name(dialog, base && *base ? base : "document.pdf");
        gtk_file_dialog_set_initial_folder(dialog, folder);
        g_object_unref(folder);
        g_free(dir);
        g_free(base);
    }
    g_object_unref(filters);
    g_object_unref(pdf);
    return dialog;
}

typedef struct {
    SpdfWindow* win; /* ref held */
    SpdfTab* tab;
} annot_save_as_ctx;

static void annot_save_as_finished(GObject* source, GAsyncResult* result, gpointer user_data) {
    annot_save_as_ctx* ctx = (annot_save_as_ctx*)user_data;
    GError* error = NULL;
    GFile* file = gtk_file_dialog_save_finish(GTK_FILE_DIALOG(source), result, &error);

    g_clear_error(&error); /* dismissal is not an error worth reporting */
    if (file) {
        char* raw = g_file_get_path(file);
        char* path = spdf_annot_filename_with_pdf_extension(raw);
        if (path && annot_tab_alive(ctx->win, ctx->tab)) annot_save_active_pdf_to_path(ctx->win, ctx->tab, path);
        g_free(path);
        g_free(raw);
        g_object_unref(file);
    }
    g_object_unref(ctx->win);
    g_free(ctx);
}

static void action_save_as(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = spdf_window_current_tab(win);
    annot_save_as_ctx* ctx;
    GtkFileDialog* dialog;

    (void)action;
    (void)parameter;
    if (!tab || !tab->doc || !tab->path || !spdf_annot_path_has_pdf_extension(tab->path)) return;
    if (!spdf_password_require_permission(GTK_WINDOW(win), tab->doc, 'c', "Save As is not allowed")) return;
    ctx = g_new0(annot_save_as_ctx, 1);
    ctx->win = g_object_ref(win);
    ctx->tab = tab;
    dialog = annot_pdf_save_dialog("Save PDF As", tab->path);
    gtk_file_dialog_save(dialog, GTK_WINDOW(win), NULL, annot_save_as_finished, ctx);
    g_object_unref(dialog);
}

/* ---------------------------------------------------------------------------
 * Write preflight (port of prompt_save_as_before_modification, async CPS
 * form). Every operation that writes the PDF back runs through here: when the
 * file is read-only or in a temp folder, the user must first Save As to a
 * writable, non-temp location; the tab is retargeted there and the operation
 * continues against the new path. Public entry point: spdf_annot_preflight
 * (spdf_annot.h) — OCR/translate (Wave C) must run through the same gate. */

typedef struct {
    SpdfWindow* win; /* ref held */
    SpdfTab* tab;
    char* action_name;
    SpdfAnnotContinuation cont; /* takes ownership of data when invoked */
    gpointer data;
    GDestroyNotify data_destroy; /* runs when the flow is abandoned instead */
} annot_preflight;

static void annot_preflight_save_dialog(annot_preflight* pf);

static void annot_preflight_abandon(annot_preflight* pf) {
    if (pf->data_destroy) pf->data_destroy(pf->data);
    g_object_unref(pf->win);
    g_free(pf->action_name);
    g_free(pf);
}

static void annot_preflight_proceed(annot_preflight* pf) {
    SpdfWindow* win = pf->win;
    SpdfTab* tab = pf->tab;
    SpdfAnnotContinuation cont = pf->cont;
    gpointer data = pf->data;
    GDestroyNotify data_destroy = pf->data_destroy;

    g_free(pf->action_name);
    g_free(pf);
    if (annot_tab_alive(win, tab))
        cont(win, tab, data);
    else if (data_destroy)
        data_destroy(data);
    g_object_unref(win);
}

static void annot_preflight_retry_response(GObject* source, GAsyncResult* result, gpointer user_data) {
    annot_preflight* pf = (annot_preflight*)user_data;

    adw_alert_dialog_choose_finish(ADW_ALERT_DIALOG(source), result);
    if (annot_tab_alive(pf->win, pf->tab))
        annot_preflight_save_dialog(pf);
    else
        annot_preflight_abandon(pf);
}

static void annot_preflight_retry(annot_preflight* pf, const char* heading, const char* body) {
    AdwDialog* dialog = adw_alert_dialog_new(heading, body);
    adw_alert_dialog_add_responses(ADW_ALERT_DIALOG(dialog), "ok", "_OK", NULL);
    adw_alert_dialog_set_default_response(ADW_ALERT_DIALOG(dialog), "ok");
    adw_alert_dialog_set_close_response(ADW_ALERT_DIALOG(dialog), "ok");
    adw_alert_dialog_choose(ADW_ALERT_DIALOG(dialog), GTK_WIDGET(pf->win), NULL, annot_preflight_retry_response, pf);
}

static void annot_preflight_save_finished(GObject* source, GAsyncResult* result, gpointer user_data) {
    annot_preflight* pf = (annot_preflight*)user_data;
    GError* error = NULL;
    GFile* file = gtk_file_dialog_save_finish(GTK_FILE_DIALOG(source), result, &error);
    char* raw;
    char* path;

    g_clear_error(&error);
    if (!file || !annot_tab_alive(pf->win, pf->tab)) {
        g_clear_object(&file);
        annot_preflight_abandon(pf);
        return;
    }
    raw = g_file_get_path(file);
    g_object_unref(file);
    path = spdf_annot_filename_with_pdf_extension(raw);
    g_free(raw);
    if (!path) {
        annot_preflight_abandon(pf);
        return;
    }
    if (!spdf_annot_save_target_acceptable(path, g_get_tmp_dir(), g_get_user_runtime_dir())) {
        g_free(path);
        annot_preflight_retry(pf, "Choose another location", "Save the PDF outside the temporary folder.");
        return;
    }
    if (!annot_save_active_pdf_to_path(pf->win, pf->tab, path)) {
        g_free(path); /* the save error was already reported */
        annot_preflight_abandon(pf);
        return;
    }
    g_free(path);
    if (spdf_annot_pdf_path_allows_same_folder_write(pf->tab->path))
        annot_preflight_proceed(pf);
    else
        annot_preflight_retry(pf, "Choose another location",
                              "The saved PDF is still not writable. Choose a writable folder.");
}

static void annot_preflight_save_dialog(annot_preflight* pf) {
    GtkFileDialog* dialog = annot_pdf_save_dialog("Save Writable PDF As", pf->tab->path);
    gtk_file_dialog_save(dialog, GTK_WINDOW(pf->win), NULL, annot_preflight_save_finished, pf);
    g_object_unref(dialog);
}

static void annot_preflight_alert_response(GObject* source, GAsyncResult* result, gpointer user_data) {
    annot_preflight* pf = (annot_preflight*)user_data;
    const char* response = adw_alert_dialog_choose_finish(ADW_ALERT_DIALOG(source), result);

    if (g_strcmp0(response, "save") != 0 || !annot_tab_alive(pf->win, pf->tab)) {
        annot_preflight_abandon(pf);
        return;
    }
    annot_preflight_save_dialog(pf);
}

void spdf_annot_preflight(SpdfWindow* win, SpdfTab* tab, const char* action_name, int permission,
                          SpdfAnnotContinuation cont, gpointer data, GDestroyNotify data_destroy) {
    annot_preflight* pf;
    AdwDialog* dialog;

    if (!tab || !tab->doc || !tab->path || !spdf_annot_path_has_pdf_extension(tab->path)) {
        if (data_destroy) data_destroy(data);
        return;
    }
    if (!spdf_password_require_permission(GTK_WINDOW(win), tab->doc, permission, "Action is not allowed")) {
        if (data_destroy) data_destroy(data);
        return;
    }
    if (spdf_annot_pdf_path_allows_same_folder_write(tab->path)) {
        cont(win, tab, data);
        return;
    }

    pf = g_new0(annot_preflight, 1);
    pf->win = g_object_ref(win);
    pf->tab = tab;
    pf->action_name = g_strdup(action_name ? action_name : "This action");
    pf->cont = cont;
    pf->data = data;
    pf->data_destroy = data_destroy;

    dialog = adw_alert_dialog_new("Save a writable copy first?", NULL);
    adw_alert_dialog_format_body(ADW_ALERT_DIALOG(dialog),
                                 "%s needs to write the PDF, but the current file is read-only or stored in a "
                                 "temporary folder. Save it as a writable PDF before continuing.",
                                 pf->action_name);
    adw_alert_dialog_add_responses(ADW_ALERT_DIALOG(dialog), "cancel", "_Cancel", "save", "_Save As", NULL);
    adw_alert_dialog_set_response_appearance(ADW_ALERT_DIALOG(dialog), "save", ADW_RESPONSE_SUGGESTED);
    adw_alert_dialog_set_default_response(ADW_ALERT_DIALOG(dialog), "save");
    adw_alert_dialog_set_close_response(ADW_ALERT_DIALOG(dialog), "cancel");
    adw_alert_dialog_choose(ADW_ALERT_DIALOG(dialog), GTK_WIDGET(win), NULL, annot_preflight_alert_response, pf);
}

/* ---------------------------------------------------------------------------
 * Page rotation (port of rotate_current_page: rotate the CURRENT page in the
 * document, persist into the file, then reload from disk so the view can
 * never drift from the saved PDF — journal item 39). */

static void annot_rotate_cont(SpdfWindow* win, SpdfTab* tab, gpointer data) {
    int degrees = GPOINTER_TO_INT(data);
    char err[1024] = "";
    int page = tab->view ? spdf_doc_view_current_page(tab->view) : 0;

    if (!spdf_rotate_page(tab->doc, page, degrees, err, sizeof(err))) {
        annot_show_error(win, "Could not rotate page", err);
        return;
    }
    if (!spdf_save_document(tab->doc, tab->path, err, sizeof(err))) {
        annot_reload_document(win, tab, page); /* discard the unsaved rotation (GTK3 reopen) */
        annot_show_error(win, "Could not rotate page", err);
        return;
    }
    annot_reload_document(win, tab, page);
}

static void annot_rotate(SpdfWindow* win, int degrees) {
    SpdfTab* tab = spdf_window_current_tab(win);
    if (!tab || !tab->doc || !tab->path || !spdf_annot_path_has_pdf_extension(tab->path)) return;
    spdf_annot_preflight(win, tab, "Rotate", 'e', annot_rotate_cont, GINT_TO_POINTER(degrees), NULL);
}

static void action_rotate_cw(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    (void)action;
    (void)parameter;
    annot_rotate(SPDF_WINDOW(user_data), 90);
}

static void action_rotate_ccw(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    (void)action;
    (void)parameter;
    annot_rotate(SPDF_WINDOW(user_data), -90);
}

/* ---------------------------------------------------------------------------
 * Comment dialogs. AdwAlertDialog with an embedded editor as the extra child
 * (the GTK3 gtk_dialog_run prompts, made async). */

static GtkTextView* annot_comment_text_view(const char* prefill) {
    GtkTextView* text_view = GTK_TEXT_VIEW(gtk_text_view_new());
    GtkTextBuffer* buffer = gtk_text_view_get_buffer(text_view);
    GtkTextIter start;
    GtkTextIter end;

    gtk_text_view_set_wrap_mode(text_view, GTK_WRAP_WORD_CHAR);
    gtk_text_buffer_set_text(buffer, prefill ? prefill : "", -1);
    gtk_text_buffer_get_bounds(buffer, &start, &end);
    gtk_text_buffer_select_range(buffer, &start, &end);
    return text_view;
}

static GtkWidget* annot_comment_scroller(GtkTextView* text_view) {
    GtkWidget* scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), GTK_WIDGET(text_view));
    gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(scroll), 130);
    gtk_widget_set_size_request(scroll, 420, -1);
    gtk_widget_add_css_class(scroll, "card");
    return scroll;
}

/* Reads, strips and returns the buffer text; NULL when empty. */
static char* annot_text_view_take_text(GtkTextView* text_view) {
    GtkTextBuffer* buffer = gtk_text_view_get_buffer(text_view);
    GtkTextIter start;
    GtkTextIter end;
    char* text;

    gtk_text_buffer_get_bounds(buffer, &start, &end);
    text = gtk_text_buffer_get_text(buffer, &start, &end, FALSE);
    g_strstrip(text);
    if (!text[0]) {
        g_free(text);
        return NULL;
    }
    return text;
}

/* --- Add Comment / Add Highlight Comment (port of add_comment_clicked +
 * spdf_add_highlight_comment call site). The selection snapshot is captured
 * BEFORE any dialog: a preflight Save As relayouts the view and clears it. */

typedef struct {
    SpdfWindow* win; /* ref held */
    SpdfTab* tab;
    gboolean use_selection;
    int page;
    double point_x; /* PDF points; text-comment anchor when no selection */
    double point_y;
    spdf_rect rects[ANNOT_SELECTION_RECT_MAX];
    int rect_count;
    char* text;
    GtkTextView* text_view; /* dialog lifetime only */
} annot_add_ctx;

static void annot_add_ctx_free(gpointer data) {
    annot_add_ctx* ctx = (annot_add_ctx*)data;
    if (!ctx) return;
    g_object_unref(ctx->win);
    g_free(ctx->text);
    g_free(ctx);
}

static void annot_add_comment_cont(SpdfWindow* win, SpdfTab* tab, gpointer data) {
    annot_add_ctx* ctx = (annot_add_ctx*)data;
    char err[1024] = "";
    gboolean ok;

    if (ctx->use_selection)
        ok = spdf_add_highlight_comment(tab->doc, ctx->page, ctx->rects, ctx->rect_count, ctx->text,
                                        annot_current_author(win), err, sizeof(err));
    else
        ok = spdf_add_text_comment(tab->doc, ctx->page, (float)ctx->point_x, (float)ctx->point_y, ctx->text,
                                   annot_current_author(win), err, sizeof(err));
    if (ok) ok = spdf_save_document(tab->doc, tab->path, err, sizeof(err));
    if (!ok)
        annot_show_error(win, "Could not add comment", err);
    else
        annot_after_document_write(tab);
    annot_add_ctx_free(ctx);
}

static void annot_add_comment_response(GObject* source, GAsyncResult* result, gpointer user_data) {
    annot_add_ctx* ctx = (annot_add_ctx*)user_data;
    const char* response = adw_alert_dialog_choose_finish(ADW_ALERT_DIALOG(source), result);
    char* text = NULL;

    if (g_strcmp0(response, "add") == 0 && ctx->text_view) text = annot_text_view_take_text(ctx->text_view);
    ctx->text_view = NULL;
    if (!text || !annot_tab_alive(ctx->win, ctx->tab)) {
        g_free(text);
        annot_add_ctx_free(ctx);
        return;
    }
    ctx->text = text;
    spdf_annot_preflight(ctx->win, ctx->tab, "Add comment", 'n', annot_add_comment_cont, ctx, annot_add_ctx_free);
}

static void annot_add_comment_flow(SpdfWindow* win, gboolean require_selection) {
    SpdfTab* tab = spdf_window_current_tab(win);
    AnnotWinState* st = annot_win_state(win);
    annot_add_ctx* ctx;
    AdwDialog* dialog;
    int sel_page = -1;
    spdf_rect rects[ANNOT_SELECTION_RECT_MAX];
    int sel_count = 0;
    char* sel_text = NULL;

    if (!tab || !tab->doc || !tab->path) return;
    if (tab->view) {
        sel_count = spdf_doc_view_get_selection_rects(tab->view, &sel_page, rects, ANNOT_SELECTION_RECT_MAX);
        if (sel_count > 0) sel_text = spdf_doc_view_copy_selection(tab->view);
    }
    if (require_selection && sel_count <= 0) return;

    ctx = g_new0(annot_add_ctx, 1);
    ctx->win = g_object_ref(win);
    ctx->tab = tab;
    if (sel_count > 0) {
        ctx->use_selection = TRUE;
        ctx->page = sel_page;
        ctx->rect_count = sel_count;
        memcpy(ctx->rects, rects, (gsize)sel_count * sizeof(spdf_rect));
    } else {
        ctx->page = st->context_page;
        ctx->point_x = st->context_x;
        ctx->point_y = st->context_y;
    }
    if (ctx->page < 0 || ctx->page >= spdf_page_count(tab->doc)) {
        g_free(sel_text);
        annot_add_ctx_free(ctx);
        return;
    }

    dialog = adw_alert_dialog_new(sel_count > 0 ? "Add Highlight Comment" : "Add Comment", "Enter the comment text.");
    ctx->text_view = annot_comment_text_view(sel_text);
    adw_alert_dialog_set_extra_child(ADW_ALERT_DIALOG(dialog), annot_comment_scroller(ctx->text_view));
    adw_alert_dialog_add_responses(ADW_ALERT_DIALOG(dialog), "cancel", "_Cancel", "add", "_Add", NULL);
    adw_alert_dialog_set_response_appearance(ADW_ALERT_DIALOG(dialog), "add", ADW_RESPONSE_SUGGESTED);
    adw_alert_dialog_set_default_response(ADW_ALERT_DIALOG(dialog), "add");
    adw_alert_dialog_set_close_response(ADW_ALERT_DIALOG(dialog), "cancel");
    adw_dialog_set_focus(dialog, GTK_WIDGET(ctx->text_view));
    adw_alert_dialog_choose(ADW_ALERT_DIALOG(dialog), GTK_WIDGET(win), NULL, annot_add_comment_response, ctx);
    g_free(sel_text);
}

static void action_add_comment(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    (void)action;
    (void)parameter;
    annot_add_comment_flow(SPDF_WINDOW(user_data), FALSE);
}

static void action_add_highlight(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    (void)action;
    (void)parameter;
    annot_add_comment_flow(SPDF_WINDOW(user_data), TRUE);
}

/* --- Edit Comment (port of edit_comment_clicked + prompt_for_comment_editor;
 * also the click-to-edit entry point for comment markers). */

typedef struct {
    SpdfWindow* win; /* ref held */
    SpdfTab* tab;
    int comment_index;
    char* text;
    char* author;
    GtkTextView* text_view; /* dialog lifetime only */
    GtkEntry* author_entry;
} annot_edit_ctx;

static void annot_edit_ctx_free(gpointer data) {
    annot_edit_ctx* ctx = (annot_edit_ctx*)data;
    if (!ctx) return;
    g_object_unref(ctx->win);
    g_free(ctx->text);
    g_free(ctx->author);
    g_free(ctx);
}

static void annot_edit_comment_cont(SpdfWindow* win, SpdfTab* tab, gpointer data) {
    annot_edit_ctx* ctx = (annot_edit_ctx*)data;
    char err[1024] = "";
    gboolean ok;
    SpdfApp* app = annot_window_app(win);

    /* GTK3 parity: the edited author becomes the default for new comments. */
    if (app) {
        SpdfState* state = spdf_app_get_state(app);
        spdf_state_set_string(&spdf_state_settings(state)->comment_author, ctx->author ? ctx->author : "");
        spdf_state_save_settings(state);
    }
    ok = spdf_update_comment(tab->doc, ctx->comment_index, ctx->text, ctx->author, err, sizeof(err));
    if (ok) ok = spdf_save_document(tab->doc, tab->path, err, sizeof(err));
    if (!ok)
        annot_show_error(win, "Could not edit comment", err);
    else
        annot_after_document_write(tab);
    annot_edit_ctx_free(ctx);
}

static void annot_edit_comment_response(GObject* source, GAsyncResult* result, gpointer user_data) {
    annot_edit_ctx* ctx = (annot_edit_ctx*)user_data;
    const char* response = adw_alert_dialog_choose_finish(ADW_ALERT_DIALOG(source), result);
    char* text = NULL;
    char* author = NULL;

    if (g_strcmp0(response, "save") == 0 && ctx->text_view && ctx->author_entry) {
        text = annot_text_view_take_text(ctx->text_view);
        author = g_strdup(gtk_editable_get_text(GTK_EDITABLE(ctx->author_entry)));
        g_strstrip(author);
    }
    ctx->text_view = NULL;
    ctx->author_entry = NULL;
    if (!text || !annot_tab_alive(ctx->win, ctx->tab)) {
        g_free(text);
        g_free(author);
        annot_edit_ctx_free(ctx);
        return;
    }
    ctx->text = text;
    ctx->author = author;
    spdf_annot_preflight(ctx->win, ctx->tab, "Edit comment", 'n', annot_edit_comment_cont, ctx, annot_edit_ctx_free);
}

static void annot_edit_comment_begin(SpdfWindow* win, SpdfTab* tab, int comment_index) {
    const spdf_comment_item* comment = annot_comment_item_for_index(tab, comment_index);
    annot_edit_ctx* ctx;
    AdwDialog* dialog;
    GtkWidget* box;
    GtkWidget* author_label;
    GtkWidget* comment_label;
    const char* author;

    if (!tab->doc || !tab->path || !comment) return;
    author = comment->author && comment->author[0] ? comment->author : annot_current_author(win);

    ctx = g_new0(annot_edit_ctx, 1);
    ctx->win = g_object_ref(win);
    ctx->tab = tab;
    ctx->comment_index = comment_index;

    dialog = adw_alert_dialog_new("Edit Comment", NULL);
    box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    author_label = gtk_label_new("Author");
    gtk_label_set_xalign(GTK_LABEL(author_label), 0.0f);
    ctx->author_entry = GTK_ENTRY(gtk_entry_new());
    gtk_editable_set_text(GTK_EDITABLE(ctx->author_entry), author ? author : "");
    comment_label = gtk_label_new("Comment");
    gtk_label_set_xalign(GTK_LABEL(comment_label), 0.0f);
    ctx->text_view = annot_comment_text_view(comment->text && comment->text[0] ? comment->text : "");
    gtk_box_append(GTK_BOX(box), author_label);
    gtk_box_append(GTK_BOX(box), GTK_WIDGET(ctx->author_entry));
    gtk_box_append(GTK_BOX(box), comment_label);
    gtk_box_append(GTK_BOX(box), annot_comment_scroller(ctx->text_view));
    adw_alert_dialog_set_extra_child(ADW_ALERT_DIALOG(dialog), box);
    adw_alert_dialog_add_responses(ADW_ALERT_DIALOG(dialog), "cancel", "_Cancel", "save", "_Save", NULL);
    adw_alert_dialog_set_response_appearance(ADW_ALERT_DIALOG(dialog), "save", ADW_RESPONSE_SUGGESTED);
    adw_alert_dialog_set_default_response(ADW_ALERT_DIALOG(dialog), "save");
    adw_alert_dialog_set_close_response(ADW_ALERT_DIALOG(dialog), "cancel");
    adw_dialog_set_focus(dialog, GTK_WIDGET(ctx->text_view));
    adw_alert_dialog_choose(ADW_ALERT_DIALOG(dialog), GTK_WIDGET(win), NULL, annot_edit_comment_response, ctx);
}

static void action_edit_comment(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = spdf_window_current_tab(win);
    AnnotWinState* st = annot_win_state(win);

    (void)action;
    (void)parameter;
    if (!tab || st->context_comment_index < 0) return;
    annot_edit_comment_begin(win, tab, st->context_comment_index);
}

/* --- Delete Comment (port of delete_comment_clicked + confirm_delete_comment). */

typedef struct {
    SpdfWindow* win; /* ref held */
    SpdfTab* tab;
    int comment_index;
} annot_delete_ctx;

static void annot_delete_ctx_free(gpointer data) {
    annot_delete_ctx* ctx = (annot_delete_ctx*)data;
    if (!ctx) return;
    g_object_unref(ctx->win);
    g_free(ctx);
}

static void annot_delete_comment_cont(SpdfWindow* win, SpdfTab* tab, gpointer data) {
    annot_delete_ctx* ctx = (annot_delete_ctx*)data;
    char err[1024] = "";
    gboolean ok;

    ok = spdf_delete_comment(tab->doc, ctx->comment_index, err, sizeof(err));
    if (ok) ok = spdf_save_document(tab->doc, tab->path, err, sizeof(err));
    if (!ok)
        annot_show_error(win, "Could not delete comment", err);
    else {
        annot_win_state(win)->context_comment_index = -1;
        annot_after_document_write(tab);
    }
    annot_delete_ctx_free(ctx);
}

static void annot_delete_comment_response(GObject* source, GAsyncResult* result, gpointer user_data) {
    annot_delete_ctx* ctx = (annot_delete_ctx*)user_data;
    const char* response = adw_alert_dialog_choose_finish(ADW_ALERT_DIALOG(source), result);

    if (g_strcmp0(response, "delete") != 0 || !annot_tab_alive(ctx->win, ctx->tab)) {
        annot_delete_ctx_free(ctx);
        return;
    }
    spdf_annot_preflight(ctx->win, ctx->tab, "Delete comment", 'n', annot_delete_comment_cont, ctx,
                         annot_delete_ctx_free);
}

static void action_delete_comment(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = spdf_window_current_tab(win);
    AnnotWinState* st = annot_win_state(win);
    annot_delete_ctx* ctx;
    AdwDialog* dialog;

    (void)action;
    (void)parameter;
    if (!tab || !tab->doc || !tab->path || !annot_comment_item_for_index(tab, st->context_comment_index)) return;

    ctx = g_new0(annot_delete_ctx, 1);
    ctx->win = g_object_ref(win);
    ctx->tab = tab;
    ctx->comment_index = st->context_comment_index;

    dialog = adw_alert_dialog_new("Delete comment?",
                                  "This will remove the selected comment from the PDF and save the document.");
    adw_alert_dialog_add_responses(ADW_ALERT_DIALOG(dialog), "cancel", "_Cancel", "delete", "_Delete", NULL);
    adw_alert_dialog_set_response_appearance(ADW_ALERT_DIALOG(dialog), "delete", ADW_RESPONSE_DESTRUCTIVE);
    adw_alert_dialog_set_default_response(ADW_ALERT_DIALOG(dialog), "cancel");
    adw_alert_dialog_set_close_response(ADW_ALERT_DIALOG(dialog), "cancel");
    adw_alert_dialog_choose(ADW_ALERT_DIALOG(dialog), GTK_WIDGET(win), NULL, annot_delete_comment_response, ctx);
}

/* ---------------------------------------------------------------------------
 * Single-page export. "Copy Page as PDF" ports copy_page_clicked (standalone
 * single-page PDF written under the temp dir, then put on the clipboard as a
 * file); "Save Page as PDF…" is the file-dialog variant the Mac app has. */

static int annot_export_page(SpdfWindow* win, SpdfTab* tab) {
    AnnotWinState* st = annot_win_state(win);
    if (st->context_page >= 0) return st->context_page;
    return tab->view ? spdf_doc_view_current_page(tab->view) : -1;
}

static void annot_copy_file_to_clipboard(SpdfWindow* win, const char* path) {
    GdkClipboard* clipboard = gtk_widget_get_clipboard(GTK_WIDGET(win));
    GFile* file = g_file_new_for_path(path);
    GdkFileList* file_list = gdk_file_list_new_from_array(&file, 1);
    GdkContentProvider* providers[2];
    GdkContentProvider* provider;

    /* GTK3 offered text/uri-list + text/plain; GdkFileList serializes to
     * text/uri-list (and application/vnd.portal.files under the portal), the
     * string provider covers plain-text paste. */
    providers[0] = gdk_content_provider_new_typed(GDK_TYPE_FILE_LIST, file_list);
    providers[1] = gdk_content_provider_new_typed(G_TYPE_STRING, path);
    provider = gdk_content_provider_new_union(providers, 2);
    gdk_clipboard_set_content(clipboard, provider);
    g_object_unref(provider);
    g_boxed_free(GDK_TYPE_FILE_LIST, file_list);
    g_object_unref(file);
}

static void action_copy_page_pdf(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = spdf_window_current_tab(win);
    char err[1024] = "";
    int page;
    char* name;
    char* dir;
    char* temp_path;

    (void)action;
    (void)parameter;
    if (!tab || !tab->doc || !tab->path) return;
    if (!spdf_password_require_permission(GTK_WINDOW(win), tab->doc, 'c', "Copying is not allowed")) return;
    page = annot_export_page(win, tab);
    if (page < 0) return;

    name = spdf_annot_single_page_filename(tab->path, page);
    dir = g_build_filename(g_get_tmp_dir(), "ShenzhenPDF-copy", NULL);
    g_mkdir_with_parents(dir, 0700);
    temp_path = g_build_filename(dir, name, NULL);

    if (spdf_save_single_page_pdf(tab->doc, page, temp_path, err, sizeof(err)))
        annot_copy_file_to_clipboard(win, temp_path);
    else
        annot_show_error(win, "Could not copy page", err);

    g_free(temp_path);
    g_free(dir);
    g_free(name);
}

typedef struct {
    SpdfWindow* win; /* ref held */
    SpdfTab* tab;
    int page;
} annot_save_page_ctx;

static void annot_save_page_finished(GObject* source, GAsyncResult* result, gpointer user_data) {
    annot_save_page_ctx* ctx = (annot_save_page_ctx*)user_data;
    GError* error = NULL;
    GFile* file = gtk_file_dialog_save_finish(GTK_FILE_DIALOG(source), result, &error);

    g_clear_error(&error);
    if (file) {
        char* raw = g_file_get_path(file);
        char* path = spdf_annot_filename_with_pdf_extension(raw);
        if (path && annot_tab_alive(ctx->win, ctx->tab) && ctx->tab->doc) {
            char err[1024] = "";
            if (!spdf_save_single_page_pdf(ctx->tab->doc, ctx->page, path, err, sizeof(err)))
                annot_show_error(ctx->win, "Could not save page", err);
        }
        g_free(path);
        g_free(raw);
        g_object_unref(file);
    }
    g_object_unref(ctx->win);
    g_free(ctx);
}

static void action_save_page_pdf(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
    SpdfWindow* win = SPDF_WINDOW(user_data);
    SpdfTab* tab = spdf_window_current_tab(win);
    annot_save_page_ctx* ctx;
    GtkFileDialog* dialog;
    char* name;
    int page;

    (void)action;
    (void)parameter;
    if (!tab || !tab->doc || !tab->path) return;
    if (!spdf_password_require_permission(GTK_WINDOW(win), tab->doc, 'c', "Saving this page is not allowed")) return;
    page = annot_export_page(win, tab);
    if (page < 0) return;

    ctx = g_new0(annot_save_page_ctx, 1);
    ctx->win = g_object_ref(win);
    ctx->tab = tab;
    ctx->page = page;

    dialog = annot_pdf_save_dialog("Save Page as PDF", tab->path);
    name = spdf_annot_single_page_filename(tab->path, page);
    gtk_file_dialog_set_initial_name(dialog, name);
    g_free(name);
    gtk_file_dialog_save(dialog, GTK_WINDOW(win), NULL, annot_save_page_finished, ctx);
    g_object_unref(dialog);
}

/* ---------------------------------------------------------------------------
 * Doc-view context menu (port of the GTK3 page_button_press menu, rebuilt as
 * GMenuModel + GtkPopoverMenu; GtkMenu is gone in GTK4). Selection- and
 * hit-dependent items are enabled/disabled just before the popover opens and
 * re-enabled when it closes (win.copy keeps its Ctrl+C accel live). */

static GMenuModel* annot_build_context_menu(void) {
    GMenu* menu = g_menu_new();
    GMenu* edit = g_menu_new();
    GMenu* comments = g_menu_new();
    GMenu* page = g_menu_new();
    GMenu* file = g_menu_new();

    g_menu_append(edit, "_Copy", "win.copy");
    g_menu_append_section(menu, NULL, G_MENU_MODEL(edit));

    g_menu_append(comments, "Add Comment…", "win.annot-add-comment");
    g_menu_append(comments, "Add Highlight Comment…", "win.annot-add-highlight");
    g_menu_append(comments, "Edit Comment…", "win.annot-edit-comment");
    g_menu_append(comments, "Delete Comment…", "win.annot-delete-comment");
    g_menu_append_section(menu, NULL, G_MENU_MODEL(comments));

    g_menu_append(page, "Copy Page as PDF", "win.copy-page-pdf");
    g_menu_append(page, "Save Page as PDF…", "win.save-page-pdf");
    g_menu_append(page, "Rotate Clockwise", "win.rotate-cw");
    g_menu_append(page, "Rotate Anticlockwise", "win.rotate-ccw");
    g_menu_append_section(menu, NULL, G_MENU_MODEL(page));

    g_menu_append(file, "Show in Folder", "win.show-in-folder");
    g_menu_append(file, "Copy Path", "win.copy-path");
    g_menu_append_section(menu, NULL, G_MENU_MODEL(file));

    g_object_unref(edit);
    g_object_unref(comments);
    g_object_unref(page);
    g_object_unref(file);
    return G_MENU_MODEL(menu);
}

static void annot_context_actions_reset(SpdfWindow* win) {
    annot_set_enabled(win, "copy", TRUE);
    annot_set_enabled(win, "annot-add-comment", TRUE);
    annot_set_enabled(win, "annot-add-highlight", TRUE);
    annot_set_enabled(win, "annot-edit-comment", TRUE);
    annot_set_enabled(win, "annot-delete-comment", TRUE);
    annot_set_enabled(win, "copy-page-pdf", TRUE);
    annot_set_enabled(win, "save-page-pdf", TRUE);
    annot_set_enabled(win, "rotate-cw", TRUE);
    annot_set_enabled(win, "rotate-ccw", TRUE);
}

static void annot_popover_closed(GtkPopover* popover, gpointer user_data) {
    SpdfDocView* view = SPDF_DOC_VIEW(user_data);
    GtkRoot* root = gtk_widget_get_root(GTK_WIDGET(view));
    (void)popover;
    if (root && SPDF_IS_WINDOW(root)) annot_context_actions_reset(SPDF_WINDOW(root));
}

/* Popovers parented with gtk_widget_set_parent must be unparented before
 * their parent widget disposes; the view's ::destroy is that hook. */
static void annot_view_destroyed(GtkWidget* view, gpointer user_data) {
    GtkWidget* popover = GTK_WIDGET(user_data);
    (void)view;
    gtk_widget_unparent(popover);
}

static GtkWidget* annot_popover_for_view(SpdfDocView* view) {
    GtkWidget* popover = (GtkWidget*)g_object_get_data(G_OBJECT(view), "spdf-annot-popover");
    GMenuModel* model;

    if (popover) return popover;
    model = annot_build_context_menu();
    popover = gtk_popover_menu_new_from_model(model);
    g_object_unref(model);
    gtk_popover_set_has_arrow(GTK_POPOVER(popover), FALSE);
    gtk_widget_set_halign(popover, GTK_ALIGN_START);
    gtk_widget_set_parent(popover, GTK_WIDGET(view));
    g_signal_connect(view, "destroy", G_CALLBACK(annot_view_destroyed), popover);
    g_signal_connect(popover, "closed", G_CALLBACK(annot_popover_closed), view);
    g_object_set_data(G_OBJECT(view), "spdf-annot-popover", popover);
    return popover;
}

static void annot_context_menu_pressed(GtkGestureClick* gesture, int n_press, double x, double y, gpointer user_data) {
    SpdfTab* tab = (SpdfTab*)user_data;
    SpdfWindow* win = tab->win;
    AnnotWinState* st;
    GtkWidget* popover;
    GdkRectangle at = {(int)x, (int)y, 1, 1};
    int page = -1;
    double page_x = 0.0;
    double page_y = 0.0;
    gboolean has_selection = FALSE;
    gboolean pdf;

    (void)gesture;
    (void)n_press;
    if (!win || !tab->view) return;

    st = annot_win_state(win);
    st->context_page = -1;
    st->context_comment_index = -1;
    if (tab->doc && spdf_doc_view_widget_point_to_page(tab->view, x, y, &page, &page_x, &page_y)) {
        st->context_page = page;
        st->context_x = page_x;
        st->context_y = page_y;
        st->context_comment_index = annot_comment_at_point(tab, page, page_x, page_y);
    }
    {
        char* selected = spdf_doc_view_copy_selection(tab->view);
        has_selection = selected != NULL;
        g_free(selected);
    }
    pdf = tab->doc && tab->path && spdf_annot_path_has_pdf_extension(tab->path);
    spdf_password_update_context_actions(G_ACTION_MAP(win), tab->doc, pdf, has_selection,
                                         has_selection || st->context_page >= 0, st->context_comment_index >= 0,
                                         tab->path && annot_export_page(win, tab) >= 0);

    popover = annot_popover_for_view(tab->view);
    gtk_popover_set_pointing_to(GTK_POPOVER(popover), &at);
    gtk_popover_popup(GTK_POPOVER(popover));
}

/* Click-to-edit on a comment marker badge. Runs in the capture phase and
 * claims the sequence, so the selection/link drag gesture never starts on a
 * badge. */
static void annot_marker_click_pressed(GtkGestureClick* gesture, int n_press, double x, double y, gpointer user_data) {
    SpdfTab* tab = (SpdfTab*)user_data;
    int page = -1;
    double page_x = 0.0;
    double page_y = 0.0;
    int comment_index;

    if (n_press != 1 || !tab->win || !tab->doc || !tab->view) return;
    if (!spdf_doc_view_widget_point_to_page(tab->view, x, y, &page, &page_x, &page_y)) return;
    comment_index = annot_comment_at_badge(tab, page, page_x, page_y);
    if (comment_index < 0) return;
    gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_CLAIMED);
    annot_edit_comment_begin(tab->win, tab, comment_index);
}

/* ---------------------------------------------------------------------------
 * Module wiring. */

static gboolean annot_initial_load_idle(gpointer data) {
    SpdfTab* tab = (SpdfTab*)data;
    tab->annot_idle_id = 0;
    annot_refresh_comments(tab);
    return G_SOURCE_REMOVE;
}

void spdf_annot_tab_attached(SpdfTab* tab) {
    GtkGesture* marker_click;
    GtkGesture* context_click;

    if (!tab || !tab->view) return;

    marker_click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(marker_click), GDK_BUTTON_PRIMARY);
    gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(marker_click), GTK_PHASE_CAPTURE);
    g_signal_connect(marker_click, "pressed", G_CALLBACK(annot_marker_click_pressed), tab);
    gtk_widget_add_controller(GTK_WIDGET(tab->view), GTK_EVENT_CONTROLLER(marker_click));

    context_click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(context_click), GDK_BUTTON_SECONDARY);
    g_signal_connect(context_click, "pressed", G_CALLBACK(annot_context_menu_pressed), tab);
    gtk_widget_add_controller(GTK_WIDGET(tab->view), GTK_EVENT_CONTROLLER(context_click));

    /* Comment load builds per-page annotation lists — keep it off the open
     * path (GTK3 loaded synchronously at open; the markers can wait a tick). */
    tab->annot_idle_id = g_idle_add_full(G_PRIORITY_LOW, annot_initial_load_idle, tab, NULL);
}

void spdf_annot_tab_closing(SpdfTab* tab) {
    if (!tab) return;
    if (tab->annot_idle_id) {
        g_source_remove(tab->annot_idle_id);
        tab->annot_idle_id = 0;
    }
    spdf_free_comments(&tab->comments);
    tab->comments_loaded = FALSE;
}

static const GActionEntry k_annot_actions[] = {
    {"rotate-cw", action_rotate_cw, NULL, NULL, NULL, {0}},
    {"rotate-ccw", action_rotate_ccw, NULL, NULL, NULL, {0}},
    {"save-as", action_save_as, NULL, NULL, NULL, {0}},
    {"annot-add-comment", action_add_comment, NULL, NULL, NULL, {0}},
    {"annot-add-highlight", action_add_highlight, NULL, NULL, NULL, {0}},
    {"annot-edit-comment", action_edit_comment, NULL, NULL, NULL, {0}},
    {"annot-delete-comment", action_delete_comment, NULL, NULL, NULL, {0}},
    {"copy-page-pdf", action_copy_page_pdf, NULL, NULL, NULL, {0}},
    {"save-page-pdf", action_save_page_pdf, NULL, NULL, NULL, {0}},
};

void spdf_annot_install(SpdfWindow* win) {
    g_return_if_fail(SPDF_IS_WINDOW(win));
    g_action_map_add_action_entries(G_ACTION_MAP(win), k_annot_actions, G_N_ELEMENTS(k_annot_actions), win);
    (void)annot_win_state(win);
}

#endif /* SPDF_ANNOT_TESTING */
