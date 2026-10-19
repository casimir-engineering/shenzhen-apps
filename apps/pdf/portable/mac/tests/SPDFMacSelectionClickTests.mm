#import <Cocoa/Cocoa.h>

#import "../SPDFMacDelayedLinkActivation.h"
#import "../SPDFMacDocumentView.h"
#import "../SPDFMacPageRendering.h"
#import "SPDFMacCursorOverlayChecks.h"

// The production model implementation also owns document-tab state and links
// MuPDF. This focused view test only needs the rendered-page Objective-C model.
@implementation SPDFRenderedPage
@end

void spdf_activate_window_for_view(NSView* view) {
    (void)view;
}

BOOL spdf_zoom_profile_enabled(void) {
    return NO;
}

double spdf_zoom_profile_now_ms(void) {
    return 0.0;
}

void spdf_zoom_profile_log(NSString* format, ...) {
    (void)format;
}

BOOL spdf_launch_profile_enabled(void) {
    return NO;
}

void spdf_launch_profile_log(NSString* format, ...) {
    (void)format;
}

@interface SPDFFakeDocumentReader : NSObject
@property(nonatomic) SPDFCursorRegionKind cursorKind;
@property(nonatomic) BOOL rangeDragProducesSelection;
@property(nonatomic) BOOL granularProducesSelection;
@property(nonatomic) BOOL hasSelection;
@property(nonatomic) NSInteger rangeCallCount;
@property(nonatomic) NSInteger granularCallCount;
@property(nonatomic) NSInteger linkOpenCount;
@property(nonatomic) NSInteger contextMenuCount;
// Whether the point the view asks about resolves to a destination inside the
// document (the reversible case the view follows straight away).
@property(nonatomic) BOOL linkStaysInDocument;
@property(nonatomic) NSInteger inDocumentFollowCount;
@property(nonatomic) NSInteger restoreCount;
@property(nonatomic) NSPoint restoredOrigin;
@property(nonatomic) NSInteger restoredPageIndex;
@property(nonatomic) SPDFMacSelectionGranularity lastGranularity;
@end

@implementation SPDFFakeDocumentReader
- (void)clearFindFieldFocus {
}
- (BOOL)handlePresentationEvent:(NSEvent*)event {
    (void)event;
    return NO;
}
- (BOOL)documentViewInPresentationMode {
    return NO;
}
- (SPDFCursorRegionKind)documentViewCursorRegionAtPageIndex:(NSInteger)pageIndex pagePoint:(NSPoint)pagePoint {
    (void)pageIndex;
    (void)pagePoint;
    return self.cursorKind;
}
- (BOOL)documentViewOpenLinkAtPageIndex:(NSInteger)pageIndex pagePoint:(NSPoint)pagePoint {
    (void)pageIndex;
    (void)pagePoint;
    ++self.linkOpenCount;
    return YES;
}
- (BOOL)documentViewFollowInDocumentLinkAtPageIndex:(NSInteger)pageIndex
                                          pagePoint:(NSPoint)pagePoint
                                      restoreOrigin:(NSPoint*)restoreOrigin
                                   restorePageIndex:(NSInteger*)restorePageIndex {
    (void)pageIndex;
    (void)pagePoint;
    if (!self.linkStaysInDocument) return NO;
    ++self.inDocumentFollowCount;
    if (restoreOrigin) *restoreOrigin = NSMakePoint(11.0, 22.0);
    if (restorePageIndex) *restorePageIndex = 7;
    return YES;
}
- (void)documentViewRestoreDocumentPosition:(NSPoint)origin pageIndex:(NSInteger)pageIndex {
    ++self.restoreCount;
    self.restoredOrigin = origin;
    self.restoredPageIndex = pageIndex;
}
- (BOOL)documentViewSelectionChangedOnPage:(NSInteger)pageIndex from:(NSPoint)start to:(NSPoint)end {
    (void)pageIndex;
    ++self.rangeCallCount;
    self.hasSelection = !NSEqualPoints(start, end) && self.rangeDragProducesSelection;
    return self.hasSelection;
}
- (BOOL)documentViewSelectionChangedOnPage:(NSInteger)pageIndex
                                      from:(NSPoint)start
                                        to:(NSPoint)end
                               granularity:(SPDFMacSelectionGranularity)granularity {
    (void)pageIndex;
    (void)start;
    (void)end;
    ++self.granularCallCount;
    self.lastGranularity = granularity;
    self.hasSelection = self.granularProducesSelection;
    return self.hasSelection;
}
- (void)showContextMenuForDocumentView:(NSView*)view event:(NSEvent*)event {
    (void)view;
    (void)event;
    ++self.contextMenuCount;
}
@end

static int gFailureCount = 0;

static void expect_integer(NSString* label, NSInteger expected, NSInteger actual) {
    if (expected == actual) return;
    fprintf(stderr, "FAIL %s: expected %ld, got %ld\n", label.UTF8String, (long)expected, (long)actual);
    ++gFailureCount;
}

static void expect_bool(NSString* label, BOOL expected, BOOL actual) {
    if (expected == actual) return;
    fprintf(stderr, "FAIL %s: expected %s, got %s\n", label.UTF8String, expected ? "YES" : "NO",
            actual ? "YES" : "NO");
    ++gFailureCount;
}

static void expect_double(NSString* label, double expected, double actual) {
    if (fabs(expected - actual) <= 0.001) return;
    fprintf(stderr, "FAIL %s: expected %.3f, got %.3f\n", label.UTF8String, expected, actual);
    ++gFailureCount;
}

static void expect_point(NSString* label, NSPoint expected, NSPoint actual) {
    if (NSEqualPoints(expected, actual)) return;
    fprintf(stderr, "FAIL %s: expected (%.1f,%.1f), got (%.1f,%.1f)\n", label.UTF8String, expected.x, expected.y,
            actual.x, actual.y);
    ++gFailureCount;
}

static NSEvent* mouse_event(NSEventType type, NSPoint point, NSEventModifierFlags flags, NSInteger clickCount,
                            NSTimeInterval timestamp) {
    return [NSEvent mouseEventWithType:type
                              location:point
                         modifierFlags:flags
                             timestamp:timestamp
                          windowNumber:0
                               context:nil
                           eventNumber:1
                            clickCount:clickCount
                              pressure:1.0];
}

static SPDFDocumentView* make_view(SPDFFakeDocumentReader* reader, NSPoint* pagePoint) {
    SPDFDocumentView* view = [[SPDFDocumentView alloc] initWithFrame:NSMakeRect(0, 0, 640, 760)];
    SPDFRenderedPage* page = [SPDFRenderedPage new];
    page.pageIndex = 0;
    page.pageWidth = 400;
    page.pageHeight = 560;
    view.zoom = 1.0;
    view.viewportWidthHint = 640;
    view.pages = @[ page ];
    view.reader = (id<SPDFMacDocumentViewReader>)reader;
    [view setValue:[[SPDFMacDelayedLinkActivation alloc] initWithDelay:0.01]
             forKey:@"pendingLinkActivation"];
    NSRect pageRect = [view rectForPageAtIndex:0];
    if (pagePoint) *pagePoint = NSMakePoint(NSMidX(pageRect), NSMidY(pageRect));
    return view;
}

static void drain_delayed_activation(void) {
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:0.08];
    while (deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:deadline];
}

static void send_click(SPDFDocumentView* view, NSPoint point, NSInteger clickCount, NSTimeInterval timestamp) {
    [view mouseDown:mouse_event(NSEventTypeLeftMouseDown, point, 0, clickCount, timestamp)];
    [view mouseUp:mouse_event(NSEventTypeLeftMouseUp, point, 0, clickCount, timestamp + 0.001)];
}

static void test_single_link_is_delayed(void) {
    SPDFFakeDocumentReader* reader = [SPDFFakeDocumentReader new];
    reader.cursorKind = SPDFCursorRegionLink;
    NSPoint point;
    SPDFDocumentView* view = make_view(reader, &point);
    send_click(view, point, 1, 1.0);
    expect_integer(@"single link is not opened on mouse-up", 0, reader.linkOpenCount);
    drain_delayed_activation();
    expect_integer(@"single link opens after multi-click window", 1, reader.linkOpenCount);
    expect_integer(@"single click uses range-clear path", 1, reader.rangeCallCount);
    expect_integer(@"single click avoids granular path", 0, reader.granularCallCount);
}

static void test_double_click_cancels_link_and_selects_word(void) {
    SPDFFakeDocumentReader* reader = [SPDFFakeDocumentReader new];
    reader.cursorKind = SPDFCursorRegionLink;
    reader.granularProducesSelection = YES;
    NSPoint point;
    SPDFDocumentView* view = make_view(reader, &point);
    send_click(view, point, 1, 1.0);
    send_click(view, point, 2, 1.01);
    drain_delayed_activation();
    expect_integer(@"double click cancels pending link", 0, reader.linkOpenCount);
    expect_integer(@"double click invokes range only for first click", 1, reader.rangeCallCount);
    expect_integer(@"double click invokes one granular selection", 1, reader.granularCallCount);
    expect_integer(@"double click selects word", SPDFMacSelectionGranularityWord, reader.lastGranularity);
}

static void test_triple_click_cancels_link_and_selects_block(void) {
    SPDFFakeDocumentReader* reader = [SPDFFakeDocumentReader new];
    reader.cursorKind = SPDFCursorRegionLink;
    reader.granularProducesSelection = YES;
    NSPoint point;
    SPDFDocumentView* view = make_view(reader, &point);
    send_click(view, point, 1, 1.0);
    send_click(view, point, 2, 1.01);
    send_click(view, point, 3, 1.02);
    drain_delayed_activation();
    expect_integer(@"triple click never activates link", 0, reader.linkOpenCount);
    expect_integer(@"triple sequence has one range call", 1, reader.rangeCallCount);
    expect_integer(@"triple sequence performs word then block", 2, reader.granularCallCount);
    expect_integer(@"third click selects block", SPDFMacSelectionGranularityBlock, reader.lastGranularity);
}

static void test_link_drag_stays_range_selection(void) {
    SPDFFakeDocumentReader* reader = [SPDFFakeDocumentReader new];
    reader.cursorKind = SPDFCursorRegionLink;
    // Even for the link kind that is now followed instantly on a click: a drag
    // is a text selection and must never navigate.
    reader.linkStaysInDocument = YES;
    reader.rangeDragProducesSelection = YES;
    NSPoint point;
    SPDFDocumentView* view = make_view(reader, &point);
    [view mouseDown:mouse_event(NSEventTypeLeftMouseDown, point, 0, 1, 1.0)];
    NSPoint dragged = NSMakePoint(point.x + 30.0, point.y + 12.0);
    [view mouseDragged:mouse_event(NSEventTypeLeftMouseDragged, dragged, 0, 1, 1.01)];
    [view mouseUp:mouse_event(NSEventTypeLeftMouseUp, dragged, 0, 1, 1.02)];
    drain_delayed_activation();
    expect_integer(@"drag uses range path on down and move", 2, reader.rangeCallCount);
    expect_bool(@"drag creates selection", YES, reader.hasSelection);
    expect_integer(@"link drag does not activate", 0, reader.linkOpenCount);
    expect_integer(@"link drag does not follow in-document either", 0, reader.inDocumentFollowCount);
    expect_integer(@"link drag restores nothing", 0, reader.restoreCount);
    expect_integer(@"drag avoids granular path", 0, reader.granularCallCount);
}

static void test_control_click_routes_context_menu(void) {
    SPDFFakeDocumentReader* reader = [SPDFFakeDocumentReader new];
    NSPoint point;
    SPDFDocumentView* view = make_view(reader, &point);
    [view mouseDown:mouse_event(NSEventTypeLeftMouseDown, point, NSEventModifierFlagControl, 1, 1.0)];
    expect_integer(@"control click opens context menu", 1, reader.contextMenuCount);
    expect_integer(@"control click avoids range", 0, reader.rangeCallCount);
    expect_integer(@"control click avoids granular selection", 0, reader.granularCallCount);
}

static void test_none_clears_without_range_fallback(void) {
    SPDFFakeDocumentReader* reader = [SPDFFakeDocumentReader new];
    reader.hasSelection = YES;
    reader.granularProducesSelection = NO;
    NSPoint point;
    SPDFDocumentView* view = make_view(reader, &point);
    send_click(view, point, 2, 1.0);
    expect_bool(@"NONE clears prior selection", NO, reader.hasSelection);
    expect_integer(@"NONE still uses granular path", 1, reader.granularCallCount);
    expect_integer(@"NONE never falls back to range", 0, reader.rangeCallCount);
    expect_integer(@"NONE double click does not activate link", 0, reader.linkOpenCount);
}

static void test_nonlink_single_click_never_schedules_activation(void) {
    SPDFFakeDocumentReader* reader = [SPDFFakeDocumentReader new];
    reader.cursorKind = SPDFCursorRegionText;
    NSPoint point;
    SPDFDocumentView* view = make_view(reader, &point);
    send_click(view, point, 1, 1.0);
    drain_delayed_activation();
    expect_integer(@"known text-only region does not probe link", 0, reader.linkOpenCount);
}

static void test_pending_link_cleanup(void) {
    SPDFFakeDocumentReader* reader = [SPDFFakeDocumentReader new];
    reader.cursorKind = SPDFCursorRegionLink;
    NSPoint point;
    SPDFDocumentView* view = make_view(reader, &point);
    send_click(view, point, 1, 1.0);
    [view cancelTransientInteraction];
    drain_delayed_activation();
    expect_integer(@"interaction reset cancels link", 0, reader.linkOpenCount);

    send_click(view, point, 1, 2.0);
    view.pages = @[];
    drain_delayed_activation();
    expect_integer(@"page reset cancels link", 0, reader.linkOpenCount);

    __weak SPDFDocumentView* weakView;
    @autoreleasepool {
        view = make_view(reader, &point);
        weakView = view;
        send_click(view, point, 1, 3.0);
        view = nil;
    }
    expect_bool(@"pending action does not retain view", YES, weakView == nil);
    drain_delayed_activation();
    expect_integer(@"deallocated view cannot activate link", 0, reader.linkOpenCount);
}

// The reported latency bug: a table-of-contents click waited out the whole
// multi-click window (~500ms measured) before a ~5ms jump. An in-document
// destination is now reached inside the mouse-up itself.
static void test_in_document_link_follows_on_mouse_up_without_waiting(void) {
    SPDFFakeDocumentReader* reader = [SPDFFakeDocumentReader new];
    reader.cursorKind = SPDFCursorRegionLink;
    reader.linkStaysInDocument = YES;
    NSPoint point;
    SPDFDocumentView* view = make_view(reader, &point);
    send_click(view, point, 1, 1.0);
    expect_integer(@"in-document link is followed on mouse-up", 1, reader.inDocumentFollowCount);
    drain_delayed_activation();
    expect_integer(@"instant follow still opens exactly once", 1, reader.inDocumentFollowCount);
    expect_integer(@"instant follow skips the deferred path", 0, reader.linkOpenCount);
    expect_integer(@"instant follow restores nothing", 0, reader.restoreCount);
}

// The guard that is kept: a link that leaves the document opens another
// application, which no second click can undo, so it still waits.
static void test_external_link_still_waits_out_the_multi_click_window(void) {
    SPDFFakeDocumentReader* reader = [SPDFFakeDocumentReader new];
    reader.cursorKind = SPDFCursorRegionLink;
    reader.linkStaysInDocument = NO;
    NSPoint point;
    SPDFDocumentView* view = make_view(reader, &point);
    send_click(view, point, 1, 1.0);
    expect_integer(@"external link is not opened on mouse-up", 0, reader.linkOpenCount);
    drain_delayed_activation();
    expect_integer(@"external link opens after the multi-click window", 1, reader.linkOpenCount);
}

// The other half of the trade: word selection over link text still works,
// because the second click puts the document back before selecting.
static void test_double_click_undoes_the_jump_and_selects_the_word(void) {
    SPDFFakeDocumentReader* reader = [SPDFFakeDocumentReader new];
    reader.cursorKind = SPDFCursorRegionLink;
    reader.linkStaysInDocument = YES;
    reader.granularProducesSelection = YES;
    NSPoint point;
    SPDFDocumentView* view = make_view(reader, &point);
    send_click(view, point, 1, 1.0);
    send_click(view, point, 2, 1.01);
    drain_delayed_activation();
    expect_integer(@"double click undoes the jump once", 1, reader.restoreCount);
    expect_point(@"undo restores the pre-jump origin", NSMakePoint(11.0, 22.0), reader.restoredOrigin);
    expect_integer(@"undo restores the pre-jump page", 7, reader.restoredPageIndex);
    expect_integer(@"double click still selects a word", 1, reader.granularCallCount);
    expect_integer(@"double click selects word granularity", SPDFMacSelectionGranularityWord,
                   reader.lastGranularity);
    expect_integer(@"double click follows the link only once", 1, reader.inDocumentFollowCount);
}

// A third click belongs to the same run, but the document is already back where
// it started: undoing twice would scroll away from the block being selected.
static void test_triple_click_undoes_once_then_selects_block(void) {
    SPDFFakeDocumentReader* reader = [SPDFFakeDocumentReader new];
    reader.cursorKind = SPDFCursorRegionLink;
    reader.linkStaysInDocument = YES;
    reader.granularProducesSelection = YES;
    NSPoint point;
    SPDFDocumentView* view = make_view(reader, &point);
    send_click(view, point, 1, 1.0);
    send_click(view, point, 2, 1.01);
    send_click(view, point, 3, 1.02);
    drain_delayed_activation();
    expect_integer(@"triple click undoes exactly once", 1, reader.restoreCount);
    expect_integer(@"triple sequence performs word then block", 2, reader.granularCallCount);
    expect_integer(@"third click selects block", SPDFMacSelectionGranularityBlock, reader.lastGranularity);
}

// A snapshot lives for one click run only: a later, unrelated double click must
// not scroll the document back to where some earlier link click started.
static void test_new_click_run_drops_the_stale_undo(void) {
    SPDFFakeDocumentReader* reader = [SPDFFakeDocumentReader new];
    reader.cursorKind = SPDFCursorRegionLink;
    reader.linkStaysInDocument = YES;
    reader.granularProducesSelection = YES;
    NSPoint point;
    SPDFDocumentView* view = make_view(reader, &point);
    send_click(view, point, 1, 1.0);
    send_click(view, point, 1, 2.0);  // fresh press: clickCount restarts at 1
    send_click(view, point, 2, 2.01);
    drain_delayed_activation();
    expect_integer(@"only the second run's jump is undone", 1, reader.restoreCount);
}

// The destination the jump lands on must be derived from the TARGET page alone.
// Centering it (the old scrollToPageRect: path) put page N-1's tail on screen.
static void test_link_destination_scroll_is_target_page_top(void) {
    NSRect previousPage = NSMakeRect(0.0, 200.0, 400.0, 560.0);
    NSRect targetPage = NSMakeRect(0.0, 800.0, 400.0, 560.0);

    // No destination offset: exactly where "go to page N" lands.
    expect_double(@"page-only destination aligns the page top",
                  NSMinY(targetPage) - kSPDFPageTopScrollLeadIn,
                  spdf_mac_link_destination_scroll_origin_y(targetPage, 0.0, 1.0));
    // A destination partway down the page is honored, scaled by zoom.
    expect_double(@"destination offset is honored at zoom 1",
                  NSMinY(targetPage) + 50.0 - kSPDFPageTopScrollLeadIn,
                  spdf_mac_link_destination_scroll_origin_y(targetPage, 50.0, 1.0));
    expect_double(@"destination offset scales with zoom",
                  NSMinY(targetPage) + 100.0 - kSPDFPageTopScrollLeadIn,
                  spdf_mac_link_destination_scroll_origin_y(targetPage, 50.0, 2.0));
    // Never above the target page, and never inside the page before it.
    expect_bool(@"result never reaches the preceding page", YES,
                spdf_mac_link_destination_scroll_origin_y(targetPage, 0.0, 1.0) > NSMaxY(previousPage));
    expect_double(@"a negative destination cannot pull the previous page in",
                  NSMinY(targetPage) - kSPDFPageTopScrollLeadIn,
                  spdf_mac_link_destination_scroll_origin_y(targetPage, -400.0, 1.0));
    // The first page clamps at the document top rather than scrolling negative.
    expect_double(@"first page clamps at the document top", 0.0,
                  spdf_mac_link_destination_scroll_origin_y(NSMakeRect(0.0, 0.0, 400.0, 560.0), 0.0, 1.0));
}

static void test_link_undo_policy(void) {
    expect_bool(@"single click never undoes", NO, spdf_mac_link_undo_applies_to_click(1, YES));
    expect_bool(@"double click undoes a live snapshot", YES, spdf_mac_link_undo_applies_to_click(2, YES));
    expect_bool(@"triple click undoes a live snapshot", YES, spdf_mac_link_undo_applies_to_click(3, YES));
    expect_bool(@"no snapshot means nothing to undo", NO, spdf_mac_link_undo_applies_to_click(2, NO));
}

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        SPDFDocumentView* cursorView=[SPDFDocumentView new];
        SPDFCursorOverlayTestReader* cursorReader=[SPDFCursorOverlayTestReader new]; cursorView.reader=(id)cursorReader;
        SPDFCheckCanvasOverlayCursor(cursorView);
        test_single_link_is_delayed();
        test_double_click_cancels_link_and_selects_word();
        test_triple_click_cancels_link_and_selects_block();
        test_link_drag_stays_range_selection();
        test_control_click_routes_context_menu();
        test_none_clears_without_range_fallback();
        test_nonlink_single_click_never_schedules_activation();
        test_pending_link_cleanup();
        test_in_document_link_follows_on_mouse_up_without_waiting();
        test_external_link_still_waits_out_the_multi_click_window();
        test_double_click_undoes_the_jump_and_selects_the_word();
        test_triple_click_undoes_once_then_selects_block();
        test_new_click_run_drops_the_stale_undo();
        test_link_undo_policy();
        test_link_destination_scroll_is_target_page_top();
    }
    if (gFailureCount > 0) {
        fprintf(stderr, "%d macOS document-view selection test(s) failed\n", gFailureCount);
        return 1;
    }
    printf("All macOS document-view selection tests passed\n");
    return 0;
}
