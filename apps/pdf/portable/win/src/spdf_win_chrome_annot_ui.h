#pragma once

/* spdf_win_chrome_annot_ui.h -- the comment FLOWS: add a highlight or a note,
 * edit, delete, set the author, the hover preview and the canvas's context
 * menu. What spdf_annot.c section 3 does for GTK and ShenzhenPDFMac.mm's
 * addComment: / editComment: / deleteComment: / setCommentAuthor: do for the
 * mac, over the Windows dialogs (spdf_win_annot_dialog.h) and the cache
 * (spdf_win_annot.h).
 *
 * Header-only and included from spdf_win_chrome_actions.h after
 * spdf_win_chrome_view_ui.h (it calls chrome_rebuild_canvas) and before
 * chrome_perform, which calls into it; spdf_win_cmd_annot.h, included later
 * from the command switch, calls the same functions -- so a badge click and
 * Edit > Edit Comment cannot behave differently. Same arrangement as every
 * other *_ui.h beside it; not part of the port's public surface.
 *
 * THE WRITE PATH, and why it rebuilds the canvas rather than re-measuring a
 * page as Rotate does. spdf_win_render.h:60 says worker documents are keyed
 * on path alone and "re-opening after such a rewrite is not wired up"; the
 * workers open their handle once per thread and keep it. So after this
 * process writes the file, a page a worker later prefetches would come from
 * the OLD bytes -- the highlight the reader just added, gone the next time
 * the page scrolls back in. The watcher's reload (spdf_win_watch_app.h) and
 * the theme toggle (chrome_rebuild_canvas) both destroy the canvas, which
 * frees its render service, which joins the workers, whose thread exit closes
 * the handle; the new canvas's workers open the saved file. That is the
 * proven path, and the reader's place survives it whole (remember +
 * apply_view). The document handle the UI thread holds is the one the core
 * mutated and saved, so it stays.
 *
 * READ-ONLY DOCUMENTS are refused with a message, not silently. GTK runs a
 * Save As preflight (spdf_annot_preflight) and the mac
 * ensureActivePDFCanBeModifiedForOperation:; a read-only tab here renders from
 * a shadow copy (spdf_win_tabs_open.h) and its path is the unwritable source,
 * so the honest answer is to say so and point at File > Save As. The
 * document's own annotate permission ('n') is honoured as both originals do.
 */

#include "spdf_win_annot.h"
#include "spdf_win_annot_dialog.h"
#include "spdf_win_annot_model.h"
#include "spdf_win_menu.h"
#include "spdf_win_settings.h"

/* Where the reader last pointed at the page: the anchor for a note added
 * without a selection (GTK's context_page/x/y from the right-click, the mac's
 * _contextPagePoint), and the comment that was under that click. */
static int g_annot_context_page = -1;
static float g_annot_context_x, g_annot_context_y;
static int g_annot_context_comment = -1;

static int annot_utf8(const wchar_t* wide, char* out, int cap) {
    if (!out || cap <= 0) return 0;
    out[0] = '\0';
    if (!wide) return 0;
    return WideCharToMultiByte(CP_UTF8, 0, wide, -1, out, cap, NULL, NULL) > 0;
}

static int annot_wide(const char* utf8, wchar_t* out, int cap) {
    if (!out || cap <= 0) return 0;
    out[0] = L'\0';
    if (!utf8) return 0;
    return MultiByteToWideChar(CP_UTF8, 0, utf8, -1, out, cap) > 0;
}

static void annot_report(app* a, const char* heading, const char* err) {
    wchar_t message[900];
    _snwprintf_s(message, _TRUNCATE, L"%hs: %hs", heading, err && err[0] ? err : "Unknown error.");
    report(message, a->window != NULL);
}

/* The selected tab's document and path; 0 with no document. `read_only` says
 * the tab renders from a shadow copy of an unwritable source. */
static int annot_target(app* a, spdf_document** doc, char* path, size_t path_cap, int* read_only) {
    char err[256] = {0};
    int sel;
    const spdf_win_tab_view* view;
    const char* p;
    *doc = NULL;
    path[0] = '\0';
    if (read_only) *read_only = 0;
    if (!a->tabs || !a->canvas) return 0;
    sel = spdf_win_tabs_selected_index(a->tabs);
    if (sel < 0) return 0;
    *doc = (spdf_document*)spdf_win_tabs_document(a->tabs, sel, err, sizeof(err));
    if (!*doc) return 0;
    p = spdf_win_tabs_path(a->tabs, sel);
    if (!p || !*p) return 0;
    strncpy_s(path, path_cap, p, _TRUNCATE);
    view = spdf_win_tabs_view_const(a->tabs, sel);
    if (read_only && view) *read_only = view->read_only;
    return 1;
}

/* May this document be annotated, and may this file be written? Reports the
 * reason when not. */
static int annot_may_write(app* a, spdf_document* doc, const char* path, int read_only, const char* action) {
    if (!spdf_win_annot_path_has_pdf_extension(path)) {
        annot_report(a, action, "Comments can only be added to PDF files.");
        return 0;
    }
    if (!spdf_has_permission(doc, 'n')) {
        annot_report(a, action, "This document does not allow annotations.");
        return 0;
    }
    if (read_only) {
        annot_report(a, action,
                     "The document is read-only or in a temporary folder. Save a writable copy first (File > Save "
                     "As), then comment on that.");
        return 0;
    }
    return 1;
}

/* Port of annot_current_author + the mac's currentCommentAuthor: the
 * persisted author, else the account's display name, else the login name. */
static void annot_current_author(wchar_t* out, int cap) {
    const spdf_win_settings* s = spdf_win_settings_shared();
    /* GetUserNameExW(NameDisplay), the mac's NSFullUserName, resolved at run
     * time: <secext.h> wants <sspi.h>'s SEC_ENTRY first and the SECURITY_WIN32
     * define before both, which a header included mid-way through
     * spdf_win_main.cpp's chain cannot arrange; secur32.dll is on every
     * Windows and a missing export just falls through to the login name. */
    typedef BOOLEAN(WINAPI * get_user_name_ex_fn)(int, LPWSTR, PULONG);
    static get_user_name_ex_fn get_user_name_ex;
    static int looked_up;
    ULONG n = (ULONG)cap;
    out[0] = L'\0';
    if (s->comment_author[0] && annot_wide(s->comment_author, out, cap)) {
        spdf_win_annot_dialog_trim(out);
        if (out[0]) return;
    }
    if (!looked_up) {
        HMODULE secur32 = LoadLibraryW(L"secur32.dll");
        looked_up = 1;
        if (secur32) get_user_name_ex = (get_user_name_ex_fn)GetProcAddress(secur32, "GetUserNameExW");
    }
    if (get_user_name_ex && get_user_name_ex(3 /* NameDisplay */, out, &n) && out[0]) return;
    n = (ULONG)cap;
    out[0] = L'\0';
    if (!GetUserNameW(out, &n)) out[0] = L'\0';
}

/* GTK3 parity, kept by both originals: the author typed into the editor
 * becomes the default for new comments (spdf_annot.c:826-831, mac :11818). */
static void annot_remember_author(const wchar_t* author) {
    spdf_win_settings* s = spdf_win_settings_shared();
    char utf8[256];
    if (!annot_utf8(author, utf8, (int)sizeof(utf8))) return;
    if (strcmp(s->comment_author, utf8) == 0) return;
    strncpy_s(s->comment_author, sizeof(s->comment_author), utf8, _TRUNCATE);
    spdf_win_settings_commit();
}

/* After a successful write of the file -- see the header for why this is a
 * canvas rebuild. Returns 1: the view changed. */
static int annot_after_write(app* a, const char* utf8_path) {
    /* Our own write: the watcher takes the new stat as its baseline rather
     * than reporting it back as a change (the same call Rotate makes). */
    spdf_win_tabs_open_note_self_save(utf8_path);
    spdf_win_annot_invalidate();
    if (a->window) spdf_win_window_tooltip(a->window, NULL, 0, 0);
    /* The panels' thumbnails and their handle describe the old file. */
    spdf_win_chrome_content_set_document(NULL, 0);
    chrome_rebuild_canvas(a);
    return 1;
}

/* Add Comment / Highlight Selection (annot_add_comment_flow, addComment:).
 * With a selection the result is a highlight annotation carrying the comment,
 * prefilled with the selected text; without one a note at the last clicked
 * point. `require_selection` is the Highlight Selection command, which does
 * nothing at all with nothing selected, as GTK's action_add_highlight does. */
static int annot_add(app* a, int require_selection) {
    spdf_document* doc;
    char path[1024];
    int read_only = 0;
    spdf_rect rects[SPDF_WIN_ANNOT_SELECTION_RECT_MAX];
    int sel_page = -1, sel_count = 0, page;
    wchar_t author[256];
    wchar_t text[4096];
    char author8[256];
    char text8[8192];
    char err[1024] = {0};
    int ok;

    if (!annot_target(a, &doc, path, sizeof(path), &read_only)) return 0;
    sel_count = spdf_win_canvas_selection_rects(a->canvas, &sel_page, rects, SPDF_WIN_ANNOT_SELECTION_RECT_MAX);
    if (require_selection && sel_count <= 0) return 0;
    if (!annot_may_write(a, doc, path, read_only, "Could not add comment")) return 0;

    text[0] = L'\0';
    if (sel_count > 0) {
        page = sel_page;
        annot_wide(spdf_win_canvas_selection_text(a->canvas), text, (int)(sizeof(text) / sizeof(text[0])));
    } else {
        page = g_annot_context_page;
        if (page < 0 || page >= spdf_win_canvas_page_count(a->canvas)) {
            annot_report(a, "Could not add comment",
                         "Select the text to highlight, or click the spot on the page the note belongs to, first.");
            return 0;
        }
    }
    annot_current_author(author, (int)(sizeof(author) / sizeof(author[0])));
    if (!spdf_win_annot_dialog_edit(a->window ? spdf_win_window_native_handle(a->window) : NULL,
                                    (a->render_flags & SPDF_RENDER_DARK_THEME) != 0,
                                    sel_count > 0 ? L"Add Highlight Comment" : L"Add Comment", L"Add", author,
                                    (int)(sizeof(author) / sizeof(author[0])), text,
                                    (int)(sizeof(text) / sizeof(text[0]))))
        return 0;
    if (!text[0]) return 0; /* an empty comment is a cancel (annot_text_view_take_text) */
    annot_remember_author(author);
    annot_utf8(author, author8, (int)sizeof(author8));
    annot_utf8(text, text8, (int)sizeof(text8));

    if (sel_count > 0)
        ok = spdf_add_highlight_comment(doc, page, rects, sel_count, text8, author8, err, sizeof(err));
    else ok = spdf_add_text_comment(doc, page, g_annot_context_x, g_annot_context_y, text8, author8, err, sizeof(err));
    if (ok) ok = spdf_save_document(doc, path, err, sizeof(err));
    if (!ok) {
        annot_report(a, "Could not add comment", err);
        return 0;
    }
    return annot_after_write(a, path);
}

/* Edit Comment (annot_edit_comment_begin, editComment:). */
static int annot_edit(app* a, int comment_index) {
    spdf_document* doc;
    char path[1024];
    int read_only = 0;
    const spdf_comment_item* item;
    wchar_t author[256];
    wchar_t text[4096];
    char author8[256];
    char text8[8192];
    char err[1024] = {0};
    int ok;

    if (!annot_target(a, &doc, path, sizeof(path), &read_only)) return 0;
    item = spdf_win_annot_item(comment_index);
    if (!item) return 0;
    if (!annot_may_write(a, doc, path, read_only, "Could not edit comment")) return 0;
    if (item->author && item->author[0]) annot_wide(item->author, author, (int)(sizeof(author) / sizeof(author[0])));
    else annot_current_author(author, (int)(sizeof(author) / sizeof(author[0])));
    annot_wide(item->text && item->text[0] ? item->text : "", text, (int)(sizeof(text) / sizeof(text[0])));
    if (!spdf_win_annot_dialog_edit(a->window ? spdf_win_window_native_handle(a->window) : NULL,
                                    (a->render_flags & SPDF_RENDER_DARK_THEME) != 0, L"Edit Comment", L"Save", author,
                                    (int)(sizeof(author) / sizeof(author[0])), text,
                                    (int)(sizeof(text) / sizeof(text[0]))))
        return 0;
    if (!text[0]) return 0;
    annot_remember_author(author);
    annot_utf8(author, author8, (int)sizeof(author8));
    annot_utf8(text, text8, (int)sizeof(text8));
    ok = spdf_update_comment(doc, comment_index, text8, author8, err, sizeof(err));
    if (ok) ok = spdf_save_document(doc, path, err, sizeof(err));
    if (!ok) {
        annot_report(a, "Could not edit comment", err);
        return 0;
    }
    return annot_after_write(a, path);
}

/* Delete Comment (action_delete_comment + annot_delete_comment_cont,
 * deleteComment:), with the mac's confirmation text. */
static int annot_delete(app* a, int comment_index) {
    spdf_document* doc;
    char path[1024];
    int read_only = 0;
    const spdf_comment_item* item;
    char detail8[512];
    wchar_t detail[600];
    char err[1024] = {0};
    int ok;

    if (!annot_target(a, &doc, path, sizeof(path), &read_only)) return 0;
    item = spdf_win_annot_item(comment_index);
    if (!item) return 0;
    if (!annot_may_write(a, doc, path, read_only, "Could not delete comment")) return 0;
    spdf_win_annot_delete_detail(item->text, detail8, sizeof(detail8));
    annot_wide(detail8, detail, (int)(sizeof(detail) / sizeof(detail[0])));
    if (!spdf_win_annot_dialog_confirm_delete(a->window ? spdf_win_window_native_handle(a->window) : NULL,
                                              (a->render_flags & SPDF_RENDER_DARK_THEME) != 0, detail))
        return 0;
    ok = spdf_delete_comment(doc, comment_index, err, sizeof(err));
    if (ok) ok = spdf_save_document(doc, path, err, sizeof(err));
    if (!ok) {
        annot_report(a, "Could not delete comment", err);
        return 0;
    }
    g_annot_context_comment = -1;
    return annot_after_write(a, path);
}

/* Set Author for Comments (setCommentAuthor:). Nothing on screen changes. */
static int annot_set_author(app* a) {
    wchar_t author[256];
    annot_current_author(author, (int)(sizeof(author) / sizeof(author[0])));
    if (!spdf_win_annot_dialog_author(a->window ? spdf_win_window_native_handle(a->window) : NULL,
                                      (a->render_flags & SPDF_RENDER_DARK_THEME) != 0, author,
                                      (int)(sizeof(author) / sizeof(author[0]))))
        return 0;
    /* An emptied field resets to the account's name (the mac's "Comment
     * author reset."), which is what "" means in settings.yaml. */
    {
        spdf_win_settings* s = spdf_win_settings_shared();
        char utf8[256];
        annot_utf8(author, utf8, (int)sizeof(utf8));
        strncpy_s(s->comment_author, sizeof(s->comment_author), utf8, _TRUNCATE);
        spdf_win_settings_commit();
    }
    return 0;
}

/* The comment a keyboard command acts on: the one under the pointer, else
 * the one under the last click (the mac's commentIndexForEditAction: order:
 * the sidebar row, then _contextCommentIndex). */
static int annot_target_comment(void) {
    int hover = spdf_win_annot_hover();
    return hover >= 0 ? hover : g_annot_context_comment;
}

/* THE HOVER PREVIEW (updateHoveredCommentForEvent: -> documentViewHoverComment:).
 * Runs on every bare move; only a CHANGE of the hovered comment touches the
 * tooltip, so the bubble stays where it first appeared while the pointer
 * moves across the annotation, and never costs a repaint. */
static int annot_hover(app* a, const SpdfWinChromeHit* hit, const spdf_win_input* in) {
    int idx = (hit->action == SPDF_WIN_CA_CANVAS || hit->action == SPDF_WIN_CA_ANNOT_EDIT) ? hit->index : -1;
    const spdf_comment_item* item;
    char text8[2048];
    wchar_t text[2048];
    if (idx == spdf_win_annot_hover()) return 0;
    spdf_win_annot_set_hover(idx);
    if (!a->window) return 0;
    item = idx >= 0 ? spdf_win_annot_item(idx) : NULL;
    if (!item) {
        spdf_win_window_tooltip(a->window, NULL, 0, 0);
        return 0;
    }
    spdf_win_annot_hover_text(item, text8, sizeof(text8));
    annot_wide(text8, text, (int)(sizeof(text) / sizeof(text[0])));
    /* Below and to the right of the pointer, the mac's offset (+14, and clear
     * of the cursor vertically). */
    spdf_win_window_tooltip(a->window, text, (int)in->x + 14, (int)in->y + 20);
    return 0;
}

/* A press over the page remembers where, in page space, for a note added
 * without a selection, and which comment (if any) was under it. */
static void annot_note_canvas_press(const spdf_win_input* in, const SpdfWinChromeHit* hit) {
    int page = -1;
    float px = 0.0f, py = 0.0f;
    if (spdf_win_annot_client_to_page(in->x, in->y, &page, &px, &py)) {
        g_annot_context_page = page;
        g_annot_context_x = px;
        g_annot_context_y = py;
    }
    g_annot_context_comment = hit->index;
}

/* THE CANVAS'S CONTEXT MENU, GTK's annot_build_context_menu (spdf_annot.c
 * :1106-1137) row for row -- Copy; the four comment items; Copy Page, Save Page
 * as PDF, Rotate both ways; Show in Folder, Copy Path -- from the menu table's
 * own titles and accelerators, so it can never disagree with the Edit menu.
 * Selection- and hit-dependent items are greyed as annot_context_menu_pressed
 * greys them. The choice is POSTED as a command, so it runs through
 * command_perform like every other route in. Returns 0: nothing on screen
 * changed by opening a menu. */
static int annot_context_menu(app* a, const spdf_win_input* in, const SpdfWinChromeHit* hit) {
    static const int k_rows[] = {SPDF_WIN_CMD_COPY,           SPDF_WIN_CMD_NONE,        SPDF_WIN_CMD_HIGHLIGHT_SELECTION,
                                 SPDF_WIN_CMD_ADD_COMMENT,    SPDF_WIN_CMD_EDIT_COMMENT, SPDF_WIN_CMD_DELETE_COMMENT,
                                 SPDF_WIN_CMD_NONE,           SPDF_WIN_CMD_COPY_PAGE,   SPDF_WIN_CMD_SAVE_PAGE_AS,
                                 SPDF_WIN_CMD_ROTATE_CW,      SPDF_WIN_CMD_ROTATE_CCW,  SPDF_WIN_CMD_NONE,
                                 SPDF_WIN_CMD_SHOW_IN_FOLDER, SPDF_WIN_CMD_COPY_PATH};
    HMENU menu;
    HWND hwnd;
    POINT pt;
    int has_selection, has_comment, chosen;
    size_t i;

    if (hit->part != SPDF_WIN_CHROME_CANVAS || !a->canvas || !a->window) return 0;
    annot_note_canvas_press(in, hit);
    hwnd = (HWND)spdf_win_window_native_handle(a->window);
    has_selection = spdf_win_canvas_has_selection(a->canvas);
    has_comment = hit->index >= 0;
    menu = CreatePopupMenu();
    if (!menu) return 0;
    for (i = 0; i < sizeof(k_rows) / sizeof(k_rows[0]); ++i) {
        const SpdfWinMenuItem* item;
        wchar_t text[160];
        UINT flags = MF_STRING;
        if (k_rows[i] == SPDF_WIN_CMD_NONE) {
            AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
            continue;
        }
        item = spdf_win_menu_item_for_command(k_rows[i]);
        if (!item) continue;
        if (item->accel) _snwprintf_s(text, _TRUNCATE, L"%s\t%s", item->title, item->accel);
        else wcsncpy_s(text, item->title, _TRUNCATE);
        if ((k_rows[i] == SPDF_WIN_CMD_COPY || k_rows[i] == SPDF_WIN_CMD_HIGHLIGHT_SELECTION) && !has_selection)
            flags |= MF_GRAYED;
        if ((k_rows[i] == SPDF_WIN_CMD_EDIT_COMMENT || k_rows[i] == SPDF_WIN_CMD_DELETE_COMMENT) && !has_comment)
            flags |= MF_GRAYED;
        AppendMenuW(menu, flags, (UINT_PTR)(SPDF_WIN_MENU_ID_BASE + k_rows[i]), text);
    }
    pt.x = (LONG)in->x;
    pt.y = (LONG)in->y;
    ClientToScreen(hwnd, &pt);
    SetForegroundWindow(hwnd);
    chosen = (int)TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_LEFTALIGN | TPM_TOPALIGN, pt.x, pt.y, 0,
                                 hwnd, NULL);
    /* TrackPopupMenu's oldest defect, the workaround spdf_win_menu.cpp uses. */
    PostMessageW(hwnd, WM_NULL, 0, 0);
    DestroyMenu(menu);
    if (chosen > 0) PostMessageW(hwnd, WM_COMMAND, (WPARAM)chosen, 0);
    return 0;
}
