#import <Cocoa/Cocoa.h>

#import "SPDFMacDelegatePrivate.h"

// Dragging a tab out into its own window.
//
// A detached tab is a new PROCESS, launched with --detached-tab <path>, and
// that launch deliberately skips session restore: it must open the one document
// it was given, not reopen every window. The cost was that it opened the
// document cold — page 1, default zoom — while the tab it came from was sitting
// on page 40. Nothing carried the reading position across the process boundary:
// documents.yaml keeps per-document preferences (sidebar, minimap), not where
// you were.
//
// So the parent writes the tab's serialised state — the same dictionary
// session.yaml stores, carrying page, zoom, fit mode, scroll origin, search and
// the Markdown selection — to a handoff file named after the document's path,
// and the child adopts it before it opens anything. Seeding the tab is enough:
// -openPaths: reuses an existing tab for a path rather than making a new one.
//
// The name is derived from the path rather than passed as an argument, so the
// child needs no new flag and an older binary launched by a newer one simply
// ignores a file it never looks for.

@interface ShenzhenMacDelegate (SPDFMacTabDetach)
// Writes the handoff, launches the new process, and closes the tab here.
- (void)detachTabAtIndex:(NSInteger)index;
// Adopts a handoff written for this launch's document, if one is waiting.
// Called instead of session restore on a --detached-tab launch.
- (void)adoptDetachedTabForLaunch;
@end
