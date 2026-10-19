// Drag-to-pan on the Markdown canvas must move the page exactly as far as the
// hand. The Markdown view zooms with NSScrollView.magnification, so the clip
// view's bounds stay in UNMAGNIFIED document units; a pointer delta in window
// points has to be divided by the magnification before it becomes a scroll.
// Applying the raw delta dragged the page twice as far as the pointer at 200%
// -- the "not 1:1" drag the PDF view never had, because it re-renders at its
// zoom and keeps the scroll view's magnification at 1.

#import <Cocoa/Cocoa.h>

#import "../SPDFMacMarkdownPanController.h"

static NSScrollView* SPDFMagnifiedScrollView(CGFloat magnification) {
    NSScrollView* scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 400, 400)];
    scrollView.allowsMagnification = YES;
    NSView* document = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 4000, 4000)];
    scrollView.documentView = document;
    scrollView.magnification = magnification;
    [scrollView.contentView scrollToPoint:NSMakePoint(500, 500)];
    [scrollView reflectScrolledClipView:scrollView.contentView];
    return scrollView;
}

static void ExpectPanShift(CGFloat magnification, NSPoint pointerDelta, NSPoint expectedShift) {
    NSScrollView* scrollView = SPDFMagnifiedScrollView(magnification);
    NSPoint before = scrollView.contentView.bounds.origin;
    SPDFMacMarkdownPanController* pan =
        [[SPDFMacMarkdownPanController alloc] initWithDocumentView:scrollView.documentView];
    [pan beginAtWindowPoint:NSMakePoint(200, 200) timestamp:1.0];
    [pan continueAtWindowPoint:NSMakePoint(200 + pointerDelta.x, 200 + pointerDelta.y) timestamp:1.1];
    NSPoint after = scrollView.contentView.bounds.origin;
    if (fabs((after.x - before.x) - expectedShift.x) > 0.01 || fabs((after.y - before.y) - expectedShift.y) > 0.01) {
        fprintf(stderr,
                "FAIL: at %.2fx a pointer move of (%.0f, %.0f) shifted the origin by (%.2f, %.2f), "
                "expected (%.2f, %.2f)\n",
                magnification, pointerDelta.x, pointerDelta.y, after.x - before.x, after.y - before.y,
                expectedShift.x, expectedShift.y);
        exit(1);
    }
    [pan cancel];
}

int main(void) {
    @autoreleasepool {
        // Dragging the hand left by 30 pulls the page left: the origin grows. In
        // a non-flipped document view, dragging UP (window y grows) scrolls the
        // content up too: the origin shrinks.
        ExpectPanShift(1.0, NSMakePoint(-30, 0), NSMakePoint(30, 0));
        ExpectPanShift(1.0, NSMakePoint(0, 30), NSMakePoint(0, 30));
        // At 200% the same 30 window points are 15 document units.
        ExpectPanShift(2.0, NSMakePoint(-30, 0), NSMakePoint(15, 0));
        ExpectPanShift(2.0, NSMakePoint(0, 30), NSMakePoint(0, 15));
        // ...and at 50% they are 60.
        ExpectPanShift(0.5, NSMakePoint(-30, 0), NSMakePoint(60, 0));
        puts("SPDFMacMarkdownPanTests passed");
    }
    return 0;
}
