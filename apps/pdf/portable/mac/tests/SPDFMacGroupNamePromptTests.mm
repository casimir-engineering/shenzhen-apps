#import "SPDFMacTabGroupNamePrompt.h"
static void Check(BOOL value, NSString* reason) { if (!value) { NSLog(@"FAIL %@",reason); exit(1); } }
int main(void) { @autoreleasepool {
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    for (NSNumber* creating in @[@YES,@NO]) {
        __block NSString* accepted=nil;
        NSViewController* content=SPDFGroupNamePromptContent(@"Purple",creating.boolValue,^(NSString* name) { accepted=name; });
        NSTextField* field=nil; NSButton* confirm=nil; NSUInteger buttons=0;
        for (NSView* child in content.view.subviews) {
            if ([child isKindOfClass:NSButton.class]) {
                ++buttons; Check(![((NSButton*)child).title isEqual:@"Keep Default"],@"no redundant Keep Default action");
            }
            if ([child.identifier isEqual:@"GroupNameField"]) field=(id)child;
            if ([child isKindOfClass:NSButton.class] && [((NSButton*)child).keyEquivalent isEqual:@"\r"]) confirm=(id)child;
        }
        Check(buttons==(creating.boolValue ? 1 : 2),@"creation has only Done; rename retains Cancel");
        Check([field.stringValue isEqual:@"Purple"],@"suggested name is editable text");
        NSWindow* window=[[NSWindow alloc] initWithContentRect:content.view.bounds styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        window.contentView=content.view; [window makeFirstResponder:field]; [field selectText:nil];
        NSTextView* editor=(id)window.firstResponder;
        Check([editor isKindOfClass:NSTextView.class] && NSEqualRanges(editor.selectedRange,NSMakeRange(0,6)),@"whole name selected for replacement");
        Check([field.delegate control:field textView:editor doCommandBySelector:@selector(insertNewline:)],
              @"Return in the name field is handled immediately");
        Check([accepted isEqual:@"Purple"],@"Return action accepts default");
        accepted=nil; field.stringValue=@"Discarded edit";
        Check([field.delegate control:field textView:editor doCommandBySelector:@selector(cancelOperation:)] && !accepted,
              @"Escape leaves the existing default/name unchanged without needing a button");
        field.stringValue=@"References"; [confirm performClick:nil]; Check([accepted isEqual:@"References"],@"edited name accepted");
        Check(!window.visible,@"prompt verification stays offscreen");
    }
    puts("SPDFMacGroupNamePromptTests passed");
} }
