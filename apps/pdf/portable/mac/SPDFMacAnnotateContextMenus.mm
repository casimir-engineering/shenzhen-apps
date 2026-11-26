// The three right-click menus of docs/plans/annotate.md § 3 (SPDFAnnotateContextMenu, SPDFMacAnnotateIntegration.h):
// an object's, the selection's and the canvas's, chosen by what is under the pointer in doc.state's answer. Every item
// is a command item: it names the object it acts on, so it does what it says even if the selection changes.
#import "SPDFMacAnnotateIntegration.h"

#import "SPDFMacAnnotatePaletteSupport.h"
#import "SPDFMacFillController.h"

static NSRect SPDFAnnotateRect(id value) {
    if ([value isKindOfClass:[NSDictionary class]])
        return NSMakeRect([value[@"x"] doubleValue], [value[@"y"] doubleValue], [value[@"w"] doubleValue], [value[@"h"] doubleValue]);
    if ([value isKindOfClass:[NSArray class]] && [value count] == 4)
        return NSMakeRect([value[0] doubleValue], [value[1] doubleValue], [value[2] doubleValue], [value[3] doubleValue]);
    return NSZeroRect;
}

// The front-most object whose bounds hold the point (canvas units), or nil.
static NSDictionary* SPDFAnnotateObjectAt(NSDictionary* state, NSPoint point) {
    NSArray* layers = [state[@"layers"] isKindOfClass:[NSArray class]] ? state[@"layers"] : @[];
    for (NSDictionary* layer in layers.reverseObjectEnumerator) {
        if (![layer isKindOfClass:[NSDictionary class]] || [layer[@"kind"] isEqual:@"background"] ||
            [layer[@"kind"] isEqual:@"raster"] || (layer[@"visible"] && ![layer[@"visible"] boolValue]))
            continue;
        NSDictionary* object = [layer[@"object"] isKindOfClass:[NSDictionary class]] ? layer[@"object"] : @{};
        NSRect bounds = SPDFAnnotateRect(layer[@"bounds"] ?: object[@"bounds"]);
        if (NSPointInRect(point, NSInsetRect(bounds, -2, -2))) return layer;
    }
    return nil;
}

static NSString* SPDFAnnotateObjectKind(NSDictionary* layer) {
    NSDictionary* object = [layer[@"object"] isKindOfClass:[NSDictionary class]] ? layer[@"object"] : nil;
    NSString* kind = object[@"kind"] ?: layer[@"objectKind"] ?: layer[@"kind"];
    return [kind isKindOfClass:[NSString class]] ? kind : @"";
}

static NSMenu* SPDFAnnotateObjectMenu(SPDFMacFillController* c, NSDictionary* layer) {
    NSNumber* objectId = layer[@"id"];
    NSString* kind = SPDFAnnotateObjectKind(layer);
    NSDictionary* object = [layer[@"object"] isKindOfClass:[NSDictionary class]] ? layer[@"object"] : @{};
    double rotation = [object[@"rotation"] ?: layer[@"rotation"] doubleValue];
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Object"];
    const NSEventModifierFlags cmd = NSEventModifierFlagCommand, opt = NSEventModifierFlagOption;
#define ITEM(title, key, mods, payload) [menu addItem:SPDFAnnotateItem(title, key, mods, payload, c, nil)]
#define ORDER(to) (@{@"op" : @"object.order", @"id" : objectId, @"to" : to})
    ITEM(@"Bring to Front", @"]", cmd | opt, ORDER(@"front"));
    ITEM(@"Bring Forward", @"]", cmd, ORDER(@"forward"));
    ITEM(@"Send Backward", @"[", cmd, ORDER(@"backward"));
    ITEM(@"Send to Back", @"[", cmd | opt, ORDER(@"back"));
    [menu addItem:[NSMenuItem separatorItem]];
    ITEM(@"Merge Down", @"", 0, (@{@"op" : @"object.merge_down", @"id" : objectId}));
    ITEM(@"Duplicate", @"d", cmd | opt, (@{@"op" : @"object.duplicate", @"id" : objectId}));
    ITEM(@"Delete", @"", 0, (@{@"op" : @"object.delete", @"id" : objectId}));
    [menu addItem:[NSMenuItem separatorItem]];
    ITEM(@"Flip Horizontal", @"", 0, (@{@"op" : @"object.transform", @"id" : objectId, @"flip" : @"horizontal"}));
    ITEM(@"Flip Vertical", @"", 0, (@{@"op" : @"object.transform", @"id" : objectId, @"flip" : @"vertical"}));
    ITEM(@"Rotate Right", @"", 0, (@{@"op" : @"object.transform", @"id" : objectId, @"rotation" : @(fmod(rotation + 90, 360))}));
    ITEM(@"Rotate Left", @"", 0, (@{@"op" : @"object.transform", @"id" : objectId, @"rotation" : @(fmod(rotation + 270, 360))}));
    BOOL shape = [kind isEqual:@"shape"] || SPDFAnnotateEntryNamed(SPDFAnnotateShapes(), kind) != nil;
    if (shape) {
        [menu addItem:[NSMenuItem separatorItem]];
        [menu addItemWithTitle:@"Outline" action:nil keyEquivalent:@""].submenu = SPDFAnnotateStyleMenu(c, YES, objectId.integerValue);
        [menu addItemWithTitle:@"Fill" action:nil keyEquivalent:@""].submenu = SPDFAnnotateStyleMenu(c, NO, objectId.integerValue);
        NSMenu* sizes = [[NSMenu alloc] initWithTitle:@"Size"];
        NSString* unit = SPDFAnnotateUnit(SPDFAnnotateCurrentKind(c));
        double width = [object[@"outline"][@"width"] doubleValue];
        for (NSNumber* size in @[ @1, @2, @3, @5, @8, @12, @20, @30, @50 ]) {
            NSMenuItem* item = SPDFAnnotateItem([NSString stringWithFormat:@"%@ %@", size, unit], @"", 0,
                                                (@{@"op" : @"object.update", @"id" : objectId, @"outline" : @{@"width" : size}}), c, nil);
            item.state = fabs(width - size.doubleValue) < 0.01 ? NSControlStateValueOn : NSControlStateValueOff;
            [sizes addItem:item];
        }
        [menu addItemWithTitle:@"Size" action:nil keyEquivalent:@""].submenu = sizes;
    }
    if ([kind isEqual:@"text"]) {
        [menu addItem:[NSMenuItem separatorItem]];
        ITEM(@"Edit Text", @"", 0, (@[ @{@"op" : @"layer.activate", @"id" : objectId}, SPDFAnnotateCommandEditText ]));
    }
    [menu addItem:[NSMenuItem separatorItem]];
    // Copy and Cut take this object: it becomes the selected one first.
    ITEM(@"Copy", @"", 0, (@[ @{@"op" : @"layer.activate", @"id" : objectId}, @{@"op" : @"doc.copy", @"scope" : @"object"} ]));
    ITEM(@"Cut", @"", 0, (@[ @{@"op" : @"layer.activate", @"id" : objectId}, @{@"op" : @"doc.copy", @"scope" : @"object"},
                             @{@"op" : @"object.delete", @"id" : objectId} ]));
#undef ORDER
    return menu;
}

static NSMenu* SPDFAnnotateSelectionContextMenu(SPDFMacFillController* c) {
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Selection"];
    ITEM(@"Cut", @"", 0, SPDFAnnotateCommandCut);
    ITEM(@"Copy", @"", 0, (@{@"op" : @"doc.copy", @"scope" : @"selection"}));
    ITEM(@"Delete", @"", 0, @{@"op" : @"select.delete"});
    [menu addItem:[NSMenuItem separatorItem]];
    ITEM(@"Crop to Selection", @"", 0, @{@"op" : @"image.crop"});
    ITEM(@"Invert Selection", @"", 0, @{@"op" : @"select.invert"});
    ITEM(@"Lift to Object", @"", 0, @{@"op" : @"select.lift"});
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Flip" action:nil keyEquivalent:@""].submenu = SPDFAnnotateFlipMenu(c, nil, @"selection");
    [menu addItemWithTitle:@"Rotate" action:nil keyEquivalent:@""].submenu = SPDFAnnotateRotateMenu(c, nil, @"selection");
    return menu;
}

static NSMenu* SPDFAnnotateCanvasMenu(SPDFMacFillController* c) {
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Canvas"];
    ITEM(@"Paste", @"", 0, SPDFAnnotatePastePayload());
    ITEM(@"Select All", @"", 0, @{@"op" : @"select.all"});
    ITEM(@"New Layer", @"", 0, @{@"op" : @"layer.add"});
    [menu addItem:[NSMenuItem separatorItem]];
    ITEM(@"Canvas Size and Properties…", @"", 0, SPDFAnnotateCommandCanvasSheet);
    if (SPDFAnnotateCanRemoveBackground()) ITEM(@"Remove Background", @"", 0, (@{@"op" : @"image.remove_background", @"scope" : @"auto"}));
    return menu;
#undef ITEM
}

NSMenu* SPDFAnnotateContextMenu(SPDFMacFillController* controller, NSInteger page, NSPoint point) {
    if (!controller || ![controller isShowing]) return nil;
    SPDFMacAnnotateSession* session = SPDFAnnotateCurrentSession(controller, YES);
    if (page >= 0) session.currentPage = page;  // the page right-clicked is the one the menu acts on
    NSDictionary* state = SPDFAnnotateDocState(controller);
    NSDictionary* object = SPDFAnnotateObjectAt(state, point);
    if (object && ![object[@"locked"] boolValue]) return SPDFAnnotateObjectMenu(controller, object);
    NSDictionary* selection = [state[@"selection"] isKindOfClass:[NSDictionary class]] ? state[@"selection"] : nil;
    if (SPDFAnnotateStateHasPixelSelection(state) && NSPointInRect(point, SPDFAnnotateRect(selection[@"bounds"])))
        return SPDFAnnotateSelectionContextMenu(controller);
    return SPDFAnnotateCanvasMenu(controller);
}

BOOL SPDFAnnotateValidateMenuItem(NSMenuItem* item, ShenzhenMacDelegate* reader, BOOL* enabled) {
    (void)reader;
    id target = item.target;
    if (item.action != @selector(perform:) || ![target conformsToProtocol:@protocol(NSMenuItemValidation)]) return NO;
    BOOL on = [target validateMenuItem:item];
    if (enabled) *enabled = on;
    return YES;
}
