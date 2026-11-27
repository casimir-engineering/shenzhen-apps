// The Layers panel's thumbnails (SPDFMacAnnotateLayersPanel.h): drawn lazily after the rows, only when the canvas
// changed; and while a stroke is drawn, the active layer's again at most ten times a second, so the row follows the
// canvas and its release, which draws them all once more, shows the same picture.
#import "SPDFMacAnnotateLayersPanelPrivate.h"

#import <QuartzCore/QuartzCore.h>

#import "SPDFMacAnnotateLayerRow.h"
#import "SPDFMacFillController.h"

NSNotificationName const SPDFAnnotateLiveStrokeNotification = @"SPDFAnnotateLiveStroke";

@implementation SPDFMacAnnotateLayersPanel (Thumbnails)

- (spdf_paint_doc*)canvas {
    SPDFMacAnnotateSession* session = _session;
    if (!session) return NULL;
    if (session.kind != SPDFAnnotateDocumentPDF) return session.canvas;
    // The page the rows were read from (SPDFAnnotateOnCurrentPage): the page last touched, else the first.
    return [session canvasForPage:MAX(0, session.currentPage) document:[_controller.host fillDocument] create:YES];
}

- (void)scheduleThumbnails {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(drawThumbnails) object:nil];
    [self performSelector:@selector(drawThumbnails) withObject:nil afterDelay:0.3];
}

- (void)drawThumbnails {
    spdf_paint_doc* doc = [self canvas];
    if (!doc || !self.superview) return;
    uint64_t generation = spdf_paint_generation(doc);
    if (doc == _thumbDoc && generation == _thumbGeneration && _thumbs.count) return;
    _thumbDoc = doc, _thumbGeneration = generation;
    [_thumbs removeAllObjects];
    for (NSDictionary* row in _rows) {  // a layer's thumbnail shows its drawing and its objects
        spdf_bitmap bitmap = {0};
        char err[128];
        if (spdf_paint_layer_thumbnail(doc, (spdf_paint_id)[row[@"id"] unsignedIntValue], 72, &bitmap, err, sizeof(err)) ==
            SPDF_PAINT_OK) {
            NSImage* image = SPDFAnnotateThumbnailImage(&bitmap);
            if (image) _thumbs[row[@"id"]] = image;
        }
        spdf_free_bitmap(&bitmap);
    }
    for (NSInteger i = 0; i < (NSInteger)_rows.count; ++i) [self configure:[_table viewAtColumn:0 row:i makeIfNecessary:NO] row:i];
}

- (void)liveStrokeChanged:(NSNotification*)note {
    (void)note;
    if (!self.superview || !_session || _liveThumbPending) return;
    _liveThumbPending = YES;
    CFTimeInterval wait = MAX(0, 0.1 - (CACurrentMediaTime() - _liveThumbAt));
    [self performSelector:@selector(drawLiveThumbnail) withObject:nil afterDelay:wait];
}

- (void)drawLiveThumbnail {
    _liveThumbPending = NO;
    _liveThumbAt = CACurrentMediaTime();
    spdf_paint_doc* doc = [self canvas];
    if (!doc || !self.superview) return;
    BOOL eraser = _session.tool == SPDFAnnotateToolEraser;  // it can take lines from other layers
    for (NSInteger i = 0; i < (NSInteger)_rows.count; ++i) {
        NSDictionary* row = _rows[i];
        if ([row[@"object"] boolValue] || (!eraser && ![row[@"id"] isEqual:_activeId])) continue;
        spdf_bitmap bitmap = {0, 0, 0, NULL};
        char err[128];
        if (spdf_paint_layer_thumbnail(doc, (spdf_paint_id)[row[@"id"] unsignedIntValue], 72, &bitmap, err, sizeof(err)) ==
            SPDF_PAINT_OK) {
            NSImage* image = SPDFAnnotateThumbnailImage(&bitmap);
            if (image) _thumbs[row[@"id"]] = image;
        }
        spdf_free_bitmap(&bitmap);
        [self configure:[_table viewAtColumn:0 row:i makeIfNecessary:NO] row:i];
    }
}

@end
