// Annotate's sheets and questions (SPDFMacAnnotateIntegration.h, "Sheets and questions"; docs/plans/annotate.md § 2
// Image group, § Decisions Text documents and Saving a canvas).
//
// WAVE 0 STUB (Mac UI B implements): no sheet is shown; each question answers its safe choice (no change).
#import "SPDFMacAnnotateIntegration.h"

#import "SPDFMacFillController.h"

void SPDFAnnotateShowResizeSheet(NSWindow* window, SPDFMacFillController* controller) {
    (void)window; (void)controller;
}

void SPDFAnnotateShowCanvasPropertiesSheet(NSWindow* window, SPDFMacFillController* controller) {
    (void)window; (void)controller;
}

void SPDFAnnotateShowRotateBySheet(NSWindow* window, SPDFMacFillController* controller) {
    (void)window; (void)controller;
}

void SPDFAnnotateAskToSaveAsPDF(NSWindow* window, void (^answer)(BOOL save)) {
    (void)window;
    if (answer) answer(NO);
}

void SPDFAnnotateAskToSaveCanvas(NSWindow* window, NSString* name, void (^answer)(NSModalResponse choice)) {
    (void)window; (void)name;
    if (answer) answer(NSAlertThirdButtonReturn);
}

void SPDFAnnotateAskToGrowCanvas(NSWindow* window, void (^answer)(BOOL grow)) {
    (void)window;
    if (answer) answer(NO);
}
