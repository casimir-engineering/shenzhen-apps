/* spdf_win_chrome_text.h — the three typeable fields, as arithmetic.
 *
 * WHAT THIS IS: a caret and a fixed UTF-16 buffer, and the seven edits a
 * single-line field supports. Pure, toolkit-free, header-only, no state, no
 * allocation -- the same shape as spdf_win_chrome.h, spdf_win_tabstrip.h and
 * spdf_win_chrome_toolbar.h, and testable the same way
 * (portable/win/tests/chrome_text_test.c).
 *
 * WHY NOT AN EDIT CONTROL. A real child HWND in the toolbar would bring its own
 * font, its own colours, its own focus ring and its own DPI behaviour, none of
 * which match the Direct2D chrome drawn around it -- and it would put a piece of
 * the window outside spdf_win_paint(), which is the one thing this port's whole
 * verification strategy depends on staying whole (spdf_win_d2d.h: the compose
 * path must never require an HWND). The fields are already DRAWN by the chrome
 * painters; what was missing was somewhere for the characters to go. This is
 * that, and it costs no window and no toolkit.
 *
 * WHAT IT DELIBERATELY DOES NOT HAVE: selection, undo, and mouse-positioned
 * carets. A find field and a page field are three to twelve characters long and
 * every one of those features needs a text-metric pass (where IS the caret, in
 * pixels?) that would drag DirectWrite into this header and out of every test
 * that can run without a device. Ctrl+A is therefore "select all" only in the
 * sense that clears the field, and the caret moves by key. Named here so the
 * absence is a decision rather than an oversight.
 *
 * SURROGATE PAIRS. WM_CHAR delivers one UTF-16 code unit per message, so an
 * astral character arrives as two calls to spdf_win_text_insert(). Inserting
 * them one at a time is correct because the caret only ever moves over units
 * that are already in the buffer; what would NOT be correct is a backspace that
 * removes one unit of a pair, so spdf_win_text_backspace() removes both. Nothing
 * else in this file has to know surrogates exist.
 */
#ifndef SPDF_WIN_CHROME_TEXT_H
#define SPDF_WIN_CHROME_TEXT_H

#include <wchar.h>

#if defined(_MSC_VER) && !defined(__cplusplus)
#define SPDF_WIN_TEXT_INLINE __inline
#else
#define SPDF_WIN_TEXT_INLINE inline
#endif

/* Which field the keyboard is talking to. Carried in SpdfWinChromeModel so a
 * painter can draw the focus ring on the right rectangle, and in `struct app` so
 * a WM_CHAR knows where to go.
 *
 * NONE is not "no field" so much as "the DOCUMENT has focus": with nothing
 * focused the arrow keys scroll and `+` zooms, which is the behaviour this port
 * already had and must not lose the moment a field exists. */
typedef enum spdf_win_text_focus {
    SPDF_WIN_FOCUS_NONE = 0,
    SPDF_WIN_FOCUS_FIND,
    SPDF_WIN_FOCUS_PAGE,
    SPDF_WIN_FOCUS_SIDEBAR_FILTER,
    /* NOT A FIELD, and the only member of this enum that is not. The empty
     * canvas's "Open a PDF…" button (spdf_win_chrome_empty.h) is a Tab stop, and
     * this enum is where the window already keeps "what does the keyboard belong
     * to" -- one value the app stores, which is the same argument
     * spdf_win_chrome_input.h makes for three FOCUS_* actions rather than one
     * carrying a field id: a second variable kept beside this one is a variable
     * that can go stale against it. chrome_focused_field() returns 0 for it, so
     * no edit call can ever be handed a NULL buffer, and chrome_field_key()
     * answers Return and Space for it before it asks for one. */
    SPDF_WIN_FOCUS_OPEN
} spdf_win_text_focus;

/* Is this a code unit a field should accept? Everything below space is a
 * control character -- Windows sends WM_CHAR for Backspace (8), Tab (9), Return
 * (13) and Escape (27), all of which are handled as KEYS -- and 0x7F is Ctrl+
 * Backspace. Accepting them would put a literal 0x08 in the query and search for
 * it. */
static SPDF_WIN_TEXT_INLINE int spdf_win_text_is_printable(unsigned unit) {
    return unit >= 0x20u && unit != 0x7Fu;
}

/* A digit-only field: the page number. Applied at the field rather than in the
 * shared insert, because the find field must take every character there is. */
static SPDF_WIN_TEXT_INLINE int spdf_win_text_is_digit(unsigned unit) {
    return unit >= L'0' && unit <= L'9';
}

/* Length in code units, with a NULL buffer reading as empty so every function
 * below tolerates one. */
static SPDF_WIN_TEXT_INLINE int spdf_win_text_len(const wchar_t* text) {
    int n = 0;
    if (!text) return 0;
    while (text[n]) ++n;
    return n;
}

/* Clamp a caret into a buffer. Called at the top of every edit, because a caret
 * can be left stale by anything that replaces the text from outside -- a
 * restored session, a click that clears the field -- and an insert at a caret
 * past the terminator would write over whatever is beyond it. */
static SPDF_WIN_TEXT_INLINE int spdf_win_text_clamp_caret(const wchar_t* text, int caret) {
    int n = spdf_win_text_len(text);
    if (caret < 0) return 0;
    if (caret > n) return n;
    return caret;
}

/* Insert one code unit at the caret. `cap` is the buffer's capacity in wchar_t
 * INCLUDING the terminator. Returns 1 when the text changed.
 *
 * A full field silently refuses rather than truncating from the front: a query
 * that quietly loses its first characters searches for something the reader did
 * not type. */
static SPDF_WIN_TEXT_INLINE int spdf_win_text_insert(wchar_t* text, int cap, int* caret, unsigned unit) {
    int n, i, c;
    if (!text || !caret || cap < 2) return 0;
    n = spdf_win_text_len(text);
    /* CLAMPED BEFORE THE REFUSAL, NOT AFTER. Every early return in this file
     * normalises the caret first, so a caret left stale by something that
     * replaced the text is repaired by the very next keystroke even when that
     * keystroke does nothing else. Returning without writing it back leaves the
     * stale value in place for the NEXT edit to act on -- which is an insert at
     * an index past the terminator. */
    c = spdf_win_text_clamp_caret(text, *caret);
    *caret = c;
    if (n + 1 >= cap) return 0;
    for (i = n; i > c; --i) text[i] = text[i - 1];
    text[c] = (wchar_t)unit;
    text[n + 1] = L'\0';
    *caret = c + 1;
    return 1;
}

/* Is this unit the low half of a surrogate pair? Only used by backspace. */
static SPDF_WIN_TEXT_INLINE int spdf_win_text_is_low_surrogate(wchar_t u) {
    return u >= 0xDC00 && u <= 0xDFFF;
}

static SPDF_WIN_TEXT_INLINE int spdf_win_text_is_high_surrogate(wchar_t u) {
    return u >= 0xD800 && u <= 0xDBFF;
}

/* Remove the character before the caret. One CHARACTER, so a surrogate pair goes
 * as a unit -- half a pair left in a query is an unpaired surrogate that no
 * conversion to UTF-8 can represent. */
static SPDF_WIN_TEXT_INLINE int spdf_win_text_backspace(wchar_t* text, int* caret) {
    int c, take = 1, i, n;
    if (!text || !caret) return 0;
    c = spdf_win_text_clamp_caret(text, *caret);
    *caret = c; /* see spdf_win_text_insert on why this precedes the refusal */
    if (c <= 0) return 0;
    if (c >= 2 && spdf_win_text_is_low_surrogate(text[c - 1]) && spdf_win_text_is_high_surrogate(text[c - 2])) take = 2;
    n = spdf_win_text_len(text);
    for (i = c - take; i + take <= n; ++i) text[i] = text[i + take];
    *caret = c - take;
    return 1;
}

/* Remove the character AFTER the caret (the Delete key). Same surrogate rule. */
static SPDF_WIN_TEXT_INLINE int spdf_win_text_delete(wchar_t* text, int* caret) {
    int c, take = 1, i, n;
    if (!text || !caret) return 0;
    n = spdf_win_text_len(text);
    c = spdf_win_text_clamp_caret(text, *caret);
    *caret = c; /* see spdf_win_text_insert on why this precedes the refusal */
    if (c >= n) return 0;
    if (c + 1 < n && spdf_win_text_is_high_surrogate(text[c]) && spdf_win_text_is_low_surrogate(text[c + 1])) take = 2;
    for (i = c; i + take <= n; ++i) text[i] = text[i + take];
    *caret = c;
    return 1;
}

/* Caret motion. `delta` is -1 or 1; the surrogate rule applies here too, so the
 * caret never lands between the halves of one character. Returns 1 when it
 * moved, which is what tells the caller whether a repaint is owed. */
static SPDF_WIN_TEXT_INLINE int spdf_win_text_move(const wchar_t* text, int* caret, int delta) {
    int n, c, want;
    if (!text || !caret) return 0;
    n = spdf_win_text_len(text);
    c = spdf_win_text_clamp_caret(text, *caret);
    want = c + (delta < 0 ? -1 : 1);
    if (want < 0 || want > n) {
        *caret = c;
        return 0;
    }
    if (want > 0 && want < n && spdf_win_text_is_low_surrogate(text[want]) &&
        spdf_win_text_is_high_surrogate(text[want - 1]))
        want += delta < 0 ? -1 : 1;
    if (want < 0) want = 0;
    if (want > n) want = n;
    *caret = want;
    return want != c;
}

static SPDF_WIN_TEXT_INLINE int spdf_win_text_home(const wchar_t* text, int* caret) {
    int c;
    if (!text || !caret) return 0;
    c = spdf_win_text_clamp_caret(text, *caret);
    *caret = 0;
    return c != 0;
}

static SPDF_WIN_TEXT_INLINE int spdf_win_text_end(const wchar_t* text, int* caret) {
    int n, c;
    if (!text || !caret) return 0;
    n = spdf_win_text_len(text);
    c = spdf_win_text_clamp_caret(text, *caret);
    *caret = n;
    return c != n;
}

static SPDF_WIN_TEXT_INLINE int spdf_win_text_clear(wchar_t* text, int* caret) {
    int had;
    if (!text) return 0;
    had = text[0] != L'\0';
    text[0] = L'\0';
    if (caret) *caret = 0;
    return had;
}

/* The page field's value, or -1 when it holds nothing usable. 1-BASED in, as the
 * reader types it; the caller subtracts the one, because page numbers are
 * 0-based everywhere inside this port (spdf_win_main.cpp's header comment) and
 * the field is the one place a human's numbering is allowed to exist. */
static SPDF_WIN_TEXT_INLINE int spdf_win_text_page_value(const wchar_t* text) {
    int value = 0, digits = 0, i;
    if (!text) return -1;
    for (i = 0; text[i]; ++i) {
        if (!spdf_win_text_is_digit((unsigned)text[i])) return -1;
        /* Cap rather than overflow: a reader who holds a digit key down must get
         * "past the end", not a negative page. */
        if (value < 100000000) value = value * 10 + (int)(text[i] - L'0');
        ++digits;
    }
    if (!digits || value < 1) return -1;
    return value;
}

#endif /* SPDF_WIN_CHROME_TEXT_H */
