#import "../SPDFMacAIChatDock.h"
#import "../SPDFMacAIChatHistoryView.h"
#import "../SPDFMacAIChatStore.h"
#import "../SPDFMacSidebarModeControl.h"
#import "../SPDFMacCollectionStyle.h"
@interface ChatReaderSurface : NSView @end
@implementation ChatReaderSurface
- (void)drawRect:(NSRect)rect {[SPDFCollectionColor(@"window") setFill];NSRectFill(rect);}
@end
static void CheckChatDock(void) {
    NSWindow* window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1240,720) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    window.contentView=[[ChatReaderSurface alloc] initWithFrame:window.contentView.bounds];
    NSView* root=window.contentView; root.wantsLayer=YES;
    SPDFSidebarNavigationControl* navigation=[[SPDFSidebarNavigationControl alloc] initWithFrame:NSMakeRect(8,684,224,36)];
    spdf_sidebar_mode_control_configure_navigation(navigation,YES,YES);
    navigation.spdf_selectedSidebarMode=SPDFSidebarModeChats;
    [navigation setCollapseTarget:navigation action:@selector(performClick:)]; [root addSubview:navigation];
    SPDFMacAIChatHistoryView* history=[[SPDFMacAIChatHistoryView alloc] initWithFrame:NSMakeRect(0,0,240,684)];
    history.autoresizingMask=NSViewHeightSizable;[root addSubview:history];
    NSView* reader=[[NSView alloc] initWithFrame:NSMakeRect(241,0,999,720)];[root addSubview:reader];
    reader.wantsLayer=YES;
    NSTextField* page=[NSTextField wrappingLabelWithString:@"Power requirements\n\nThe board uses a 5 V supply.\n\nMaximum current: 2 A\n\nConnect a regulated power supply to J1."];
    page.font=[NSFont systemFontOfSize:20];page.translatesAutoresizingMaskIntoConstraints=NO;[reader addSubview:page];
    [NSLayoutConstraint activateConstraints:@[[page.leadingAnchor constraintEqualToAnchor:reader.leadingAnchor constant:32],[page.trailingAnchor constraintEqualToAnchor:reader.trailingAnchor constant:-32],[page.topAnchor constraintEqualToAnchor:reader.topAnchor constant:48]]];
    SPDFMacAIChatView* view=[[SPDFMacAIChatView alloc] initWithFrame:NSMakeRect(0,0,400,720)];
    SPDFMacAIChatDock* dock=[[SPDFMacAIChatDock alloc] initWithReaderView:reader chatView:view width:400];
    Check(dock.visible && reader.superview==dock.split && view.superview==dock.split,@"reader and chat share a split without replacing reader content");
    ChatFixture* session=[ChatFixture new];session.canUndo=YES;session.canRedo=YES;
    session.activityState=SPDFMacAIChatActivityCompleted;
    session.chat=@{@"id":@"layout",@"messages":@[@{@"role":@"user",@"content":@"What power supply does the board need?"},@{@"role":@"assistant",@"content":@"Use a **5 V regulated supply**, rated for at least **2 A**.\n\nSee [Power requirements, page 2](spdf-ai://document?path=doc:board&page=2)."}]};
    [view displaySession:(id)session];
    [root layoutSubtreeIfNeeded];
    NSView* hide=Find(view,@"close"); NSView* chatIcon=nil;
    for(NSView* child in navigation.subviews) if([child.accessibilityLabel isEqual:@"Chats"]) chatIcon=child;
    Check(chatIcon && fabs(NSMidY([hide convertRect:hide.bounds toView:root])-NSMidY([chatIcon convertRect:chatIcon.bounds toView:root]))<.01,@"chat toolbar icons align with production sidebar icon row");
    [history displayChats:@[@{@"id":@"layout",@"title":@"Board power requirements",@"updated":@0},@{@"id":@"second",@"title":@"Translate generated chapters to English",@"updated":@0}] selectedID:@"layout"];
    for(NSString* appearance in @[NSAppearanceNameDarkAqua,NSAppearanceNameAqua]) {
        window.appearance=[NSAppearance appearanceNamed:appearance];
        [window.effectiveAppearance performAsCurrentDrawingAppearance:^{reader.layer.backgroundColor=NSColor.textBackgroundColor.CGColor;}];
        [root layoutSubtreeIfNeeded];
        Capture(root,[NSString stringWithFormat:@"workspace-%@",appearance]);
        NSArray* transcript=session.chat[@"messages"];
        session.chat=@{@"id":@"empty-layout",@"messages":@[]}; session.activityState=SPDFMacAIChatActivityIdle;
        [view displaySession:(id)session]; [root layoutSubtreeIfNeeded];
        Capture(root,[NSString stringWithFormat:@"workspace-empty-%@",appearance]);
        NSStackView* rows=[view valueForKey:@"messages"];
        Check(rows.arrangedSubviews.count==1 && [rows.arrangedSubviews.firstObject isKindOfClass:NSTextField.class],@"layer-backed reader empty chat never paints a message bubble");
        session.chat=@{@"id":@"layout",@"messages":transcript}; session.activityState=SPDFMacAIChatActivityCompleted;
        [view displaySession:(id)session];
    }
    for(NSNumber* width in @[@999,@700,@600,@999]) {
        [dock.split setFrameSize:NSMakeSize(width.doubleValue,720)];[dock.split adjustSubviews];[root layoutSubtreeIfNeeded];
        Check(NSMinX(reader.frame)==NSMaxX(view.frame)+dock.split.dividerThickness && NSWidth(reader.frame)>=279,@"resize keeps panels adjacent and reading space visible");
        Check(NSWidth(view.frame)>=320 && NSWidth(view.frame)<=400,@"resizing preserves usable chat width");
        Check(InspectTargets(view)>=12,@"chat actions stay reachable beside the reader");
    }
    [dock setVisible:NO];Check(view.hidden && NSMinX(reader.frame)==0 && NSWidth(reader.frame)==NSWidth(dock.split.bounds),@"hide restores full reader width");
    [dock setVisible:YES];Check(!view.hidden && NSWidth(view.frame)==400,@"show restores chosen chat width");
    __block NSUInteger resizes=0;dock.resized=^(CGFloat width){(void)width;resizes++;};
    [dock splitViewDidResizeSubviews:[NSNotification notificationWithName:NSSplitViewDidResizeSubviewsNotification object:dock.split]];
    Check(resizes==0,@"unrelated mouse activity and programmatic layout cannot record a divider drag");
    [dock.split setValue:@YES forKey:@"trackingDivider"];[view setFrameSize:NSMakeSize(360,720)];
    [dock splitViewDidResizeSubviews:[NSNotification notificationWithName:NSSplitViewDidResizeSubviewsNotification object:dock.split]];
    [dock.split setValue:@NO forKey:@"trackingDivider"];
    [dock setVisible:NO];[dock setVisible:YES];
    Check(resizes==1 && NSWidth(view.frame)==360,@"only the split-local divider gesture updates remembered chat width");
    __block NSString* opened=nil;history.action=^(NSString* action){opened=action;};
    NSTableView* table=[history valueForKey:@"table"];
    [table keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36]];
    Check([opened isEqual:@"load:layout"],@"Return reopens selected saved chat");
    NSURL* directory=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    SPDFMacAIChatStore* store=[[SPDFMacAIChatStore alloc] initWithDirectory:directory];
    Check(![NSFileManager.defaultManager fileExistsAtPath:directory.path],@"chat store construction creates no storage");
    NSString* identifier=NSUUID.UUID.UUIDString;
    NSDictionary* saved=@{@"id":identifier,@"title":@"Board notes",@"updated":@1,@"messages":@[@{@"role":@"user",@"content":@"Find capacitor voltage"},@{@"role":@"assistant",@"content":@"The supply is regulated."}]};
    Check([store saveChat:saved error:nil],@"chat fixture saves");
    Check([store chatsMatchingQuery:@"CAPACITOR"].count==1 && [store chatsMatchingQuery:@"regulated"].count==1 && [store chatsMatchingQuery:@"Board"].count==1,@"chat search matches both speakers and titles case-insensitively");
    Check([store chatsMatchingQuery:@"nonexistent"].count==0,@"chat search filters unmatched conversations");
    Check([[[[SPDFMacAIChatStore alloc] initWithDirectory:directory] chatWithID:identifier][@"messages"] isEqual:saved[@"messages"]],@"both speakers survive store reopening");
    [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
    Check(!window.visible,@"composite fixture never orders a window");
}
