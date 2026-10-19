#pragma once

#import "SPDFMacMarkdownPageCanvas.h"

@class SPDFMarkdownPaginationPlan;

@class SPDFMarkdownPage;
@class SPDFMarkdownPageFragment;
@class SPDFMacMarkdownPanController;

// Shared between SPDFMacMarkdownPageCanvas.mm and its categories
// (SPDFMacMarkdownPageCanvas+Navigation.mm); not part of the public canvas API.
@interface SPDFMacMarkdownPageCanvas ()
@property(nonatomic, readonly) SPDFMarkdownPaginationPlan* plan;
@property(nonatomic, readonly) NSAttributedString* attributedString;
// YES while a left-button selection drag is in flight (forces the I-beam in
// updateCursorForPointInWindow:, matching the PDF view's selection drag).
@property(nonatomic, readonly, getter=isDraggingSelection) BOOL draggingSelection;
// Transient "Copied" feedback on ONE code box's copy button: the block index
// whose button reads "Copied", nil when none. copiedCodeGeneration stamps the
// arming so a later copy invalidates an in-flight reset without a timer.
@property(nonatomic, strong) NSNumber* copiedCodeBlockIndex;
@property(nonatomic) NSUInteger copiedCodeGeneration;
// Double-click word selection: the word containing `index`, else the image
// attachment character at (or just before — CTLine hit-testing returns the
// caret index, which lands after the character for a right-half click) the
// index, so double-clicking an image selects exactly its attachment
// character. Zero length when neither resolves.
- (NSRange)wordRangeAtIndex:(NSUInteger)index;
// Character index under a canvas-space point (a caret index: a click on a
// character's right half resolves to the following index), NSNotFound when
// the point is not over a drawn line fragment.
- (NSUInteger)characterIndexAtPoint:(NSPoint)point;
@end

// Implemented in SPDFMacMarkdownPageCanvas+Pan.mm: the lazily created hand-pan
// controller shared by the right-/middle-button pan handlers and the cursor
// precedence logic (an active pan grab owns the cursor).
@interface SPDFMacMarkdownPageCanvas (Pan)
@property(nonatomic, readonly) SPDFMacMarkdownPanController* spdf_panController;
@end

// Drawing/geometry internals implemented alongside the public (Decorations)
// category in SPDFMacMarkdownPageCanvas+Decorations.mm.
@interface SPDFMacMarkdownPageCanvas (DecorationsInternal)
// Paper presentation for the plan's theme variant: the light theme keeps the
// white sheet + drop shadow, the dark theme paints the theme paper with a 1px
// border instead. paperFillColor/drawsPaperShadow expose the decision to
// headless tests. viewportBackgroundColor is the gutter AROUND the sheets: the
// theme's own dark gutter, or windowBackgroundColor unchanged in light.
- (NSColor*)paperFillColor;
- (BOOL)drawsPaperShadow;
- (NSColor*)viewportBackgroundColor;
- (void)drawPaperBackgroundInFrame:(NSRect)pageFrame;
- (void)drawPaperBorderInFrame:(NSRect)pageFrame;
- (SPDFMarkdownPageFragment*)codeControlFragmentOnPage:(SPDFMarkdownPage*)page blockIndex:(NSUInteger)blockIndex;
// The chrome row inside a code box's reserved header band, and the two
// controls anchored to its ends: the copy button left, the language control
// right, same height and same theme colors. The copy rect is NSZeroRect when
// the row is too narrow to hold both.
- (NSRect)codeControlRowRectForFragment:(SPDFMarkdownPageFragment*)fragment pageFrame:(NSRect)pageFrame;
- (NSRect)codeLanguageControlRectForFragment:(SPDFMarkdownPageFragment*)fragment pageFrame:(NSRect)pageFrame;
- (NSRect)codeLanguageControlHitRectForFragment:(SPDFMarkdownPageFragment*)fragment pageFrame:(NSRect)pageFrame;
- (NSRect)copyCodeControlRectForFragment:(SPDFMarkdownPageFragment*)fragment pageFrame:(NSRect)pageFrame;
- (NSRect)copyCodeControlHitRectForFragment:(SPDFMarkdownPageFragment*)fragment pageFrame:(NSRect)pageFrame;
// The copy button's current title ("Copy", or "Copied" while the feedback is
// armed for that block).
- (NSString*)copyCodeControlTitleForBlockIndex:(NSUInteger)blockIndex;
// Runs the copy button's click: asks copyCodeBlockHandler for the write and
// arms the "Copied" feedback when it succeeds (NSBeep when it does not).
- (void)handleCopyCodeBlock:(NSUInteger)blockIndex;
- (void)drawCodeBoxControlsOnPage:(SPDFMarkdownPage*)page pageFrame:(NSRect)pageFrame;
// Canvas-space rects of every link-run portion inside the page's line
// fragments, using the same CTLine offset mapping the highlight drawing uses.
- (NSArray<NSValue*>*)linkRectsForPage:(SPDFMarkdownPage*)page pageFrame:(NSRect)pageFrame;
// Whether a canvas point is on link text (inside a link rect, hover slop
// included). The click path checks this before opening anything, so a click in
// a table row's empty space cannot reach the link cell beside it.
- (BOOL)pointIsOnLink:(NSPoint)point;
@end

// Search/highlight geometry internals implemented alongside the public
// (Search) category in SPDFMacMarkdownPageCanvas+Search.mm.
@interface SPDFMacMarkdownPageCanvas (SearchInternal)
// The single source of truth for range-to-rect mapping: PAGE-LOCAL rects
// (relative to the page frame origin, flipped like the canvas) for every
// portion of `ranges` rendered by `page`, in fragment order.
- (void)enumeratePageLocalRectsForRanges:(NSArray<NSValue*>*)ranges
                                  onPage:(SPDFMarkdownPage*)page
                              usingBlock:(void (^)(NSRect rect))block;
// PDF-parity animated red outline around the active find match.
- (void)drawActiveSearchOnPage:(SPDFMarkdownPage*)page pageFrame:(NSRect)pageFrame;
@end
