// A picture file dropped on a page, a picture or a canvas while Annotate shows becomes a Picture object where it was
// dropped (docs/plans/annotate.md § 2, "drop a picture file"), selected, with the Select tool chosen as after Paste.
// Anything else dropped there (a PDF, a document) still opens as before. The canvas view and the Fill & Sign overlay
// under it both take drops, since either can be the view under the pointer.
#import "SPDFMacAnnotateCanvasViewPrivate.h"

#import "SPDFMacAnnotateImageIO.h"
#import "SPDFMacAnnotatePaletteSupport.h"
#import "SPDFMacDocumentFormats.h"
#import "SPDFMacFillController.h"
#import "SPDFMacFillOverlayView.h"

@interface NSObject (SPDFAnnotateDropReader)
- (BOOL)openFilesFromPasteboard:(NSPasteboard*)pasteboard;  // the reader: open what was dropped as documents
@end

// The canvas showing over this view, when Annotate is on for its document.
static SPDFMacAnnotateCanvasView* SPDFAnnotateDropCanvas(NSView* view) {
    SPDFMacAnnotateCanvasView* canvas = [view isKindOfClass:SPDFMacAnnotateCanvasView.class]
                                            ? (SPDFMacAnnotateCanvasView*)view
                                            : ((SPDFMacFillOverlayView*)view).controller.annotateCanvasView;
    return canvas.session && !canvas.hidden && !canvas.holdsLastFrame ? canvas : nil;
}

static NSString* SPDFAnnotateDroppedPicture(NSPasteboard* pasteboard) {
    for (NSURL* url in [pasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}])
        if (SPDFAnnotateDocumentKindForPath(url.path) == SPDFAnnotateDocumentPicture) return url.path;
    return nil;
}

// The page under the drop and the drop point on it (canvas units); NO when it is not over a page or the picture.
static BOOL SPDFAnnotateDropPoint(SPDFMacAnnotateCanvasView* canvas, id<NSDraggingInfo> sender, NSInteger* page,
                                  NSPoint* point) {
    NSPoint view = [canvas convertPoint:sender.draggingLocation fromView:nil];
    return [canvas canvasPointForViewPoint:view page:page canvasPoint:point];
}

static NSDragOperation SPDFAnnotateDragEntered(NSView* view, id<NSDraggingInfo> sender) {
    SPDFMacAnnotateCanvasView* canvas = SPDFAnnotateDropCanvas(view);
    NSInteger page = -1;
    NSPoint point;
    if (canvas && SPDFAnnotateDroppedPicture(sender.draggingPasteboard) && SPDFAnnotateDropPoint(canvas, sender, &page, &point))
        return NSDragOperationCopy;
    return SPDFDocumentPathsFromPasteboard(sender.draggingPasteboard).count ? NSDragOperationCopy : NSDragOperationNone;
}

static BOOL SPDFAnnotatePerformDrop(NSView* view, id<NSDraggingInfo> sender) {
    SPDFMacAnnotateCanvasView* canvas = SPDFAnnotateDropCanvas(view);
    NSString* path = canvas ? SPDFAnnotateDroppedPicture(sender.draggingPasteboard) : nil;
    NSInteger page = -1;
    NSPoint point = NSZeroPoint;
    SPDFAnnotatePicture* picture = path && SPDFAnnotateDropPoint(canvas, sender, &page, &point)
                                       ? SPDFAnnotateDecodePicture(path, NULL) : nil;
    if (!picture) {
        id reader = canvas.controller.host ?: ((SPDFMacFillOverlayView*)view).controller.host;
        return [reader respondsToSelector:@selector(openFilesFromPasteboard:)] &&
               [reader openFilesFromPasteboard:sender.draggingPasteboard];
    }
    // Its own size (2 pixels a point on a PDF page), shrunk to fit what is in view, centred where it was dropped.
    if (page >= 0 && ![canvas docForPage:page])
        [canvas.session canvasForPage:page document:[canvas.controller.host fillDocument] create:YES];
    CGFloat perUnit = canvas.session.kind == SPDFAnnotateDocumentPDF ? 2 : 1;
    NSRect fit = [canvas placementForSize:NSMakeSize(picture.width / perUnit, picture.height / perUnit) page:page];
    NSSize size = NSIsEmptyRect(fit) ? NSMakeSize(picture.width / perUnit, picture.height / perUnit) : fit.size;
    NSRect rect = NSMakeRect(point.x - size.width / 2, point.y - size.height / 2, size.width, size.height);
    SPDFMacFillController* controller = canvas.controller;
    [canvas takeKeys];
    [canvas operation:@{@"op": @"picture.add", @"path": path, @"rect": SPDFAnnotateRectObject(rect)} page:page
                 done:^(NSDictionary* result) {
                   if ([result[@"ok"] boolValue]) SPDFAnnotateChooseTool(controller, @"select", nil);
                 }];
    return YES;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation SPDFMacAnnotateCanvasView (Drop)

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    [self.overlay registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender { return SPDFAnnotateDragEntered(self, sender); }
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender { return SPDFAnnotateDragEntered(self, sender); }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender { return SPDFAnnotatePerformDrop(self, sender); }

@end

@implementation SPDFMacFillOverlayView (AnnotateDrop)

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender { return SPDFAnnotateDragEntered(self, sender); }
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender { return SPDFAnnotateDragEntered(self, sender); }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender { return SPDFAnnotatePerformDrop(self, sender); }

@end
#pragma clang diagnostic pop
