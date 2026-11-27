// Annotate's menu items, keys and their validation (SPDFMacAnnotateIntegration.h, "Menus, context menus and keys";
// docs/plans/annotate.md § 3, § 4, "Annotate keys"). The context menus are in SPDFMacAnnotateContextMenus.mm.
//
// Every item is a command item (SPDFAnnotateItem): it sends an operation through applyOperation:, or opens a sheet or
// a dialog that then sends one. Where the app already used a key, the app keeps it and Annotate's item takes the
// fallback with Option added (the spec's "Annotate keys" table).
#import "SPDFMacAnnotateIntegration.h"
#import "SPDFMacAnnotateMenus.h"

#import <objc/runtime.h>

#import "SPDFMacAnnotateCanvasView.h"
#import "SPDFMacAnnotateImageIO.h"
#import "SPDFMacAnnotatePaletteSupport.h"
#import "SPDFMacFillController+Annotate.h"
#import "SPDFMacFillOverlayView.h"

@interface ShenzhenMacDelegate (SPDFAnnotateMenusReader)
- (SPDFMacFillController*)existingFillController;
@end

static const NSEventModifierFlags kCmd = NSEventModifierFlagCommand, kShift = NSEventModifierFlagShift,
                                  kOpt = NSEventModifierFlagOption, kCtrl = NSEventModifierFlagControl;

#pragma mark - The Edit menu's standard items (Cut, Copy, Paste, Select All, Undo, Redo)

// Their target while Annotate is installed: an edit action becomes an operation when Annotate takes it, and goes on
// to the responder chain as before otherwise (text being typed, Fill & Sign's own Select, Annotate off).
@interface SPDFAnnotateEditTarget : NSObject <NSMenuItemValidation>
@property(nonatomic, weak) ShenzhenMacDelegate* reader;
@end

static char kSPDFAnnotateEditTargetKey, kSPDFAnnotateEditActionKey;

static SEL SPDFAnnotateEditAction(NSMenuItem* item) {
    NSString* name = objc_getAssociatedObject(item, &kSPDFAnnotateEditActionKey);
    return name ? NSSelectorFromString(name) : NULL;
}

static BOOL SPDFAnnotateTakesEdits(SPDFMacFillController* controller, SEL action) {
    if (!controller || ![controller isShowing]) return NO;
    // A sheet (Resize and skew, Canvas size, a Save panel) or another window in front keeps its own Edit keys, and so
    // does a text box or field being typed in: they act on what is typed, not on the canvas.
    NSWindow* document = [controller.host fillWindow];
    NSWindow* key = NSApp.keyWindow;
    if (document.attachedSheet || (key && key != document)) return NO;
    if ([document.firstResponder isKindOfClass:[NSText class]]) return NO;
    SPDFAnnotateDocumentKind kind = SPDFAnnotateCurrentKind(controller);
    if (kind == SPDFAnnotateDocumentNone || kind == SPDFAnnotateDocumentText) return NO;
    if (action == @selector(undo:) || action == @selector(redo:)) return YES;  // one undo stack per tab
    SPDFMacAnnotateSession* session = SPDFAnnotateCurrentSession(controller, NO);
    // Whatever tool is chosen: a picture on the clipboard is pasted as a Picture object, and Annotate's selected
    // objects are what Copy and Cut take (the page's text is copied with nothing of Annotate's selected).
    if (action == @selector(paste:) && SPDFAnnotatePasteboardHasPicture(NSPasteboard.generalPasteboard)) return YES;
    if ((action == @selector(copy:) || action == @selector(cut:)) && session.selectedObjects.count) return YES;
    NSString* tool = SPDFAnnotateChosenToolName(session);
    NSSet* fillTools = [NSSet setWithArray:@[ @"form_text", @"form_mark", @"form_signature", @"pen", @"arrow", @"select", @"" ]];
    return kind != SPDFAnnotateDocumentPDF || ![fillTools containsObject:tool];
}

static id SPDFAnnotateEditPayload(SEL action) {
    if (action == @selector(copy:)) return @{@"op" : @"doc.copy", @"scope" : @"auto"};
    if (action == @selector(cut:)) return SPDFAnnotateCommandCut;
    if (action == @selector(paste:)) return SPDFAnnotatePastePayload();
    if (action == @selector(selectAll:)) return @{@"op" : @"select.all"};
    if (action == @selector(undo:)) return @{@"op" : @"history.undo"};
    if (action == @selector(redo:)) return @{@"op" : @"history.redo"};
    return nil;
}

BOOL SPDFAnnotatePerformEditAction(SEL action, SPDFMacFillController* controller) {
    id payload = SPDFAnnotateEditPayload(action);
    if (!payload || !SPDFAnnotateTakesEdits(controller, action)) return NO;
    SPDFAnnotatePerform(controller, payload);
    return YES;
}

@implementation SPDFAnnotateEditTarget

- (void)perform:(NSMenuItem*)item {
    SEL action = SPDFAnnotateEditAction(item);
    if (!action || SPDFAnnotatePerformEditAction(action, [self.reader existingFillController])) return;
    [NSApp sendAction:action to:nil from:item];
}

- (BOOL)validateMenuItem:(NSMenuItem*)item {
    SEL action = SPDFAnnotateEditAction(item);
    SPDFMacFillController* controller = [self.reader existingFillController];
    if (action && SPDFAnnotateTakesEdits(controller, action)) {
        if (action == @selector(paste:))
            return SPDFAnnotatePasteboardHasPicture(NSPasteboard.generalPasteboard);
        return SPDFAnnotatePayloadEnabled(controller, SPDFAnnotateEditPayload(action), NULL);
    }
    if (!action) return NO;
    // As before Annotate: whoever in the responder chain does it says whether it can.
    id target = [NSApp targetForAction:action to:nil from:item];
    if (!target) return NO;
    if (![target respondsToSelector:@selector(validateMenuItem:)]) return YES;
    NSMenuItem* probe = [[NSMenuItem alloc] initWithTitle:item.title action:action keyEquivalent:@""];
    return [target validateMenuItem:probe];
}

@end

static void SPDFAnnotateTakeEditItem(NSMenu* menu, SEL action, SPDFAnnotateEditTarget* target) {
    NSInteger index = [menu indexOfItemWithTarget:nil andAction:action];
    if (index < 0) return;
    NSMenuItem* item = [menu itemAtIndex:index];
    objc_setAssociatedObject(item, &kSPDFAnnotateEditActionKey, NSStringFromSelector(action), OBJC_ASSOCIATION_COPY);
    item.action = @selector(perform:);
    item.target = target;
}

static NSMenuItem* SPDFAnnotateEditItem(NSString* title, SEL action, NSString* key, NSEventModifierFlags mods,
                                        SPDFAnnotateEditTarget* target) {
    NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title action:@selector(perform:) keyEquivalent:key];
    item.keyEquivalentModifierMask = mods;
    item.target = target;
    objc_setAssociatedObject(item, &kSPDFAnnotateEditActionKey, NSStringFromSelector(action), OBJC_ASSOCIATION_COPY);
    return item;
}

#pragma mark - Installing

static NSMenuItem* SPDFAnnotateMenuBarItem(NSString* title, NSString* key, NSEventModifierFlags mods, id payload,
                                           ShenzhenMacDelegate* reader, NSString* symbol) {
    NSMenuItem* item = SPDFAnnotateItem(title, key, mods, payload, nil, reader);
    if (symbol) item.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    return item;
}

void SPDFAnnotateInstallMenuItems(NSMenu* fileMenu, NSMenu* editMenu, NSMenu* viewMenu, ShenzhenMacDelegate* reader) {
    NSMenu* main = fileMenu.supermenu;
    if (!viewMenu) viewMenu = [main itemWithTitle:@"View"].submenu;
#define BAR(title, key, mods, payload, symbol) SPDFAnnotateMenuBarItem(title, key, mods, payload, reader, symbol)
    // File: New Canvas (Cmd-N, free), Save (Cmd-S) and Save As... (Shift-Cmd-S), Set as Desktop Picture.
    [fileMenu insertItem:BAR(SPDFAnnotateNewCanvasTitle, @"n", kCmd, SPDFAnnotateCommandNewCanvas, @"square.dashed")
                 atIndex:0];
    NSInteger saveAs = [fileMenu indexOfItemWithTarget:nil andAction:@selector(saveDocumentAs:)];
    if (saveAs >= 0) {
        NSMenuItem* old = [fileMenu itemAtIndex:saveAs];
        NSMenuItem* save = BAR(@"Save", @"s", kCmd, SPDFAnnotateCommandSave, @"square.and.arrow.down");
        NSMenuItem* as = BAR(old.title, @"S", kCmd | kShift, SPDFAnnotateCommandSaveAs, @"square.and.arrow.down.on.square");
        [fileMenu removeItemAtIndex:saveAs];
        [fileMenu insertItem:as atIndex:saveAs];
        [fileMenu insertItem:save atIndex:saveAs];
        [fileMenu insertItem:BAR(@"Set as Desktop Picture", @"", 0, SPDFAnnotateCommandDesktopPicture, @"menubar.dock.rectangle")
                     atIndex:saveAs + 2];
    }
    // Edit: Undo, Redo, Repeat first; Cut, Copy, Paste and Select All reach Annotate while it shows.
    SPDFAnnotateEditTarget* edit = [SPDFAnnotateEditTarget new];
    edit.reader = reader;
    objc_setAssociatedObject(reader, &kSPDFAnnotateEditTargetKey, edit, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for (NSString* name in @[ @"cut:", @"copy:", @"paste:", @"selectAll:" ])
        SPDFAnnotateTakeEditItem(editMenu, NSSelectorFromString(name), edit);
    NSMenuItem* undo = SPDFAnnotateEditItem(@"Undo", @selector(undo:), @"z", kCmd, edit);
    NSMenuItem* redo = SPDFAnnotateEditItem(@"Redo", @selector(redo:), @"Z", kCmd | kShift, edit);
    NSMenuItem* redoY = SPDFAnnotateEditItem(@"Redo", @selector(redo:), @"y", kCmd, edit);
    redoY.hidden = YES;  // Cmd-Y works too, without a second row
    redoY.allowsKeyEquivalentWhenHidden = YES;
    unichar f4 = NSF4FunctionKey;
    NSMenuItem* repeat = BAR(@"Repeat", [NSString stringWithCharacters:&f4 length:1], 0, SPDFAnnotateCommandRepeat, nil);
    NSArray* top = @[ undo, redo, redoY, repeat, [NSMenuItem separatorItem] ];
    for (NSUInteger i = 0; i < top.count; ++i) [editMenu insertItem:top[i] atIndex:(NSInteger)i];
    NSInteger paste = [editMenu indexOfItem:[editMenu itemWithTitle:@"Paste"]];
    NSArray* selection = @[
        BAR(@"Paste from file…", @"V", kCmd | kShift | kOpt, SPDFAnnotateCommandPasteFromFile, nil),
        BAR(@"Duplicate", @"d", kCmd | kOpt, (@{@"op" : @"object.duplicate", @"ids" : SPDFAnnotateSelectedIds}), nil),
        BAR(@"Invert selection", @"I", kCmd | kShift | kOpt, @{@"op" : @"select.invert"}, nil),
        BAR(@"Crop to selection", @"X", kCmd | kShift, @{@"op" : @"image.crop"}, nil),
    ];
    for (NSUInteger i = 0; i < selection.count && paste >= 0; ++i)
        [editMenu insertItem:selection[i] atIndex:paste + 1 + (NSInteger)i];
    // Depth (§ 3): the selected objects.
    NSMenu* arrange = [[NSMenu alloc] initWithTitle:@"Arrange"];
    [arrange addItem:BAR(@"Bring to Front", @"]", kCmd | kOpt, (@{@"op" : @"object.order", @"ids" : SPDFAnnotateSelectedIds, @"to" : @"front"}), nil)];
    [arrange addItem:BAR(@"Bring Forward", @"]", kCmd, (@{@"op" : @"object.order", @"ids" : SPDFAnnotateSelectedIds, @"to" : @"forward"}), nil)];
    [arrange addItem:BAR(@"Send Backward", @"[", kCmd, (@{@"op" : @"object.order", @"ids" : SPDFAnnotateSelectedIds, @"to" : @"backward"}), nil)];
    [arrange addItem:BAR(@"Send to Back", @"[", kCmd | kOpt, (@{@"op" : @"object.order", @"ids" : SPDFAnnotateSelectedIds, @"to" : @"back"}), nil)];
    NSInteger fillItem = [editMenu indexOfItemWithTitle:@"Fill & Sign"];
    if (fillItem < 0) fillItem = [editMenu indexOfItemWithTitle:SPDFAnnotateTitle];
    NSMenuItem* arrangeItem = [[NSMenuItem alloc] initWithTitle:@"Arrange" action:nil keyEquivalent:@""];
    arrangeItem.submenu = arrange;
    [editMenu insertItem:arrangeItem atIndex:fillItem >= 0 ? fillItem + 1 : editMenu.numberOfItems];
    // View: Layers, Status Bar, Rulers, Gridlines, Thumbnail.
    if (viewMenu) {
        [viewMenu addItem:[NSMenuItem separatorItem]];
        [viewMenu addItem:BAR(@"Layers", @"L", kCmd | kShift, SPDFAnnotateCommandLayers, @"square.3.layers.3d")];
        [viewMenu addItem:BAR(@"Status Bar", @"", 0, (@{@"op" : @"view.set", @"statusbar" : @"toggle"}), nil)];
        [viewMenu addItem:BAR(@"Rulers", @"R", kCmd | kShift | kOpt, (@{@"op" : @"view.set", @"rulers" : @"toggle"}), nil)];
        [viewMenu addItem:BAR(@"Gridlines", @"'", kCmd, (@{@"op" : @"view.set", @"gridlines" : @"toggle"}), nil)];
        [viewMenu addItem:BAR(@"Thumbnail", @"", 0, (@{@"op" : @"view.set", @"thumbnail" : @"toggle"}), nil)];
    }
    // Image, after Edit: the Image group's commands, then Colors and Layers.
    NSMenu* image = SPDFAnnotateImageMenu(nil, reader);
    [image addItem:[NSMenuItem separatorItem]];
    NSMenu* colors = [[NSMenu alloc] initWithTitle:@"Colors"];
    [colors addItem:BAR(@"Edit colors…", @"", 0, SPDFAnnotateCommandEditColors, nil)];
    [colors addItem:BAR(@"Save Colors…", @"", 0, SPDFAnnotateCommandSaveColors, nil)];
    [colors addItem:BAR(@"Get Colors…", @"", 0, SPDFAnnotateCommandGetColors, nil)];
    [colors addItem:BAR(@"Swap Color 1 and Color 2 (X)", @"", 0, SPDFAnnotateCommandSwapColors, nil)];
    [colors addItem:BAR(@"Reset to black and white (D)", @"", 0, SPDFAnnotateCommandDefaultColors, nil)];
    [image addItemWithTitle:@"Colors" action:nil keyEquivalent:@""].submenu = colors;
    NSMenu* layers = [[NSMenu alloc] initWithTitle:@"Layers"];
    [layers addItem:BAR(@"New Layer", @"", 0, @{@"op" : @"layer.add"}, nil)];
    [layers addItem:BAR(@"Merge Down", @"", 0, (@{@"op" : @"object.merge_down", @"id" : SPDFAnnotateSelectedIds}), nil)];
    [layers addItem:[NSMenuItem separatorItem]];
    [layers addItem:BAR(@"Move to Layer Above", @"", 0, (@{@"op" : @"object.layer", @"ids" : SPDFAnnotateSelectedIds, @"to" : @"above"}), nil)];
    [layers addItem:BAR(@"Move to Layer Below", @"", 0, (@{@"op" : @"object.layer", @"ids" : SPDFAnnotateSelectedIds, @"to" : @"below"}), nil)];
    [image addItemWithTitle:@"Layers" action:nil keyEquivalent:@""].submenu = layers;
    NSMenuItem* imageItem = [[NSMenuItem alloc] initWithTitle:@"Image" action:nil keyEquivalent:@""];
    imageItem.submenu = image;
    NSInteger editIndex = [main indexOfItemWithTitle:@"Edit"];
    [main insertItem:imageItem atIndex:editIndex >= 0 ? editIndex + 1 : main.numberOfItems];
#undef BAR
}

#pragma mark - Keys (§ 2, § 3, § 4)

static NSString* SPDFAnnotateKeyLetter(NSEvent* event, BOOL* shift) {
    NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (mods & (kCmd | kCtrl | kOpt)) return nil;
    if (shift) *shift = (mods & kShift) != 0;
    NSString* chars = event.charactersIgnoringModifiers.lowercaseString ?: @"";
    unichar c = chars.length == 1 ? [chars characterAtIndex:0] : 0;
    return c > 0x20 && c < 0x7f ? chars : nil;  // a printable key: not Delete, Escape, the arrows or Tab
}

BOOL SPDFAnnotateClaimsKey(NSEvent* event, SPDFMacFillController* controller) {
    if (![controller isShowing] || controller.editor) return NO;
    NSString* letter = SPDFAnnotateKeyLetter(event, NULL);
    return letter && [@"paestnbfizulxd[]" rangeOfString:letter].location != NSNotFound;
}

static NSString* SPDFAnnotateNext(NSArray<NSString*>* cycle, NSString* current) {
    NSUInteger index = [cycle indexOfObject:current];
    return cycle[index == NSNotFound ? 0 : (index + 1) % cycle.count];
}

// [ and ]: the chosen tool's size one step down or up, within its range.
static void SPDFAnnotateStepSize(SPDFMacFillController* c, NSString* tool, NSInteger step) {
    NSDictionary* o = SPDFAnnotateToolOptions(tool);
    BOOL shape = [tool isEqual:@"shape"], line = [tool isEqual:@"pen"] || [tool isEqual:@"arrow"];
    double size = shape ? [o[@"outline"][@"width"] doubleValue] : line ? [o[@"width"] doubleValue] : [o[@"size"] doubleValue];
    double low = [tool isEqual:@"eraser"] ? 4 : line ? 0.5 : 1;
    double high = [tool isEqual:@"pencil"] ? 20 : shape ? 50 : line ? 20 : 100;
    if (!o[@"size"] && !shape && !line) return;  // a tool without a size
    double next = MIN(high, MAX(low, size + step));
    if (next == size) return;
    SPDFAnnotateChooseTool(c, tool, shape ? @{@"outline" : @{@"width" : @(next)}} : line ? @{@"width" : @(next)} : @{@"size" : @(next)});
}

// Delete, Escape and the arrows act on Annotate's selection before the document pages or scrolls.
static BOOL SPDFAnnotateSelectionKey(NSEvent* event, SPDFMacFillController* c, NSString* tool) {
    unichar key = event.charactersIgnoringModifiers.length ? [event.charactersIgnoringModifiers characterAtIndex:0] : 0;
    BOOL arrow = key == NSLeftArrowFunctionKey || key == NSRightArrowFunctionKey || key == NSUpArrowFunctionKey ||
                 key == NSDownArrowFunctionKey;
    if (key != 127 && key != NSDeleteFunctionKey && key != 27 && !arrow) return NO;
    NSDictionary* state = SPDFAnnotateDocState(c);
    NSArray* ids = SPDFAnnotateSelectedObjectIds(state);
    BOOL pixels = SPDFAnnotateStateHasPixelSelection(state);
    if (key == 27) {
        if (!ids.count && !pixels) return NO;
        SPDFAnnotateSend(c, SPDFAnnotateOnCurrentPage(c, @{@"op" : @"select.none"}), nil);  // a lifted selection stays an object
        return YES;
    }
    if (key == 127 || key == NSDeleteFunctionKey) {
        if (!ids.count && !pixels) return NO;
        SPDFAnnotateSend(c, SPDFAnnotateOnCurrentPage(c, @{@"op" : @"select.delete"}), nil);
        return YES;
    }
    CGFloat step = (event.modifierFlags & kShift) ? 10 : 1;
    CGFloat dx = key == NSLeftArrowFunctionKey ? -step : key == NSRightArrowFunctionKey ? step : 0;
    CGFloat dy = key == NSUpArrowFunctionKey ? -step : key == NSDownArrowFunctionKey ? step : 0;
    if (ids.count) {
        SPDFAnnotateSend(c, SPDFAnnotateOnCurrentPage(c, @{@"op" : @"object.move", @"ids" : ids, @"dx" : @(dx), @"dy" : @(dy)}), nil);
        return YES;
    }
    if (!pixels) return NO;
    // Pixels move once they are lifted into a Picture object, as a drag inside the selection does.
    __weak SPDFMacFillController* weak = c;
    SPDFAnnotateSend(c, SPDFAnnotateOnCurrentPage(c, @{@"op" : @"select.lift"}), ^(NSDictionary* result) {
      if (![result[@"ok"] boolValue] || !result[@"id"]) return;
      SPDFAnnotateSend(weak, SPDFAnnotateOnCurrentPage(weak, @{@"op" : @"object.move", @"id" : result[@"id"], @"dx" : @(dx), @"dy" : @(dy)}), nil);
    });
    (void)tool;
    return YES;
}

BOOL SPDFAnnotateHandleKey(NSEvent* event, SPDFMacFillController* controller) {
    if (![controller isShowing] || controller.editor) return NO;
    SPDFAnnotateDocumentKind kind = SPDFAnnotateCurrentKind(controller);
    if (kind == SPDFAnnotateDocumentNone || kind == SPDFAnnotateDocumentText) return NO;
    SPDFMacAnnotateSession* session = SPDFAnnotateCurrentSession(controller, YES);
    NSString* tool = SPDFAnnotateChosenToolName(session);
    BOOL pdf = kind == SPDFAnnotateDocumentPDF;
    NSSet* fillTools = [NSSet setWithArray:@[ @"form_text", @"form_mark", @"form_signature", @"pen", @"arrow", @"select" ]];
    BOOL shift = NO;
    NSString* letter = SPDFAnnotateKeyLetter(event, &shift);
    if (!letter) return !(pdf && [fillTools containsObject:tool]) && SPDFAnnotateSelectionKey(event, controller, tool);
    unichar k = [letter characterAtIndex:0];
    NSString* next = nil;
    NSDictionary* options = nil;
    switch (k) {
        case 'p': next = @"pen"; break;
        case 'a': next = @"arrow"; break;
        case 'n': next = @"pencil"; break;
        case 'f': next = @"fill"; break;
        case 'i': next = @"color_picker"; break;
        case 'z': next = @"magnifier"; break;
        case 't': next = shift || !pdf ? @"text_box" : @"form_text"; break;  // T is Fill & Sign's Text on a PDF
        case 's': next = SPDFAnnotateNext(@[ @"select", @"rect_select", @"freeform_select" ], tool); break;
        case 'e':
            next = @"eraser";
            // Pressed again: Whole lines and Pixels in turn.
            if ([tool isEqual:@"eraser"])
                options = @{@"eraser" : [SPDFAnnotateToolOptions(@"eraser")[@"eraser"] isEqual:@"pixels"] ? @"lines" : @"pixels"};
            break;
        case 'b': {
            NSMutableArray* brushes = [NSMutableArray array];
            for (SPDFAnnotateEntry* entry in SPDFAnnotateBrushes()) [brushes addObject:entry.name];
            next = SPDFAnnotateBrushIndex(tool) > 0 ? SPDFAnnotateNext(brushes, tool) : SPDFAnnotateBrushName(MAX(1, session.brush));
            break;
        }
        case 'u': {
            next = @"shape";
            NSString* shape = [tool isEqual:@"shape"] ? SPDFAnnotateNext(@[ @"rectangle", @"oval", @"line", @"arrow_line" ], session.shape)
                                                      : session.shape ?: SPDFAnnotateToolOptions(@"shape")[@"shape"];
            options = @{@"shape" : shape};
            break;
        }
        case 'l': next = @"shape"; options = @{@"shape" : @"line"}; break;
        case 'x': SPDFAnnotatePerform(controller, SPDFAnnotateCommandSwapColors); return YES;
        case 'd': SPDFAnnotatePerform(controller, SPDFAnnotateCommandDefaultColors); return YES;
        case '[': SPDFAnnotateStepSize(controller, tool, -1); return YES;
        case ']': SPDFAnnotateStepSize(controller, tool, 1); return YES;
        default: return NO;
    }
    SPDFAnnotateChooseTool(controller, next, options);
    return YES;
}

// Type-to-search asks here first (SPDFMacFindInteraction.mm): while Annotate shows, its letters reach the overlay (a
// PDF) or the canvas even when the page itself has the keyboard, after a click on the page or on a radio button.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation ShenzhenMacDelegate (SPDFAnnotateTypedKeys)
- (BOOL)annotateTakeTypedKey:(NSEvent*)event {
    SPDFMacFillController* controller = [self existingFillController];
    if (![controller isShowing]) return NO;
    SPDFMacAnnotateCanvasView* canvas = controller.annotateCanvasView;
    BOOL onCanvas = canvas.session && !canvas.hidden && SPDFAnnotateCurrentKind(controller) != SPDFAnnotateDocumentPDF;
    NSView* target = onCanvas ? (NSView*)canvas : (NSView*)controller.overlay;
    if (!target.window || target.hiddenOrHasHiddenAncestor || ![(id)target handlesTypedKey:event]) return NO;
    [target.window makeFirstResponder:target];
    [target keyDown:event];
    return YES;
}
@end
#pragma clang diagnostic pop
