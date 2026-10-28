// Event-dispatch coverage: no direct composer keyDown or palette activation calls.
// NSApplication runs the real search monitor; NSWindow dispatches chat keys. A
// never-ordered panel is not the application key window, so it cannot receive
// NSApplication native forwarding without activating a user-visible app.
#import "SPDFMacPalettePresentation.h"
#import "SPDFMacAIChatDock.h"
@interface ShenzhenMacDelegate (ChatWindowMenuProbe)
- (void)closeDocument:(id)sender;
- (id)readerAIHistoryState;
- (void)rememberAIChatWidth:(CGFloat)width;
- (void)aiChatAction:(NSString*)action;
@end
@interface ComposerInvisiblePanel : NSPanel
@property(nonatomic) BOOL fixtureVisible;
@property(nonatomic) NSUInteger dispatchedKeys;
@end
@implementation ComposerInvisiblePanel
- (void)makeKeyAndOrderFront:(id)sender { (void)sender;self.fixtureVisible=YES; }
- (void)orderOut:(id)sender { (void)sender;self.fixtureVisible=NO; }
- (BOOL)isVisible { return self.fixtureVisible; }
- (void)sendEvent:(NSEvent*)event { if(event.type==NSEventTypeKeyDown)self.dispatchedKeys++;[super sendEvent:event]; }
@end
@interface ComposerEventReader : ComposerReaderProbe
@property(nonatomic) NSUInteger chatOpens;
@property(nonatomic) NSUInteger persistenceCount;
- (void)seedPalette;
- (NSPanel*)fixturePanel;
- (BOOL)searchMonitorInstalled;
@end
@implementation ComposerEventReader
- (void)persistActiveState {self.persistenceCount++;}
- (void)seedPalette {
    _window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1000,700) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
    _window.releasedWhenClosed=NO;
    _splitView=[[NSSplitView alloc] initWithFrame:_window.contentView.bounds];_splitView.vertical=YES;
    _splitView.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;[_window.contentView addSubview:_splitView];
    _documentContainer=[[NSView alloc] initWithFrame:_splitView.bounds];[_splitView addSubview:_documentContainer];
    _palettePanel=[[ComposerInvisiblePanel alloc] initWithContentRect:NSMakeRect(-20000,-20000,650,390)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskFullSizeContentView backing:NSBackingStoreBuffered defer:NO];
    _palettePanel.releasedWhenClosed=NO;_palettePanel.alphaValue=0;
    _paletteMode=1;_paletteSearchField=[[SPDFPaletteSearchField alloc] initWithFrame:NSMakeRect(10,10,400,30)];
    ((SPDFPaletteSearchField*)_paletteSearchField).reader=self;_paletteSearchField.delegate=self;
    _paletteTable=[NSTableView new];_paletteTable.dataSource=self;_paletteResults=[NSMutableArray array];
    [_palettePanel.contentView addSubview:_paletteSearchField];
}
- (NSPanel*)fixturePanel { return _palettePanel; }
- (BOOL)searchMonitorInstalled { return _paletteEventMonitor!=nil; }
// An empty search, as production fills it: the chat row first and highlighted.
- (void)refreshPaletteResults {
    [_paletteResults setArray:@[spdf_collection_palette_chat_row(@"")]];
    [_paletteTable reloadData];[self selectFirstPaletteResult];
}
- (NSArray*)paletteMenuCommandCandidates { return @[]; }
- (void)showAIChatForQuery:(NSString*)query { self.chatOpens++;[super showAIChatForQuery:query]; }
@end
static void CheckComposerEventDispatch(void) {
    SaveComposerSettings(YES,YES,YES);
    ComposerEventReader* reader=[ComposerEventReader new];reader.testKey=@"sk-or-v1-offline-acceptance-only";[reader seedPalette];
    Check(!reader.isAIChatVisible && !reader.aiChatWindow,"reader initialization creates no chat panel/window");
    id lazyHistory=[reader readerAIHistoryState];
    Check(![lazyHistory valueForKey:@"session"] && ![lazyHistory valueForKey:@"view"] && ![lazyHistory valueForKey:@"tools"],"history state does not initialize chat UI or model transport");
    [reader showPaletteWithTitle:@"Search"];NSPanel* panel=[reader fixturePanel];
    Check([reader searchMonitorInstalled],"search lifecycle installs monitor");
    NSUInteger before=ComposerRequestCount();[NSApp sendEvent:ComposerReturn(NO,panel.windowNumber)];
    Check(reader.chatOpens==1 && ![reader searchMonitorInstalled] && !reader.settingsOpens,"Return transitions search to dock once");
    id state=[reader readerAIState];SPDFMacAIChatView* view=[state valueForKey:@"view"];
    SPDFMacAIChatSession* session=[state valueForKey:@"session"];
    SPDFMacAIChatDock* dock=[state valueForKey:@"dock"];NSWindow* window=view.window;
    Check(dock && reader.isAIChatVisible && !reader.aiChatWindow && window && window!=panel && window.firstResponder==view.composer,
        "chat is docked inside reader with composer first responder");
    Check(dock.split.subviews.count==2 && NSWidth(dock.split.subviews.lastObject.frame)>250,"document remains beside chat");
    NSUInteger saves=reader.persistenceCount;
    [reader rememberAIChatWidth:350];[reader rememberAIChatWidth:360];[reader rememberAIChatWidth:370];
    Check(reader.persistenceCount==saves,"chat divider motion performs no synchronous session writes");
    Check(ComposerWait(^BOOL{return reader.persistenceCount>saves;}),"chat divider persists after gesture settles");
    Check(reader.persistenceCount==saves+1 && [[reader sidebarWorkspaceState][@"chatWidth"] isEqual:@370],"one settled save preserves the final chat width");
    view.composer.string=@"Send through window event dispatch";[window sendEvent:ComposerReturn(NO,window.windowNumber)];
    Check(ComposerWait(^BOOL{return [session.chat[@"messages"] count]==2 && !session.running;}),"docked Return completes a real offline transport turn");
    Check(ComposerRequestCount()==before+1 && !view.composer.string.length && !reader.settingsOpens,"one Return sends exactly once without opening settings");
    view.composer.string=@"New line";[view.composer setSelectedRange:NSMakeRange(8,0)];before=ComposerRequestCount();
    [window sendEvent:ComposerReturn(YES,window.windowNumber)];
    Check([view.composer.string isEqual:@"New line\n"] && ComposerRequestCount()==before,"Shift Return adds newline");
    NSString* chatID=session.chat[@"id"];view.composer.string=@"Draft A";
    [reader aiChatAction:@"new"];view.composer.string=@"Draft B";
    [reader aiChatAction:[@"load:" stringByAppendingString:chatID]];
    Check([view.composer.string isEqual:@"Draft A"],"switching chats preserves independent immutable drafts");
    view.composer.string=@"Draft survives hiding";
    NSEvent* escape=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0
        windowNumber:window.windowNumber context:nil characters:@"\x1b" charactersIgnoringModifiers:@"\x1b" isARepeat:NO keyCode:53];
    [window sendEvent:escape];Check(!reader.isAIChatVisible && [view.composer.string isEqual:@"Draft survives hiding"],"Escape hides dock without losing draft");
    Check(NSWidth(dock.split.subviews.lastObject.frame)==NSWidth(dock.split.bounds),"hidden dock returns all space to document");
    [reader showAIChat:nil];Check(reader.isAIChatVisible && [session.chat[@"id"] isEqual:chatID] && [view.composer.string isEqual:@"Draft survives hiding"],"reopening preserves conversation and draft");
    [reader showPaletteWithTitle:@"Search"];Check(reader.isAIChatVisible && panel.visible,"search can coexist with docked chat");
    [reader closePalette:nil];[reader closeAIChat];[panel close];
    Check(!window.visible,"headless event test never presents reader window");
}
