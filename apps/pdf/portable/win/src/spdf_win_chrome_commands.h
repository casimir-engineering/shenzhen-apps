#pragma once

/* spdf_win_chrome_commands.h -- the KEYBOARD: the keymap, the three typeable
 * fields, and the one switch that performs a command whatever asked for it.
 *
 * Split out of spdf_win_main.cpp, which is at its 500-line cap and where
 * tools/file-size-limits.md asks for an extracted file rather than a raised one.
 * Header-only and included AFTER `struct app`, spdf_win_chrome_scene.h,
 * spdf_win_chrome_tabs_ui.h and spdf_win_chrome_actions.h -- it calls into all
 * four. Same arrangement as spdf_win_tabs_app.h beside it; not part of the
 * port's public surface.
 *
 * ONE SWITCH FOR EVERY ROUTE IN. A command can arrive from the menu bar
 * (WM_COMMAND), from an accelerator (WM_KEYDOWN matched against
 * spdf_win_menu.h's table) or, later, from a command palette. All three land in
 * command_perform() and therefore cannot behave differently -- which is the same
 * argument spdf_win_chrome_input.h makes for naming a mouse action after its
 * INTENT so "the keyboard and the mouse can converge on the same handler".
 *
 * THE ORDER INSIDE key_for_window() IS THE POINT, and it is:
 *
 *   1. ACCELERATORS, always, focused field or not. Ctrl+F must open the find
 *      field while the page field has the keyboard, and Ctrl+W must close the
 *      tab while the reader is halfway through a query. Every accelerator in the
 *      table carries Ctrl, Alt or a function key, so none of them is a character
 *      anyone could be trying to type.
 *   2. THE FOCUSED FIELD, if there is one. Left/Right move the caret rather than
 *      scrolling the page; Return commits; Escape gives the keyboard back to the
 *      document. An unrecognised key is SWALLOWED here rather than falling
 *      through, because a Down arrow that scrolled the document while the reader
 *      was typing in the toolbar would be indistinguishable from a bug.
 *   3. THE DOCUMENT. Exactly what it was before any of this existed.
 */

#include "spdf_win_chrome_text.h"
#include "spdf_win_clipboard_page.h"
#include "spdf_win_export.h"
#include "spdf_win_print.h"
#include "spdf_win_properties.h"
#include "spdf_win_menu.h"
#include "spdf_win_page_wheel.h" /* Alt + wheel pages, by how far the wheel turned */

/* The three typeable fields -- which buffer has the keyboard, a typed code unit,
 * a key while a field is focused. Step 2 of key_for_window() below, in its own
 * file since this one reached its cap. */
#include "spdf_win_chrome_typing.h"

/* --- commands ------------------------------------------------------------ */

/* Every command, whatever asked for it. `in` is the event that carried it, which
 * is what the zoom commands need to lay the chrome out the same way the painter
 * did -- see chrome_layout_for_input's own note on why a cached layout will not
 * do. */

/* --- the document actions: save, properties, copy page --------------------
 *
 * (Print is spdf_win_cmd_window.h's: it carries the scaling choice from
 * settings.yaml, so the case that once lived here passed a default the
 * reader could never change and was dead the moment that handler claimed it.)
 *
 * These subsystems take a document, its path as UTF-16, and a page. The
 * app holds the path as UTF-8 (the core's currency) and the document behind the
 * tab model, so this is the one place that widens and resolves. Widening here
 * rather than in each subsystem keeps the CP_UTF8 conversion in one place, which
 * is the same discipline the tab titles and the outline follow -- this machine's
 * ANSI code page is 1252 and a narrow conversion loses a CJK filename silently.
 *
 * A NULL document means no tab is open; every case below no-ops rather than
 * reaching into a half-closed tab. */
typedef struct SpdfWinDocAction {
    spdf_document* doc;
    /* 1024 == SPDF_COMPAT_PATH_MAX (spdf_win_compat.h), which matches the
     * core's own path buffers. Not the header's constant, because this file
     * does not include the compat shim; kept equal deliberately. */
    wchar_t path[1024];
    int page;
    HWND hwnd;
} SpdfWinDocAction;

static int doc_action_for(app* a, SpdfWinDocAction* act) {
    char err[256] = {0};
    const char* utf8 = NULL;
    int sel;

    memset(act, 0, sizeof(*act));
    if (!a->tabs || !a->canvas) return 0;
    sel = spdf_win_tabs_selected_index(a->tabs);
    if (sel < 0) return 0;
    act->doc = (spdf_document*)spdf_win_tabs_document(a->tabs, sel, err, sizeof(err));
    if (!act->doc) return 0;
    utf8 = spdf_win_tabs_path(a->tabs, sel);
    if (utf8 && *utf8 &&
        MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, act->path,
                            (int)(sizeof(act->path) / sizeof(act->path[0]))) == 0)
        act->path[0] = 0;
    act->page = spdf_win_canvas_current_page(a->canvas);
    act->hwnd = a->window ? (HWND)spdf_win_window_native_handle(a->window) : NULL;
    return 1;
}

/* Report a failure the way the rest of the app does. `err` empty means the user
 * cancelled a dialog, which is not a failure and says nothing. */
static void doc_action_report(app* a, const char* err) {
    wchar_t message[600];
    if (!err || !err[0]) return;
    _snwprintf_s(message, _TRUNCATE, L"%hs", err);
    report(message, a->window != NULL);
}

/* PER-TRACK COMMAND HANDLERS. Each header below owns the commands of one
 * parity track (see portable/docs/windows-feature-matrix.md) and is included
 * here, after the app struct and the chrome model are complete, so the tracks
 * can land handlers in parallel without any of them editing the switch below.
 * A handler returns 1 when it consumed the command. The order is the order
 * they are asked; no command id is claimed by two of them, so it does not
 * matter. */
#include "spdf_win_cmd_window.h"
#include "spdf_win_cmd_search.h"
#include "spdf_win_cmd_docs.h"
#include "spdf_win_cmd_tools.h"
#include "spdf_win_cmd_shell.h"
#include "spdf_win_cmd_annot.h"

static int command_perform(app* a, int command, const spdf_win_input* in) {
    SpdfWinChromeModel model;
    SpdfWinChromeLayout l;
    chrome_layout_for_input(a, in, &model, &l);

    /* The parity tracks first; everything they do not claim falls through to
     * the switch this file has always had. */
    if (spdf_win_cmd_window_perform(a, command, in)) return 1;
    if (spdf_win_cmd_search_perform(a, command, in)) return 1;
    if (spdf_win_cmd_docs_perform(a, command, in)) return 1;
    if (spdf_win_cmd_tools_perform(a, command, in)) return 1;
    if (spdf_win_cmd_shell_perform(a, command, in)) return 1;
    if (spdf_win_cmd_annot_perform(a, command, in)) return 1;

    switch (command) {
        case SPDF_WIN_CMD_OPEN:
        case SPDF_WIN_CMD_NEW_TAB: return chrome_open_dialog(a);
        case SPDF_WIN_CMD_CLOSE_TAB:
            if (!spdf_win_tabs_close_enabled(spdf_win_tabs_count(a->tabs), spdf_win_tabs_selected_index(a->tabs),
                                             a->canvas != NULL))
                return 0;
            return chrome_close_tab(a, spdf_win_tabs_selected_index(a->tabs));
        case SPDF_WIN_CMD_QUIT:
            /* WM_CLOSE rather than PostQuitMessage, so the exit runs the same
             * path the caption's X runs: DestroyWindow, then WM_DESTROY, then
             * the quit -- which is what gets the session written. */
            if (a->window) PostMessageW((HWND)spdf_win_window_native_handle(a->window), WM_CLOSE, 0, 0);
            return 0;

        case SPDF_WIN_CMD_FIRST_PAGE: return a->canvas ? spdf_win_canvas_scroll_to_page(a->canvas, 0) : 0;
        case SPDF_WIN_CMD_LAST_PAGE:
            return a->canvas ? spdf_win_canvas_scroll_to_page(a->canvas, spdf_win_canvas_page_count(a->canvas) - 1) : 0;
        case SPDF_WIN_CMD_PREV_PAGE: return chrome_step_page(a, -1);
        case SPDF_WIN_CMD_NEXT_PAGE: return chrome_step_page(a, 1);
        case SPDF_WIN_CMD_GOTO_PAGE: return chrome_focus(a, SPDF_WIN_FOCUS_PAGE);
        case SPDF_WIN_CMD_PREV_TAB:
        case SPDF_WIN_CMD_NEXT_TAB:
            /* Where the reader is in the tab being left is written back first,
             * so returning to it lands on the same page. */
            spdf_win_tabs_app_remember(a->tabs, a->canvas);
            spdf_win_tabs_select_relative(a->tabs, command == SPDF_WIN_CMD_NEXT_TAB ? 1 : -1);
            return show_selected_tab(a);

        case SPDF_WIN_CMD_ZOOM_IN: return chrome_zoom_step(a, &l, 1);
        case SPDF_WIN_CMD_ZOOM_OUT: return chrome_zoom_step(a, &l, 0);
        case SPDF_WIN_CMD_ZOOM_ACTUAL:
        case SPDF_WIN_CMD_FIT_PAGE:
        case SPDF_WIN_CMD_FIT_WIDTH:
        case SPDF_WIN_CMD_FIT_HEIGHT: {
            spdf_win_zoom_mode mode = command == SPDF_WIN_CMD_ZOOM_ACTUAL  ? SPDF_WIN_ZOOM_ACTUAL
                                      : command == SPDF_WIN_CMD_FIT_PAGE   ? SPDF_WIN_ZOOM_FIT_PAGE
                                      : command == SPDF_WIN_CMD_FIT_WIDTH  ? SPDF_WIN_ZOOM_FIT_WIDTH
                                                                           : SPDF_WIN_ZOOM_FIT_HEIGHT;
            if (!a->canvas) return 0;
            spdf_win_canvas_set_zoom_mode(a->canvas, mode);
            return 1;
        }

        case SPDF_WIN_CMD_TOGGLE_SIDEBAR: a->show_sidebar = !a->show_sidebar; return 1;
        case SPDF_WIN_CMD_TOGGLE_MINIMAP: a->show_minimap = !a->show_minimap; return 1;
        case SPDF_WIN_CMD_TOGGLE_THEME: return chrome_toggle_theme(a);
        /* The Markdown reader's A-/A+: re-lays the selected tab out at the new
         * size and persists it; inert on a PDF tab (spdf_win_md_commands.h). */
        case SPDF_WIN_CMD_MD_TEXT_SMALLER: return spdf_win_md_command_text_step(a, -1);
        case SPDF_WIN_CMD_MD_TEXT_LARGER: return spdf_win_md_command_text_step(a, 1);

        /* CF_UNICODETEXT, inside the canvas. Returns 1 when something was
         * copied; a Ctrl+C with nothing selected is not a failure and does not
         * repaint. The clipboard cannot be opened at all while the workstation
         * is locked (OpenClipboard fails with ERROR_ACCESS_DENIED), which the
         * canvas reports as "nothing copied" -- correct behaviour, not a bug. */
        case SPDF_WIN_CMD_COPY: return a->canvas ? spdf_win_canvas_copy_selection(a->canvas) : 0;
        case SPDF_WIN_CMD_FIND: return chrome_focus(a, SPDF_WIN_FOCUS_FIND);
        case SPDF_WIN_CMD_FIND_NEXT: return chrome_find_step(a, 1);
        case SPDF_WIN_CMD_FIND_PREV: return chrome_find_step(a, -1);
        case SPDF_WIN_CMD_SAVE_AS:
        case SPDF_WIN_CMD_SAVE_PAGE_AS:
        case SPDF_WIN_CMD_COPY_PAGE:
        case SPDF_WIN_CMD_COPY_PAGE_TEXT:
        case SPDF_WIN_CMD_COPY_PAGE_IMAGE: {
            SpdfWinDocAction act;
            char err[512] = {0};
            char saved[1024] = {0};
            unsigned long os_error = 0;
            if (!doc_action_for(a, &act)) return 0;
            switch (command) {
                case SPDF_WIN_CMD_SAVE_AS:
                    spdf_win_export_save_document_as(act.hwnd, act.doc, act.path, err, sizeof(err), saved,
                                                     sizeof(saved));
                    break;
                case SPDF_WIN_CMD_SAVE_PAGE_AS:
                    spdf_win_export_save_page_as(act.hwnd, act.doc, act.path, act.page, err, sizeof(err), saved,
                                                 sizeof(saved));
                    break;
                case SPDF_WIN_CMD_COPY_PAGE:
                    spdf_win_copy_page_pdf(act.doc, act.page, act.path, err, sizeof(err), &os_error);
                    break;
                case SPDF_WIN_CMD_COPY_PAGE_TEXT:
                    spdf_win_copy_page_text(act.doc, act.page, err, sizeof(err), &os_error);
                    break;
                default:
                    spdf_win_copy_page_image(act.doc, act.page, 0.0, err, sizeof(err), &os_error);
                    break;
            }
            /* A SAVE ONTO THE DOCUMENT'S OWN PATH IS A SELF-SAVE, and the file
             * watcher has to be told so, or it stats the file, sees a size and
             * mtime that differ from its baseline, calls it an external change
             * and reloads the tab out from under the reader -- for a write the
             * app itself just made. Rotate's in-place save has always noted
             * this; Save As never did, and Save As onto the same path is how a
             * reader "saves" a rotated or repaired document.
             *
             * The SELECTED tab's path only. If the reader saved over some OTHER
             * open tab's file, that tab's content on disk really has changed
             * relative to what it is holding, and reloading it is right.
             * spdf_win_recents_path_equal is the comparison because the dialog
             * can hand back the same file spelled differently ("c:/x/a.pdf" for
             * "C:\x\a.pdf"), and note_self_save is keyed on the watched path. */
            if (saved[0]) {
                const char* own = docs_selected_path(a);
                if (own && spdf_win_recents_path_equal(saved, own)) spdf_win_tabs_open_note_self_save(own);
            }
            doc_action_report(a, err);
            return 0; /* nothing on screen changed */
        }

        case SPDF_WIN_CMD_FIND_REGEX:
            a->find_regex = !a->find_regex;
            chrome_find_push(a);
            return 1;
        default: return 0;
    }
}

/* The check marks and the greying, from the app's actual state. Called after
 * anything that could have changed one; a couple of dozen CheckMenuItem calls,
 * which is nothing against the frame it accompanies. */
static void chrome_sync_menu(app* a) {
    SpdfWinMenuState st;
    if (!a->menu) return;
    memset(&st, 0, sizeof(st));
    st.sidebar_visible = a->show_sidebar;
    st.minimap_visible = a->show_minimap;
    st.dark_theme = (a->render_flags & SPDF_RENDER_DARK_THEME) != 0;
    st.keep_image_colors = (a->render_flags & SPDF_RENDER_PRESERVE_IMAGES) != 0;
    st.regex = a->find_regex;
    st.regex_multiline = spdf_win_find_regex_multiline();
    st.has_document = a->canvas != NULL;
    st.tab_count = spdf_win_tabs_count(a->tabs);
    st.can_close_tab = spdf_win_tabs_close_enabled(spdf_win_tabs_count(a->tabs), spdf_win_tabs_selected_index(a->tabs),
                                                   a->canvas != NULL);
    /* The document's own print flag, so Print greys out before the reader picks
     * it rather than being refused afterwards. Resolved through the tab model
     * because the app holds no document of its own in windowed mode. */
    if (a->tabs && a->canvas) {
        SpdfWinDocAction act;
        st.can_print = doc_action_for(a, &act) ? spdf_win_print_allowed(act.doc) : 0;
    }
    spdf_win_menu_sync(a->menu, &st);
}

/* --- the keymap ---------------------------------------------------------
 *
 * Deliberately here and not in spdf_win_window.cpp: which key pages forward is
 * product policy, and the window has no business knowing a document exists.
 *
 * A KEY THAT MOVES THE VIEW MEASURES THE CANVAS, NOT THE CLIENT AREA. `in`
 * carries the client size, and the canvas is a sub-rect of it: a Page Down of
 * 0.9 client heights overshoots by the two 42 pt bands, and a `+` about the
 * client centre zooms about a point that is not the middle of the page. So the
 * client area is divided here with the same function the painter uses. */
static int key_for_window(app* a, const spdf_win_input* in) {
    SpdfWinChromeModel model;
    SpdfWinChromeLayout l;
    float page_step, line = 60.0f;
    /* _ex, not the bare matcher: the table names its keys by virtual-key code
     * and VK_OEM_MINUS is on no French key at all, so Zoom Out had no French
     * accelerator (spdf_win_menu_layout.h has the measurement). The character
     * the ACTIVE layout puts on the key recovers it, exactly as the mac's
     * `keyEquivalent:@"-"` does, and `text_key` keeps an AltGr character from
     * being read as a Ctrl+Alt accelerator. */
    int command = spdf_win_menu_command_for_key_ex(in->key, in->key_char, in->mods, in->text_key);

    if (command != SPDF_WIN_CMD_NONE) return command_perform(a, command, in);
    /* A BARE TAB GOES THERE TOO, focused or not: with no document it moves the
     * keyboard onto the empty canvas's Open button (spdf_win_chrome_typing.h). */
    if (a->focus != SPDF_WIN_FOCUS_NONE || in->key == SPDF_WIN_KEY_TAB) return chrome_field_key(a, in);

    chrome_layout_for_input(a, in, &model, &l);
    page_step = l.canvas.h * 0.9f;

    /* PRESENTING: the arrows, Page Up/Down and Space turn PAGES, not lines --
     * SPDFMacPresentationIntegration.mm's keyDown (left/up/page-up back;
     * right/down/page-down/space forward), through the same step the pointer
     * uses. Everything else falls through to the keymap below. */
    if (a->presentation) {
        switch (in->key) {
            case SPDF_WIN_KEY_LEFT:
            case SPDF_WIN_KEY_UP:
            case SPDF_WIN_KEY_PRIOR: return presentation_step_page(a, -1);
            case SPDF_WIN_KEY_RIGHT:
            case SPDF_WIN_KEY_DOWN:
            case SPDF_WIN_KEY_NEXT:
            case VK_SPACE: return presentation_step_page(a, 1);
            default: break;
        }
    }

    switch (in->key) {
        /* ESCAPE, WITH NOTHING FOCUSED: end any pointer gesture and drop the
         * selection. Returning 0 when there was nothing to drop is deliberate --
         * spdf_win_window.cpp then leaves full screen if the window is in it and
         * otherwise does nothing at all (it used to close the window, which macOS
         * never did: windows-feature-matrix.md gap 2, pinned by
         * window_keys_test.c). So Escape dismisses the most local thing there is,
         * then presentation or full screen, and never the window. */
        case SPDF_WIN_KEY_ESCAPE:
            spdf_win_canvas_pointer_cancel(a->canvas);
            a->drag = SPDF_WIN_CA_NONE;
            return spdf_win_canvas_clear_selection(a->canvas);
        case SPDF_WIN_KEY_DOWN: return spdf_win_canvas_scroll_by(a->canvas, 0.0f, line);
        case SPDF_WIN_KEY_UP: return spdf_win_canvas_scroll_by(a->canvas, 0.0f, -line);
        case SPDF_WIN_KEY_RIGHT: return spdf_win_canvas_scroll_by(a->canvas, line, 0.0f);
        case SPDF_WIN_KEY_LEFT: return spdf_win_canvas_scroll_by(a->canvas, -line, 0.0f);
        case SPDF_WIN_KEY_NEXT:
        case VK_SPACE: return spdf_win_canvas_scroll_by(a->canvas, 0.0f, page_step);
        case SPDF_WIN_KEY_PRIOR: return spdf_win_canvas_scroll_by(a->canvas, 0.0f, -page_step);
        case SPDF_WIN_KEY_HOME: return spdf_win_canvas_scroll_to(a->canvas, 0.0f, 0.0f);
        case SPDF_WIN_KEY_END: return spdf_win_canvas_scroll_to(a->canvas, 0.0f, spdf_win_canvas_content_h(a->canvas));
        /* The two KEYPAD keys, which are the same virtual-key codes on every
         * layout there is. The main row's `+` and `-` are below, by character:
         * on a French keyboard the '-' key reports VK_6 and VK_OEM_MINUS does
         * not exist, so naming the code here bound nothing at all. */
        case SPDF_WIN_KEY_ADD: return chrome_zoom_step(a, &l, 1);
        case SPDF_WIN_KEY_SUBTRACT: return chrome_zoom_step(a, &l, 0);
        default: break;
    }

    /* Unmodified `+` and `-`, which this port has always had -- by the character
     * the ACTIVE layout puts on the key, which is how the mac's
     * `keyEquivalent:@"+"`/@"-" behave and the only spelling that reaches a
     * reader who is not on a US keyboard. '=' counts as '+' for the same reason
     * the accelerator table carries a Ctrl+= row: it is the key '+' is printed
     * on. Shared with the toolbar's zoom pill through chrome_zoom_step, so the
     * two cannot drift apart.
     *
     * CTRL AND ALT DISQUALIFY: a Ctrl combination the table did not claim is an
     * accelerator nobody bound, not a bare zoom key. (It used to zoom -- the
     * switch above tested the virtual-key code and never looked at `mods`.)
     *
     * SHIFT DISQUALIFIES '-' AND NOT '=', because that is where the glyphs are:
     * on both layouts '-' is the unshifted position of its key and '+' is the
     * shifted position of '='. Without the rule a French reader typing '6' --
     * which is Shift on the key whose unshifted character is '-' -- would zoom
     * out on every digit. */
    if (in->mods & (SPDF_WIN_MOD_CTRL | SPDF_WIN_MOD_ALT)) return 0;
    switch (spdf_win_menu_zoom_char(in->key, in->key_char)) {
        case '+':
        case '=': return chrome_zoom_step(a, &l, 1);
        case '-': return (in->mods & SPDF_WIN_MOD_SHIFT) ? 0 : chrome_zoom_step(a, &l, 0);
        default: return 0;
    }
}

/* --- Alt + wheel: the page arrows, wherever the pointer is ----------------
 *
 * Decided HERE, before the wheel is routed by position (chrome_wheel), because
 * "regardless of where you hover" is the point: the mac routes it from the
 * window's -sendEvent: for the same reason. The policy -- one notch is one
 * page, a fast spin earns several, the remainder carries -- is
 * spdf_win_page_wheel.h; this is the glue: the notch the window converted the
 * wheel into, the clock, and the page arrows themselves (chrome_step_page, so a
 * fitted page simply advances and a zoomed page lands on the next page at the
 * same zoom, exactly as the toolbar arrows do). Consumed whether or not a page
 * turned, so an Alt + wheel never also scrolls whatever is under the pointer.
 *
 * Alt + Ctrl + wheel never arrives: the window routes every Ctrl + wheel to
 * SPDF_WIN_INPUT_ZOOM first, which is the mac's "Command and Control already
 * mean zoom". Shift rides along -- the window put the distance in dx, so the
 * vertical is taken when there is one and the horizontal otherwise. */
static int chrome_page_wheel(app* a, const spdf_win_input* in) {
    static SpdfWinPageWheel wheel;
    UINT lines = 3;
    double notch, delta;
    int pages, i, changed = 0;
    SystemParametersInfoW(SPI_GETWHEELSCROLLLINES, 0, &lines, 0);
    notch = spdf_win_page_wheel_notch_px(lines, in->dpi_scale, in->view_px_h);
    delta = fabs(in->dy) > 1e-4f ? in->dy : in->dx;
    pages = spdf_win_page_wheel_step(&wheel, delta, notch, (double)GetTickCount64() / 1000.0);
    /* A COUNT: a fast spin earns several pages and must get them all. The
     * document's ends stop the loop, as they stop the arrows. */
    for (i = 0; i < pages; ++i) changed |= chrome_step_page(a, 1);
    for (i = 0; i > pages; --i) changed |= chrome_step_page(a, -1);
    return changed;
}

/* --- the one input entry point ------------------------------------------ */

static int input_for_window(void* user, spdf_win_input* in) {
    app* a = (app*)user;
    int changed;

    /* A DROP AND A COMMAND ARE HANDLED WITH NO DOCUMENT OPEN, which is what
     * makes the app recoverable from its own empty state: with no canvas there
     * is nothing to scroll and nothing to click, but File > Open and a dropped
     * file must still work. Everything below this line needs a canvas. */
    if (in->kind == SPDF_WIN_INPUT_DROP_FILE) {
        changed = chrome_open_wide(a, in->text);
        chrome_sync_menu(a);
        return changed;
    }
    if (in->kind == SPDF_WIN_INPUT_COMMAND) {
        changed = command_perform(a, (int)in->key, in);
        chrome_sync_menu(a);
        return changed;
    }

    /* NO EARLY RETURN FOR A MISSING CANVAS, and that is deliberate.
     *
     * There used to be an `if (!a->canvas) return 0;` here, from when the whole
     * client area was document. Now the strip IS the title bar, and on a bare
     * launch -- no session to restore -- the window has chrome and no canvas: the
     * guard swallowed the cursor query, so WM_NCHITTEST answered HTCLIENT across
     * the empty strip and the window could not be dragged, its caption buttons
     * were dead, the `+` did nothing, and Ctrl+O -- the very thing the empty
     * window's own hint tells the reader to press -- never reached the keymap.
     *
     * Every path below tolerates a NULL canvas, and that was checked rather than
     * assumed: no file in the input layer touches a canvas member directly
     * (grep for `a->canvas->` finds nothing), and every spdf_win_canvas_*
     * entry point returns early or a neutral value on NULL. The find bridge
     * accepts a NULL path. So with no document a scroll is a no-op, a click on
     * the strip drags or selects a tab, a caption button minimises or closes,
     * and a keystroke reaches the same keymap it always did. */
    switch (in->kind) {
        /* Alt + wheel is the page arrows wherever the pointer is
         * (chrome_page_wheel above); any other wheel goes where the pointer is:
         * the strip, the Search list or the document (chrome_wheel,
         * spdf_win_chrome_field_ui.h). */
        case SPDF_WIN_INPUT_SCROLL:
            if (spdf_win_page_wheel_modifiers_page(in->mods)) return chrome_page_wheel(a, in);
            return chrome_wheel(a, in);
        case SPDF_WIN_INPUT_ZOOM: return chrome_zoom_at_client(a, in);
        case SPDF_WIN_INPUT_CHAR: return chrome_char(a, in->key);
        /* A worker's message to the window (spdf_win_window.h). The only one so
         * far: a Markdown document's remote images landed in the cache, so the
         * tab is re-shown and the placeholders become pictures. */
        case SPDF_WIN_INPUT_APP_MESSAGE:
            /* A canvas render landed: the next paint adopts it from the cache
             * as it always did, so all this owes is the invalidate. */
            if (in->key == SPDF_WIN_WM_RENDER_READY) return 1;
            /* The Markdown file's off-thread re-read is ready: swap it under
             * the canvas, keeping the reader's place (spdf_win_md_commands.h). */
            if (in->key == SPDF_WIN_MD_WM_RELOADED) return spdf_win_md_command_reloaded(a);
            return in->key == SPDF_WIN_MD_WM_IMAGES_ARRIVED ? spdf_win_md_command_images_arrived(a) : 0;
        case SPDF_WIN_INPUT_KEY:
            changed = key_for_window(a, in);
            chrome_sync_menu(a);
            return changed;
        /* Every mouse event goes through the chrome router FIRST, and reaches the
         * document's pan only as SPDF_WIN_CA_CANVAS. */
        case SPDF_WIN_INPUT_MOUSE_DOWN:
            changed = chrome_mouse(a, in);
            chrome_sync_menu(a);
            return changed;
        /* The right button too: a page BACK while presenting, nothing otherwise
         * (chrome_mouse hands it to presentation_mouse first). */
        case SPDF_WIN_INPUT_CONTEXT:
        case SPDF_WIN_INPUT_MOUSE_UP:
        case SPDF_WIN_INPUT_MOUSE_MOVE:
        case SPDF_WIN_INPUT_CURSOR: return chrome_mouse(a, in);
        default: return 0;
    }
}
