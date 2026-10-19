#pragma once

/* spdf_win_chrome_empty.h -- THE WINDOW WITH NO DOCUMENT: which of the toolbar's
 * controls it may honestly offer, and the one control it must.
 *
 * WHY THIS FILE EXISTS. A bare launch with nothing to restore drew the FULL
 * toolbar and made every control of it look live: the Side Panel switch, the two
 * power tools, a page field, the page arrows, the fit popup, the zoom pill, the
 * find group and the Map switch, all at full contrast, all inert. The only
 * affordance was one line of grey text naming a keyboard shortcut. Measured on
 * this machine, the window was foreground, enabled, unhung, answering WM_NULL in
 * 0 ms -- and a person who clicked the page arrow, dragged the zoom and flicked
 * the switch concluded, correctly on the evidence in front of them, that the
 * application was broken. That is the defect: not an unresponsive window, a
 * window that lies about what it can do.
 *
 * WHAT macOS DOES, WHICH IS WHAT THIS PORTS. It never presents an open panel at
 * launch. -performStartupDocumentWork (ShenzhenPDFMac.mm:845-877) has three
 * arms, and the "nothing to restore" one is
 * `[self showEmptyDocumentViewWithMessage:@"Open a document"]` (:860-862): a full
 * window, a full toolbar, one centred line of secondaryLabelColor text
 * (SPDFMacDocumentView.mm:509-530), and every document-dependent control
 * DISABLED one by one in -updateControls (:10218-10248). Each case below cites
 * the line that disables it. The GTK original is the same policy with less
 * decoration (spdf_window.c:142-160 desensitises the same row and shows no
 * placeholder text at all).
 *
 * THE ONE THING THIS PORT ADDS, and why. macOS's way out of the empty state is
 * File > Open in the menu bar, and this port HAS no menu bar: the whole menu
 * moved into the toolbar's `...` overflow button (spdf_win_chrome_input.h,
 * SPDF_WIN_CA_APP_MENU). A three-dot button is not an obvious way to open a
 * document, and "press Ctrl+O" is not an affordance -- it is a fact a reader has
 * to already know. So the empty canvas gets a primary button, routed to
 * SPDF_WIN_CMD_OPEN: the same command Ctrl+O and the tab strip's `+` already
 * post, so there is exactly one open dialog however it is reached.
 *
 * SAME RULES AS ITS NEIGHBOURS: pure, header-only, no app state, no toolkit, no
 * allocation -- the family spdf_win_chrome.h and spdf_win_chrome_toolbar.h
 * belong to, and testable the same way
 * (portable/win/tests/empty_state_test.c).
 *
 * INCLUDED FROM BOTH SIDES, WHICH IS THE POINT, so unlike
 * spdf_win_chrome_toolbar_route.h it depends on nothing that only exists inside
 * spdf_win_chrome_input.h: the PAINTERS reach it through
 * spdf_win_chrome_paint.h and the ROUTER through spdf_win_chrome_input.h. What
 * needs the action enum and the hit struct -- the one function that turns a
 * point into SPDF_WIN_CA_OPEN_DOC -- therefore lives next door in
 * spdf_win_chrome_toolbar_route.h, which is already the router-side half of this
 * seam and already included at the right moment.
 *
 * THE RULE IT ENFORCES, IN ONE SENTENCE: the painter and the router ask the same
 * two functions, so a control drawn dead is a control that cannot be hit, and a
 * button that is drawn is a button that can. spdf_win_chrome.h says why that has
 * to be one function rather than two agreeing ones: "hit-testing and painting
 * must agree exactly ... here they agree only if they call the same functions".
 */

#include "spdf_win_chrome_toolbar.h"
/* For SpdfWinChromeColor, which spdf_win_chrome_dim() below takes and returns.
 * spdf_win_chrome.h does NOT pull the theme in, and the router's include chain
 * (spdf_win_chrome_input.h -> spdf_win_chrome_toolbar_route.h -> here) does not
 * either -- so without this line the router's translation unit parses
 * `SpdfWinChromeColor` as an undeclared identifier, which MSVC reports as
 * "inline variables require /std:c++17" and then as a cascade of redefinitions
 * inside spdf_win_chrome_theme.h when it finally arrives. Cost ten minutes.
 * The theme header is pure, toolkit-free and #ifdef-guarded, so it costs the
 * pure tests nothing. */
#include "spdf_win_chrome_theme.h"

#if defined(_MSC_VER) && !defined(__cplusplus)
#define SPDF_WIN_CE_INLINE __inline
#else
#define SPDF_WIN_CE_INLINE inline
#endif

/* THE DISABLED LOOK, AS ONE NUMBER. 0.44 is not new: it is the alpha the find
 * pill already drew itself at with nothing to step through
 * (spdf_win_chrome_find.cpp, "what an NSSegmentedControl with both segments
 * disabled looks like"). Named here and used by both painters so the row has ONE
 * disabled appearance rather than one per author -- a second, slightly different
 * grey is how a reader learns to distrust the first. */
#define SPDF_WIN_CHROME_DISABLED_ALPHA 0.44f

/* IS THERE A DOCUMENT? `page_count`, which is exactly what macOS asks
 * (-updateControls's `BOOL hasDoc = _doc != NULL` next to
 * `spdf_page_count(_doc)`) and what the model already documents as its own
 * answer: "-1 with page_count 0 is no document" (SpdfWinChromeModel::page_index).
 * The two power tools have tested it this way since they were drawn.
 *
 * IT MUST BE THE MODEL AND NOT THE APP, because the router gets a model built by
 * chrome_layout_for_input() and the painter gets one built by
 * spdf_win_chrome_model_build(), and the whole point of this header is that both
 * reach the same verdict from the same field. (That field was memset to zero in
 * the router's model until this change, which is why the refusal below could not
 * have been written against it before: it would have refused the entire toolbar
 * on every document this app opens.) */
static SPDF_WIN_CE_INLINE int spdf_win_chrome_has_document(const SpdfWinChromeModel* m) {
    return m && m->page_count > 0;
}

/* A colour, dimmed if the control it paints is disabled. Alpha rather than a
 * second palette entry: every one of these roles already carries an alpha the
 * theme chose (spdf_win_chrome_theme.h), and multiplying keeps the relationship
 * that file exists to preserve instead of inventing fourteen "disabled" values
 * that would each have to be re-derived when the theme moves. */
static SPDF_WIN_CE_INLINE SpdfWinChromeColor spdf_win_chrome_dim(SpdfWinChromeColor c, int enabled) {
    if (!enabled) c.a *= SPDF_WIN_CHROME_DISABLED_ALPHA;
    return c;
}

/* DOES THIS CONTROL'S ACTION NEED A DOCUMENT? One switch, cited case by case to
 * the line of -updateControls that disables the same control on macOS, so the
 * list can be diffed against the original rather than argued about.
 *
 * The three that are NOT here are the interesting part:
 *
 *   SPDF_WIN_TB_SEPARATOR   decoration a hairline wide; the router already skips
 *                           it and no painter gives it a state.
 *   SPDF_WIN_TB_OVERFLOW    the app menu, which is this port's File menu and
 *                           therefore the one thing an empty window most needs.
 *                           macOS keeps the same commands live in
 *                           -validateMenuItem: (:16317-16325 whitelists
 *                           openDocument:, openRecentDocument:, showAboutPanel:
 *                           and the rest); the menu's own greying is
 *                           spdf_win_menu_rules.h's job and already reads
 *                           has_document.
 *   SPDF_WIN_TB_READING_THEME  the reading theme is a SETTING, not a property of
 *                           the document, and macOS does not disable it either
 *                           (it is absent from -updateControls's list). It was
 *                           inert here only because chrome_toggle_theme() bailed
 *                           on a NULL canvas; that bail is gone, so the button
 *                           is live because it works, not because it looks nice.
 *
 * Takes an int rather than spdf_win_toolbar_item so a caller may pass what
 * spdf_win_toolbar_hit() returned without a cast, and so this stays compilable
 * by the plain C tests. */
static SPDF_WIN_CE_INLINE int spdf_win_toolbar_item_needs_document(int item) {
    switch (item) {
        case SPDF_WIN_TB_SIDEBAR_TOGGLE: /* _sidebarToggleButton.enabled = hasDoc (:10227) */
        case SPDF_WIN_TB_OCR:            /* _ocrButton.enabled = hasDoc && pdf   (:10234) */
        case SPDF_WIN_TB_TRANSLATE:      /* the same policy, SPDFMacTranslationPolicy.mm */
        case SPDF_WIN_TB_PAGE_FIELD:     /* _pageField.enabled = hasDoc          (:10228) */
        case SPDF_WIN_TB_PAGE_COUNT:     /* the "/ 0" label beside it, created as "/ 0" (:2701) */
        case SPDF_WIN_TB_PAGE_PILL:      /* both _pageSegments                   (:10188-10189) */
        case SPDF_WIN_TB_FIT_POPUP:      /* _fitModePopup.enabled = hasDoc       (:10231) */
        case SPDF_WIN_TB_ZOOM_PILL:      /* both _zoomSegments                   (:10229-10230) */
        case SPDF_WIN_TB_MD_TEXT_PILL:   /* a text size needs text; and the pill is
                                          * in the row only on a Markdown tab anyway */
        case SPDF_WIN_TB_FIND_FIELD:     /* _searchField.enabled = hasDoc        (:10232) */
        case SPDF_WIN_TB_FIND_REGEX:     /* _findRegexCheckbox.enabled = hasDoc  (:10233) */
        case SPDF_WIN_TB_FIND_COUNT:     /* the counter beside them */
        case SPDF_WIN_TB_FIND_PILL:      /* nothing to step through */
        case SPDF_WIN_TB_MINIMAP_TOGGLE: /* _minimapToggleButton.enabled = hasDoc (:10236),
                                          * and the strip itself is force-hidden with no
                                          * document (-setMinimapActuallyVisible:, :9137) */
            return 1;
        default: return 0;
    }
}

/* Is this control live in the row the model describes? The one question both the
 * painter and the router ask, so neither can answer it for itself. */
static SPDF_WIN_CE_INLINE int spdf_win_toolbar_item_enabled(const SpdfWinChromeModel* m, int item) {
    return spdf_win_chrome_has_document(m) || !spdf_win_toolbar_item_needs_document(item);
}

/* --- the way in ---------------------------------------------------------
 *
 * A primary button in the middle of the empty canvas, under the placeholder
 * line. Its metrics are constants for the same reason every width in
 * spdf_win_chrome_toolbar.h is: the row must lay itself out with no text-metric
 * pass, which is what keeps the geometry free of DirectWrite and therefore
 * testable with no device. 168 pt holds "Open a PDF..." at the toolbar's label
 * size with Windows 11's button padding either side.
 *
 * WHERE IT SITS, and why it is below the middle rather than at it: the
 * placeholder line is drawn CENTRED in the canvas region by
 * spdf_win_d2d.cpp's draw_message(), which is macOS's own placement
 * (SPDFMacDocumentView.mm:525 puts its 44 pt text rect at midY - 18). So the
 * button starts 16 pt past the middle -- clear of that line at every DPI -- and
 * the drop hint follows it. Nothing here may move the message: it is also how
 * `a->status` reaches the reader. */
#define SPDF_WIN_CHROME_EMPTY_BUTTON_W 168.0
#define SPDF_WIN_CHROME_EMPTY_BUTTON_H 32.0
#define SPDF_WIN_CHROME_EMPTY_BUTTON_TOP 16.0 /* below the canvas's vertical middle */
#define SPDF_WIN_CHROME_EMPTY_HINT_GAP 10.0   /* between the button and the drop hint */
#define SPDF_WIN_CHROME_EMPTY_HINT_H 20.0

/* THE SMALLEST CANVAS THE BUTTON WILL APPEAR IN. Below this the button and the
 * message would overlap, and a button drawn across a line of text is worse than
 * no button -- Ctrl+O, the drop target and the overflow menu all still work.
 * Stated as a threshold rather than as a clamp because a squeezed button is a
 * button whose label is truncated to "Open a...", which reads as a bug. */
#define SPDF_WIN_CHROME_EMPTY_MIN_W 240.0
#define SPDF_WIN_CHROME_EMPTY_MIN_H 150.0

#define SPDF_WIN_CHROME_EMPTY_OPEN_LABEL L"Open a PDF…"
#define SPDF_WIN_CHROME_EMPTY_DROP_HINT L"or drop a PDF here"

/* IS THIS THE EMPTY STATE -- no document AND no tab that holds one?
 *
 * TWO TESTS, NOT ONE, and the second is the one that matters. page_count alone
 * is also 0 for a tab whose document failed to open, and that window has a
 * message of its own to show ("could not open ...", through scene->message):
 * dropping a 168 pt accent button on top of it would bury the only explanation
 * the reader gets. tab_count == 0 is precisely "there is nothing open at all",
 * which is the state -performStartupDocumentWork's else arm produces and the
 * state the last tab closing returns to. */
static SPDF_WIN_CE_INLINE int spdf_win_chrome_is_empty_state(const SpdfWinChromeModel* m) {
    return m && !spdf_win_chrome_has_document(m) && m->tab_count <= 0 && !m->presentation;
}

/* The button's rect in CLIENT device pixels, or an empty rect when it is not on
 * screen -- which every consumer must treat as absent, the same contract
 * SpdfWinChromeLayout and SpdfWinToolbarLayout both state. Snapped to whole
 * pixels: a capsule at a fractional x puts its hairline across two columns. */
static SPDF_WIN_CE_INLINE SpdfWinChromeRect spdf_win_chrome_empty_open_rect(const SpdfWinChromeLayout* l,
                                                                           const SpdfWinChromeModel* m) {
    SpdfWinChromeRect r = spdf_win_chrome_zero();
    float s;

    if (!l || !spdf_win_chrome_is_empty_state(m)) return r;
    if (spdf_win_chrome_rect_empty(l->canvas)) return r;
    s = l->dpi_scale > 0.0f ? l->dpi_scale : 1.0f;
    if (l->canvas.w < spdf_win_chrome_px(SPDF_WIN_CHROME_EMPTY_MIN_W, s)) return r;
    if (l->canvas.h < spdf_win_chrome_px(SPDF_WIN_CHROME_EMPTY_MIN_H, s)) return r;

    r.w = spdf_win_chrome_px(SPDF_WIN_CHROME_EMPTY_BUTTON_W, s);
    r.h = spdf_win_chrome_px(SPDF_WIN_CHROME_EMPTY_BUTTON_H, s);
    r.x = floorf(l->canvas.x + (l->canvas.w - r.w) * 0.5f);
    r.y = floorf(l->canvas.y + l->canvas.h * 0.5f + spdf_win_chrome_px(SPDF_WIN_CHROME_EMPTY_BUTTON_TOP, s));
    return r;
}

/* The quiet line under the button. Empty whenever the button is, so the hint
 * cannot outlive the thing it is a hint about. */
static SPDF_WIN_CE_INLINE SpdfWinChromeRect spdf_win_chrome_empty_hint_rect(const SpdfWinChromeLayout* l,
                                                                           const SpdfWinChromeModel* m) {
    SpdfWinChromeRect b = spdf_win_chrome_empty_open_rect(l, m);
    SpdfWinChromeRect r = spdf_win_chrome_zero();
    float s;

    if (spdf_win_chrome_rect_empty(b)) return r;
    s = l->dpi_scale > 0.0f ? l->dpi_scale : 1.0f;
    r.x = l->canvas.x;
    r.w = l->canvas.w;
    r.y = b.y + b.h + spdf_win_chrome_px(SPDF_WIN_CHROME_EMPTY_HINT_GAP, s);
    r.h = spdf_win_chrome_px(SPDF_WIN_CHROME_EMPTY_HINT_H, s);
    /* Off the bottom of a short canvas: the hint goes, the button stays. */
    if (r.y + r.h > l->canvas.y + l->canvas.h) return spdf_win_chrome_zero();
    return r;
}

/* Is this point on the button? The hit test both the router
 * (spdf_win_chrome_empty_route, spdf_win_chrome_toolbar_route.h) and any future
 * hover state go through, so there is one answer. */
static SPDF_WIN_CE_INLINE int spdf_win_chrome_empty_open_hit(const SpdfWinChromeLayout* l, const SpdfWinChromeModel* m,
                                                             float x, float y) {
    return spdf_win_chrome_contains(spdf_win_chrome_empty_open_rect(l, m), x, y);
}
