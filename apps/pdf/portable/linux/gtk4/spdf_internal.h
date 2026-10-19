// Internal module seams for the GTK4 frontend. Every module includes this.
// Contract file: agents extend their own module's section; the tab/view/render
// seams below change only by integrator decision.
#pragma once

#include <adwaita.h>
#include <gtk/gtk.h>

#include "shenzhen_pdf_core.h"

G_BEGIN_DECLS

typedef struct _SpdfTab SpdfTab;
typedef struct _SpdfWindow SpdfWindow;
typedef struct _SpdfPasswordCredential SpdfPasswordCredential;
typedef struct _SpdfPasswordSource SpdfPasswordSource;
typedef struct _SpdfPasswordPrompt SpdfPasswordPrompt;

// ---------------------------------------------------------------------------
// spdf_launch.c — launch profiling (SPDF_LAUNCH_PROFILE=1, same as Mac).
void spdf_launch_mark(const char* stage); // no-op unless profiling enabled
gboolean spdf_launch_profile_enabled(void);

// ---------------------------------------------------------------------------
// Flatpak detection, shared by every module that must behave differently in
// the sandbox (spdf_updater.c, spdf_resident.c, spdf_default_reader.c).
// /.flatpak-info exists in every Flatpak sandbox; FLATPAK_ID covers the
// (theoretical) case of a caller scrubbing the filesystem view but not env.
static inline gboolean spdf_running_in_flatpak(void) {
    return g_file_test("/.flatpak-info", G_FILE_TEST_EXISTS) || g_getenv("FLATPAK_ID") != NULL;
}

// ---------------------------------------------------------------------------
// spdf_render.c — worker render pipeline (ported semantics from GTK3 file:
// persistent worker docs, display-list cache, render tokens, 96MB byte cap).
typedef struct _SpdfRenderService SpdfRenderService;
typedef struct {
    int page;
    double scale;      // device pixels per PDF point
    GdkRectangle crop; // page-space crop in device px; {0,0,0,0} = full
    guint64 token;     // request generation; stale results dropped
} SpdfRenderSpec;
// Fires exactly once per token, always on the main thread; texture is NULL on
// cancel/error/shutdown — the deterministic release point for user_data.
// texture is owned by callee after return.
typedef void (*SpdfRenderDone)(GdkTexture* texture, const SpdfRenderSpec* spec, gpointer user_data);
SpdfRenderService* spdf_render_service_new(const char* path, SpdfPasswordCredential* credential, char** error);
void spdf_render_service_free(SpdfRenderService* svc);
guint64 spdf_render_request(SpdfRenderService* svc, const SpdfRenderSpec* spec,
                            int priority /*0=visible,1=near,2=warm*/, SpdfRenderDone done, gpointer user_data);
void spdf_render_cancel(SpdfRenderService* svc, guint64 token);
void spdf_render_set_byte_cap(SpdfRenderService* svc, gsize bytes);
// Drop every cached texture/list (rotation/OCR/save rewrote the file; worker
// docs re-open by themselves, keyed on path+mtime+size).
void spdf_render_service_invalidate(SpdfRenderService* svc);
// Per-thread persistent worker document keyed on (path, mtime, size); worker
// threads only (Mac workerDocumentForPath). The returned document is owned by
// the calling thread's private slot — do not close it. NULL + err on failure.
spdf_document* spdf_render_worker_document(const SpdfPasswordSource* source, char* err, size_t err_len);

// ---------------------------------------------------------------------------
// spdf_docview.c — the page canvas (custom GtkWidget, snapshot + GdkTexture).
#define SPDF_TYPE_DOC_VIEW (spdf_doc_view_get_type())
G_DECLARE_FINAL_TYPE(SpdfDocView, spdf_doc_view, SPDF, DOC_VIEW, GtkWidget)
SpdfDocView* spdf_doc_view_new(SpdfTab* tab);
void spdf_doc_view_goto_page(SpdfDocView* v, int page);
int spdf_doc_view_current_page(SpdfDocView* v);
void spdf_doc_view_set_zoom(SpdfDocView* v, double zoom, gboolean anchored, double anchor_x, double anchor_y);
double spdf_doc_view_get_zoom(SpdfDocView* v);
typedef enum {
    SPDF_FIT_PAGE,
    SPDF_FIT_WIDTH,
    SPDF_FIT_HEIGHT,
    SPDF_FIT_CUSTOM
} SpdfFitMode;
void spdf_doc_view_set_fit(SpdfDocView* v, SpdfFitMode m);
SpdfFitMode spdf_doc_view_get_fit(SpdfDocView* v);
void spdf_doc_view_get_scroll(SpdfDocView* v, double* x, double* y);
void spdf_doc_view_set_scroll(SpdfDocView* v, double x, double y);
// One Ctrl+wheel zoom step (dy in scroll-event units), for widgets that
// forward their Ctrl+scroll to the document (the minimap; Mac
// minimapViewDidReceiveZoomScrollWheel). anchor_x/anchor_y are widget-space
// coordinates of the view; has_anchor=FALSE anchors at the viewport center.
void spdf_doc_view_zoom_scroll(SpdfDocView* v, double dy, gboolean has_anchor, double anchor_x, double anchor_y);
char* spdf_doc_view_copy_selection(SpdfDocView* v); // NULL if none
// Kick the first-page render before the window maps (launch-speed budget);
// renders at the restored zoom, settle pass corrects fit after first allocate.
void spdf_doc_view_prime_first_page(SpdfDocView* v);
// "page-changed", "zoom-changed", "selection-changed" signals emitted.

// --- Wave B additions (spdf_annot.c is the consumer) ------------------------
// The document behind the view was rewritten in place (rotate/OCR/comment
// save) or the tab was retargeted at another file (Save As): drop every
// texture, orphan in-flight render contexts, re-read page sizes from
// tab->doc and relayout, preserving the current page. Callers invalidate the
// render service themselves (spdf_render_service_invalidate) first.
void spdf_doc_view_document_changed(SpdfDocView* v);
// Resolve a widget-space point to (page, PDF-point) coordinates; FALSE when
// the point is over the margins/background.
gboolean spdf_doc_view_widget_point_to_page(SpdfDocView* v, double widget_x, double widget_y, int* page, double* page_x,
                                            double* page_y);
// Copy up to rect_max selection rects (PDF points on *page); returns the
// count, 0 when there is no selection.
int spdf_doc_view_get_selection_rects(SpdfDocView* v, int* page, spdf_rect* rects, int rect_max);
// Comment markers, drawn as a snapshot overlay (same pattern as the
// selection). The view copies the array; annotations module owns the truth.
typedef struct {
    int page;
    spdf_rect bounds; // annotation bounds, PDF points (origin top-left)
} SpdfCommentMarker;
void spdf_doc_view_set_comment_markers(SpdfDocView* v, const SpdfCommentMarker* markers, int count);
// Badge rect (PDF points) drawn for a comment marker and hit-tested by the
// click-to-edit gesture: a 12pt square hugging the annotation's top-right
// corner. Pure, shared between spdf_docview.c drawing and spdf_annot.c
// hit-testing so the two can never disagree.
static inline spdf_rect spdf_comment_marker_badge(const spdf_rect* bounds) {
    spdf_rect badge;
    float right = bounds->x0 > bounds->x1 ? bounds->x0 : bounds->x1;
    float top = bounds->y0 < bounds->y1 ? bounds->y0 : bounds->y1;
    badge.x0 = right - 4.0f;
    badge.x1 = right + 8.0f;
    badge.y0 = top - 8.0f;
    badge.y1 = top + 4.0f;
    return badge;
}

// ---------------------------------------------------------------------------
// spdf_tab.c (owned by spdf_window.c agent) — per-document model.
struct _SpdfTab {
    char* path;
    spdf_document* doc; // main-thread core doc (metadata/search)
    SpdfRenderService* render;
    SpdfDocView* view;
    AdwTabPage* page; // owning AdwTabView page
    SpdfWindow* win;
    char* search_text;         // persisted per-tab query
    gboolean read_only_shadow; // orange-dot shadow copy tab
    // agents may append fields; never reorder existing ones mid-wave
    // --- appended by spdf_search.c (wave B) ---
    gboolean search_regex;                // persisted per-tab regex toggle
    gboolean search_regex_multiline;      // persisted per-tab multiline toggle (GTK3 default TRUE)
    int find_match_index;                 // persisted current match, -1 = none
    struct _SpdfSearchController* search; // owned; created in spdf_tab_open
    GtkWidget* scroller;                  // GtkScrolledWindow wrapping view
    GtkWidget* overlay;                   // page-content root: scroller + overlay lanes
    // --- appended by spdf_annot.c (wave B) ---
    spdf_comments comments; // cached comment list (markers, context menu)
    gboolean comments_loaded;
    guint annot_idle_id; // deferred initial comment load
    // --- appended by spdf_minimap.c (wave B) ---
    GtkWidget* minimap;    // document-map strip, right of the overlay
    gboolean show_minimap; // per-document visibility (documents.json "showMinimap")
    // --- appended by spdf_sidebar.c (wave B) ---
    spdf_outline outline;      // cached outline (chapters pane, search grouping)
    gboolean outline_loaded;   // load attempted (count may be 0)
    gboolean sidebar_resolved; // per-document showSidebar resolved into...
    gboolean sidebar_visible;  // ...this flag (documents.json, else default)
    // --- appended by spdf_watcher.c (wave C) ---
    char* working_path;          // read-only shadow copy actually opened; NULL = path
    guint64 ro_copy_file_size;   // source stat the shadow copy reflects
    double ro_copy_modified_at;  //   (session keys roCopyFileSize/roCopyModifiedAt)
    struct _SpdfTabWatch* watch; // owned by spdf_watcher.c; NULL when unwatched
    // --- appended by spdf_password.c ---
    SpdfPasswordCredential* credential; // memory-only; source-identity bound
};
typedef void (*SpdfTabOpenReady)(SpdfTab* tab, gboolean cancelled, const char* error, gpointer user_data);
SpdfPasswordPrompt* spdf_tab_open_async(SpdfWindow* win, const char* path, SpdfTabOpenReady ready, gpointer user_data,
                                        GDestroyNotify destroy);
SpdfTab* spdf_tab_attach_opened(SpdfWindow* win, char* canonical, char* working_path, guint64 copy_size,
                                double copy_mtime, gboolean source_read_only, spdf_document* doc,
                                SpdfPasswordCredential* credential);
void spdf_tab_close(SpdfTab* tab);
void spdf_window_accept_opened(SpdfWindow* win, SpdfTab* tab, const char* canonical, int page_index,
                               gboolean remember_recent);

// ---------------------------------------------------------------------------
// spdf_state.c — JSON state, schema-compatible with the Mac app.
typedef struct _SpdfState SpdfState;        // settings + session + favorites + recents
SpdfState* spdf_state_load(void);           // cheap; must stay off the hot launch path
void spdf_state_save_session(SpdfState* s); // coalesced, async write
void spdf_state_flush(SpdfState* s);

G_END_DECLS
