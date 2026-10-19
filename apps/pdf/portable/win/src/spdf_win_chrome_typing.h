#pragma once

/* spdf_win_chrome_typing.h -- THE THREE TYPEABLE FIELDS: which buffer the
 * keyboard is talking to, one typed code unit, and a key while a field has the
 * keyboard.
 *
 * Split out of spdf_win_chrome_commands.h when the wiring pass brought that
 * file to its 500-line cap (tools/file-size-limits.md asks for an extracted
 * file rather than a raised one). The seam is the one that header's own
 * comment draws: step 2 of key_for_window() -- "THE FOCUSED FIELD, if there is
 * one" -- is this file whole, and nothing here knows a command exists. What is
 * left next door is the keymap, the command switch and the menu sync.
 *
 * Header-only and included from spdf_win_chrome_commands.h only, after
 * `struct app`, spdf_win_chrome_scene.h and spdf_win_chrome_field_ui.h (it
 * calls chrome_find_push, chrome_find_step and spdf_win_chrome_content_set_filter).
 * Not part of the port's public surface.
 */

#include "spdf_win_chrome_text.h"

/* Which buffer the keyboard is talking to, resolved once. Returning the caret by
 * pointer as well as the buffer is what lets one set of edit calls serve all
 * three; the alternative is the same seven-case switch written three times. */
typedef struct SpdfWinFocusedField {
    wchar_t* text;
    int cap; /* capacity in wchar_t, terminator included */
    int* caret;
} SpdfWinFocusedField;

static int chrome_focused_field(app* a, SpdfWinFocusedField* out) {
    out->text = NULL;
    out->cap = 0;
    out->caret = NULL;
    switch (a->focus) {
        case SPDF_WIN_FOCUS_FIND:
            out->text = a->find_text;
            out->cap = (int)(sizeof(a->find_text) / sizeof(a->find_text[0]));
            out->caret = &a->find_caret;
            return 1;
        case SPDF_WIN_FOCUS_PAGE:
            out->text = a->page_text;
            out->cap = (int)(sizeof(a->page_text) / sizeof(a->page_text[0]));
            out->caret = &a->page_caret;
            return 1;
        case SPDF_WIN_FOCUS_SIDEBAR_FILTER:
            out->text = a->filter_text;
            out->cap = (int)(sizeof(a->filter_text) / sizeof(a->filter_text[0]));
            out->caret = &a->filter_caret;
            return 1;
        default: return 0;
    }
}

/* A field's text changed: tell whatever consumes it.
 *
 * The FIND query goes to the process-wide session, which restarts the search
 * only when the query actually differs (spdf_win_find_set), so a keystroke that
 * produced the same string costs a strcmp. The FILTER goes to the panel content
 * bridge, which re-filters the outline it already has rather than reopening the
 * document. The PAGE field consumes nothing until Return -- a field that jumped
 * on every digit would send a reader typing "12" to page 1 first. */
static void chrome_field_changed(app* a) {
    if (a->focus == SPDF_WIN_FOCUS_FIND) chrome_find_push(a);
    else if (a->focus == SPDF_WIN_FOCUS_SIDEBAR_FILTER) spdf_win_chrome_content_set_filter(a->filter_text);
}

/* Return in the page field. 1-based in, 0-based to the canvas -- the one place
 * in this port where a human's page numbering exists, exactly as the toolbar
 * painter is the one place it is written out. An out-of-range or unparseable
 * number does nothing and KEEPS the focus, so the reader can correct it. */
static int chrome_commit_page(app* a) {
    int value = spdf_win_text_page_value(a->page_text);
    if (!a->canvas || value < 1 || value > spdf_win_canvas_page_count(a->canvas)) return 0;
    spdf_win_canvas_scroll_to_page(a->canvas, value - 1);
    a->focus = SPDF_WIN_FOCUS_NONE;
    return 1;
}

/* Give the keyboard back to the document. Escape's job, and the find field's
 * Escape also CLEARS the query -- which is what makes the highlights and the
 * counter go away, i.e. what a reader means by cancelling a search. The sidebar
 * filter clears for the same reason: an invisible filter still hiding rows is
 * the worst state either control can be left in. */
static int chrome_blur(app* a) {
    if (a->focus == SPDF_WIN_FOCUS_FIND) {
        spdf_win_text_clear(a->find_text, &a->find_caret);
        chrome_find_push(a);
    } else if (a->focus == SPDF_WIN_FOCUS_SIDEBAR_FILTER) {
        spdf_win_text_clear(a->filter_text, &a->filter_caret);
        spdf_win_chrome_content_set_filter(a->filter_text);
    } else if (a->focus == SPDF_WIN_FOCUS_NONE) {
        return 0;
    }
    a->focus = SPDF_WIN_FOCUS_NONE;
    return 1;
}

/* One typed code unit. The page field takes digits only; the other two take
 * anything printable, which is what makes a CJK or accented query possible at
 * all -- WM_CHAR is the layout's and the IME's output, not a key.
 *
 * WITH NO FIELD FOCUSED the character is not dropped: it STARTS a search, the
 * mac's type-to-search (documentTypeToSearchKeyDown, ShenzhenPDFMac.mm:10169),
 * through chrome_type_to_search in spdf_win_chrome_field_ui.h -- which declines
 * control characters and a window with no document, so the keymap keeps
 * those. */
static int chrome_char(app* a, unsigned unit) {
    SpdfWinFocusedField f;
    if (!chrome_focused_field(a, &f)) return chrome_type_to_search(a, unit);
    if (!spdf_win_text_is_printable(unit)) return 0;
    if (a->focus == SPDF_WIN_FOCUS_PAGE && !spdf_win_text_is_digit(unit)) return 0;
    if (!spdf_win_text_insert(f.text, f.cap, f.caret, unit)) return 0;
    chrome_field_changed(a);
    return 1;
}

/* A key while a field has the keyboard. Returns 1 when the view changed, and
 * SWALLOWS everything else (see spdf_win_chrome_commands.h's header). */
static int chrome_field_key(app* a, const spdf_win_input* in) {
    SpdfWinFocusedField f;
    int changed = 0;

    /* THE EMPTY CANVAS'S OPEN BUTTON IS A TAB STOP, and this is the whole of its
     * keyboard. It is handled here, before chrome_focused_field(), because it is
     * the one focus target that is not a text buffer -- and it is reached here at
     * all because key_for_window() forwards a bare Tab into this function even
     * with nothing focused (see its call site). Both halves in one place, so
     * "Tab reaches it, Return presses it" is four lines rather than a policy
     * spread over two files.
     *
     * SPACE AS WELL AS RETURN: that is what a focused button answers to
     * everywhere on this desktop, and there is no document for Space to scroll
     * on this window. Escape and a second Tab give the keyboard back -- with one
     * stop there is nowhere else to go, and a Tab that did nothing would look
     * like the focus had been lost. */
    if (a->focus == SPDF_WIN_FOCUS_OPEN) {
        if (in->key == SPDF_WIN_KEY_RETURN || in->key == VK_SPACE) return chrome_open_dialog(a);
        if (in->key != SPDF_WIN_KEY_TAB && in->key != SPDF_WIN_KEY_ESCAPE) return 0;
        a->focus = SPDF_WIN_FOCUS_NONE;
        return 1;
    }
    /* A BARE TAB WITH NO DOCUMENT REACHES THE BUTTON. With one, Tab is left
     * exactly as it was -- unbound, swallowed by the keymap's default -- because
     * a real focus ring order over eighteen toolbar controls is a feature this
     * port has not written and must not half-write here. */
    if (in->key == SPDF_WIN_KEY_TAB && a->focus == SPDF_WIN_FOCUS_NONE) {
        if (a->canvas) return 0;
        a->focus = SPDF_WIN_FOCUS_OPEN;
        return 1;
    }
    if (!chrome_focused_field(a, &f)) return 0;

    switch (in->key) {
        case SPDF_WIN_KEY_ESCAPE: return chrome_blur(a);
        case SPDF_WIN_KEY_TAB:
            /* Plain Tab leaves the field. Ctrl+Tab never reaches here: it is an
             * accelerator, matched before this function is called. */
            a->focus = SPDF_WIN_FOCUS_NONE;
            return 1;
        case SPDF_WIN_KEY_RETURN:
            if (a->focus == SPDF_WIN_FOCUS_PAGE) return chrome_commit_page(a);
            if (a->focus == SPDF_WIN_FOCUS_FIND)
                /* Return steps forward, Shift+Return back -- the convention every
                 * find bar on this desktop uses, and the keyboard half of the
                 * prev/next pill beside the field. */
                return chrome_find_step(a, (in->mods & SPDF_WIN_MOD_SHIFT) ? -1 : 1);
            a->focus = SPDF_WIN_FOCUS_NONE;
            return 1;
        case SPDF_WIN_KEY_BACK: changed = spdf_win_text_backspace(f.text, f.caret); break;
        case SPDF_WIN_KEY_DELETE: changed = spdf_win_text_delete(f.text, f.caret); break;
        case SPDF_WIN_KEY_LEFT: return spdf_win_text_move(f.text, f.caret, -1);
        case SPDF_WIN_KEY_RIGHT: return spdf_win_text_move(f.text, f.caret, 1);
        case SPDF_WIN_KEY_HOME: return spdf_win_text_home(f.text, f.caret);
        case SPDF_WIN_KEY_END: return spdf_win_text_end(f.text, f.caret);
        default: return 0; /* swallowed: no scrolling while typing */
    }
    if (changed) chrome_field_changed(a);
    return changed;
}
