#pragma once

#import "SPDFMacDelegatePrivate.h"

// The minimap thumbnails of pages an edit changed (Fill & Sign, comments).
//
// A redraw after an edit replaces the page objects of the pages it draws again and carries their thumbnails over (so
// the strip never blanks), and a whole-document re-render starts every page from a placeholder. Neither knew which
// thumbnails the edit made wrong: Fill & Sign kept showing the page as it was before the edit, and comments threw away
// every thumbnail and rendered them all again. Each edit now names the pages it changed: those get a new thumbnail in
// the same turn when the strip shows them (else as soon as the strip's window reaches them), the others keep theirs.
@interface ShenzhenMacDelegate (SPDFMacEditedPageThumbnails)
// Moved from ShenzhenPDFMac.mm unchanged: the thumbnail and the lower-resolution images a re-rendered page keeps.
- (void)copyMinimapThumbnailFromPage:(SPDFRenderedPage*)source toPage:(SPDFRenderedPage*)destination;

// Call once `pages` have been redrawn after an edit saved to the file. A page the strip shows gets its new thumbnail
// rendered now, from the document in memory, so no frame shows the old one. A page off the strip's view but within its
// thumbnail window keeps its old thumbnail until the new one, rendered from the saved file, lands; further out the old
// one is dropped and the page renders when the window reaches it, like any page not yet drawn.
- (void)refreshMinimapThumbnailsOfEditedPages:(NSIndexSet*)pages;

// As -renderDocumentAndScrollToPage:_pageIndex alignTop:NO restoreOrigin:, keeping the minimap thumbnails of every
// page but `pages`, which are refreshed as above.
- (void)rerenderDocumentAfterEditOfPages:(NSIndexSet*)pages restoreOrigin:(NSValue*)restoreOrigin;

// Changes whenever an edit changes the page: a thumbnail whose render started under another stamp shows the page as
// it was and is never adopted.
- (NSUInteger)minimapThumbnailEditStampForPage:(NSInteger)pageIndex;
@end
