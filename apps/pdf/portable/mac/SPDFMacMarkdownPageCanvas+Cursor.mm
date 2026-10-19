#import "SPDFMacMarkdownPageCanvasPrivate.h"
#import "SPDFMacCursorOverlay.h"

#import <CoreText/CoreText.h>

#import "SPDFMacMarkdownPanController.h"
#import "markdown/SPDFMarkdown.h"

// PDF-parity pointer feedback for the paginated Markdown canvas. Like
// SPDFDocumentView, the tracking area installed in updateTrackingAreas (see
// SPDFMacMarkdownPageCanvas.mm) drives mouseMoved:/mouseExited: here, and one
// precedence chain owns the cursor: an active hand pan keeps its closed-hand
// grab; presentation mode forces the arrow; a live selection drag forces the
// I-beam even over links; otherwise the hovered region decides (link/control
// -> pointing hand, text line box -> I-beam, margins/gaps/gutter -> arrow).
@implementation SPDFMacMarkdownPageCanvas (Cursor)

// Strict line boxes: unlike characterIndexAtPoint:'s nearest-hit clamping,
// only the area actually covered by a fragment's typographic line counts as
// text, so page margins, the gap between pages, and the gutter resolve to
// the arrow cursor.
- (NSArray<NSValue*>*)textLineBoxRectsForPage:(SPDFMarkdownPage*)page pageFrame:(NSRect)pageFrame {
    NSRect printable = self.plan.configuration.printableRect;
    NSAttributedString* attributedString = self.attributedString;
    NSMutableArray<NSValue*>* rects = [NSMutableArray array];
    for (SPDFMarkdownPageFragment* fragment in page.fragments) {
        if (!fragment.attributedRange.length || NSMaxRange(fragment.attributedRange) > attributedString.length)
            continue;
        NSAttributedString* lineString = [attributedString attributedSubstringFromRange:fragment.attributedRange];
        CTLineRef line = SPDFMarkdownCreateFragmentLine(lineString);
        CGFloat width = (CGFloat)CTLineGetTypographicBounds(line, NULL, NULL, NULL) * fragment.scale;
        CFRelease(line);
        if (width <= 0.0) continue;
        [rects addObject:[NSValue valueWithRect:NSMakeRect(
                                                    NSMinX(pageFrame) + NSMinX(printable) + fragment.xOffset,
                                                    NSMinY(pageFrame) + self.plan.configuration.topContentInset +
                                                        fragment.pageYOffset,
                                                    width, fragment.height)]];
    }
    return rects;
}

- (SPDFCursorRegionKind)cursorRegionAtPoint:(NSPoint)point {
    if (self.presentationMode || !self.pageCount) return SPDFCursorRegionNone;
    // The code-box controls are the strongest affordance (their hit rects
    // already carry the control's own slop).
    if ([self codeLanguageBlockAtPoint:point] || [self copyCodeBlockAtPoint:point]) return SPDFCursorRegionLink;
    NSInteger pageIndex = [self pageIndexForVisibleRect:NSMakeRect(point.x, point.y, 1.0, 1.0)];
    if (pageIndex < 0 || pageIndex >= (NSInteger)self.pageCount) return SPDFCursorRegionNone;
    NSRect pageFrame = [self frameForPageAtIndex:(NSUInteger)pageIndex];
    if (!NSPointInRect(point, pageFrame)) return SPDFCursorRegionNone;  // page gap / gutter
    SPDFMarkdownPage* page = self.plan.pages[(NSUInteger)pageIndex];
    // Same helper as the PDF path: links win over text, with the 2pt slop.
    return spdf_cursor_region_at_point(point, [self linkRectsForPage:page pageFrame:pageFrame],
                                       [self textLineBoxRectsForPage:page pageFrame:pageFrame], 2.0);
}

- (BOOL)spdf_windowIsFrontmostAtWindowPoint:(NSPoint)windowPoint {
    NSWindow* window = self.window;
    if (!window) return NO;
    NSRect screenRect = [window convertRectToScreen:NSMakeRect(windowPoint.x, windowPoint.y, 1.0, 1.0)];
    NSInteger hitWindowNumber = [NSWindow windowNumberAtPoint:screenRect.origin belowWindowWithWindowNumber:0];
    return hitWindowNumber == window.windowNumber;
}

- (void)updateCursorForPointInWindow:(NSPoint)windowPoint {
    if (self.spdf_panController.isPanning) return;  // the closed-hand grab owns the cursor
    if (self.presentationMode) {
        [NSCursor.arrowCursor set];
        return;
    }
    // Selection drag in progress: I-beam until release, even while over a link.
    if (self.isDraggingSelection) {
        [NSCursor.IBeamCursor set];
        return;
    }
    // The ActiveAlways tracking area fires even when another window covers this
    // one, so an unfocused window only touches the cursor when it is actually
    // the top window at the point (key windows skip the window-server IPC).
    if (!self.window.isKeyWindow && ![self spdf_windowIsFrontmostAtWindowPoint:windowPoint]) return;
    if (SPDFApplyCursorOverlay(self,windowPoint)) return;
    SPDFCursorRegionKind kind = [self cursorRegionAtPoint:[self convertPoint:windowPoint fromView:nil]];
    if (kind == SPDFCursorRegionLink) [NSCursor.pointingHandCursor set];
    else if (kind == SPDFCursorRegionText) [NSCursor.IBeamCursor set];
    else [NSCursor.arrowCursor set];
}

- (void)refreshCursorForMouseLocation {
    NSWindow* window = self.window;
    if (!window) return;
    NSPoint windowPoint = [window mouseLocationOutsideOfEventStream];
    NSPoint viewPoint = [self convertPoint:windowPoint fromView:nil];
    if (!NSPointInRect(viewPoint, self.visibleRect)) return;
    [self updateCursorForPointInWindow:windowPoint];
}

- (void)mouseMoved:(NSEvent*)event {
    [self updateCursorForPointInWindow:event.locationInWindow];
}

- (void)mouseExited:(NSEvent*)event {
    if (self.spdf_panController.isPanning || self.isDraggingSelection) return;
    if ((self.window.isKeyWindow || [self spdf_windowIsFrontmostAtWindowPoint:event.locationInWindow]) &&
        !SPDFApplyCursorOverlay(self,event.locationInWindow)) [NSCursor.arrowCursor set];
}

@end
