// Annotate's PDF page canvases and Fill & Sign's commit cycle (SPDFMacFillController+AnnotatePDF.h): the check
// before a page changes, the write back after, the page's canvas read again when Fill & Sign changed the page, Fill &
// Sign's undo steps put on the tab's one undo stack, and which commands are locked on a page.
#import "SPDFMacFillController+AnnotatePDF.h"

#import "SPDFMacAnnotateCanvasView.h"
#import "SPDFMacAnnotateSession.h"
#import "SPDFMacFillControllerPrivate.h"

#import <objc/runtime.h>

typedef BOOL (^SPDFAnnotatePDFWrite)(spdf_document* doc, NSMutableIndexSet* pages, char* err, size_t errLen);

// SPDFMacFillController+Edits.mm: check, write into the main-thread document, save, redraw the pages in this turn.
@interface SPDFMacFillController (AnnotatePDFEditsShared)
- (BOOL)change:(BOOL)fieldsOnly write:(SPDFAnnotatePDFWrite)write emptySaves:(BOOL)emptySaves;
@end

// Removes a block observer when the controller goes.
@interface SPDFAnnotateObserverToken : NSObject
- (instancetype)initWithObserver:(id)observer;
@end

static char kSPDFAnnotateUndoObserverKey;
static char kSPDFAnnotatePendingWriteKey;

BOOL SPDFAnnotatePDFCommandIsLocked(NSString* op, spdf_paint_doc* canvas) {
    if (canvas && spdf_paint_kind(canvas) != SPDF_PAINT_DOC_PDF) return NO;
    return spdf_paint_pdf_op_locked(canvas, op.UTF8String) != 0;
}

@implementation SPDFMacFillController (AnnotatePDF)

- (nullable SPDFMacAnnotateSession*)annotatePDFSession {
    SPDFDocumentTab* tab = [self.host fillTab];
    return tab ? [SPDFMacAnnotateSession existingSessionForTab:tab] : nil;
}

#pragma mark - Before and after a canvas operation

- (BOOL)annotatePrepareForPDFChange {
    if (self.busy) return NO;
    [self flushPendingChanges];  // Fill & Sign's text box and lines waiting go first, in the order they were made
    return [self.host fillPrepareForChangeOfFieldsOnly:NO];
}

- (BOOL)annotateWritePDFPage:(NSInteger)page canvas:(spdf_paint_doc*)canvas error:(NSString**)error {
    if (!canvas) return YES;
    return [self annotateWritePDFPages:@{@(page): [NSValue valueWithPointer:canvas]} error:error];
}

// Every page given written back in one change: one save and one redraw, and none when no page changed.
- (BOOL)annotateWritePDFPages:(NSDictionary<NSNumber*, NSValue*>*)canvases error:(NSString**)error {
    if (!canvases.count) return YES;
    if (self.busy) {  // a Fill & Sign change is being written: these pages follow it
        for (NSNumber* page in canvases) [self annotateWriteLater:page.integerValue];
        return YES;
    }
    __block NSString* problem = nil;
    BOOL ok = [self change:NO write:^BOOL(spdf_document* doc, NSMutableIndexSet* pages, char* err, size_t len) {
      for (NSNumber* page in [canvases.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
          spdf_paint_doc* canvas = (spdf_paint_doc*)canvases[page].pointerValue;
          int changed = 0;
          if (doc != spdf_paint_pdf_document(canvas)) {  // moved to a writable copy since the canvas opened
              snprintf(err, len, "The document was replaced by its copy. Try again.");
              problem = @(err);
              return NO;
          }
          spdf_paint_status status = spdf_paint_pdf_write_back(canvas, &changed, err, len);
          if (status != SPDF_PAINT_OK) {
              problem = err[0] ? @(err) : @"The change couldn't be written.";
              return NO;
          }
          if (changed) [pages addIndex:page.unsignedIntegerValue];
      }
      return YES;
    } emptySaves:NO];
    if (!ok && error) *error = problem ?: @"The change couldn't be saved.";
    if (ok) for (NSNumber* page in canvases) [self.annotateCanvasView canvasDidChangeOnPage:page.integerValue];
    return ok;
}

// The page's canvas written once the change being written now is done (pages waiting, in order).
- (void)annotateWriteLater:(NSInteger)page {
    NSMutableIndexSet* waiting = objc_getAssociatedObject(self, &kSPDFAnnotatePendingWriteKey);
    if (!waiting) {
        waiting = [NSMutableIndexSet indexSet];
        objc_setAssociatedObject(self, &kSPDFAnnotatePendingWriteKey, waiting, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL scheduled = waiting.count > 0;
    [waiting addIndex:(NSUInteger)page];
    if (scheduled) return;
    __weak SPDFMacFillController* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      SPDFMacFillController* me = weakSelf;
      NSMutableIndexSet* pages = objc_getAssociatedObject(me, &kSPDFAnnotatePendingWriteKey);
      if (!me || !pages.count) return;
      if (me.busy) {
          NSInteger first = (NSInteger)pages.firstIndex;
          [pages removeIndex:(NSUInteger)first];
          [me annotateWriteLater:first];  // still busy: wait again, keeping the others
          return;
      }
      NSIndexSet* now = [pages copy];
      [pages removeAllIndexes];
      [me annotateWritePDFPages:[me annotateCanvasesOfPages:now] error:NULL];
    });
}

- (NSDictionary<NSNumber*, NSValue*>*)annotateCanvasesOfPages:(NSIndexSet*)pages {
    SPDFMacAnnotateSession* session = [self annotatePDFSession];
    NSMutableDictionary* canvases = [NSMutableDictionary dictionary];
    [pages enumerateIndexesUsingBlock:^(NSUInteger page, BOOL* stop) {
      (void)stop;
      spdf_paint_doc* canvas = [session canvasForPage:(NSInteger)page document:NULL create:NO];
      if (canvas) canvases[@(page)] = [NSValue valueWithPointer:canvas];
    }];
    return canvases;
}

#pragma mark - Fill & Sign changed a page

- (void)annotatePDFPageDidChange:(NSInteger)page {
    SPDFMacAnnotateSession* session = [self annotatePDFSession];
    if (!session) return;  // Annotate never opened in this tab: nothing to keep in step
    [self annotateTrackFillUndoSteps];
    spdf_paint_doc* canvas = [session canvasForPage:page document:[self.host fillDocument] create:NO];
    if (!canvas || spdf_paint_pdf_document(canvas) != [self.host fillDocument]) return;
    char err[256];
    if (spdf_paint_pdf_reload(canvas, err, sizeof err) == SPDF_PAINT_OK) [self.annotateCanvasView canvasDidChangeOnPage:page];
}

// Every Fill & Sign undo step (a line, a signature, a field, a Remove command) also goes on the tab's one undo stack,
// so Cmd-Z undoes Annotate's and Fill & Sign's changes in the order they were made.
- (void)annotateTrackFillUndoSteps {
    if (objc_getAssociatedObject(self, &kSPDFAnnotateUndoObserverKey)) return;
    __weak SPDFMacFillController* weakSelf = self;
    id observer = [NSNotificationCenter.defaultCenter
        addObserverForName:NSUndoManagerDidCloseUndoGroupNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification* note) {
                  SPDFMacFillController* me = weakSelf;
                  NSUndoManager* undo = note.object;
                  if (!me || undo != [me session].undoManager) return;
                  if (undo.isUndoing || undo.isRedoing || undo.groupingLevel > 0) return;
                  [[me annotatePDFSession] recordFillStep];
                }];
    objc_setAssociatedObject(self, &kSPDFAnnotateUndoObserverKey, [[SPDFAnnotateObserverToken alloc] initWithObserver:observer],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end

@implementation SPDFAnnotateObserverToken {
    id _observer;
}
- (instancetype)initWithObserver:(id)observer {
    if ((self = [super init])) _observer = observer;
    return self;
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:_observer];
}
@end
