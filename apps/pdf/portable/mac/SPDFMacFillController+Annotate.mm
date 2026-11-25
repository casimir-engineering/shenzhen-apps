// The single path for every Annotate change (SPDFMacFillController+Annotate.h).
//
// Ownership: the canvas and frontend routes, the session and canvas view plumbing are Mac UI A's; the fill_on_pdf
// route (-annotateApplyFillOperation:...) is the PDF agent's. Frontend operations are in
// SPDFMacAnnotateFrontendOperations.mm.
#import "SPDFMacFillController+Annotate.h"

#import <objc/runtime.h>

#import "SPDFMacAnnotateCanvasView.h"
#import "SPDFMacAnnotateImageIO.h"
#import "SPDFMacAnnotateIntegration.h"
#import "SPDFMacAnnotateOperations.h"
#import "SPDFMacAnnotateSessionPrivate.h"
#import "SPDFMacFillControllerPrivate.h"
#import "SPDFMacFillOverlayView.h"
#import "SPDFMacModels.h"

static char kSPDFAnnotateCanvasViewKey;

@implementation SPDFMacFillController (Annotate)

#pragma mark - The entry point

- (void)applyOperation:(NSDictionary*)op tab:(SPDFDocumentTab*)tab completion:(SPDFAnnotateCompletion)completion {
    SPDFAnnotateCompletion finish = ^(NSDictionary* result) {
        if (completion) completion(result ?: SPDFAnnotateErrorAnswer(@"failed", @"That didn't work."));
    };
    if (![op isKindOfClass:NSDictionary.class] || ![op[@"op"] isKindOfClass:NSString.class]) {
        finish(SPDFAnnotateErrorAnswer(@"invalid_json", @"An operation is an object with an \"op\" name."));
        return;
    }
    tab = tab ?: [self.host fillTab];
    SPDFAnnotateDocumentKind kind = SPDFAnnotateKindForTab(tab);
    const spdf_paint_op_info* info = spdf_paint_op_find([op[@"op"] UTF8String]);
    if (kind == SPDFAnnotateDocumentNone && !(info && (info->flags & SPDF_PAINT_OP_NO_TARGET))) {
        finish(SPDFAnnotateErrorAnswer(@"no_document", @"Open a document or a canvas first."));
        return;
    }
    char* answer = NULL;
    spdf_paint_doc_kind checkKind = kind == SPDFAnnotateDocumentNone ? SPDF_PAINT_DOC_TEXT
                                                                       : (spdf_paint_doc_kind)kind;
    spdf_paint_status status = spdf_paint_check_op(SPDFAnnotateJSONString(op).UTF8String, checkKind, &info, &answer);
    if (status != SPDF_PAINT_OK || !info) {
        finish(answer ? SPDFAnnotateParseAnswer(answer)
                      : SPDFAnnotateErrorAnswer(@"unknown_op", @"There is no such operation."));
        return;
    }
    if (info->route == SPDF_PAINT_ROUTE_FRONTEND) {
        [self annotateApplyFrontendOperation:op info:info tab:tab completion:finish];
        return;
    }
    if (info->route == SPDF_PAINT_ROUTE_FILL_ON_PDF && kind == SPDFAnnotateDocumentPDF) {
        [self annotateApplyFillOperation:op info:info tab:tab completion:finish];
        return;
    }
    [self annotateApplyCanvasOperation:op info:info tab:tab completion:finish];
}

- (void)applyOperations:(NSArray<NSDictionary*>*)ops tab:(SPDFDocumentTab*)tab
             completion:(SPDFAnnotateCompletion)completion {
    NSMutableArray* results = [NSMutableArray array];
    NSArray* list = [ops isKindOfClass:NSArray.class] ? [ops copy] : @[];
    __weak SPDFMacFillController* weakSelf = self;
    __block void (^next)(NSUInteger) = nil;
    void (^step)(NSUInteger) = ^(NSUInteger index) {
        SPDFMacFillController* me = weakSelf;
        if (!me || index >= list.count) {
            BOOL ok = results.count == list.count;
            for (NSDictionary* result in results) ok = ok && [result[@"ok"] boolValue];
            if (completion) completion(@{@"ok": @(ok), @"results": results});
            next = nil;
            return;
        }
        [me applyOperation:list[index] tab:tab completion:^(NSDictionary* result) {
            [results addObject:result];
            if (![result[@"ok"] boolValue]) {
                if (completion) completion(@{@"ok": @NO, @"results": results});
                next = nil;
                return;
            }
            void (^again)(NSUInteger) = next;
            if (again) again(index + 1);
        }];
    };
    next = step;
    step(0);
}

#pragma mark - The canvas route

- (void)annotateApplyCanvasOperation:(NSDictionary*)op info:(const spdf_paint_op_info*)info tab:(SPDFDocumentTab*)tab
                          completion:(SPDFAnnotateCompletion)completion {
    SPDFMacAnnotateSession* session = [self annotateSessionForTab:tab create:YES];
    if (!session) {
        completion(SPDFAnnotateErrorAnswer(@"needs_pdf", SPDFAnnotateNeedsPDFText));
        return;
    }
    NSError* error = nil;
    if (![session loadIfNeeded:&error]) {
        completion(SPDFAnnotateErrorAnswer(@"io_error", error.localizedDescription));
        return;
    }
    NSInteger page = -1;
    if (session.kind == SPDFAnnotateDocumentPDF) {
        NSInteger asked = [op[@"page"] isKindOfClass:NSNumber.class] ? [op[@"page"] integerValue] : 0;
        if (asked <= 0) asked = MAX(0, session.currentPage) + 1;
        page = asked - 1;
        spdf_document* pdf = tab == [self.host fillTab] ? [self.host fillDocument] : tab.cachedDocument;
        if (![session canvasForPage:page document:pdf create:YES]) {
            completion(SPDFAnnotateErrorAnswer(@"not_found", @"There is no such page."));
            return;
        }
    }
    int oldWidth = 0, oldHeight = 0;
    spdf_paint_doc* canvas = [session canvasForPage:page document:NULL create:NO];
    spdf_paint_size(canvas, &oldWidth, &oldHeight);
    __weak SPDFMacFillController* weakSelf = self;
    void (^apply)(const spdf_paint_apply_input*) = ^(const spdf_paint_apply_input* input) {
        NSDictionary* result = [session applyCanvasOperation:op page:page input:input];
        SPDFMacFillController* me = weakSelf;
        if ([result[@"ok"] boolValue] && me) {
            int width = 0, height = 0;
            spdf_paint_size(canvas, &width, &height);
            SPDFMacAnnotateCanvasView* view = me.annotateCanvasView;
            if (view.session == session) {
                if (width != oldWidth || height != oldHeight) [view canvasSizeDidChange];
                [view canvasDidChangeOnPage:page];
            }
            if ([session.tab isEqual:[me.host fillTab]]) [me.host fillStateDidChange];
        }
        completion(result);
    };
    if (info->flags & SPDF_PAINT_OP_NEEDS_INPUT) {
        SPDFAnnotatePrepareInput(op, session, page, ^(NSDictionary* failure, const spdf_paint_apply_input* input) {
            if (failure) completion(failure);
            else apply(input);
        });
        return;
    }
    apply(NULL);
}

#pragma mark - The Fill & Sign route (PDF agent)

// On a PDF: pen.add, arrow.add, erase.lines and form.* through Fill & Sign's own code, each recorded with
// -[SPDFMacAnnotateSession recordFillStep]. Implemented by the PDF scope.
- (void)annotateApplyFillOperation:(NSDictionary*)op info:(const spdf_paint_op_info*)info tab:(SPDFDocumentTab*)tab
                        completion:(SPDFAnnotateCompletion)completion {
    (void)op; (void)info; (void)tab;
    completion(SPDFAnnotateErrorAnswer(@"not_implemented", @"Fill & Sign's operations aren't connected yet."));
}

#pragma mark - Sessions and views

- (SPDFMacAnnotateSession*)annotateSessionForTab:(SPDFDocumentTab*)tab create:(BOOL)create {
    tab = tab ?: [self.host fillTab];
    if (!tab) return nil;
    SPDFMacAnnotateSession* session = [SPDFMacAnnotateSession existingSessionForTab:tab];
    if (session || !create) return session;
    SPDFAnnotateDocumentKind kind = SPDFAnnotateKindForTab(tab);
    if (kind == SPDFAnnotateDocumentNone || kind == SPDFAnnotateDocumentText) return nil;
    session = [SPDFMacAnnotateSession sessionForTab:tab kind:kind path:tab.path];
    id host = self.host;
    // The reader's category implements the host methods (its protocol is declared on an interface only).
    if ([host respondsToSelector:@selector(annotateSessionProtectPath:)]) session.host = host;
    return session;
}

- (SPDFMacAnnotateCanvasView*)annotateCanvasView {
    return objc_getAssociatedObject(self, &kSPDFAnnotateCanvasViewKey);
}

- (SPDFMacAnnotateCanvasView*)annotateEnsureCanvasView {
    SPDFMacAnnotateCanvasView* view = self.annotateCanvasView;
    if (!view) {
        view = [[SPDFMacAnnotateCanvasView alloc] initWithController:self];
        objc_setAssociatedObject(self, &kSPDFAnnotateCanvasViewKey, view, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return view;
}

- (SPDFMacAnnotateLayersPanel*)annotateLayersPanel {
    return nil;
}

- (SPDFMacAnnotatePaletteGroups*)annotatePaletteGroups {
    return nil;
}

// -refreshChrome's hook: the canvas view and the status bar follow the mode and the tab.
- (void)annotateChromeDidRefresh:(BOOL)showing {
    SPDFMacAnnotateSession* session = showing ? [self annotateSessionForTab:nil create:NO] : nil;
    if (session && ![session loadIfNeeded:NULL]) session = nil;
    if (!session && !self.annotateCanvasView) return;
    SPDFMacAnnotateCanvasView* view = [self annotateEnsureCanvasView];
    if (session && self.overlay) {
        [view attachBelowOverlay:self.overlay];
        view.session = session;
        view.hidden = NO;
        [view toolDidChange];
        if (session.kind != SPDFAnnotateDocumentPDF) [view takeKeys];
    } else if (![view holdsLastFrame]) {
        view.session = nil;
        view.hidden = YES;
    }
    SPDFAnnotateUpdateStatusBar(self, showing ? session : nil);
}

@end

SPDFAnnotateDocumentKind SPDFAnnotateKindForTab(SPDFDocumentTab* tab) {
    if (!tab.path.length || tab.missingFile) return SPDFAnnotateDocumentNone;
    if (SPDFAnnotateIsBackingPath(tab.path)) return SPDFAnnotateDocumentCanvas;
    SPDFAnnotateDocumentKind kind = SPDFAnnotateDocumentKindForPath(tab.path);
    // A .szpaint opened by path is shown through its backing picture; never a tab of its own file.
    return kind == SPDFAnnotateDocumentCanvas ? SPDFAnnotateDocumentNone : kind;
}
