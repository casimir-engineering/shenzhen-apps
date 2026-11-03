#pragma once

#import "SPDFMacDelegatePrivate.h"

// Zooming and panning the presented page (SPDFMacPresentationViewport.mm).
//
// Presentation mode shows one page. Zoom it (pinch, Cmd+Plus/Minus, Cmd+wheel,
// the Fit and 100% commands) and, once it is larger than the screen, the arrow
// keys, the wheel and a click-drag pan it, never past its edges. Where the page
// fits, they turn pages as before; on a zoomed page an arrow pressed afresh at
// the edge it points to turns the page, and a scroll gesture that starts there
// does. The zoom stays when the page turns, and the new page opens at its top
// left, as in Preview. Leaving presentation mode puts back the reader's zoom
// and place exactly as they were.
@interface ShenzhenMacDelegate (SPDFMacPresentationViewport)
- (void)rememberViewForPresentation;
// NO when nothing was remembered for this document; the caller then shows the
// current page in the restored fit mode.
- (BOOL)restoreViewAfterPresentation;
// While presenting, a tab's saved view state stays the reader's, not the zoom
// or place on the screen.
- (void)keepNormalViewInPresentedTab:(SPDFDocumentTab*)tab;
// After a PDF page is turned while presenting: the presented fit mode, or zoom,
// fits the turned page, shown at its top left.
- (void)refitPresentedPage:(SPDFFitMode)fitMode zoom:(CGFloat)zoom;
// YES when the arrow key panned the page (or was a held key stopping at its
// edge); NO lets the key turn the page.
- (BOOL)presentationArrowKeyDown:(NSEvent*)event;
- (BOOL)presentationWheelTurnsPage:(NSEvent*)event;
- (BOOL)handlePresentationPanEvent:(NSEvent*)event;
- (NSScrollView*)presentationEventTargetView;
@end
