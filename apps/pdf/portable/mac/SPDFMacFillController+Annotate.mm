// The single path for every Annotate change (SPDFMacFillController+Annotate.h).
//
// Ownership: the canvas and frontend routes, the session and canvas view plumbing are Mac UI A's; the fill_on_pdf
// route (-annotateApplyFillOperation:...) is the PDF agent's. Frontend operations are in
// SPDFMacAnnotateFrontendOperations.mm.
#import "SPDFMacFillController+Annotate.h"

#import <objc/runtime.h>

#import "SPDFMacAnnotateLayersPanel.h"
#import "SPDFMacAnnotatePaletteSupport.h"
#import "SPDFMacFillPalette.h"

#import "SPDFMacFillController+AnnotatePDF.h"

#import "SPDFMacAnnotateCanvasView.h"
#import "SPDFMacAnnotateImageIO.h"
#import "SPDFMacAnnotateIntegration.h"
#import "SPDFMacAnnotateOperations.h"
#import "SPDFMacAnnotateSessionPrivate.h"
#import "SPDFMacFillControllerPrivate.h"
#import "SPDFMacFillOverlayView.h"
#import "SPDFMacModels.h"

static char kSPDFAnnotateCanvasViewKey;

@interface NSObject (SPDFAnnotateToolbarSync)
- (void)syncToolbarState;  // the reader's toolbar (ShenzhenPDFMac.mm)
@end

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
    NSDictionary* palette = SPDFAnnotateApplyPaletteOperation(self, op, tab);  // tool.choose; colours' side (UI B)
    if (palette) {
        finish(palette);
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
    if (info->route == SPDF_PAINT_ROUTE_FILL_ON_PDF && kind == SPDFAnnotateDocumentPDF &&
        [self annotateApplyFillOperation:op info:info tab:tab completion:finish])
        return;
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
    // A change to a PDF page: Fill & Sign's checks first (they may move the tab to its writable copy), then the
    // canvas, then the page written back as annotations (SPDFMacFillController+AnnotatePDF.h).
    BOOL pdfChange = page >= 0 && !(info->flags & (SPDF_PAINT_OP_READ_ONLY | SPDF_PAINT_OP_UI_STATE)) &&
                     [tab isEqual:[self.host fillTab]];
    if (pdfChange) {
        if (![self annotatePrepareForPDFChange]) {
            completion(SPDFAnnotateErrorAnswer(@"cancelled", @"This document can't be changed right now."));
            return;
        }
        canvas = [session canvasForPage:page document:[self.host fillDocument] create:YES];
        if (!canvas) {
            completion(SPDFAnnotateErrorAnswer(@"not_found", @"There is no such page."));
            return;
        }
    }
    __weak SPDFMacFillController* weakSelf = self;
    void (^apply)(const spdf_paint_apply_input*) = ^(const spdf_paint_apply_input* input) {
        SPDFMacFillController* placing = weakSelf;
        NSDictionary* sent = op;
        // A picture given no box: centred in the part of the page or picture in view, shrunk to fit it.
        if ([op[@"op"] isEqual:@"picture.add"] && !op[@"rect"] && input && input->picture && placing &&
            placing.annotateCanvasView.session == session) {
            CGFloat perUnit = session.kind == SPDFAnnotateDocumentPDF ? 2 : 1;  // a page's added pixels: 2 per point
            NSSize natural = NSMakeSize(input->picture->width / perUnit, input->picture->height / perUnit);
            NSRect box = [placing.annotateCanvasView placementForSize:natural page:page];
            if (!NSIsEmptyRect(box)) {
                NSMutableDictionary* placed = [op mutableCopy];
                placed[@"rect"] = @{@"x": @(NSMinX(box)), @"y": @(NSMinY(box)), @"w": @(NSWidth(box)), @"h": @(NSHeight(box))};
                sent = placed;
            }
        }
        NSDictionary* result = [session applyCanvasOperation:sent page:page input:input];
        if ([op[@"op"] isEqual:@"picture.add"] && [result[@"ok"] boolValue] && result[@"id"])
            session.selectedObjects = @[result[@"id"]];  // selected, its handles showing
        SPDFMacFillController* me = weakSelf;
        if (pdfChange && [result[@"ok"] boolValue] && me) {
            NSString* problem = nil;
            if (![me annotateWritePDFPage:page canvas:canvas error:&problem])
                result = SPDFAnnotateErrorAnswer(@"io_error", problem ?: @"The change couldn't be saved.");
        }
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
    if (kind == SPDFAnnotateDocumentPDF) {  // Fill & Sign's steps share the tab's one undo stack from now on
        __weak SPDFMacFillController* weakSelf = self;
        session.fillStepHandler = ^(BOOL redo) {
            SPDFMacFillController* me = weakSelf;
            if (redo) [me redo];
            else [me undo];
        };
        [self annotateTrackFillUndoSteps];
    }
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
    return SPDFAnnotateLayersPanelFor(self, NO);
}

- (SPDFMacAnnotatePaletteGroups*)annotatePaletteGroups {
    return self.palette.annotateGroups;
}

// -refreshChrome's hook: the canvas view and the status bar follow the mode and the tab.
- (void)annotateChromeDidRefresh:(BOOL)showing {
    // The palette shows or hides the Layers panel as it refreshes, but it is not refreshed while hidden: a tab without
    // Annotate on kept the other tab's panel over its page.
    if (!showing) SPDFAnnotateSyncLayersPanel(self);
    SPDFMacAnnotateSession* session = showing ? [self annotateSessionForTab:nil create:NO] : nil;
    if (session && ![session loadIfNeeded:NULL]) session = nil;
    if (!session && !self.annotateCanvasView) return;
    SPDFMacAnnotateCanvasView* view = [self annotateEnsureCanvasView];
    if (session && self.overlay) {
        [view attachBelowOverlay:self.overlay];
        view.session = session;
        view.showsRulers = SPDFAnnotateSettings.shared.showsRulers;  // as View > Rulers and Gridlines were left
        view.showsGridlines = SPDFAnnotateSettings.shared.showsGridlines;
        view.hidden = NO;
        [view toolDidChange];
        if (session.kind != SPDFAnnotateDocumentPDF) [view takeKeys];
    } else if (![view holdsLastFrame]) {
        view.session = nil;
        view.hidden = YES;
    }
    SPDFAnnotateUpdateStatusBar(self, showing ? session : nil);
    // The toolbar's zoom counts from Annotate's 100 % on a picture (-actualZoom): it says it again now.
    id host = self.host;
    if (session.kind != SPDFAnnotateDocumentPDF && [host respondsToSelector:@selector(syncToolbarState)])
        [host syncToolbarState];
}

@end

SPDFAnnotateDocumentKind SPDFAnnotateKindForTab(SPDFDocumentTab* tab) {
    if (!tab.path.length || tab.missingFile) return SPDFAnnotateDocumentNone;
    if (SPDFAnnotateIsBackingPath(tab.path)) return SPDFAnnotateDocumentCanvas;
    SPDFAnnotateDocumentKind kind = SPDFAnnotateDocumentKindForPath(tab.path);
    // A .szpaint opened by path is shown through its backing picture; never a tab of its own file.
    return kind == SPDFAnnotateDocumentCanvas ? SPDFAnnotateDocumentNone : kind;
}
