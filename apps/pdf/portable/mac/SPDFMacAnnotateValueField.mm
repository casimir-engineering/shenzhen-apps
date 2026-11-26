// A slider's value that edits in place (SPDFMacAnnotateValueField.h).
#import "SPDFMacAnnotateValueField.h"

#import "SPDFMacCollectionStyle.h"

@interface SPDFAnnotateValueField () <NSTextFieldDelegate>
@property(nonatomic) BOOL cancelled;   // Escape: the end of editing leaves the value as it was
@property(nonatomic) double original;  // what Escape goes back to
@property(nonatomic, readwrite) BOOL editing;
@property(nonatomic) NSTimeInterval startedBy;  // the press that started the editing (its timestamp), if one did
@end

@implementation SPDFAnnotateValueField

+ (instancetype)valueFieldWithFontSize:(CGFloat)size tip:(NSString*)tip {
    SPDFAnnotateValueField* field = [self labelWithString:@""];
    field.font = [NSFont systemFontOfSize:size];
    field.textColor = SPDFCollectionColor(@"text");
    field.editable = YES;  // looks like a label until clicked
    field.bezeled = NO;
    field.drawsBackground = NO;
    field.focusRingType = NSFocusRingTypeNone;
    field.delegate = field;
    field.toolTip = tip;
    return field;
}

static NSString* SPDFNumberPart(NSString* shown) {
    return [shown componentsSeparatedByString:@" "].firstObject ?: @"";
}

- (BOOL)acceptsFirstMouse:(NSEvent*)event { (void)event; return YES; }

- (BOOL)becomeFirstResponder {
    if (![super becomeFirstResponder]) return NO;
    self.cancelled = NO;
    self.editing = YES;
    NSEvent* event = NSApp.currentEvent;
    self.startedBy = event.type == NSEventTypeLeftMouseDown ? event.timestamp : -1;
    NSText* editor = self.currentEditor;
    editor.string = SPDFNumberPart(self.stringValue);
    self.original = editor.string.doubleValue;
    [editor selectAll:nil];
    return YES;
}

// The click that starts editing leaves the number selected (the field editor would put a caret where it landed);
// later clicks go to the field editor as usual.
- (void)mouseDown:(NSEvent*)event {
    if (self.editing && event.timestamp == self.startedBy) return;  // the press that just started it (in a table)
    if (self.currentEditor || ![self.window makeFirstResponder:self]) [super mouseDown:event];
}

- (BOOL)control:(NSControl*)control textView:(NSTextView*)textView doCommandBySelector:(SEL)command {
    (void)control;
    double step = command == @selector(moveUp:) ? 1 : command == @selector(moveDown:) ? -1
                : command == @selector(moveUpAndModifySelection:) ? 10
                : command == @selector(moveDownAndModifySelection:) ? -10 : 0;
    if (step) {  // shown at once; used when the editing ends (using it ends the editing)
        double shown = self.stepped ? self.stepped(textView.string.doubleValue + step) : textView.string.doubleValue + step;
        textView.string = [NSString stringWithFormat:shown < 10 && fmod(shown, 1) ? @"%.1f" : @"%.0f", shown];
        [textView selectAll:nil];
        return YES;
    }
    if (command == @selector(cancelOperation:)) self.cancelled = YES;
    if (command != @selector(cancelOperation:) && command != @selector(insertNewline:)) return NO;
    NSView* keys = self.keysView ? self.keysView() : nil;
    [self.window makeFirstResponder:keys.window == self.window ? keys : nil];
    return YES;
}

- (void)controlTextDidEndEditing:(NSNotification*)note {
    (void)note;
    NSScanner* scanner = [NSScanner scannerWithString:self.stringValue];
    double typed = 0;
    BOOL ok = !self.cancelled && [scanner scanDouble:&typed];
    self.cancelled = NO;
    self.editing = NO;
    if (self.ended) self.ended(ok ? typed : self.original, ok);  // after the editor is gone: the field shows its unit again
}

@end
