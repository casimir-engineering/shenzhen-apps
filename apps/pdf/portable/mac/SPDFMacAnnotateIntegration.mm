// Annotate in the reader (SPDFMacAnnotateIntegration.h).
//
// WAVE 0 STUB (Mac UI A implements): no method is called from the reader yet; each does nothing. The texts are real:
// they are the spec's words, in one place for every Annotate file.
#import "SPDFMacAnnotateIntegration.h"

NSString* const SPDFAnnotateTitle = @"Annotate";
NSString* const SPDFAnnotateFormGroupTitle = @"Fill & Sign";
NSString* const SPDFAnnotateNewCanvasTitle = @"New Canvas";
NSString* const SPDFAnnotateUntitledCanvasTitle = @"Untitled canvas";
NSString* const SPDFAnnotateSaveAsPDFQuestion = @"To annotate this document, save it as a PDF.";
NSString* const SPDFAnnotateSaveAsPDFButton = @"Save as PDF…";
NSString* const SPDFAnnotatePageLockedText = @"The page itself can't be changed.";
NSString* const SPDFAnnotateNeedsPDFText = @"Save this document as a PDF to annotate it.";
NSString* const SPDFAnnotateCopyNoteText = @"Annotate saves a copy of this picture as PNG.";
NSString* const SPDFAnnotateWritableCopyNote =
    @"You're annotating a copy, because the original can't be changed. Choose File > Save As... to put it where you "
    @"want.";
NSString* const SPDFAnnotateGrowCanvasQuestion = @"Make the canvas bigger to fit?";
NSString* const SPDFAnnotateRemoveEverythingTitle = @"Remove Everything Added with Annotate";
NSString* const SPDFAnnotateProjectFormatTitle = @"Shenzhen Paint project";

@implementation ShenzhenMacDelegate (SPDFMacAnnotate)

- (void)toggleAnnotate:(id)sender {
    (void)sender;
}

- (BOOL)annotateAvailable {
    return NO;
}

- (BOOL)annotateShowing {
    return NO;
}

- (SPDFAnnotateDocumentKind)annotateActiveDocumentKind {
    return SPDFAnnotateDocumentNone;
}

- (SPDFMacAnnotateSession*)annotateActiveSession {
    return nil;
}

- (void)newCanvas:(id)sender {
    (void)sender;
}

- (SPDFDocumentTab*)annotateNewCanvasWidth:(NSInteger)width height:(NSInteger)height
                                background:(spdf_paint_color)background front:(BOOL)front {
    (void)width; (void)height; (void)background; (void)front;
    return nil;
}

- (void)annotateRestoreCanvasTab:(SPDFDocumentTab*)tab {
    (void)tab;
}

- (BOOL)annotateOpenProjectAtPath:(NSString*)path {
    (void)path;
    return NO;
}

- (void)annotateSaveTextDocumentAsPDF:(NSString*)path
                           completion:(void (^)(SPDFDocumentTab*, NSError*))completion {
    (void)path;
    if (completion) completion(nil, nil);
}

- (void)annotateSaveDocument:(id)sender {
    (void)sender;
}

- (void)annotateSaveDocumentAs:(id)sender {
    (void)sender;
}

- (void)setDesktopPicture:(id)sender {
    (void)sender;
}

- (void)toggleAnnotateLayers:(id)sender {
    (void)sender;
}

- (void)toggleAnnotateStatusBar:(id)sender {
    (void)sender;
}

- (void)toggleAnnotateRulers:(id)sender {
    (void)sender;
}

- (void)toggleAnnotateGridlines:(id)sender {
    (void)sender;
}

- (void)toggleAnnotateThumbnail:(id)sender {
    (void)sender;
}

- (void)annotateFlushEdits {
}

- (void)annotateActiveDocumentChanged {
}

- (BOOL)annotateTabShouldClose:(SPDFDocumentTab*)tab {
    (void)tab;
    return YES;
}

- (void)annotateFlushForQuit {
}

@end
