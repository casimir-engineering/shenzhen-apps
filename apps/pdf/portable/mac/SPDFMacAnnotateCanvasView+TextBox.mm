// The canvas view's text box (SPDFMacAnnotateCanvasView.h): a box dragged (or clicked) with the Text box tool, typed
// in place with the text bar's font, size and styles, and sent as one text.add when it closes; a text object
// double-clicked with Select is typed in again and sent as one object.update.
#import "SPDFMacAnnotateCanvasViewPrivate.h"

#import "SPDFMacAnnotateImageIO.h"
#import "SPDFMacAnnotateIntegration.h"
#import "SPDFMacAnnotatePaletteSupport.h"
#import "SPDFMacFillController+Annotate.h"
#import "SPDFMacAnnotateSessionPrivate.h"
#import "SPDFMacFillController.h"
#import "SPDFMacFillOverlayView.h"
#import "SPDFMacFillPalette.h"
#import "SPDFMacAnnotatePaletteGroups.h"

// The font the text bar shows (SPDFMacAnnotateToolOptions.mm): the one picked, else Helvetica Neue.
static NSString* SPDFAnnotateTextBoxFont(NSDictionary* options) {
    NSString* font = [options[@"font"] isKindOfClass:NSString.class] ? options[@"font"] : nil;
    return font.length ? font : @"Helvetica Neue";
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation SPDFMacAnnotateCanvasView (TextBox)

#pragma mark - The text box

- (void)openTextEditorAt:(NSRect)rect page:(NSInteger)page object:(NSNumber*)object text:(NSString*)text {
    [self commitTextEditor];
    NSDictionary* options = [SPDFAnnotateSettings.shared optionsForTool:@"text_box"];
    CGFloat size = [options[@"size"] doubleValue] ?: 24;
    if (NSWidth(rect) < 4 || NSHeight(rect) < 4) rect.size = NSMakeSize(MAX(NSWidth(rect), size * 8), size * 1.6);
    self.textRect = rect;
    self.textPage = page;
    self.textObject = object;
    NSTextView* editor = [[NSTextView alloc] initWithFrame:NSZeroRect];
    editor.drawsBackground = NO;
    editor.richText = NO;
    editor.allowsUndo = YES;
    editor.textContainerInset = NSZeroSize;
    editor.textContainer.lineFragmentPadding = 0;
    editor.string = text ?: @"";
    editor.textColor = SPDFAnnotateColor(self.session.color1);
    editor.insertionPointColor = editor.textColor;
    editor.delegate = (id<NSTextViewDelegate>)self;
    self.textEditor = editor;
    [self addSubview:editor];
    [self layoutTextEditor];
    [self.window makeFirstResponder:editor];
    SPDFAnnotateInstallFontResolver();
}

- (void)layoutTextEditor {
    NSTextView* editor = self.textEditor;
    if (!editor) return;
    NSDictionary* options = [SPDFAnnotateSettings.shared optionsForTool:@"text_box"];
    CGFloat scale = [self scaleForPage:self.textPage];
    CGFloat size = ([options[@"size"] doubleValue] ?: 24) * scale;
    NSFont* font = [NSFont fontWithName:SPDFAnnotateTextBoxFont(options) size:size];
    font = font ?: [NSFont systemFontOfSize:size];
    NSFontTraitMask traits = ([options[@"bold"] boolValue] ? NSBoldFontMask : 0) |
                             ([options[@"italic"] boolValue] ? NSItalicFontMask : 0);
    if (traits) font = [NSFontManager.sharedFontManager convertFont:font toHaveTrait:traits];
    editor.font = font;
    // As it will be drawn: Color 1 (seen even while it is transparent) and the underline and strikethrough.
    NSColor* ink = [SPDFAnnotateColor(self.session.color1) colorWithAlphaComponent:1];
    editor.textColor = ink;
    NSMutableDictionary* typing = [editor.typingAttributes mutableCopy];
    typing[NSForegroundColorAttributeName] = ink;
    typing[NSUnderlineStyleAttributeName] = @([options[@"underline"] boolValue] ? NSUnderlineStyleSingle : 0);
    typing[NSStrikethroughStyleAttributeName] = @([options[@"strikethrough"] boolValue] ? NSUnderlineStyleSingle : 0);
    editor.typingAttributes = typing;
    if (editor.string.length)
        [editor.textStorage addAttributes:@{NSForegroundColorAttributeName: ink,
                                            NSUnderlineStyleAttributeName: typing[NSUnderlineStyleAttributeName],
                                            NSStrikethroughStyleAttributeName: typing[NSStrikethroughStyleAttributeName]}
                                    range:NSMakeRange(0, editor.string.length)];
    editor.frame = [self viewRectForCanvasRect:self.textRect page:self.textPage];
    editor.wantsLayer = YES;
    editor.layer.borderWidth = 1;
    editor.layer.borderColor = NSColor.controlAccentColor.CGColor;
}

- (BOOL)textView:(NSTextView*)textView doCommandBySelector:(SEL)selector {
    (void)textView;
    if (selector == @selector(cancelOperation:)) {
        [self commitTextEditor];
        return YES;
    }
    return NO;
}

- (void)editTextObject:(NSDictionary*)object page:(NSInteger)page {
    NSDictionary* state = object[@"object"];
    NSString* text = [state[@"text"] isKindOfClass:NSString.class] ? state[@"text"] : @"";
    [self openTextEditorAt:[object[@"rect"] rectValue] page:page object:object[@"id"] text:text];
}

// Text typing is one text.add, or one object.update for a box edited again, when the box closes (§ 6).
- (void)commitTextEditor {
    NSTextView* editor = self.textEditor;
    if (!editor) return;
    self.textEditor = nil;
    NSString* text = [editor.string copy];
    [editor removeFromSuperview];
    [self.window makeFirstResponder:self];
    NSNumber* object = self.textObject;
    self.textObject = nil;
    if (!object && !text.length) return;
    NSDictionary* options = [SPDFAnnotateSettings.shared optionsForTool:@"text_box"];
    NSMutableDictionary* op = [NSMutableDictionary dictionary];
    for (NSString* key in @[@"font", @"size", @"bold", @"italic", @"underline", @"strikethrough", @"align",
                            @"background"])
        if (options[key]) op[key] = options[key];
    op[@"font"] = SPDFAnnotateTextBoxFont(options);  // the text bar's font, also before one is picked
    op[@"text"] = text;
    if (object) {
        op[@"op"] = @"object.update";
        op[@"id"] = object;
    } else {
        op[@"op"] = @"text.add";
        op[@"rect"] = SPDFAnnotateRectObject(self.textRect);
        op[@"color"] = [self colorFor:NO];
    }
    __weak SPDFMacAnnotateCanvasView* weakSelf = self;
    [self operation:op page:self.textPage done:^(NSDictionary* result) {
        if ([result[@"ok"] boolValue] && result[@"id"]) weakSelf.session.selectedObjects = @[result[@"id"]];
    }];
}

// The context menu's Edit Text (SPDFAnnotateEditTextNotification): the selected text object is typed in again.
- (void)editTextRequested:(NSNotification*)note {
    if (note.object != self.controller || !self.session) return;
    NSInteger page = self.session.kind == SPDFAnnotateDocumentPDF ? self.session.currentPage : -1;
    NSNumber* selected = self.session.selectedObjects.firstObject;
    for (NSDictionary* object in [self objectsOnPage:page])
        if ([object[@"id"] isEqual:selected] && [object[@"kind"] isEqual:@"text"]) {
            [self editTextObject:object page:page];
            return;
        }
}

// Cmd-B, Cmd-I and Cmd-U while typing in a text box are the text bar's Bold, Italic and Underline (the menu bar's
// Cmd-B and Cmd-I keep the app's meaning everywhere else).
- (BOOL)performKeyEquivalent:(NSEvent*)event {
    NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask &
                                ~(NSEventModifierFlagCapsLock | NSEventModifierFlagNumericPad | NSEventModifierFlagFunction);
    NSString* style = @{@"b": @"bold", @"i": @"italic", @"u": @"underline"}[event.charactersIgnoringModifiers.lowercaseString];
    if (self.textEditor && self.window.firstResponder == self.textEditor && mods == NSEventModifierFlagCommand && style) {
        BOOL on = ![[SPDFAnnotateSettings.shared optionsForTool:@"text_box"][style] boolValue];
        [self.controller applyOperation:@{@"op": @"tool.choose", @"tool": @"text_box", @"options": @{style: @(on)}}
                                    tab:nil completion:nil];
        [self.controller.palette.annotateGroups row2ForSession:self.session];  // the text bar shows B, I, U as set
        [self layoutTextEditor];
        return YES;
    }
    return [super performKeyEquivalent:event];
}

@end
#pragma clang diagnostic pop
