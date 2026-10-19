#pragma once

#import "SPDFMacUIHelpers.h"

@class SPDFMarkdownPaginationPlan;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPDFMacMarkdownPageFitMode) {
    SPDFMacMarkdownPageFitCustom = 0,
    SPDFMacMarkdownPageFitActual = 1,
    SPDFMacMarkdownPageFitWidth = 2,
    SPDFMacMarkdownPageFitHeight = 3,
    SPDFMacMarkdownPageFitPage = 4,
};

@interface SPDFMacMarkdownPagedView : SPDFScrollView
@property(nonatomic, readonly) NSUInteger pageCount;
@property(nonatomic, readonly) NSInteger currentPageIndex;
@property(nonatomic, readonly) NSUInteger visibleAttributedLocation;
@property(nonatomic, readonly, copy) NSArray<NSValue*>* documentPageRects;
@property(nonatomic, readonly) NSSize documentCanvasSize;
@property(nonatomic) SPDFMacMarkdownPageFitMode fitMode;
@property(nonatomic) BOOL presentationMode;
@property(nonatomic) NSRange selectedRange;
@property(nonatomic, readonly, copy) NSString* selectedText;
@property(nonatomic, copy) NSArray<NSValue*>* searchRanges;
// Current find match, drawn as the PDF view's animated red outline ({0,0} =
// none). Setting either property repaints only — use centerRange: to scroll.
@property(nonatomic) NSRange activeSearchRange;
@property(nonatomic) CGFloat activeSearchAlpha;  // 0..1 outline opacity
@property(nonatomic, copy, nullable) void (^viewportChangedHandler)(NSInteger pageIndex, CGFloat zoom);
@property(nonatomic, copy, nullable) void (^activateDestinationHandler)(NSString* destination, BOOL wikiLink);
@property(nonatomic, copy, nullable) void (^chooseCodeLanguageHandler)(NSUInteger blockIndex);
// A code box's copy button was clicked: copy that block's RAW source and
// return whether it was written (YES arms the button's brief "Copied" state).
@property(nonatomic, copy, nullable) BOOL (^copyCodeBlockHandler)(NSUInteger blockIndex);

- (instancetype)initWithPaginationPlan:(SPDFMarkdownPaginationPlan*)plan
                      attributedString:(NSAttributedString*)attributedString NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder*)coder NS_UNAVAILABLE;
// Image-aware copy of the current selection (see the canvas's (Copy)
// category): an image-only selection writes the attachment's image at its
// natural decoded size, a mixed selection plain text plus RTFD, plain text
// otherwise. `transform` maps the plain text before it is written (the
// collapse-whitespace preference hook); NO when nothing was written.
- (BOOL)selectionContainsImage;
- (BOOL)writeSelectionToPasteboard:(NSPasteboard*)pasteboard
                plainTextTransform:(NSString* (^_Nullable)(NSString* text))transform;
// Repaints the page canvas without re-paginating. The canvas is the scroll
// view's DOCUMENT view, so -setNeedsDisplay: on the scroll view itself does
// not reach it.
- (void)redrawPages;
- (void)setZoom:(CGFloat)zoom centeredAtPoint:(NSPoint)point;
- (void)zoomByFactor:(CGFloat)factor;
- (void)goToPageAtIndex:(NSInteger)pageIndex alignTop:(BOOL)alignTop;
- (BOOL)revealRange:(NSRange)range;
// Centers the range's first fragment rect in the viewport (clamped through
// the page-aware scroll path), matching the PDF view's scroll-to-find-match.
// revealRange: stays top-aligned for chapter/anchor navigation.
- (BOOL)centerRange:(NSRange)range;
- (NSUInteger)pageIndexForRange:(NSRange)range;
// Per page index, the rects of every range portion rendered on that page, in
// PAGE-LOCAL coordinates (relative to that page's frame origin, flipped like
// the canvas) — minimap marker geometry. Pages without a match are absent.
- (NSDictionary<NSNumber*, NSArray<NSValue*>*>*)pageLocalRectsForRanges:(NSArray<NSValue*>*)ranges;
// First glyph-run rect of the range in CANVAS coordinates (the space of
// documentPageRects / documentVisibleRect). NSZeroRect when unmapped — search
// match geometry for scrollbar markers and nearest-match selection.
- (NSRect)firstRectForRange:(NSRange)range;
- (void)centerAtDocumentPoint:(NSPoint)point;
- (void)centerOnPageAtIndex:(NSInteger)pageIndex xFraction:(CGFloat)xFraction yFraction:(CGFloat)yFraction;
- (void)scrollByDocumentDeltaX:(CGFloat)deltaX deltaY:(CGFloat)deltaY;
- (void)forwardScrollWheelEvent:(NSEvent*)event;
- (void)magnifyByDelta:(CGFloat)delta;
- (BOOL)zoomWithScrollWheelEvent:(NSEvent*)event centeredAtWindowPoint:(NSPoint)windowPoint;
- (void)magnifyByDelta:(CGFloat)delta centeredAtWindowPoint:(NSPoint)windowPoint;
- (void)magnifyByDelta:(CGFloat)delta centeredAtDocumentPoint:(NSPoint)documentPoint;
- (void)noteExternalScrollPositionChanged;
// The code-language control's frame in this view's coordinate space (the
// magnified canvas rect run through the standard convertRect: chain), for
// anchoring popovers. NSZeroRect when the block has no control or the control
// is scrolled outside the viewport.
- (NSRect)codeLanguageControlFrameInViewForBlockIndex:(NSUInteger)blockIndex;
@end


// Exact-viewport fit (SPDFMacMarkdownPagedView+Fit.mm). A fit is two things: the
// magnification a mode means against the raw viewport, and the placing of the
// CURRENT page once that zoom is in -- centered where it is smaller than the
// viewport, flush with its top where it is taller, as a one-page document's
// sheet sits and as the PDF view places a fitted page.
@interface SPDFMacMarkdownPagedView (Fit)
- (void)applyFitMode:(SPDFMacMarkdownPageFitMode)fitMode;
- (CGFloat)zoomForFitMode:(SPDFMacMarkdownPageFitMode)fitMode;
- (void)alignCurrentPageAfterFit;
@end

NS_ASSUME_NONNULL_END
