// spdf_annot.c — annotations + file operations for the GTK4 shell (Wave B):
// comment CRUD (add at selection/point, add highlight+comment, edit, delete),
// page rotate cw/ccw, Save As with tab retargeting, single-page export
// (clipboard + file), the doc-view context menu, and comment markers with
// click-to-edit.
//
// Ported semantics (portable/linux/ShenzhenPDFGtk.c unless noted):
//   add_comment_clicked / spdf_add_highlight_comment call sites (@6760/@6785),
//   edit_comment_clicked (@6883), delete_comment_clicked (@6934),
//   rotate_current_page (@6957), copy_page_clicked (@6387) →
//   spdf_save_single_page_pdf, save_active_pdf_to_path /
//   prompt_save_as_before_modification (@3485/@3537, journal item 35), the
//   page_button_press context menu (@9950), comment_index_at_page_point
//   (@6856). "Save Page as PDF…" is new on Linux (the Mac app saves pages,
//   GTK3 only copied them; both are provided, labeled distinctly).
//
// All dialogs are async (AdwAlertDialog / GtkFileDialog); every dialog chain
// revalidates that its tab still lives in its window before touching it.
#pragma once

#ifndef SPDF_ANNOT_TESTING
#include "spdf_window.h"

G_BEGIN_DECLS

// Registers this module's win.* actions on the window action map (replaces
// the Wave A stubs for win.rotate-cw / win.rotate-ccw / win.save-as and adds
// the context-menu actions). Called from spdf_window_init.
void spdf_annot_install(SpdfWindow* win);

// Attaches the context-menu and comment-marker click controllers to the
// tab's doc view and schedules the initial (idle, off the launch path)
// comment load. Called from spdf_tab_open.
void spdf_annot_tab_attached(SpdfTab* tab);

// Releases the comment cache and pending idles appended to SpdfTab.
// Called from spdf_tab_close.
void spdf_annot_tab_closing(SpdfTab* tab);

// Async write preflight (GTK3 prompt_save_as_before_modification, journal
// item 35): calls cont(win, tab, data) once the tab's PDF is writable in
// place — prompting for (and retargeting the tab to) a writable, non-temp
// Save As copy first when needed. When the flow is abandoned (cancel, save
// failure, tab gone) data_destroy runs on data instead. Rotate and the
// comment CRUD run through this; OCR/translate (Wave C) must share it.
typedef void (*SpdfAnnotContinuation)(SpdfWindow* win, SpdfTab* tab, gpointer data);
void spdf_annot_preflight(SpdfWindow* win, SpdfTab* tab, const char* action_name, int permission,
                          SpdfAnnotContinuation cont, gpointer data, GDestroyNotify data_destroy);

// The file watcher (Wave C) reloaded tab->doc in place: refresh the comment
// cache + markers against the new document.
void spdf_annot_document_reloaded(SpdfTab* tab);

// --- Wave B sidebar coordination (single consumer: spdf_sidebar.c) ----------
// Invoked on the main thread after a tab's comment cache is (re)loaded —
// initial idle load, comment CRUD, rotate, Save As retarget, document reload
// — so the sidebar's comments pane can refresh live. One hook, process-wide;
// NULL clears it. Not fired by spdf_annot_tab_closing (the tab is going away).
typedef void (*SpdfAnnotCommentsChanged)(SpdfTab* tab, gpointer user_data);
void spdf_annot_set_comments_changed_hook(SpdfAnnotCommentsChanged hook, gpointer user_data);

G_END_DECLS
#else
#include <glib.h>
#endif

G_BEGIN_DECLS

// ---------------------------------------------------------------------------
// Pure path/preflight logic (glib string logic only — no GTK, no probing),
// exercised by tests/annot_preflight_test.c. Ports of the GTK3 helpers named
// in each comment.

// path_has_pdf_extension: last extension is ".pdf", ASCII case-insensitive.
gboolean spdf_annot_path_has_pdf_extension(const char* path);

// path_is_under_directory: canonicalized prefix containment (or equality).
gboolean spdf_annot_path_is_under_directory(const char* path, const char* directory);

// path_is_in_temp_directory, with the probed directories injected so the
// rule is testable: tmp_dir (g_get_tmp_dir), runtime_dir
// (g_get_user_runtime_dir, may be NULL), plus the hard-coded /tmp and
// /var/tmp.
gboolean spdf_annot_path_is_temp_in(const char* path, const char* tmp_dir, const char* runtime_dir);

// filename_with_pdf_extension: append ".pdf" unless already present.
char* spdf_annot_filename_with_pdf_extension(const char* path);

// copy_page_clicked's name build: "<basename sans .ext> - page <n+1>.pdf".
char* spdf_annot_single_page_filename(const char* doc_path, int page_index);

// pdf_path_allows_same_folder_write's verdict, given the probed facts:
// never in a temp directory, file writable, directory writable+searchable.
gboolean spdf_annot_same_folder_write_allowed(gboolean is_temp, gboolean file_writable, gboolean dir_writable);

// prompt_save_as_before_modification's save-target rule: the chosen path
// must keep a .pdf extension and stay out of the temp directories.
gboolean spdf_annot_save_target_acceptable(const char* path, const char* tmp_dir, const char* runtime_dir);

// ---------------------------------------------------------------------------
// Thin probing wrappers (g_access / g_get_tmp_dir) over the pure rules.
gboolean spdf_annot_path_is_in_temp_directory(const char* path);
gboolean spdf_annot_pdf_path_allows_same_folder_write(const char* path);

G_END_DECLS
