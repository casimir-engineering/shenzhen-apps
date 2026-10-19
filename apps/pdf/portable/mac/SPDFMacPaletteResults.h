#import <Foundation/Foundation.h>

// Pure helpers for assembling the Cmd+K palette's open-document results and
// deduplicating them against favorites. Kept free of controller state so they
// can be unit-tested standalone (see tests/SPDFMacPaletteResultsTests.mm).

// YES when the query is a case/diacritic-insensitive substring of the tab
// title or of the file name — the same matching the other palette entries use.
// An empty query matches everything.
BOOL spdf_palette_open_document_matches_query(NSString* query, NSString* title, NSString* path);

// Filters open-tab candidates (@{@"path", @"title"}, in window/tab order) down
// to the ones matching the query, preserving order and deduplicating repeated
// documents (the same file open in more than one tab/window is shown once).
NSArray<NSDictionary*>* spdf_palette_open_document_results(NSArray<NSDictionary*>* candidates, NSString* query);

// Removes document-level favorite results whose document is already shown as
// an open-document row (openStandardizedPaths holds standardized paths), so a
// document that is open and also a favorite appears once, as the open entry.
// Page-level favorites are kept: they target a specific page, which the
// open-document row does not.
NSArray<NSDictionary*>* spdf_palette_favorites_without_open_documents(NSArray<NSDictionary*>* favoriteResults,
                                                                      NSSet<NSString*>* openStandardizedPaths);

// YES when the query is a browse keyword for the Favorites group: a
// case-insensitive prefix of "favorites" at least 3 characters long ("fav",
// "favo", ... "favorites"), ignoring surrounding whitespace. The palette then
// reveals every favorite instead of only title matches.
BOOL spdf_palette_query_reveals_all_favorites(NSString* query);

// Formats a menu item's key equivalent for display, e.g. ("f", Cmd|Shift) ->
// "⇧⌘F". modifierMask is the item's keyEquivalentModifierMask; an
// uppercase-letter key equivalent implies Shift, matching menu behavior.
// Returns @"" when there is no key equivalent.
NSString* spdf_palette_key_equivalent_display_string(NSString* keyEquivalent, NSUInteger modifierMask);

// Builds the menu path breadcrumb shown under a menu-command palette row,
// e.g. (@[@"View"], @"Document Map") -> "View ▸ Document Map". Empty
// components are skipped.
NSString* spdf_palette_menu_breadcrumb(NSArray<NSString*>* menuTitles, NSString* itemTitle);

// YES when the query is a case/diacritic-insensitive substring of the menu
// item title or of its breadcrumb (so "view" finds every View-menu command).
// An empty query matches everything.
BOOL spdf_palette_menu_command_matches_query(NSString* query, NSString* title, NSString* breadcrumb);

// Removes menu-command entries (@{... @"selector"}) whose action selector is
// already covered by a visible curated palette action, so a curated action
// and the equivalent menu item never show as duplicate rows.
NSArray<NSDictionary*>* spdf_palette_menu_commands_excluding_selectors(NSArray<NSDictionary*>* menuCommands,
                                                                       NSSet<NSString*>* excludedSelectors);

// YES for rows a person can highlight and choose; headings, separators and
// status lines ("Searching…") are not.
BOOL spdf_palette_row_is_selectable(NSDictionary* row);

// The row to highlight after moving `delta` rows from `current` (-1 when none
// is highlighted). A single step (`wrap`) goes round from the last row to the
// first and back; a page stops at the first or last row. Rows that cannot be
// highlighted are skipped. Returns -1 when no row can be highlighted.
NSInteger spdf_palette_row_after_move(NSArray<NSDictionary*>* rows, NSInteger current, NSInteger delta, BOOL wrap);

// The first (or last) row that can be highlighted, or -1.
NSInteger spdf_palette_boundary_row(NSArray<NSDictionary*>* rows, BOOL last);

// The row to highlight when new results replace the list, given the row that
// was highlighted (nil for none). Unless the person moved the highlight, the
// first row that can be chosen. Otherwise the same row again even if its
// title changed, or the row a document now shares with its working copy (its
// "mergedPaths" hold the highlighted path); failing both, the first row.
// Returns -1 when no row can be chosen.
NSInteger spdf_palette_row_to_highlight(NSArray<NSDictionary*>* rows, NSDictionary* highlighted, BOOL movedByPerson);
