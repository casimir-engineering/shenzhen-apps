// The single path for every Annotate change (SPDFMacFillController+Annotate.h).
//
// WAVE 0 STUB (the routing is the PDF agent's for fill_on_pdf and Mac UI A's for the rest): every operation goes to
// the core's check, whose stub answers not_implemented, so callers can already be wired to it.
#import "SPDFMacFillController+Annotate.h"

#import "SPDFMacFillController+AnnotatePDF.h"

#include "spdf_paint.h"

static NSDictionary* SPDFAnnotateNotBuiltAnswer(void) {
    return @{@"ok": @NO, @"error": @"not_implemented", @"message": @"Annotate is not built yet."};
}

@implementation SPDFMacFillController (Annotate)

- (void)applyOperation:(NSDictionary*)op tab:(SPDFDocumentTab*)tab completion:(SPDFAnnotateCompletion)completion {
    (void)tab;
    NSData* json = op ? [NSJSONSerialization dataWithJSONObject:op options:0 error:NULL] : nil;
    NSString* text = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : @"";
    char* answer = NULL;
    const spdf_paint_op_info* info = NULL;
    spdf_paint_check_op(text.UTF8String, SPDF_PAINT_DOC_PDF, &info, &answer);
    // PDF agent's route: pen.add, arrow.add, erase.lines and form.* on a PDF go to Fill & Sign's own code.
    if (!answer && [self annotateApplyFillOperation:op info:info tab:tab completion:completion]) return;
    NSDictionary* result = nil;
    if (answer) {
        NSData* data = [NSData dataWithBytes:answer length:strlen(answer)];
        result = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        spdf_paint_free(answer);
    }
    if (completion) completion([result isKindOfClass:[NSDictionary class]] ? result : SPDFAnnotateNotBuiltAnswer());
}

- (void)applyOperations:(NSArray<NSDictionary*>*)ops tab:(SPDFDocumentTab*)tab
             completion:(SPDFAnnotateCompletion)completion {
    (void)ops; (void)tab;
    if (completion) completion(@{@"ok": @NO, @"results": @[SPDFAnnotateNotBuiltAnswer()]});
}

- (SPDFMacAnnotateSession*)annotateSessionForTab:(SPDFDocumentTab*)tab create:(BOOL)create {
    (void)tab; (void)create;
    return nil;
}

- (SPDFMacAnnotateCanvasView*)annotateCanvasView {
    return nil;
}

- (SPDFMacAnnotateLayersPanel*)annotateLayersPanel {
    return nil;
}

- (SPDFMacAnnotatePaletteGroups*)annotatePaletteGroups {
    return nil;
}

@end
