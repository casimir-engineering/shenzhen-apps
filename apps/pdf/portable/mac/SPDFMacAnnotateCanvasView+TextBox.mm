// The canvas view's text box (SPDFMacAnnotateCanvasView.h): a box dragged (or clicked) with the Text box tool, typed
// in place with the text bar's font, size and styles, and sent as one text.add when it closes; a text object
// double-clicked with Select is typed in again and sent as one object.update.
#import "SPDFMacAnnotateCanvasViewPrivate.h"

#import "SPDFMacAnnotateImageIO.h"
#import "SPDFMacAnnotateIntegration.h"
#import "SPDFMacAnnotateSessionPrivate.h"
#import "SPDFMacFillController.h"
#import "SPDFMacFillOverlayView.h"

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
    NSFont* font = [options[@"font"] isKindOfClass:NSString.class] ? [NSFont fontWithName:options[@"font"] size:size] : nil;
    font = font ?: [NSFont systemFontOfSize:size];
    NSFontTraitMask traits = ([options[@"bold"] boolValue] ? NSBoldFontMask : 0) |
                             ([options[@"italic"] boolValue] ? NSItalicFontMask : 0);
    if (traits) font = [NSFontManager.sharedFontManager convertFont:font toHaveTrait:traits];
    editor.font = font;
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

@end
#pragma clang diagnostic pop
