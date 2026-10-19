#pragma once
#import "SPDFMacDelegatePrivate.h"

// Every document window of this process (ShenzhenPDFMac.mm).
NSArray<ShenzhenMacDelegate*>* SPDFMacAllWindowControllers(void);

// What choosing and moving through Cmd+K palette rows does. Return opens the
// highlighted row, whatever highlighted it (arrow keys, the pointer, or the
// first row being highlighted on its own); Cmd+Return opens the chat with the
// typed words from any row. See tests/SPDFMacPaletteActivationTests.mm.
@interface ShenzhenMacDelegate (SPDFMacPaletteActivation)
// Handles a key pressed while the palette is in front. NO leaves the key to the
// search field: ordinary typing, and an input method still composing text.
- (BOOL)paletteHandleKeyEvent:(NSEvent*)event;
- (void)paletteMoveSelection:(NSInteger)delta;
- (void)paletteSelectBoundary:(BOOL)last;
// Page Up (-1) and Page Down (1): as many rows as fit in view, by their heights.
- (void)paletteMovePage:(NSInteger)direction;
// YES once the person moved the highlight (arrow keys, Home, End, a page, a
// click) since the search last changed; results arriving later then keep it.
- (BOOL)paletteHighlightMovedByPerson;
- (void)paletteForgetHighlightMove;
// A mouse press in the palette window, in its coordinates.
- (void)paletteNoteClickAt:(NSPoint)locationInWindow;
// A mouse press in the palette window: only a left click on a row moves the highlight.
- (void)paletteNoteMouseDown:(NSEvent*)event;
// Shows search results ("No matches" when there are none). The highlight stays on
// the row the person moved it to, else goes to the first row that can be chosen.
- (void)applyPaletteRows:(NSArray<NSDictionary*>*)rows;
// Return (sender is the search field or nil) or a click (sender is the table).
// Nothing happens when no row can be chosen.
- (void)activatePaletteSelection:(id)sender;
// Opens the chat, starting one about the typed words when there are any.
- (void)paletteStartChat;
- (void)openPaletteResult:(NSDictionary*)result;
// Brings an open document's tab forward in its own group, in whichever window
// shows it, through the same path as opening it from Finder.
- (void)focusOpenDocumentTabForPath:(NSString*)path;
- (void)installPaletteEventMonitor;
- (void)closePalette:(id)sender;
- (void)paletteFavoriteDeleteClicked:(id)sender;
@end
