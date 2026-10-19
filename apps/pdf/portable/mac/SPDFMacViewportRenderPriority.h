#import "SPDFMacDelegatePrivate.h"

// Which pages the document viewport shows, and how their full-page renders are
// queued. The first three methods moved here from ShenzhenPDFMac.mm unchanged.
@interface ShenzhenMacDelegate (SPDFMacViewportRenderPriority)
// The pages intersecting the viewport (in presentation mode, the one shown),
// widened by `radius` pages around each; *preferredPageOut is the page the
// viewport is centred on.
- (NSArray<NSNumber*>*)visibleDocumentPageIndexesWithExtraRadius:(NSInteger)radius
                                                   preferredPage:(NSInteger*)preferredPageOut;
- (void)queueVisibleDocumentPageRendersForCurrentViewportForceHighPriority:(BOOL)forceHighPriority;
- (void)syncCurrentPageFromVisibleViewportQueueRenders:(BOOL)queueRenders forceHighPriority:(BOOL)forceHighPriority;

// Renders every page in the viewport now, side by side on the user-initiated
// render queue. Called once an open has painted, after an explicit jump (page
// field, next/previous page, first/last, palette, AI tools) and when a scroll
// has settled.
//
// Those pages are all the reader is waiting for, yet they reached the one-wide
// Utility background queue through the scroll-maintenance tick and rendered one
// after another. Measured on a 10-page A3 vector set at Fit Page on a 2x display
// (each sheet ~240 ms to render): restored at page 7, the neighbours peeking into
// the viewport were sharp ~830 ms after the open; a jump to page 30 of 40 took
// ~530 ms; paging with key repeat left the last page waiting behind the renders
// queued for every page passed on the way.
//
// Trackpad scrolling keeps the gentle background queue while it moves
// (architecture.md 3.3): nothing here runs per scroll event.
- (void)spdf_queueViewportPageRendersNow;

// A page render's cleanup: forgets the page's queue entry only while it still
// belongs to `operation` (nil once that operation is gone). The withdraw above
// can lose a race -- the one-wide queue starts the operation between the
// isExecuting check and -cancel -- and the replacement is registered under the
// same page number before the cancelled operation's cleanup runs. Removing by
// page number alone then dropped the replacement's entry, so the next scroll
// tick queued the page a second time.
- (void)spdf_forgetQueuedRenderOperation:(NSOperation*)operation page:(NSNumber*)page;
@end
