static void CheckNoBlankChatRows(SPDFMacAIChatView* view,NSUInteger expected,NSString* stage) {
    NSArray* bodies=ChatBodies(view);
    Check(bodies.count==expected,[stage stringByAppendingString:@": only meaningful message bodies appear"]);
    for(NSTextView* body in bodies)
        Check([body.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length>0,
            [stage stringByAppendingString:@": no blank assistant bubble"]);
}
static void RunBlankChatRowsChecks(void) {
    NSWindow* window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1200,680) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    NSView* reader=[[NSView alloc] initWithFrame:window.contentView.bounds];[window.contentView addSubview:reader];
    SPDFMacAIChatView* view=[[SPDFMacAIChatView alloc] initWithFrame:NSZeroRect];
    SPDFMacAIChatDock* dock=[[SPDFMacAIChatDock alloc] initWithReaderView:reader chatView:view width:400];
    [dock setVisible:YES];
    NSMutableArray* messages=[NSMutableArray arrayWithObject:@{@"role":@"user",@"content":@"What does this document say?"}];
    // Providers may return line breaks alongside tool calls. These are valid
    // protocol records, but must not consume transcript rows or history limits.
    for(NSUInteger i=0;i<45;i++) [messages addObject:@{@"role":@"assistant",@"content":i%2 ? @"\n\n" : @" \t \r\n",@"tool_calls":@[]}];
    [messages addObject:@{@"role":@"assistant",@"content":@"The saved answer is **still present**.\n\nIt includes its supporting context."}];
    ChatFixture* fixture=[ChatFixture new]; fixture.chat=@{@"id":@"blank-tool-rounds",@"messages":messages};
    [view displaySession:(id)fixture];SettleChatLayout(window);
    CheckNoBlankChatRows(view,2,@"Historical transcript");
    Check(!Find(view,@"older"),@"invisible tool-round whitespace does not consume the forty-message display budget");
    [view displayChats:@[]];[view displaySession:(id)fixture];SettleChatLayout(window);
    CheckNoBlankChatRows(view,2,@"Reopened transcript");
    [view setChatSearchQuery:@"still present"];SettleChatLayout(window);
    CheckNoBlankChatRows(view,1,@"Search finds saved answer");
    [view setChatSearchQuery:@""];SettleChatLayout(window);CheckNoBlankChatRows(view,2,@"Cleared search");
    Capture(view,@"no-blank-tool-rounds");
    // Optional read-only replay of a reported real chat, never a running app capture.
    NSString* replay=NSProcessInfo.processInfo.environment[@"SPDF_CHAT_REPLAY"];
    if(replay.length) {
        NSDictionary* chat=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:replay] options:0 error:nil];
        Check([chat[@"messages"] isKindOfClass:NSArray.class],@"saved chat replay loaded");
        fixture.chat=chat;[view displaySession:(id)fixture];SettleChatLayout(window);
        NSUInteger count=0;NSString* final=@"";
        for(NSDictionary* message in chat[@"messages"]) {
            if(![@[@"user",@"assistant"] containsObject:message[@"role"]])continue;
            NSString* text=message[@"content"];
            if([text isKindOfClass:NSString.class] && [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) {count++;final=text;}
        }
        CheckNoBlankChatRows(view,MIN(count,40UL),@"Reported saved chat");
        Check([[ChatBodies(view).lastObject string] containsString:[[final componentsSeparatedByString:@"\n"] firstObject]],@"saved final answer is rendered after reopening");
        Capture(view,@"reported-chat-replay");
    }
    Check(!window.visible,@"blank-row fixture never opens a window");
}
