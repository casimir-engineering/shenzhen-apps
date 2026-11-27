// Annotate's command items and the menus built from them (SPDFMacAnnotatePaletteSupport.h, "Command items"): one
// target carries out an item's payload (operations through applyOperation:, or a frontend command that opens a sheet,
// a panel or a file dialog first) and validates it, so the palette, the menu bar and the context menus agree.
#import "SPDFMacAnnotatePaletteSupport.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>

#import "SPDFMacAnnotateColors.h"
#import "SPDFMacAnnotateIntegration.h"
#import "SPDFMacAnnotateLayersPanel.h"
#import "SPDFMacFillController+Annotate.h"

NSString* const SPDFAnnotateCommandResizeSheet = @"sheet.resize";
NSString* const SPDFAnnotateCommandCanvasSheet = @"sheet.canvas";
NSString* const SPDFAnnotateCommandRotateBySheet = @"sheet.rotate_by";
NSString* const SPDFAnnotateCommandEditColors = @"colors.edit";
NSString* const SPDFAnnotateCommandSaveColors = @"colors.save_file";
NSString* const SPDFAnnotateCommandGetColors = @"colors.get_file";
NSString* const SPDFAnnotateCommandSwapColors = @"colors.swap";
NSString* const SPDFAnnotateCommandDefaultColors = @"colors.default";
NSString* const SPDFAnnotateCommandCut = @"selection.cut";
NSString* const SPDFAnnotateCommandCopyToFile = @"selection.copy_to_file";
NSString* const SPDFAnnotateCommandPasteFromFile = @"selection.paste_from_file";
NSString* const SPDFAnnotateCommandTransparent = @"selection.transparent_toggle";
NSString* const SPDFAnnotateCommandRepeat = @"edit.repeat";
NSString* const SPDFAnnotateCommandLayers = @"view.layers";
NSString* const SPDFAnnotateCommandEditText = @"object.edit_text";
NSString* const SPDFAnnotateCommandNewCanvas = @"file.new_canvas";
NSString* const SPDFAnnotateCommandSave = @"file.save";
NSString* const SPDFAnnotateCommandSaveAs = @"file.save_as";
NSString* const SPDFAnnotateCommandDesktopPicture = @"file.desktop_picture";
NSNotificationName const SPDFAnnotateEditTextNotification = @"SPDFAnnotateEditTextNotification";

@interface ShenzhenMacDelegate (SPDFAnnotateCommandsReader)
- (SPDFMacFillController*)fillController;
- (SPDFMacFillController*)existingFillController;
- (void)saveDocumentAs:(id)sender;
@end

static char kSPDFAnnotateTargetKey;

@interface SPDFAnnotateCommandTarget : NSObject <NSMenuItemValidation>
@property(nonatomic, weak) SPDFMacFillController* controller;
@property(nonatomic, weak) ShenzhenMacDelegate* reader;
@end

#pragma mark - Doing

static ShenzhenMacDelegate* SPDFAnnotateReaderFor(SPDFMacFillController* controller) {
    id host = controller.host;
    return [host isKindOfClass:[ShenzhenMacDelegate class]] ? host : nil;
}

static void SPDFAnnotateRunCommand(SPDFMacFillController* c, NSString* command);

static void SPDFAnnotateSendAll(SPDFMacFillController* controller, NSArray* ops, NSUInteger index) {
    if (index >= ops.count) return;
    if ([ops[index] isKindOfClass:[NSString class]]) {  // a command in a list runs once the operations before it did
        SPDFAnnotateRunCommand(controller, ops[index]);
        SPDFAnnotateSendAll(controller, ops, index + 1);
        return;
    }
    __weak SPDFMacFillController* weak = controller;
    SPDFAnnotateSend(controller, SPDFAnnotateOnCurrentPage(controller, ops[index]), ^(NSDictionary* result) {
      if ([result[@"ok"] boolValue]) SPDFAnnotateSendAll(weak, ops, index + 1);  // stops at the first error
    });
}

static void SPDFAnnotateFileCommand(ShenzhenMacDelegate* reader, NSString* command) {
    BOOL picture = [reader annotateActiveSession] && ([reader annotateActiveDocumentKind] == SPDFAnnotateDocumentPicture ||
                                                     [reader annotateActiveDocumentKind] == SPDFAnnotateDocumentCanvas);
    if ([command isEqual:SPDFAnnotateCommandNewCanvas]) [reader newCanvas:nil];
    else if ([command isEqual:SPDFAnnotateCommandDesktopPicture]) [reader setDesktopPicture:nil];
    // Cmd-S writes a picture Annotate changed; everywhere else it keeps the app's meaning, Save As...
    else if ([command isEqual:SPDFAnnotateCommandSave]) picture ? [reader annotateSaveDocument:nil] : [reader saveDocumentAs:nil];
    else if ([command isEqual:SPDFAnnotateCommandSaveAs]) picture ? [reader annotateSaveDocumentAs:nil] : [reader saveDocumentAs:nil];
}

static void SPDFAnnotateRunCommand(SPDFMacFillController* c, NSString* command) {
    NSWindow* window = [c.host fillWindow];
    SPDFMacAnnotateSession* session = SPDFAnnotateCurrentSession(c, YES);
    if ([command isEqual:SPDFAnnotateCommandResizeSheet]) SPDFAnnotateShowResizeSheet(window, c);
    else if ([command isEqual:SPDFAnnotateCommandCanvasSheet]) SPDFAnnotateShowCanvasPropertiesSheet(window, c);
    else if ([command isEqual:SPDFAnnotateCommandRotateBySheet]) SPDFAnnotateShowRotateBySheet(window, c);
    else if ([command isEqual:SPDFAnnotateCommandEditColors]) SPDFAnnotateOpenColorPanel(c);
    else if ([command isEqual:SPDFAnnotateCommandSaveColors]) SPDFAnnotateSaveColorsFile(c);
    else if ([command isEqual:SPDFAnnotateCommandGetColors]) SPDFAnnotateGetColorsFile(c);
    else if ([command isEqual:SPDFAnnotateCommandLayers]) SPDFAnnotateToggleLayersPanel(c);
    else if ([command isEqual:SPDFAnnotateCommandSwapColors] && session)
        SPDFAnnotateSend(c, @{@"op" : @"colors.set", @"color1" : SPDFAnnotateHex(session.color2),
                              @"color2" : SPDFAnnotateHex(session.color1)}, nil);
    else if ([command isEqual:SPDFAnnotateCommandDefaultColors])
        SPDFAnnotateSend(c, @{@"op" : @"colors.set", @"color1" : @"#000000", @"color2" : @"#FFFFFF"}, nil);
    else if ([command isEqual:SPDFAnnotateCommandCut])
        SPDFAnnotateSendAll(c, @[ @{@"op" : @"doc.copy", @"scope" : @"auto"}, @{@"op" : @"select.delete"} ], 0);
    else if ([command isEqual:SPDFAnnotateCommandTransparent]) {
        BOOL on = ![SPDFAnnotateToolOptions(@"rect_select")[@"transparent"] boolValue];
        [[SPDFAnnotateSettings shared] setOptions:@{@"transparent" : @(on)} forTool:@"rect_select"];
        [[SPDFAnnotateSettings shared] setOptions:@{@"transparent" : @(on)} forTool:@"freeform_select"];
        SPDFAnnotateSend(c, SPDFAnnotateOnCurrentPage(c, @{@"op" : @"select.transparent", @"on" : @(on)}), nil);
    } else if ([command isEqual:SPDFAnnotateCommandRepeat]) {
        NSDictionary* op = session.repeatableOperation;
        if (op) SPDFAnnotateSend(c, op, nil);
    } else if ([command isEqual:SPDFAnnotateCommandEditText]) {
        SPDFAnnotateChooseTool(c, @"text_box", nil);
        [NSNotificationCenter.defaultCenter postNotificationName:SPDFAnnotateEditTextNotification object:c userInfo:nil];
    } else if ([command isEqual:SPDFAnnotateCommandCopyToFile]) {
        NSSavePanel* panel = [NSSavePanel savePanel];
        panel.allowedContentTypes = @[ UTTypePNG ];
        panel.nameFieldStringValue = @"Selection.png";
        [panel beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
          if (response != NSModalResponseOK) return;
          // The selection's own pixels (or the selected object), as Copy puts them on the clipboard.
          SPDFAnnotateSend(c, SPDFAnnotateOnCurrentPage(c, @{@"op" : @"doc.copy", @"scope" : @"auto", @"out" : panel.URL.path}), nil);
        }];
    } else if ([command isEqual:SPDFAnnotateCommandPasteFromFile]) {
        NSOpenPanel* panel = [NSOpenPanel openPanel];
        panel.allowedContentTypes = @[ UTTypeImage ];
        [panel beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
          if (response != NSModalResponseOK) return;
          SPDFAnnotatePerform(c, @[ @{@"op" : @"picture.add", @"path" : panel.URL.path}, @{@"op" : @"tool.choose", @"tool" : @"select"} ]);
        }];
    } else {
        SPDFAnnotateFileCommand(SPDFAnnotateReaderFor(c), command);
    }
}

NSString* const SPDFAnnotateSelectedIds = @"$selected";

// An operation naming "$selected" for its id or ids acts on the selected objects (menu bar items and keys).
// View > Status Bar, Rulers, Gridlines, Thumbnail: what each shows now (SPDFAnnotateSettings).
static BOOL SPDFAnnotateViewFlag(NSString* key) {
    SPDFAnnotateSettings* settings = [SPDFAnnotateSettings shared];
    if ([key isEqual:@"statusbar"]) return settings.showsStatusBar;
    if ([key isEqual:@"rulers"]) return settings.showsRulers;
    if ([key isEqual:@"gridlines"]) return settings.showsGridlines;
    return [[settings optionsForTool:@"view"][key] boolValue];
}

static NSString* SPDFAnnotateToggledKey(NSDictionary* op) {
    for (NSString* key in op)
        if ([op[key] isEqual:@"toggle"]) return key;
    return nil;
}

static NSArray* SPDFAnnotateResolveSelected(SPDFMacFillController* controller, NSDictionary* op) {
    NSString* toggled = SPDFAnnotateToggledKey(op);
    if (toggled) {  // view.set {rulers: "toggle"}: the opposite of what shows
        NSMutableDictionary* resolved = [op mutableCopy];
        resolved[toggled] = @(!SPDFAnnotateViewFlag(toggled));
        return @[ resolved ];
    }
    BOOL one = [op[@"id"] isEqual:SPDFAnnotateSelectedIds], many = [op[@"ids"] isEqual:SPDFAnnotateSelectedIds];
    if (!one && !many) return @[ op ];
    NSArray* ids = SPDFAnnotateSelectedObjectIds(SPDFAnnotateDocState(controller));
    if (!ids.count) return @[];
    NSMutableArray* ops = [NSMutableArray array];
    for (NSNumber* objectId in many ? @[ ids ] : ids) {  // "id": one operation per selected object
        NSMutableDictionary* resolved = [op mutableCopy];
        resolved[many ? @"ids" : @"id"] = objectId;
        [ops addObject:resolved];
    }
    return ops;
}

void SPDFAnnotatePerform(SPDFMacFillController* controller, id payload) {
    if (!controller) return;
    if ([payload isKindOfClass:[NSDictionary class]]) SPDFAnnotateSendAll(controller, SPDFAnnotateResolveSelected(controller, payload), 0);
    else if ([payload isKindOfClass:[NSArray class]]) SPDFAnnotateSendAll(controller, payload, 0);
    else if ([payload isKindOfClass:[NSString class]]) SPDFAnnotateRunCommand(controller, payload);
}

#pragma mark - Validating

static NSDictionary* SPDFAnnotateCachedState(SPDFMacFillController* controller) {
    // Menus validate every item at once: one doc.state answers them all.
    static __weak SPDFMacFillController* cachedFor;
    static NSDictionary* cached;
    static CFAbsoluteTime when;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (cachedFor != controller || now - when > 0.25) {
        cached = SPDFAnnotateDocState(controller);
        cachedFor = controller;
        when = now;
    }
    return cached;
}

static BOOL SPDFAnnotateNeedsSelection(NSString* name, NSDictionary* op) {
    if ([name isEqual:@"select.delete"] || [name isEqual:@"select.lift"] || [name isEqual:@"select.invert"]) return YES;
    if ([name isEqual:@"image.crop"]) return !op[@"rect"];
    return [name isEqual:@"doc.copy"];
}

BOOL SPDFAnnotatePayloadEnabled(SPDFMacFillController* controller, id payload, NSString** tooltip) {
    if (tooltip) *tooltip = nil;
    if (!controller || ![controller isShowing]) return NO;
    SPDFAnnotateDocumentKind kind = SPDFAnnotateCurrentKind(controller);
    if (kind == SPDFAnnotateDocumentNone || kind == SPDFAnnotateDocumentText) return NO;
    if ([payload isKindOfClass:[NSArray class]]) payload = [payload firstObject];
    if ([payload isKindOfClass:[NSString class]]) {
        SPDFMacAnnotateSession* session = SPDFAnnotateCurrentSession(controller, NO);
        if ([payload isEqual:SPDFAnnotateCommandCanvasSheet] && kind == SPDFAnnotateDocumentPDF) {
            if (tooltip) *tooltip = SPDFAnnotatePageLockedText;
            return NO;
        }
        if ([payload isEqual:SPDFAnnotateCommandRepeat]) return session.repeatableOperation != nil;
        if ([payload isEqual:SPDFAnnotateCommandCut] || [payload isEqual:SPDFAnnotateCommandCopyToFile])
            return SPDFAnnotatePayloadEnabled(controller, @{@"op" : @"doc.copy"}, NULL);
        return YES;
    }
    if (![payload isKindOfClass:[NSDictionary class]]) return NO;
    NSString* name = payload[@"op"];
    const spdf_paint_op_info* info = spdf_paint_op_find(name.UTF8String ?: "");
    if (!info) return NO;
    if (!(info->kinds & (unsigned)kind)) {
        if (tooltip && kind == SPDFAnnotateDocumentPDF) *tooltip = SPDFAnnotatePageLockedText;
        return NO;
    }
    if ([name isEqual:@"history.undo"] || [name isEqual:@"history.redo"]) {
        SPDFMacAnnotateSession* session = SPDFAnnotateCurrentSession(controller, NO);
        BOOL undo = [name isEqual:@"history.undo"];
        return undo ? (session.canUndo || [controller canUndo]) : (session.canRedo || [controller canRedo]);
    }
    if (SPDFAnnotateNeedsSelection(name, payload) || [payload[@"id"] isEqual:SPDFAnnotateSelectedIds] ||
        [payload[@"ids"] isEqual:SPDFAnnotateSelectedIds]) {
        BOOL objects = [payload[@"id"] isEqual:SPDFAnnotateSelectedIds] || [payload[@"ids"] isEqual:SPDFAnnotateSelectedIds];
        NSDictionary* state = SPDFAnnotateCachedState(controller);
        // Without an answer (Annotate still opening) the command stays available and answers nothing_selected.
        if (state && (objects || !SPDFAnnotateStateHasPixelSelection(state)) && !SPDFAnnotateSelectedObjectIds(state).count)
            return NO;
    }
    if ([name isEqual:@"object.layer"] && payload[@"to"]) {  // Move to Layer Above / Below: not past the ends
        NSDictionary* state = SPDFAnnotateCachedState(controller);
        id ids = [payload[@"ids"] isEqual:SPDFAnnotateSelectedIds] ? SPDFAnnotateSelectedObjectIds(state) : payload[@"ids"];
        NSNumber* first = [ids isKindOfClass:[NSArray class]] ? [ids firstObject] : payload[@"id"];
        if (state && !SPDFAnnotateLayerNeighbour(state, first, [payload[@"to"] isEqual:@"above"])) return NO;
    }
    return YES;
}

static BOOL SPDFAnnotatePayloadChosen(SPDFMacFillController* controller, NSDictionary* op) {
    if (![op isKindOfClass:[NSDictionary class]] || ![op[@"op"] isEqual:@"tool.choose"]) return NO;
    for (NSString* part in @[ @"outline", @"fill" ])  // a style item: the Shapes tool's remembered style
        if (op[@"options"][part]) return [op[@"options"][part][@"style"] isEqual:SPDFAnnotateToolOptions(@"shape")[part][@"style"]];
    SPDFMacAnnotateSession* session = SPDFAnnotateCurrentSession(controller, NO);
    NSString* chosen = SPDFAnnotateChosenToolName(session);
    if (![op[@"tool"] isEqual:chosen]) return NO;
    NSString* shape = op[@"options"][@"shape"];
    return !shape || [shape isEqual:session.shape];
}

@implementation SPDFAnnotateCommandTarget

- (SPDFMacFillController*)controllerCreating:(BOOL)create {
    if (self.controller) return self.controller;
    return create ? [self.reader fillController] : [self.reader existingFillController];
}

- (void)perform:(NSMenuItem*)item {
    id payload = item.representedObject;
    if ([payload isKindOfClass:[NSString class]] && [payload hasPrefix:@"file."]) {
        SPDFAnnotateFileCommand(self.reader ?: SPDFAnnotateReaderFor(self.controller), payload);
        return;
    }
    SPDFAnnotatePerform([self controllerCreating:YES], payload);
}

- (BOOL)validateMenuItem:(NSMenuItem*)item {
    id payload = item.representedObject;
    ShenzhenMacDelegate* reader = self.reader ?: SPDFAnnotateReaderFor(self.controller);
    if ([payload isEqual:SPDFAnnotateCommandNewCanvas]) return YES;
    if ([payload isEqual:SPDFAnnotateCommandSave] || [payload isEqual:SPDFAnnotateCommandSaveAs]) {
        // A picture or canvas Annotate opened is always saved by Annotate (a WebP or RAW as a PNG copy).
        SPDFAnnotateDocumentKind kind = [reader annotateActiveDocumentKind];
        if ([reader annotateActiveSession].loaded && (kind == SPDFAnnotateDocumentPicture || kind == SPDFAnnotateDocumentCanvas))
            return YES;
        return [reader validateMenuItem:[[NSMenuItem alloc] initWithTitle:@"" action:@selector(saveDocumentAs:)
                                                             keyEquivalent:@""]];
    }
    // While a sheet is up (Resize and skew, Canvas size, a Save panel), the canvas commands wait for it to close.
    if ([[(self.controller ?: [reader existingFillController]).host fillWindow] attachedSheet]) return NO;
    if ([payload isEqual:SPDFAnnotateCommandDesktopPicture])
        return [reader annotateActiveDocumentKind] == SPDFAnnotateDocumentPicture ||
               [reader annotateActiveDocumentKind] == SPDFAnnotateDocumentCanvas;
    SPDFMacFillController* controller = [self controllerCreating:NO];
    if ([payload isEqual:SPDFAnnotateCommandLayers]) {
        item.state = SPDFAnnotateLayersPanelShown(controller) ? NSControlStateValueOn : NSControlStateValueOff;
        return [controller isShowing];
    }
    if ([payload isEqual:SPDFAnnotateCommandTransparent])
        item.state = [SPDFAnnotateToolOptions(@"rect_select")[@"transparent"] boolValue] ? NSControlStateValueOn
                                                                                           : NSControlStateValueOff;
    else if ([payload isKindOfClass:[NSDictionary class]] && SPDFAnnotateToggledKey(payload))
        item.state = SPDFAnnotateViewFlag(SPDFAnnotateToggledKey(payload)) ? NSControlStateValueOn : NSControlStateValueOff;
    else if ([payload isKindOfClass:[NSDictionary class]] && [payload[@"op"] isEqual:@"tool.choose"])
        item.state = SPDFAnnotatePayloadChosen(controller, payload) ? NSControlStateValueOn : NSControlStateValueOff;
    NSString* tooltip = nil;
    BOOL enabled = SPDFAnnotatePayloadEnabled(controller, payload, &tooltip);
    item.toolTip = tooltip;
    return enabled;
}

@end

static SPDFAnnotateCommandTarget* SPDFAnnotateTargetFor(SPDFMacFillController* controller, ShenzhenMacDelegate* reader) {
    id owner = controller ?: reader;
    if (!owner) return nil;
    SPDFAnnotateCommandTarget* target = objc_getAssociatedObject(owner, &kSPDFAnnotateTargetKey);
    if (!target) {
        target = [SPDFAnnotateCommandTarget new];
        target.controller = controller;
        target.reader = controller ? nil : reader;
        objc_setAssociatedObject(owner, &kSPDFAnnotateTargetKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return target;
}

NSMenuItem* SPDFAnnotateItem(NSString* title, NSString* key, NSEventModifierFlags modifiers, id payload,
                             SPDFMacFillController* controller, ShenzhenMacDelegate* reader) {
    NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title action:@selector(perform:) keyEquivalent:key ?: @""];
    if (key.length) item.keyEquivalentModifierMask = modifiers;
    item.representedObject = payload;
    item.target = SPDFAnnotateTargetFor(controller, reader);
    return item;
}

#pragma mark - Menus

static NSMenuItem* SPDFAnnotateAdd(NSMenu* menu, NSMenuItem* item) {
    [menu addItem:item];
    return item;
}
#define ITEM(title, key, mods, payload) SPDFAnnotateAdd(menu, SPDFAnnotateItem(title, key, mods, payload, controller, reader))
static const NSEventModifierFlags kCmd = NSEventModifierFlagCommand, kShift = NSEventModifierFlagShift,
                                  kOpt = NSEventModifierFlagOption;

static NSMenu* SPDFAnnotateStyleMenuFor(SPDFMacFillController* controller, ShenzhenMacDelegate* reader, BOOL outline,
                                        NSInteger objectId);

NSMenu* SPDFAnnotateSelectionMenu(SPDFMacFillController* controller, ShenzhenMacDelegate* reader) {
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Selection"];
    ITEM(@"Select", @"", 0, (@{@"op" : @"tool.choose", @"tool" : @"select"}));
    ITEM(@"Rectangular selection", @"", 0, (@{@"op" : @"tool.choose", @"tool" : @"rect_select"}));
    ITEM(@"Free-form selection", @"", 0, (@{@"op" : @"tool.choose", @"tool" : @"freeform_select"}));
    [menu addItem:[NSMenuItem separatorItem]];
    ITEM(@"Select all", @"a", kCmd, @{@"op" : @"select.all"});
    ITEM(@"Invert selection", @"I", kCmd | kShift | kOpt, @{@"op" : @"select.invert"});
    ITEM(@"Delete", @"\x08", 0, @{@"op" : @"select.delete"});
    ITEM(@"Transparent selection", @"", 0, SPDFAnnotateCommandTransparent);
    ITEM(@"Crop to selection", @"X", kCmd | kShift, @{@"op" : @"image.crop"});
    [menu addItem:[NSMenuItem separatorItem]];
    ITEM(@"Cut", @"x", kCmd, SPDFAnnotateCommandCut);
    ITEM(@"Copy", @"c", kCmd, (@{@"op" : @"doc.copy", @"scope" : @"auto"}));
    ITEM(@"Paste", @"v", kCmd, SPDFAnnotatePastePayload());
    ITEM(@"Paste from file…", @"V", kCmd | kShift | kOpt, SPDFAnnotateCommandPasteFromFile);
    ITEM(@"Copy to file…", @"", 0, SPDFAnnotateCommandCopyToFile);
    return menu;
}

NSMenu* SPDFAnnotateRotateMenu(SPDFMacFillController* controller, ShenzhenMacDelegate* reader, NSString* scope) {
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Rotate"];
    ITEM(@"Rotate right 90°", @"", 0, (@{@"op" : @"image.rotate", @"degrees" : @90, @"scope" : scope}));
    ITEM(@"Rotate left 90°", @"", 0, (@{@"op" : @"image.rotate", @"degrees" : @-90, @"scope" : scope}));
    ITEM(@"Rotate 180°", @"", 0, (@{@"op" : @"image.rotate", @"degrees" : @180, @"scope" : scope}));
    ITEM(@"Rotate by…", @"", 0, SPDFAnnotateCommandRotateBySheet);
    return menu;
}

NSMenu* SPDFAnnotateFlipMenu(SPDFMacFillController* controller, ShenzhenMacDelegate* reader, NSString* scope) {
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Flip"];
    ITEM(@"Flip vertical", @"", 0, (@{@"op" : @"image.flip", @"axis" : @"vertical", @"scope" : scope}));
    ITEM(@"Flip horizontal", @"", 0, (@{@"op" : @"image.flip", @"axis" : @"horizontal", @"scope" : scope}));
    return menu;
}

BOOL SPDFAnnotateCanRemoveBackground(void) {
    return [NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){14, 0, 0}];
}

NSMenu* SPDFAnnotateImageMenu(SPDFMacFillController* controller, ShenzhenMacDelegate* reader) {
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Image"];
    ITEM(@"Crop", @"", 0, @{@"op" : @"image.crop"});
    ITEM(@"Resize and skew…", @"i", kCmd | kOpt, SPDFAnnotateCommandResizeSheet);
    [menu addItemWithTitle:@"Rotate" action:nil keyEquivalent:@""].submenu = SPDFAnnotateRotateMenu(controller, reader, @"auto");
    [menu addItemWithTitle:@"Flip" action:nil keyEquivalent:@""].submenu = SPDFAnnotateFlipMenu(controller, reader, @"auto");
    [menu addItem:[NSMenuItem separatorItem]];
    ITEM(@"Invert colors", @"i", kCmd | NSEventModifierFlagControl, (@{@"op" : @"image.invert", @"scope" : @"auto"}));
    if (SPDFAnnotateCanRemoveBackground())
        ITEM(@"Remove background", @"", 0, (@{@"op" : @"image.remove_background", @"scope" : @"auto"}));
    ITEM(@"Canvas size and properties…", @"c", kCmd | kOpt, SPDFAnnotateCommandCanvasSheet);
    ITEM(@"Clear image", @"\x08", kCmd | kShift, @{@"op" : @"image.clear"});
    return menu;
}

NSMenu* SPDFAnnotateToolsMenu(SPDFMacFillController* controller, ShenzhenMacDelegate* reader) {
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Tools"];
    for (SPDFAnnotateEntry* tool in SPDFAnnotateTools()) {
        NSString* title = tool.key.length ? [NSString stringWithFormat:@"%@ (%@)", tool.label, tool.key] : tool.label;
        NSMenuItem* item = ITEM(title, @"", 0, (@{@"op" : @"tool.choose", @"tool" : tool.name}));
        item.image = SPDFAnnotateSymbol(tool.symbol, tool.label);
    }
    return menu;
}

NSMenu* SPDFAnnotateBrushMenu(SPDFMacFillController* controller, ShenzhenMacDelegate* reader) {
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Brushes"];
    for (SPDFAnnotateEntry* brush in SPDFAnnotateBrushes()) {
        NSMenuItem* item = ITEM(brush.label, @"", 0, (@{@"op" : @"tool.choose", @"tool" : brush.name}));
        item.image = SPDFAnnotateSymbol(brush.symbol, brush.label);
    }
    return menu;
}

NSMenu* SPDFAnnotateShapeMenu(SPDFMacFillController* controller, ShenzhenMacDelegate* reader) {
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Shapes"];
    for (SPDFAnnotateEntry* shape in SPDFAnnotateShapes()) {
        NSMenuItem* item = ITEM(shape.label, @"", 0,
                                (@{@"op" : @"tool.choose", @"tool" : @"shape", @"options" : @{@"shape" : shape.name}}));
        item.image = SPDFAnnotateSymbol(shape.symbol, shape.label);
    }
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Outline" action:nil keyEquivalent:@""].submenu =
        SPDFAnnotateStyleMenuFor(controller, reader, YES, 0);
    [menu addItemWithTitle:@"Fill" action:nil keyEquivalent:@""].submenu =
        SPDFAnnotateStyleMenuFor(controller, reader, NO, 0);
    return menu;
}

NSMenu* SPDFAnnotateStyleMenu(SPDFMacFillController* controller, BOOL outline, NSInteger objectId) {
    return SPDFAnnotateStyleMenuFor(controller, nil, outline, objectId);
}

static NSMenu* SPDFAnnotateStyleMenuFor(SPDFMacFillController* controller, ShenzhenMacDelegate* reader, BOOL outline,
                                        NSInteger objectId) {
    NSString* part = outline ? @"outline" : @"fill";
    NSMenu* menu = [[NSMenu alloc] initWithTitle:outline ? @"Outline" : @"Fill"];
    NSString* current = SPDFAnnotateToolOptions(@"shape")[part][@"style"];
    for (SPDFAnnotateEntry* style in SPDFAnnotateStyles()) {
        NSString* title = [style.name isEqual:@"none"] ? (outline ? @"No outline" : @"No fill") : style.label;
        NSMutableArray* ops = [NSMutableArray array];
        if (objectId > 0) [ops addObject:@{@"op" : @"object.update", @"id" : @(objectId), part : @{@"style" : style.name}}];
        [ops addObject:@{@"op" : @"tool.choose", @"tool" : @"shape", @"options" : @{part : @{@"style" : style.name}}}];
        NSMenuItem* item = ITEM(title, @"", 0, ops.count == 1 ? ops[0] : ops);
        item.state = objectId <= 0 && [style.name isEqual:current] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    return menu;
}
