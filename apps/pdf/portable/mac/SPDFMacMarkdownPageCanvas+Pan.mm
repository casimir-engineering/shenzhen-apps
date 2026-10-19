#import "SPDFMacMarkdownPageCanvas.h"

#import <objc/runtime.h>

#import "SPDFMacMarkdownPanController.h"

static char kSPDFMacMarkdownPanControllerKey;

@implementation SPDFMacMarkdownPageCanvas (Pan)

- (SPDFMacMarkdownPanController*)spdf_panController {
    SPDFMacMarkdownPanController* controller = objc_getAssociatedObject(self, &kSPDFMacMarkdownPanControllerKey);
    if (!controller) {
        controller = [[SPDFMacMarkdownPanController alloc] initWithDocumentView:self];
        objc_setAssociatedObject(self, &kSPDFMacMarkdownPanControllerKey, controller,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return controller;
}

- (void)rightMouseDown:(NSEvent*)event {
    if (!NSApp.active) [NSApp activateIgnoringOtherApps:YES];
    if (!self.window.keyWindow) [self.window makeKeyAndOrderFront:nil];
    if (event.modifierFlags & NSEventModifierFlagCommand) return;
    [self.spdf_panController beginAtWindowPoint:event.locationInWindow timestamp:event.timestamp];
}

- (void)rightMouseDragged:(NSEvent*)event {
    [self.spdf_panController continueAtWindowPoint:event.locationInWindow timestamp:event.timestamp];
}

- (void)rightMouseUp:(NSEvent*)event {
    SPDFMacMarkdownPanController* controller = self.spdf_panController;
    BOOL showMenu = (event.modifierFlags & NSEventModifierFlagCommand) != 0 || !controller.moved;
    if (showMenu) [NSMenu popUpContextMenu:[self menuForEvent:event] withEvent:event forView:self];
    [controller end];
}

- (void)otherMouseDown:(NSEvent*)event {
    if (event.buttonNumber == 2)
        [self.spdf_panController beginAtWindowPoint:event.locationInWindow timestamp:event.timestamp];
    else
        [super otherMouseDown:event];
}

- (void)otherMouseDragged:(NSEvent*)event {
    SPDFMacMarkdownPanController* controller = self.spdf_panController;
    if (controller.isPanning)
        [controller continueAtWindowPoint:event.locationInWindow timestamp:event.timestamp];
    else
        [super otherMouseDragged:event];
}

- (void)otherMouseUp:(NSEvent*)event {
    SPDFMacMarkdownPanController* controller = self.spdf_panController;
    if (controller.isPanning)
        [controller end];
    else
        [super otherMouseUp:event];
}

@end
