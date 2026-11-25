// Showing the Layers panel (SPDFMacAnnotateLayersPanel.h): one per window's controller, made on first use, shown
// while Annotate is on and the person wants it (remembered in SPDFAnnotateSettings.showsLayers).
#import "SPDFMacAnnotateLayersPanel.h"

#import <objc/runtime.h>

#import "SPDFMacAnnotateIntegration.h"
#import "SPDFMacAnnotatePaletteSupport.h"
#import "SPDFMacFillController.h"

static char kSPDFLayersPanelKey;

SPDFMacAnnotateLayersPanel* SPDFAnnotateLayersPanelFor(SPDFMacFillController* controller, BOOL create) {
    if (!controller) return nil;
    SPDFMacAnnotateLayersPanel* panel = objc_getAssociatedObject(controller, &kSPDFLayersPanelKey);
    if (!panel && create) {
        panel = [[SPDFMacAnnotateLayersPanel alloc] initWithController:controller];
        objc_setAssociatedObject(controller, &kSPDFLayersPanelKey, panel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return panel;
}

BOOL SPDFAnnotateLayersPanelShown(SPDFMacFillController* controller) {
    return SPDFAnnotateLayersPanelFor(controller, NO).superview != nil;
}

void SPDFAnnotateSyncLayersPanel(SPDFMacFillController* controller) {
    SPDFAnnotateDocumentKind kind = SPDFAnnotateCurrentKind(controller);
    BOOL show = [controller isShowing] && [SPDFAnnotateSettings shared].showsLayers && kind != SPDFAnnotateDocumentNone &&
                kind != SPDFAnnotateDocumentText;
    SPDFMacAnnotateLayersPanel* panel = SPDFAnnotateLayersPanelFor(controller, show);
    BOOL wasShown = panel.superview != nil;
    id host = controller.host;
    ShenzhenMacDelegate* reader = [host isKindOfClass:[ShenzhenMacDelegate class]] ? host : nil;
    if (!show) {
        [panel detach];
        if (wasShown) [reader annotateLayersPanelDidShow:NO];
        return;
    }
    [panel attachToContainer:[controller.host fillContainer]];
    if (!wasShown) [reader annotateLayersPanelDidShow:YES];
    [panel reloadFromSession:SPDFAnnotateCurrentSession(controller, YES)];
}

void SPDFAnnotateToggleLayersPanel(SPDFMacFillController* controller) {
    SPDFAnnotateSettings* settings = [SPDFAnnotateSettings shared];
    settings.showsLayers = !SPDFAnnotateLayersPanelShown(controller);
    SPDFAnnotateSyncLayersPanel(controller);
    [controller refreshChrome];
}
