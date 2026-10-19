// spdf_palette.c — the Ctrl+K command palette (Mac showPaletteWithTitle /
// GTK3 show_favorites_dialog parity): every runnable command from the
// spdf_shortcuts.c table, favorites, recents, and text search across all open
// documents; plus the favorite-page / favorite-document toggle actions.
//
// The filter/snippet helpers at the top are pure glib logic so they can be
// unit-tested without GTK (tests/palette_filter_test.c builds this header and
// spdf_palette.c with SPDF_PALETTE_TESTING, same pattern as spdf_state.c).
#pragma once

#ifdef SPDF_PALETTE_TESTING
#include <glib.h>
#else
#include "spdf_app.h"
#include "spdf_window.h"
#endif

G_BEGIN_DECLS

// Total pages searched across all open documents per palette query (same cap
// as the GTK3 MAX_PALETTE_SEARCH_PAGES and in the same spirit as the Mac
// 220-result cap).
#define SPDF_PALETTE_MAX_SEARCH_PAGES 250
// Text search starts at 2 query bytes (GTK3 parity).
#define SPDF_PALETTE_MIN_TEXT_QUERY_BYTES 2
// At most this many snippet fragments per matching page (Mac parity).
#define SPDF_PALETTE_MAX_SNIPPETS_PER_PAGE 3

// ---------------------------------------------------------------------------
// Pure filter logic (no GTK).

// Palette sections, in display order. Open documents come first: with a
// query they are the strongest match for "take me to that document" (the
// live tab beats reopening a favorite); with an empty query they make the
// palette a quick tab switcher before the browsing groups below — Mac
// refreshPaletteResults ordering (ShenzhenPDFMac.mm @12452-12526: Open
// documents, Favorites, Actions, Text in open documents; Recents is the
// GTK4-only extra slotted before the text matches).
typedef enum {
    SPDF_PALETTE_SECTION_OPEN_DOCS = 0,
    SPDF_PALETTE_SECTION_FAVORITES,
    SPDF_PALETTE_SECTION_COMMANDS,
    SPDF_PALETTE_SECTION_RECENTS,
    SPDF_PALETTE_SECTION_MATCHES,
} SpdfPaletteSection;

// Fuzzy match score of query against haystack. Returns -1 when the query is
// not a case-insensitive (ASCII) subsequence of haystack; otherwise a score
// >= 0, higher is better. Matching is greedy left-most; each matched byte
// scores +1, +3 more when it sits on a word boundary (start of string or
// preceded by a non-alphanumeric byte), +2 more when it immediately follows
// the previously matched byte (consecutive run). Skipped bytes between the
// first and last match subtract 1 each (capped at 8) and bytes skipped before
// the first match subtract 1 each (capped at 3), so tight, early, word-aligned
// matches outrank scattered ones. An empty query matches everything with 0.
int spdf_palette_fuzzy_score(const char* query, const char* haystack);

// One entry of the command section's input table (built from
// spdf_shortcuts_table() by the palette; faked directly by the tests).
typedef struct {
    const char* action;     // detailed action name, e.g. "win.open"
    const char* title;      // human-readable label (fuzzy-matched)
    const char* accel;      // primary accelerator string, NULL when none
    const char* breadcrumb; // menu path subtitle ("View ▸ Zoom in"), NULL when
                            // none; part of the fuzzy haystack (Mac
                            // spdf_palette_menu_command_matches_query matches
                            // title OR breadcrumb)
    gboolean enabled;       // live GAction enabled state
    gboolean toggled;       // stateful boolean action currently on — the row
                            // title gets the Mac "✓ " checkmark prefix
                            // (ShenzhenPDFMac.mm @12416-12418)
} SpdfPaletteCommand;

typedef struct {
    int index; // index into the input command array
    int score; // spdf_palette_fuzzy_score of the query against the entry
} SpdfPaletteMatch;

// Filters and ranks commands for the palette's Commands section. Disabled
// entries and entries with no title are always skipped. An empty (or NULL)
// query keeps table order; otherwise an entry matches when the query is a
// fuzzy match of its title or its breadcrumb (so searching by menu name
// works, Mac spdf_palette_menu_command_matches_query semantics) and takes
// the better of the two scores; results are sorted by score descending,
// ties by table order. Returns the number of matches written (at most
// out_max).
int spdf_palette_filter_commands(const SpdfPaletteCommand* commands, int count, const char* query,
                                 SpdfPaletteMatch* out, int out_max);

// Joins the menu path and the item title with " ▸ ", skipping empty
// components — port of SPDFMacPaletteResults.mm spdf_palette_menu_breadcrumb
// (@94-101) with the GTK4 shortcuts table's single group level. Returns NULL
// when both parts are empty; caller frees.
char* spdf_palette_menu_breadcrumb(const char* group, const char* title);

// One open-tab candidate for the Open documents section (built from the live
// tab views by the palette; faked directly by the tests).
typedef struct {
    const char* path;  // absolute document path
    const char* title; // tab display title
} SpdfPaletteOpenDoc;

// TRUE when the query is empty or a case-insensitive (ASCII) substring of
// the title or of the path's basename (directories never match) — port of
// SPDFMacPaletteResults.mm spdf_palette_open_document_matches_query (@10-16).
gboolean spdf_palette_open_document_matches_query(const char* query, const char* title, const char* path);

// Filters the Open documents section: keeps candidate order, drops blank
// paths, deduplicates by canonicalized path (the same document open in two
// windows lists once) and applies the query match above — port of
// SPDFMacPaletteResults.mm spdf_palette_open_document_results (@18-32).
// Writes candidate indices into out; returns how many (at most out_max).
int spdf_palette_filter_open_documents(const SpdfPaletteOpenDoc* docs, int count, const char* query, int* out,
                                       int out_max);

// TRUE when the trimmed query is a >= 3 character case-insensitive prefix of
// the word "favorites" ("fav", "favo", … "favorites") — the browse keyword
// that reveals every favorite; port of SPDFMacPaletteResults.mm
// spdf_palette_query_reveals_all_favorites (@122-128).
gboolean spdf_palette_query_reveals_all_favorites(const char* query);

// TRUE when a favorite must be hidden because the document it points at is
// already listed in the Open documents section: only document-level
// favorites dedupe (a page favorite is a distinct jump target) — port of
// SPDFMacPaletteResults.mm spdf_palette_favorites_without_open_documents
// (@130-145). open_paths holds canonicalized paths (g_str_hash set).
gboolean spdf_palette_favorite_shadowed_by_open_doc(const char* favorite_type, const char* favorite_path,
                                                    GHashTable* open_paths);

// Extracts a short display snippet around the first case-insensitive (ASCII)
// occurrence of query in line: up to 24 bytes of context on each side,
// clipped to UTF-8 boundaries, trimmed, with a leading/trailing ellipsis when
// clipped. Returns NULL when query does not occur in line. Caller frees.
char* spdf_palette_snippet_from_line(const char* line, const char* query);

#ifndef SPDF_PALETTE_TESTING
// ---------------------------------------------------------------------------
// Shell entry points (bodies of the win.palette / win.favorite-page /
// win.favorite-document actions registered in spdf_window.c).

void spdf_palette_open(SpdfWindow* win);
void spdf_palette_toggle_favorite_page(SpdfWindow* win);
void spdf_palette_toggle_favorite_document(SpdfWindow* win);
#endif

G_END_DECLS
