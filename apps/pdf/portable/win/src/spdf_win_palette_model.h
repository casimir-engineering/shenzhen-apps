/* spdf_win_palette_model.h — what the Ctrl+K palette SHOWS, as a value: the
 * rows, their sections and the selection, rebuilt from a query. No window.
 *
 * WHAT THIS IS THE PORT OF. GTK's palette_rebuild() and its four
 * palette_append_* functions (portable/linux/gtk4/spdf_palette.c:794-1038),
 * which assemble the sections in the mac's refreshPaletteResults order -- Open
 * documents, Favorites, Commands, then the GTK4-only Recents -- from the pure
 * filter functions this port carries in spdf_win_palette_filter.h. The text
 * search across open documents ("Text in Open Documents", a worker thread per
 * query) is deliberately not here yet; it is the one section that needs the
 * core, and the palette is useful without it.
 *
 * ONE ADDITION FROM THE MAC: a query beginning with '>' lists COMMANDS ONLY,
 * the way the mac palette (and every editor's) does; the '>' and the spaces
 * after it are not part of the match.
 *
 * WHY A MODEL AND NOT A WINDOW. The same reason spdf_win_chrome_model.h exists:
 * everything that decides what a keystroke shows is testable here with no
 * device (portable/win/tests/palette_model_test.c), and the Win32 popup in
 * spdf_win_palette.cpp only draws rows and reports the chosen one.
 *
 * Commands come from the one menu table (spdf_win_menu.h), so the palette
 * cannot offer a command the menu does not, or spell one differently -- the
 * title is the menu title with its mnemonic stripped, the breadcrumb is the
 * top-level menu's, the accelerator is what the menu prints, and the
 * enabled/toggled state comes from the same SpdfWinMenuState the menu is
 * synced from. Favorites and recents come from their stores directly.
 */
#ifndef SPDF_WIN_PALETTE_MODEL_H
#define SPDF_WIN_PALETTE_MODEL_H

#include "spdf_win_menu.h"
#include "spdf_win_palette_filter.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum spdf_win_palette_row_kind {
    SPDF_WIN_PALETTE_ROW_OPEN_DOC = 0,
    SPDF_WIN_PALETTE_ROW_FAVORITE,
    SPDF_WIN_PALETTE_ROW_COMMAND,
    SPDF_WIN_PALETTE_ROW_RECENT,
    SPDF_WIN_PALETTE_ROW_STATUS /* "No results": neither selectable nor activatable */
} spdf_win_palette_row_kind;

#define SPDF_WIN_PALETTE_MAX_ROWS 200
#define SPDF_WIN_PALETTE_PATH_MAX 1024
/* SPDF_PALETTE_MAX_FAVORITE_ROWS */
#define SPDF_WIN_PALETTE_MAX_FAVORITE_ROWS 100

typedef struct SpdfWinPaletteRow {
    int kind;    /* spdf_win_palette_row_kind */
    int section; /* spdf_win_palette_section */
    int command; /* ROW_COMMAND: the spdf_win_command to run */
    int doc;     /* ROW_OPEN_DOC: index into the documents the caller passed */
    int page;    /* ROW_FAVORITE: 0-based target page, or -1 for the document */
    int toggled; /* ROW_COMMAND: drawn with a check mark */
    char path[SPDF_WIN_PALETTE_PATH_MAX];
    char title[256];
    char subtitle[SPDF_WIN_PALETTE_PATH_MAX];
    char accel[32];
} SpdfWinPaletteRow;

typedef struct SpdfWinPaletteModel SpdfWinPaletteModel;

SpdfWinPaletteModel* spdf_win_palette_model_create(void);
void spdf_win_palette_model_destroy(SpdfWinPaletteModel* m);

/* Every open tab, in tab order, and which one is selected (-1 for none). The
 * selected tab is left out of the Open Documents section: it lists switch
 * targets, and the front document would be a no-op (GTK palette_append_open_docs,
 * mac openDocumentPaletteCandidates). Borrowed for the life of the model. */
void spdf_win_palette_model_set_documents(SpdfWinPaletteModel* m, const SpdfWinPaletteOpenDoc* docs, int count,
                                          int selected);

/* The state the menu is synced from; NULL means "everything enabled, nothing
 * ticked". Disabled commands are hidden, not greyed (mac behaviour). */
void spdf_win_palette_model_set_menu_state(SpdfWinPaletteModel* m, const SpdfWinMenuState* state);

/* Set the query and rebuild every section. UTF-8; NULL reads as "". */
void spdf_win_palette_model_set_query(SpdfWinPaletteModel* m, const char* utf8_query);

int spdf_win_palette_model_row_count(const SpdfWinPaletteModel* m);
const SpdfWinPaletteRow* spdf_win_palette_model_row(const SpdfWinPaletteModel* m, int index);
/* 1 when row `index` is the first of its section, i.e. a header is drawn above it. */
int spdf_win_palette_model_section_starts(const SpdfWinPaletteModel* m, int index);
const char* spdf_win_palette_section_title(int section);

/* The selection: -1 when nothing is selectable. A rebuild selects the first
 * selectable row (GTK palette_select_first). Moving skips status rows and stops
 * at the ends. */
int spdf_win_palette_model_selected(const SpdfWinPaletteModel* m);
void spdf_win_palette_model_move(SpdfWinPaletteModel* m, int delta);
void spdf_win_palette_model_select(SpdfWinPaletteModel* m, int index);

/* The menu title with its '&' mnemonic removed ("&&" -> "&"), as UTF-8. Exposed
 * for the palette window's own labels. Returns 0 when it does not fit. */
int spdf_win_palette_menu_text(const wchar_t* text, char* out, size_t out_cap);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_PALETTE_MODEL_H */
