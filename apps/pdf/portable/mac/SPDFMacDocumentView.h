#import <Cocoa/Cocoa.h>

// The exact-fit canvas geometry this view lays pages out with; the reader that
// scrolls those pages into place (ShenzhenPDFMac.mm) uses the same rules.
#import "SPDFMacFitGeometry.h"

#import "SPDFMacModels.h"
#import "markdown/SPDFMarkdownDecorations.h"
#import "SPDFMacSelectionClick.h"
#import "SPDFMacUIHelpers.h"

@protocol SPDFMacDocumentViewReader <SPDFMacUIReader>
- (BOOL)documentViewSelectionChangedOnPage:(NSInteger)pageIndex
                                      from:(NSPoint)start
                                        to:(NSPoint)end
                               granularity:(SPDFMacSelectionGranularity)granularity;
// Follows a link whose destination is inside this document, synchronously, on
// the mouse-up that released the click - no multi-click wait, because the jump
// costs a few milliseconds and can be taken back. Returns NO (having done
// nothing) when the point has no link or the link leaves the document; an
// external URL opens another app, which is irreversible, so it keeps the
// deferred activation path instead. On YES the caller receives the scroll
// origin and page index from BEFORE the jump, to hand back to
// documentViewRestoreDocumentPosition:pageIndex: if the click turns out to be
// the first of a multi-click selection.
- (BOOL)documentViewFollowInDocumentLinkAtPageIndex:(NSInteger)pageIndex
                                          pagePoint:(NSPoint)pagePoint
                                      restoreOrigin:(NSPoint*)restoreOrigin
                                   restorePageIndex:(NSInteger*)restorePageIndex;
- (void)documentViewRestoreDocumentPosition:(NSPoint)origin pageIndex:(NSInteger)pageIndex;
@end

@interface SPDFDocumentView : NSView <NSDraggingDestination>
@property(nonatomic, copy) NSArray<SPDFRenderedPage*>* pages;
@property(nonatomic) NSInteger currentPageIndex;
@property(nonatomic) CGFloat zoom;
@property(nonatomic) CGFloat viewportWidthHint;
@property(nonatomic) CGFloat viewportHeightHint;
@property(nonatomic) CGFloat backingScale;
@property(nonatomic) NSInteger activeFindPageIndex;
@property(nonatomic) NSRect activeFindRect;
@property(nonatomic) CGFloat activeFindAlpha;
@property(nonatomic) BOOL presentationMode;
// The active reading theme, threaded in from the delegate exactly like the
// Markdown canvas's plan variant. It decides the gutter fill and how a page is
// separated from it: light keeps the drop shadow, dark draws a 1px border
// (a black shadow is invisible against a dark gutter).
@property(nonatomic) SPDFMarkdownThemeVariant themeVariant;
@property(nonatomic) BOOL liveZooming;
@property(nonatomic, copy) NSString* emptyMessage;
@property(nonatomic, weak) id<SPDFMacDocumentViewReader> reader;
- (NSSize)documentSizeForClipSize:(NSSize)clipSize;
// Image-only page refresh: swaps in an updated pages array whose page SIZES are
// unchanged (only a render image differs), keeping the layout cache valid and
// repainting just the changed page — unlike the `pages` setter, which fully
// invalidates layout and repaints the whole view. Use on render-completion /
// eviction hot paths to avoid an O(n) layout rebuild + full redraw per page.
- (void)refreshRenderedPages:(NSArray<SPDFRenderedPage*>*)pages changedPageIndex:(NSInteger)changedIndex;
- (NSRect)rectForPageAtIndex:(NSInteger)pageIndex;
- (NSInteger)pageIndexForVisibleRect:(NSRect)visibleRect;
- (BOOL)point:(NSPoint)point fallsInPage:(NSInteger*)pageIndex pagePoint:(NSPoint*)pagePoint;
- (void)cancelTransientInteraction;
// Re-resolve the pointer cursor (I-beam / hand / arrow) for the current mouse
// location, e.g. after a cursor-region cache fill or when a pan drag ends.
// No-op when the pointer is outside the view.
- (void)refreshCursorForMouseLocation;
// The page-separation decision for the active theme, split into fill/stroke
// choices so a headless test can probe it without rasterizing — the mirror of
// the Markdown canvas's paperFillColor/drawsPaperShadow seam. pageBorderColor
// is nil whenever no border is drawn (light theme).
@end

// Implemented in SPDFMacDocumentViewTheme.mm.
@interface SPDFDocumentView (Theme)
- (BOOL)drawsPageShadow;
- (NSColor*)pageBorderColor;  // nil when no border is drawn
// The underlay painted beneath a page's rendered bitmap, in the active theme's
// own paper color. Never white in the dark theme: a fractional gap between the
// bitmap and the page rect would show the underlay as a bright edge.
- (NSColor*)pageFillColor;
// The viewport gutter behind the sheets: the theme's own dark gutter, or the
// unchanged system-derived canvas background in light.
- (NSColor*)viewportBackgroundColor;
// Drawn after the page content, so the hairline stays crisp at the page edge.
- (void)drawPageBorderInRect:(NSRect)pageRect;
@end
