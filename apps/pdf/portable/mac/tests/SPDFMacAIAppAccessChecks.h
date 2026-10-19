#import "SPDFMacAIAppAccess.h"
// These windows report availability to the API but are never ordered on screen.
@interface AIAppAccessWindow : NSWindow
@property(nonatomic) BOOL fixtureAvailable;
@end
@implementation AIAppAccessWindow
- (BOOL)isVisible { return self.fixtureAvailable; }
@end
@interface AIAppAccessMenu : NSMenu
@property(nonatomic) NSUInteger updates;
@end
@implementation AIAppAccessMenu
- (void)update { self.updates++; [super update]; }
@end
@interface AIAppAccessReceiver : NSObject <NSTextFieldDelegate>
@property(nonatomic) NSUInteger actions;
@property(nonatomic) NSUInteger changes;
@property(nonatomic) NSUInteger commits;
@property(nonatomic) NSString* value;
@property(nonatomic) BOOL simulateModal;
@property(nonatomic) BOOL nestedToolDidRun;
- (void)changed:(id)sender;
@end
@implementation AIAppAccessReceiver
- (void)changed:(id)sender {
    (void)sender;self.actions++;
    if(self.simulateModal) {
        // Model a runModal handler without opening UI: the next tool arrives on the main queue.
        dispatch_async(dispatch_get_main_queue(),^{self.nestedToolDidRun=YES;});
        NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:.2];
        while(!self.nestedToolDidRun && deadline.timeIntervalSinceNow>0)
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:deadline];
    }
}
- (void)controlTextDidChange:(NSNotification*)note { self.changes++;self.value=[note.object stringValue]; }
- (void)controlTextDidEndEditing:(NSNotification*)note { self.commits++;self.value=[note.object stringValue]; }
@end
static NSDictionary* AppAccessRow(NSDictionary* snapshot,NSString* section,NSString* label) {
    for(NSDictionary* row in snapshot[section])if([row[@"label"] isEqual:label])return row;
    return nil;
}
static void DrainNativeAppAccess(void) {
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
}
static void CheckNativeAppAccess(void) {
    AIAppAccessReceiver* receiver=[AIAppAccessReceiver new];
    NSMenu* originalMenu=NSApp.mainMenu;
    AIAppAccessMenu* menu=[[AIAppAccessMenu alloc] initWithTitle:@"Fixture"];menu.autoenablesItems=NO;
    NSMenuItem* command=[[NSMenuItem alloc] initWithTitle:@"Fixture command" action:@selector(changed:) keyEquivalent:@""];
    command.target=receiver;[menu addItem:command];
    [menu addItem:[[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@""]];
    NSApp.mainMenu=menu;menu.updates=0;
    AIAppAccessWindow* window=[[AIAppAccessWindow alloc] initWithContentRect:NSMakeRect(0,0,300,200)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed=NO;window.fixtureAvailable=YES;
    NSPopUpButton* popup=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(0,0,100,24) pullsDown:NO];
    popup.accessibilityLabel=@"Fixture choice";[popup addItemsWithTitles:@[@"First",@"Second",@"Disabled"]];
    popup.menu.autoenablesItems=NO;[popup itemAtIndex:2].enabled=NO;
    popup.target=receiver;popup.action=@selector(changed:);[window.contentView addSubview:popup];
    NSTextField* field=[[NSTextField alloc] initWithFrame:NSMakeRect(0,30,100,24)];
    field.accessibilityLabel=@"Fixture field";field.stringValue=@"before";field.delegate=receiver;
    field.target=receiver;field.action=@selector(changed:);[window.contentView addSubview:field];
    NSSecureTextField* secure=[NSSecureTextField new];secure.stringValue=@"SECRET_FIXTURE";
    secure.accessibilityLabel=@"Hidden secure fixture";[window.contentView addSubview:secure];
    NSTextField* labelled=[NSTextField new];labelled.placeholderString=@"API key";labelled.stringValue=@"SECRET_FIXTURE";
    [window.contentView addSubview:labelled];
    NSView* secretGroup=[NSView new];secretGroup.identifier=@"credentialGroup";
    NSTextField* child=[NSTextField new];child.stringValue=@"SECRET_FIXTURE";
    [secretGroup addSubview:child];[window.contentView addSubview:secretGroup];
    @try {
        ShenzhenMacDelegate* reader=[ShenzhenMacDelegate new];
        Check(menu.updates==0,"native app access adds no menu discovery during reader initialization");
        NSDictionary* result=[reader aiAppAccess:@{@"operation":@"inspect"}];
        NSDictionary* choice=AppAccessRow(result,@"controls",@"Fixture choice");
        NSDictionary* text=AppAccessRow(result,@"controls",@"Fixture field");
        Check(choice && text,"native discovery includes offscreen fixture controls without ordering windows");
        Check([choice[@"value"] isEqual:@"0"] && [choice[@"choices"] count]==2,
            "popup value is selected index and disabled choices are omitted");
        NSString* json=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:result options:0 error:nil]
            encoding:NSUTF8StringEncoding];
        Check(![json containsString:@"SECRET_FIXTURE"] && !AppAccessRow(result,@"menus",@"Quit"),
            "secure fields, credential-labelled fields and ancestors, and termination are excluded");
        result=[reader aiAppAccess:@{@"operation":@"set",@"id":choice[@"id"],@"value":@"Second"}];
        Check(popup.indexOfSelectedItem==0 && receiver.actions==0 && [result[@"queued"] boolValue],
            "native activation returns before actions can enter a modal loop");DrainNativeAppAccess();
        Check(popup.indexOfSelectedItem==1 && receiver.actions==1 && [result[@"dispatched"] boolValue] &&
            ![result[@"undoable"] boolValue] && !result[@"appReceipt"],"popup dispatch selects correct item without claiming Undo");
        result=[reader aiAppAccess:@{@"operation":@"set",@"id":choice[@"id"],@"value":@"Disabled"}];
        Check(result[@"error"] && popup.indexOfSelectedItem==1,"disabled choice cannot be dispatched");
        result=[reader aiAppAccess:@{@"operation":@"activate",@"id":choice[@"id"]}];
        Check(result[@"error"] && receiver.actions==1,"popup cannot open a tracking menu through button activation");
        result=[reader aiAppAccess:@{@"operation":@"set",@"id":text[@"id"],@"value":@"after"}];
        DrainNativeAppAccess();
        Check([result[@"dispatched"] boolValue] && receiver.changes==1 && receiver.commits==1 &&
            [receiver.value isEqual:@"after"] && receiver.actions==2,"text set drives delegate callbacks and target action");
        field.hidden=YES;
        Check([reader aiAppAccess:@{@"operation":@"set",@"id":text[@"id"],@"value":@"bad"}][@"error"]!=nil,
            "a control hidden since inspection is unavailable");field.hidden=NO;
        window.contentView.identifier=@"credentialContainer";
        Check([reader aiAppAccess:@{@"operation":@"set",@"id":text[@"id"],@"value":@"bad"}][@"error"]!=nil,
            "a control under a newly secret ancestor is unavailable");window.contentView.identifier=nil;
        NSString* oversized=[@"x" stringByPaddingToLength:8193 withString:@"x" startingAtIndex:0];
        Check([reader aiAppAccess:@{@"operation":@"set",@"id":text[@"id"],@"value":oversized}][@"error"]!=nil,
            "native text input has a bounded payload");
        result=[reader aiAppAccess:@{@"operation":@"inspect"}];
        Check([AppAccessRow(result,@"controls",@"Fixture choice")[@"value"] isEqual:@"1"],
            "native popup inspection reports the changed selection, not inherited button state");
        Check([reader aiAppAccess:@{@"operation":@"set",@"id":text[@"id"],@"value":@"bad"}][@"error"]!=nil,
            "fresh inspection invalidates old target IDs");
        NSDictionary* commandRow=AppAccessRow(result,@"menus",@"Fixture command");
        Check(commandRow!=nil,"native menu is discoverable");
        receiver.simulateModal=YES;
        result=[reader aiAppAccess:@{@"operation":@"activate",@"id":commandRow[@"id"]}];
        DrainNativeAppAccess();
        Check([result[@"dispatched"] boolValue] && receiver.actions==3 && ![result[@"undoable"] boolValue],
            "menu action is dispatch-only and cannot claim generic Undo");
        Check(receiver.nestedToolDidRun,"a native nested event loop permits the next tool's main-queue callback");
        [menu removeItem:command];
        Check([reader aiAppAccess:@{@"operation":@"activate",@"id":commandRow[@"id"]}][@"error"]!=nil &&
            receiver.actions==3,"removed menu commands cannot use stale IDs");
        NSString* huge=[@"📖" stringByPaddingToLength:20000 withString:@"📖" startingAtIndex:0];
        for(NSUInteger i=0;i<400;i++) {
            NSMenuItem* item=[[NSMenuItem alloc] initWithTitle:huge action:@selector(changed:) keyEquivalent:@""];
            item.target=receiver;[menu addItem:item];
        }
        [popup removeAllItems];for(NSUInteger i=0;i<40;i++)[popup addItemWithTitle:huge];
        field.stringValue=huge;result=[reader aiAppAccess:@{@"operation":@"inspect"}];
        Check([NSJSONSerialization dataWithJSONObject:result options:0 error:nil].length<66000,
            "menu/control labels and popup choices obey total JSON output bound");
    } @finally { NSApp.mainMenu=originalMenu;window.fixtureAvailable=NO;[window close]; }
}
