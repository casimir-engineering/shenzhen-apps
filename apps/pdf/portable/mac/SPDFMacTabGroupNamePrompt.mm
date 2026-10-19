#import "SPDFMacTabGroupNamePrompt.h"
#import <objc/runtime.h>

static char promptKey;
@interface SPDFGroupNamePromptController : NSViewController <NSPopoverDelegate, NSTextFieldDelegate>
@property NSTextField* field;
@property(copy) void (^accept)(NSString*);
@property(weak) NSPopover* popover;
@property(weak) NSView* anchor;
@end
@implementation SPDFGroupNamePromptController
- (void)confirm:(id)sender {
    (void)sender; NSString* name=self.field.stringValue;
    void (^accept)(NSString*)=self.accept;
    [self.popover close];
    if (accept) accept(name);
}
- (void)cancelOperation:(id)sender { (void)sender; [self.popover close]; }
- (BOOL)control:(NSControl*)control textView:(NSTextView*)textView doCommandBySelector:(SEL)command {
    (void)control; (void)textView;
    if (command == @selector(cancelOperation:)) { [self cancelOperation:nil]; return YES; }
    if (command == @selector(insertNewline:)) { [self confirm:nil]; return YES; }
    return NO;
}
- (void)popoverDidClose:(NSNotification*)notification {
    (void)notification; self.accept=nil;
    objc_setAssociatedObject(self.anchor,&promptKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@end

NSViewController* SPDFGroupNamePromptContent(NSString* defaultName, BOOL creating, void (^accept)(NSString*)) {
    SPDFGroupNamePromptController* controller=[SPDFGroupNamePromptController new];
    controller.accept=accept;
    NSView* view=[[NSView alloc] initWithFrame:NSMakeRect(0,0,292,112)];
    controller.view=view;
    NSTextField* title=[NSTextField labelWithString:creating ? @"Name New Group" : @"Rename Group"];
    title.font=[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    title.frame=NSMakeRect(14,82,264,18); [view addSubview:title];
    NSTextField* field=[[NSTextField alloc] initWithFrame:NSMakeRect(14,48,264,26)];
    field.stringValue=defaultName ?: @""; field.accessibilityLabel=@"Group name";
    field.identifier=@"GroupNameField"; field.bezelStyle=NSTextFieldRoundedBezel;
    field.font=[NSFont systemFontOfSize:13]; field.delegate=controller; controller.field=field; [view addSubview:field];
    if (!creating) {
        NSButton* cancel=[NSButton buttonWithTitle:@"Cancel" target:controller action:@selector(cancelOperation:)];
        cancel.frame=NSMakeRect(78,10,112,28); cancel.keyEquivalent=@"\033";
        [view addSubview:cancel];
    }
    NSButton* done=[NSButton buttonWithTitle:creating ? @"Done" : @"Rename" target:controller action:@selector(confirm:)];
    done.frame=NSMakeRect(194,10,84,28); done.keyEquivalent=@"\r";
    [view addSubview:done];
    return controller;
}

void SPDFPresentGroupNamePrompt(NSView* anchor, NSRect rect, NSString* name, BOOL creating, void (^accept)(NSString*)) {
    if (!anchor.window) return;
    [(NSPopover*)objc_getAssociatedObject(anchor,&promptKey) close];
    SPDFGroupNamePromptController* controller=(id)SPDFGroupNamePromptContent(name,creating,accept);
    NSPopover* popover=[NSPopover new]; popover.behavior=NSPopoverBehaviorTransient;
    popover.animates=NO; popover.contentViewController=controller; popover.delegate=controller;
    controller.popover=popover; controller.anchor=anchor;
    objc_setAssociatedObject(anchor,&promptKey,popover,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [popover showRelativeToRect:rect ofView:anchor preferredEdge:NSRectEdgeMinY];
    [controller.view.window makeFirstResponder:controller.field]; [controller.field selectText:nil];
}
