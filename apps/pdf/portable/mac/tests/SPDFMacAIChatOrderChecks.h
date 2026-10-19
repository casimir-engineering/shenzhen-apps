static NSArray<NSTextView*>* ChatBodies(SPDFMacAIChatView* view) {
    NSMutableArray* result=[NSMutableArray array];
    for(NSView* child in [(NSStackView*)[view valueForKey:@"messages"] arrangedSubviews])
        if([child isKindOfClass:NSTextView.class])[result addObject:child];
    return result;
}
static void RunChatOrderChecks(void) {
    NSWindow* window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,410,650)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    SPDFMacAIChatView* view=[[SPDFMacAIChatView alloc] initWithFrame:window.contentView.bounds];
    view.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;[window.contentView addSubview:view];
    NSMutableArray* messages=[NSMutableArray array];
    for(NSUInteger i=0;i<44;i++)[messages addObject:@{@"role":i%2 ? @"assistant" : @"user",
        @"content":[NSString stringWithFormat:@"Message %lu: This paragraph provides enough details to wrap across several lines in the narrow chat panel.",(unsigned long)i]}];
    ChatFixture* fixture=[ChatFixture new];fixture.chat=@{@"id":@"chronology",@"messages":[messages copy]};
    [view displaySession:(id)fixture];SettleChatLayout(window);
    NSArray* bodies=ChatBodies(view);NSScrollView* scroll=[view valueForKey:@"scroll"];
    Check(bodies.count==40 && [[bodies.firstObject string] hasPrefix:@"Message 4:"] && [[bodies.lastObject string] hasPrefix:@"Message 43:"],@"latest40 messages are displayed in chronological order");
    Check(fabs(NSMaxY(scroll.contentView.bounds)-NSHeight(scroll.documentView.bounds))<2,@"opening a long conversation lands at its newest bottom");
    [scroll.contentView scrollToPoint:NSMakePoint(0,100)];[scroll reflectScrolledClipView:scroll.contentView];
    [messages addObject:@{@"role":@"assistant",@"content":@"An additional answer arriving while earlier messages are being read."}];
    fixture.chat=@{@"id":@"chronology",@"messages":[messages copy]};[view displaySession:(id)fixture];SettleChatLayout(window);
    Check(fabs(scroll.contentView.bounds.origin.y-100)<2,@"incoming reply does not pull a reader away from earlier messages");
    [messages addObject:@{@"role":@"user",@"content":@"My next question"}];
    fixture.chat=@{@"id":@"chronology",@"messages":[messages copy]};[view displaySession:(id)fixture];SettleChatLayout(window);
    Check(fabs(NSMaxY(scroll.contentView.bounds)-NSHeight(scroll.documentView.bounds))<2,@"sending a new question returns to the newest bottom");
    [scroll.contentView scrollToPoint:NSMakePoint(0,0)];[scroll reflectScrolledClipView:scroll.contentView];
    NSTextView* anchor=ChatBodies(view).firstObject;NSString* anchorText=anchor.string;
    CGFloat position=[anchor convertPoint:NSZeroPoint toView:scroll.documentView].y-scroll.contentView.bounds.origin.y;
    [(NSButton*)Find(view,@"older") performClick:nil];SettleChatLayout(window);
    NSTextView* restored=nil;for(NSTextView* body in ChatBodies(view))if([body.string isEqual:anchorText])restored=body;
    CGFloat restoredPosition=[restored convertPoint:NSZeroPoint toView:scroll.documentView].y-scroll.contentView.bounds.origin.y;
    Check(restored && fabs(restoredPosition-position)<2,@"prepending older messages keeps the previous first message in place");
    Check([[ChatBodies(view).firstObject string] hasPrefix:@"Message 0:"],@"oldest messages appear at top after loading history");
    Check(!window.visible,@"chronology fixture never presents a window");
}
