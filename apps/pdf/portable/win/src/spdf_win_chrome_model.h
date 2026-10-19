/* spdf_win_chrome_model.h — build a chrome model from the app's tab state.
 *
 * Its own translation unit rather than a few lines in spdf_win_main.cpp for the
 * reason tools/file-size-limits.md gives: that file is at its 500-line cap and
 * the repo prefers extracting a focused file over raising one. It also keeps the
 * UTF-8-to-UTF-16 title conversion in one place, which is where the storage for
 * those titles has to live anyway.
 *
 * WHY A STORE. SpdfWinChromeModel borrows its title strings, because the painter
 * must not allocate. The tab model owns UTF-8 titles, and the strip needs UTF-16.
 * Something has to own the converted strings for the duration of a paint, and a
 * caller-provided store makes that ownership explicit and stack-allocatable
 * instead of hiding a malloc on the paint path.
 */
#ifndef SPDF_WIN_CHROME_MODEL_H
#define SPDF_WIN_CHROME_MODEL_H

#include "spdf_win_chrome.h"
#include "spdf_win_tabs.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Enough for any strip a human will use: the visible-tab capacity of a 5K-wide
 * window is well under 40, and beyond this the overflow menu is the answer
 * rather than more geometry. Tabs past the limit are not shown in the strip;
 * they remain in the tab model and reachable by Ctrl+Tab, so nothing is lost
 * but the drawing. */
#define SPDF_WIN_CHROME_MAX_TABS 64
#define SPDF_WIN_CHROME_MAX_TITLE 192

typedef struct SpdfWinChromeTabStore {
    SpdfWinChromeTab tabs[SPDF_WIN_CHROME_MAX_TABS];
    wchar_t titles[SPDF_WIN_CHROME_MAX_TABS][SPDF_WIN_CHROME_MAX_TITLE];
    int count;
} SpdfWinChromeTabStore;

/* Everything the window layer knows that the chrome must show, and that the tab
 * model does not carry.
 *
 * A STRUCT RATHER THAN A POSITIONAL LIST, and the reason is not taste. This began
 * as five trailing arguments; feeding the toolbar its real page number, page
 * count, zoom, DPI scale and fit mode, plus the hover state, would make eleven,
 * six of them ints and three of them floats. That is the shape of call site where
 * a dpi_scale ends up where a font size belongs and nothing complains --
 * spdf_win_chrome_paint.h says the same thing about SpdfWinChromePaintCtx, for
 * the same reason.
 *
 * Call spdf_win_chrome_model_inputs_init() first. It sets the macOS defaults --
 * both panels visible, nothing hovered, no document -- so a caller that only
 * cares about two fields writes two fields, and a field added here later cannot
 * silently arrive as zero at a caller that predates it. */
typedef struct SpdfWinChromeModelInputs {
    int dark;
    int show_sidebar;
    int show_minimap;
    float sidebar_w; /* points; 0 asks spdf_win_chrome.h for its default (240) */
    float minimap_w; /* points; 0 likewise (126.5) */
    /* Hover, from spdf_win_chrome_input.h's router. -1 is "nothing", which is
     * the value SpdfWinChromeModel documents; these drive the painter's existing
     * hover branches and nothing else. */
    int hot_tab;
    int hot_close;
    /* A tab reorder drag in progress, straight into the model's own two fields
     * (see SpdfWinChromeModel). Both -1 for none, which
     * spdf_win_chrome_model_inputs_init() sets. */
    int drag_tab;
    int drop_slot;
    /* THE TYPEABLE FIELDS. `page_text` is what the reader has typed into the
     * page field, borrowed and NULL when the field is not being edited; `focus`
     * is which field has the keyboard, as spdf_win_text_focus. The FIND field's
     * text does not come through here -- it lives in the process-wide find
     * session with the match count and the marks, which is where the model
     * builder already fetches it from (spdf_win_find_fill_model). */
    const wchar_t* page_text;
    int focus;
    /* The sidebar's list, for the input router: how many rows are showing after
     * filtering, and how far the list is scrolled. See the fields of the same
     * names on SpdfWinChromeModel. */
    int sidebar_row_count;
    float sidebar_scroll_y;
    /* Toolbar readouts. `page_index` is 0-BASED, as everywhere inside this port;
     * the toolbar adds the one. -1 with page_count 0 is "no document". */
    int page_index;
    int page_count;
    float zoom;           /* device pixels per PDF point, from spdf_win_canvas_zoom() */
    float zoom_dpi_scale; /* device pixels per logical pixel, to make a percentage */
    int fit_mode;         /* spdf_win_chrome_fit; the window maps the canvas's own enum */
    /* The caption buttons, straight into the model's three fields of the same
     * names (SpdfWinChromeModel). spdf_win_chrome_model_inputs_init() seeds them
     * from spdf_win_chrome_caption_state() below, so a caller that knows nothing
     * about the caption -- the app's paint glue, the headless frame -- gets the
     * window's live state, or the at-rest state when there is no window. */
    int maximized;
    int caption_hot;
    int caption_pressed;
    /* PRESENTATION: the strip and toolbar collapse to nothing and both panels
     * are hidden whatever show_sidebar/show_minimap say (ShenzhenPDFMac.mm:13432
     * -enterPresentationMode: sets both preferred-visible flags NO). Seeded by
     * spdf_win_chrome_model_inputs_init() from spdf_win_chrome_presentation(),
     * the process-wide flag below, for the reason the caption state is. */
    int presentation;
    /* The selected tab is a Markdown document, so the toolbar gets the A−/A＋
     * text-size pill. Straight into the model field of the same name; see
     * SpdfWinChromeModel::markdown for why it is geometry. */
    int markdown;
} SpdfWinChromeModelInputs;

void spdf_win_chrome_model_inputs_init(SpdfWinChromeModelInputs* in);

/* --- the caption buttons' state ------------------------------------------
 *
 * THE ONE PIECE OF WINDOW STATE THE MODEL CARRIES, and it travels the way the
 * scroller's hover does (spdf_win_chrome_scroll_set_hot, whose long note in
 * spdf_win_chrome_paint.h is the argument): a setter the window layer calls,
 * read once when the inputs are initialised. Two things force that shape.
 * First, whether the window is maximized and whether the pointer is over the
 * close button are facts only spdf_win_window.cpp has -- WM_SIZE and
 * WM_NCMOUSEMOVE deliver them -- and that file knows no app and no model.
 * Second, the model is rebuilt from `struct app` every paint by code that owns
 * neither the window nor this file, so the state has to be somewhere both can
 * reach without either learning the other's types. One window per process
 * (multi-window is multi-process, per session.yaml's window ids), so a
 * process-wide value is the whole truth.
 *
 * DEFAULTS TO AT REST: not maximized, nothing hovered, nothing held. A process
 * that never creates a window -- every offscreen render -- never calls the
 * setter and composes the same frame it always would. */
void spdf_win_chrome_caption_set_state(int maximized, int hot, int pressed);
void spdf_win_chrome_caption_state(int* maximized, int* hot, int* pressed);

/* --- presentation ---------------------------------------------------------
 *
 * Whether the window is presenting, travelling the same way as the caption
 * state and for the same reason: the model is rebuilt every paint by code that
 * fills SpdfWinChromeModelInputs field by field, and that code belongs to
 * another track. Set by the app when F5 toggles; read by inputs_init. One
 * window per process, so a process-wide value is the whole truth; defaults to
 * not presenting, so every offscreen render composes the window it always did
 * unless `--presentation` asks for the collapsed one. */
void spdf_win_chrome_presentation_set(int on);
int spdf_win_chrome_presentation(void);

/* Fills `model` and `store` from `tabs` and `in`. `store` must outlive the paint
 * that reads `model`. Safe with a NULL `tabs`, which yields a model with no tabs
 * -- the state the window is in while the last tab is closing -- and with a NULL
 * `in`, which yields the initialised defaults. */
void spdf_win_chrome_model_build(SpdfWinChromeModel* model, SpdfWinChromeTabStore* store, spdf_win_tabs* tabs,
                                 const SpdfWinChromeModelInputs* in);

/* --- the find query -----------------------------------------------------
 *
 * WHAT THIS REPLACED. The process-wide find session lives in
 * spdf_win_chrome_model.cpp (that file's own comment explains why it is there
 * and not in spdf_win_chrome_find.cpp or spdf_win_search.cpp), and until now the
 * query reached it through two environment variables -- SPDF_FIND_QUERY and
 * SPDF_FIND_REGEX -- because no keyboard input reached that track. Both were
 * documented as temporary at their definitions and both are GONE: this is the
 * setter the toolbar's search field calls, and it is the only way in.
 *
 * UTF-16 IN, because that is what WM_CHAR produces and what the toolbar draws.
 * The conversion to the UTF-8 the engine and the core want happens once, here,
 * rather than at every caller -- and rather than in the model builder, which
 * runs once per frame.
 *
 * STILL LAZY. A process that never types a query still creates no session, no
 * worker thread and no second document handle: spdf_win_find_shared() checks
 * this stored query exactly as it used to check the environment. `query` NULL or
 * empty cancels any live search and clears the toolbar's readout.
 *
 * The stored UTF-16 is what SpdfWinChromeModel::query then borrows, so it must
 * outlive a paint; it is a static buffer inside spdf_win_chrome_model.cpp. */
void spdf_win_find_set_query(const wchar_t* query, int regex);

/* The query as last set, UTF-8, for the session: each tab remembers its own
 * (spdf_win_tab_view::search_text), and the tab model has no access to the
 * find field's UTF-16 buffer. Empty string, never NULL, when there is none.
 * Borrowed static storage, valid until the next set. */
const char* spdf_win_find_query_utf8(void);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_CHROME_MODEL_H */
