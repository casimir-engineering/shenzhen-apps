/* spdf_win_palette.h — the Ctrl+K palette's WINDOW: a popup over the document
 * window that draws a SpdfWinPaletteModel and reports the row the reader chose.
 *
 * WHAT IT IS THE PORT OF. macOS's showPaletteWithTitle (ShenzhenPDFMac.mm
 * :12259-12331): a floating utility panel, 650 wide, a search field over a
 * table of 42 pt rows with 32 pt section headers, sized to its rows up to 60%
 * of the screen, hung 88 pt below the top of the document window and centred
 * on it, hiding when the app deactivates. GTK's is an AdwDialog of 620 x 460.
 * The numbers here are the mac's.
 *
 * DRAWN WITH DIRECT2D AND DIRECTWRITE, NOT WIN32 CONTROLS. The document window
 * is one Direct2D surface (spdf_win_d2d.h) with the chrome painted from
 * spdf_win_chrome_theme.h's palette; a ListBox and an Edit would bring their
 * own fonts, colours and focus rings and look like a dialog from another decade
 * pasted over a Windows 11 window. The palette therefore paints its rows with
 * the same theme values the tab strip uses, and types into a UTF-16 buffer with
 * the same arithmetic as the toolbar's find field (spdf_win_chrome_text.h).
 *
 * MODAL, LIKE THE MENUS. spdf_win_palette_run() runs its own message loop and
 * returns the choice, for the same reason spdf_win_menu_tab_overflow() does:
 * the caller that opened the palette is the caller that acts on the result,
 * and no row has to be kept alive across messages. Escape, a click outside and
 * deactivation all dismiss it.
 *
 * WHAT DECIDES ANYTHING lives in spdf_win_palette_model.{h,c}: every keystroke
 * here becomes a query the model filters, Up/Down become model moves, and the
 * only thing the window adds is pixels. That split is what lets the palette's
 * behaviour be tested with no desktop (palette_model_test.c) while the window
 * is exercised by hand.
 */
#ifndef SPDF_WIN_PALETTE_H
#define SPDF_WIN_PALETTE_H

#include "spdf_win_palette_model.h"

#ifdef __cplusplus
extern "C" {
#endif

/* The row that was activated, copied out before the window is destroyed. */
typedef struct SpdfWinPaletteChoice {
    int kind;    /* spdf_win_palette_row_kind */
    int command; /* ROW_COMMAND */
    int doc;     /* ROW_OPEN_DOC: the caller's document index */
    int page;    /* ROW_FAVORITE: 0-based, or -1 */
    char path[SPDF_WIN_PALETTE_PATH_MAX];
} SpdfWinPaletteChoice;

/* Show the palette over `hwnd_owner` (an HWND) and run until dismissed. The
 * model must already have its documents and menu state; the window sets its
 * query. `dark` picks the chrome theme; `dpi_scale` is the owner's (1.0 at
 * 96 DPI). Returns 1 with `out` filled when a row was chosen, 0 when
 * dismissed, -1 when the window could not be created (no desktop). */
int spdf_win_palette_run(void* hwnd_owner, int dark, float dpi_scale, SpdfWinPaletteModel* model,
                         SpdfWinPaletteChoice* out);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_WIN_PALETTE_H */
