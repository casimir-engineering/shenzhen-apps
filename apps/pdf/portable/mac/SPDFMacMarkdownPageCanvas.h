#pragma once

#import <AppKit/AppKit.h>

#import "SPDFMacCursorRegions.h"

@class SPDFMarkdownPaginationPlan;
@protocol SPDFMacUIReader;

NS_ASSUME_NONNULL_BEGIN

@interface SPDFMacMarkdownPageCanvas : NSView
@property(nonatomic, weak, nullable) id<SPDFMacUIReader> reader;
@property(nonatomic, readonly) NSUInteger pageCount;
@property(nonatomic) BOOL presentationMode;
@property(nonatomic) NSRange selectedRange;
@property(nonatomic, copy) NSArray<NSValue*>* searchRanges;
// Current find match, drawn as the PDF view's animated red outline. {0,0}
// means none; setting either property repaints only (no scrolling).
@property(nonatomic) NSRange activeSearchRange;
@property(nonatomic) CGFloat activeSearchAlpha;  // 0..1 outline opacity
@property(nonatomic, copy, nullable) void (^selectionChangedHandler)(NSRange range);
@property(nonatomic, copy, nullable) void (^activateDestinationHandler)(NSString* destination, BOOL wikiLink);
@property(nonatomic, copy, nullable) void (^chooseCodeLanguageHandler)(NSUInteger blockIndex);
// Asked to copy one code block's RAW source to the clipboard (the reader owns
// the pasteboard write; it holds the parsed document). Returning YES arms the
// button's brief "Copied" state; NO beeps.
@property(nonatomic, copy, nullable) BOOL (^copyCodeBlockHandler)(NSUInteger blockIndex);

- (instancetype)initWithPaginationPlan:(SPDFMarkdownPaginationPlan*)plan
                      attributedString:(NSAttributedString*)attributedString NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder*)coder NS_UNAVAILABLE;
// Viewport size in CANVAS coordinates (the paged view's clip bounds size, which
// is contentSize / magnification). Drives the exact-fit vertical inset: the
// outer canvas inset collapses to 0 as the page height reaches the viewport
// (Fit Page puts the page top at the viewport top with nothing to scroll on a
// one-page document) and a single page shorter than the viewport is centered
// vertically. NSZeroSize (standalone canvases) keeps the full decorative inset.
@property(nonatomic) NSSize layoutViewportSize;
- (NSRect)frameForPageAtIndex:(NSUInteger)pageIndex;
- (NSInteger)pageIndexAtPoint:(NSPoint)point;
- (void)resizeForWidth:(CGFloat)width;
- (NSInteger)pageIndexForVisibleRect:(NSRect)visibleRect;
- (NSUInteger)attributedLocationNearestToPoint:(NSPoint)point;
@end

// Implemented in SPDFMacMarkdownPageCanvas+Navigation.mm.
@interface SPDFMacMarkdownPageCanvas (Navigation)
- (BOOL)scrollRangeToVisible:(NSRange)range;
- (NSUInteger)pageIndexForRange:(NSRange)range;
// Canvas-space rect of the first rendered portion of `range`: the range's
// glyph run inside the fragment that renders range.location, falling back to
// that fragment's full line band. NSZeroRect when the plan has no pages.
- (NSRect)firstRectForRange:(NSRange)range;
@end

// Implemented in SPDFMacMarkdownPageCanvas+Copy.mm: the image-aware selection
// copy backing the Cmd+C / Copy chain.
@interface SPDFMacMarkdownPageCanvas (Copy)
// YES when the selection intersects at least one image attachment run.
- (BOOL)selectionContainsImageAttachment;
// Writes the selection to `pasteboard`: an image-only selection (one
// attachment character, optionally with surrounding whitespace) writes the
// attachment's image at its natural decoded size; a mixed selection writes
// the plain text plus an RTFD rendition keeping the attachments; a plain-text
// selection writes just the string. `transform` (when given) maps the plain
// text before it is written — the collapse-whitespace preference hook. NO for
// an empty selection or when the pasteboard rejects the write.
- (BOOL)writeSelectionToPasteboard:(NSPasteboard*)pasteboard
                plainTextTransform:(NSString* (^_Nullable)(NSString* text))transform;
// The image drawn at `point`, or nil when the point is not over one. Probes
// the hit character and the one before it (CTLine hit-testing returns a caret
// index, which lands after the character on a right-half click).
- (nullable NSImage*)imageAtPoint:(NSPoint)point;
// Retargets `menu`'s Copy item to copy the image at `point` directly, leaving
// the selection untouched. No-op when the point is not over an image.
- (void)spdf_retargetCopyItemInMenu:(NSMenu*)menu forImageAtPoint:(NSPoint)point;
@end

// Implemented in SPDFMacMarkdownPageCanvas+Decorations.mm: the dynamic-color
// page chrome (code boxes, heading rules) and the two controls sharing each
// code box's reserved header band — the copy button on the left and the
// language control on the right.
@interface SPDFMacMarkdownPageCanvas (Decorations)
- (nullable NSNumber*)codeLanguageBlockAtPoint:(NSPoint)point;
// The code block whose COPY button covers `point` (its own hit slop applied),
// nil otherwise. Disjoint from codeLanguageBlockAtPoint: — the two controls
// sit at opposite ends of the row and never share a hit rect.
- (nullable NSNumber*)copyCodeBlockAtPoint:(NSPoint)point;
- (nullable NSString*)codeLanguageLabelForBlockIndex:(NSUInteger)blockIndex;
// Canvas-space frames of a code block's controls, or NSZeroRect when the block
// index has no code-box control row in the plan (and, for the copy button,
// when the row is too narrow to hold both controls).
- (NSRect)codeLanguageControlFrameForBlockIndex:(NSUInteger)blockIndex;
- (NSRect)copyCodeControlFrameForBlockIndex:(NSUInteger)blockIndex;
@end

// Implemented in SPDFMacMarkdownPageCanvas+Cursor.mm: PDF-parity pointer
// feedback driven by the tracking area (pointing hand over links and the
// code-language control, I-beam over text line boxes, arrow elsewhere).
@interface SPDFMacMarkdownPageCanvas (Cursor)
// Resolve the cursor region for a canvas-space point: the code-language
// control and link runs (2pt slop) beat text; text requires the point to be
// inside a fragment's line box on a page; margins, page gaps, and the gutter
// resolve to none. Presentation mode forces none (arrow).
- (SPDFCursorRegionKind)cursorRegionAtPoint:(NSPoint)point;
// Re-resolve the pointer cursor (I-beam / hand / arrow) for the current mouse
// location, e.g. after a scroll/zoom change or when a pan drag ends. No-op
// when the pointer is outside the view.
- (void)refreshCursorForMouseLocation;
@end

// Implemented in SPDFMacMarkdownPageCanvas+Search.mm.
@interface SPDFMacMarkdownPageCanvas (Search)
// Per page index, the rects of every range portion rendered on that page, in
// PAGE-LOCAL coordinates (relative to that page's frame origin, same flipped
// orientation as the canvas), using the same CTLine mapping as highlight
// drawing. Pages without a match are absent.
- (NSDictionary<NSNumber*, NSArray<NSValue*>*>*)pageLocalRectsForRanges:(NSArray<NSValue*>*)ranges;
@end

NS_ASSUME_NONNULL_END
