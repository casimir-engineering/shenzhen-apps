// The single path for every Annotate change (SPDFMacFillController+Annotate.h).
//
// WAVE 0 STUB (the routing is the PDF agent's for fill_on_pdf and Mac UI A's for the rest): every operation goes to
// the core's check, whose stub answers not_implemented, so callers can already be wired to it.
#import "SPDFMacFillController+Annotate.h"

#import "SPDFMacAnnotateLayersPanel.h"
#import "SPDFMacAnnotatePaletteSupport.h"
#import "SPDFMacFillPalette.h"

#include "spdf_paint.h"

static NSDictionary* SPDFAnnotateNotBuiltAnswer(void) {
    return @{@"ok": @NO, @"error": @"not_implemented", @"message": @"Annotate is not built yet."};
}

@implementation SPDFMacFillController (Annotate)

- (void)applyOperation:(NSDictionary*)op tab:(SPDFDocumentTab*)tab completion:(SPDFAnnotateCompletion)completion {
    NSDictionary* palette = SPDFAnnotateApplyPaletteOperation(self, op, tab);  // tool.choose; colours' side (UI B)
    if (palette) {
        if (completion) completion(palette);
        return;
    }
    (void)tab;
    NSData* json = op ? [NSJSONSerialization dataWithJSONObject:op options:0 error:NULL] : nil;
    NSString* text = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : @"";
    char* answer = NULL;
    spdf_paint_check_op(text.UTF8String, SPDF_PAINT_DOC_PDF, NULL, &answer);
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
    return SPDFAnnotateLayersPanelFor(self, NO);
}

- (SPDFMacAnnotatePaletteGroups*)annotatePaletteGroups {
    return self.palette.annotateGroups;
}

@end
