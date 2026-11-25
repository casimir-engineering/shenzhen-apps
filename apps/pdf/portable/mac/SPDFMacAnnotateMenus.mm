// Annotate's menu items, context menus, keys and their validation (SPDFMacAnnotateIntegration.h, "Menus, context
// menus and keys"; docs/plans/annotate.md § 3, § 4, "Annotate keys").
//
// WAVE 0 STUB (Mac UI B implements): installs nothing, handles nothing.
#import "SPDFMacAnnotateIntegration.h"

#import "SPDFMacFillController.h"

void SPDFAnnotateInstallMenuItems(NSMenu* fileMenu, NSMenu* editMenu, NSMenu* viewMenu, ShenzhenMacDelegate* reader) {
    (void)fileMenu; (void)editMenu; (void)viewMenu; (void)reader;
}

BOOL SPDFAnnotateValidateMenuItem(NSMenuItem* item, ShenzhenMacDelegate* reader, BOOL* enabled) {
    (void)item; (void)reader;
    if (enabled) *enabled = NO;
    return NO;
}

NSMenu* SPDFAnnotateContextMenu(SPDFMacFillController* controller, NSInteger page, NSPoint point) {
    (void)controller; (void)page; (void)point;
    return nil;
}

BOOL SPDFAnnotateHandleKey(NSEvent* event, SPDFMacFillController* controller) {
    (void)event; (void)controller;
    return NO;
}
