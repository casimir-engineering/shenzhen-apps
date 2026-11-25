// What Annotate draws over a picture or each PDF page, and its gestures (SPDFMacAnnotateCanvasView.h).
//
// WAVE 0 STUB (Mac UI A implements): a view that draws nothing and takes no events.
#import "SPDFMacAnnotateCanvasView.h"

#import "SPDFMacFillController.h"
#import "SPDFMacFillOverlayView.h"

@interface SPDFMacAnnotateCanvasView ()
@property(nonatomic, weak, readwrite) SPDFMacFillController* controller;
@property(nonatomic, weak, readwrite) SPDFMacFillOverlayView* overlay;
@end

@implementation SPDFMacAnnotateCanvasView

- (instancetype)initWithController:(SPDFMacFillController*)controller {
    self = [super initWithFrame:NSZeroRect];
    if (self) _controller = controller;
    return self;
}

- (void)attachBelowOverlay:(SPDFMacFillOverlayView*)overlay {
    self.overlay = overlay;
}

- (BOOL)takesEventsForTool:(SPDFAnnotateTool)tool {
    (void)tool;
    return NO;
}

- (void)canvasDidChangeOnPage:(NSInteger)page {
    (void)page;
}

- (void)canvasSizeDidChange {
}

- (void)toolDidChange {
}

- (BOOL)canvasPointForViewPoint:(NSPoint)point page:(NSInteger*)page canvasPoint:(NSPoint*)canvasPoint {
    (void)point;
    if (page) *page = -1;
    if (canvasPoint) *canvasPoint = NSZeroPoint;
    return NO;
}

- (NSRect)viewRectForCanvasRect:(NSRect)rect page:(NSInteger)page {
    (void)rect; (void)page;
    return NSZeroRect;
}

- (BOOL)cancelGesture {
    return NO;
}

@end
