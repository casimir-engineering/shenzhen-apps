// The end of the chat (SPDFMacAIChatViewFollow.mm): sending takes the person there from anywhere and keeps them
// there; scrolled up, nothing moves under them and a pill says what arrived below; it scrolls to the first unseen
// message and goes once that message is in view. And a paused request offers Continue beside what is left.
static BOOL FollowAtEnd(NSScrollView* scroll) {
    return fabs(NSMaxY(scroll.contentView.bounds) - NSHeight(scroll.documentView.bounds)) < 2;
}
static void FollowShow(SPDFMacAIChatView* view, ChatFixture* fixture, NSMutableArray* messages, NSWindow* window) {
    fixture.chat = @{@"id" : @"follow", @"messages" : [messages copy]};
    [view displaySession:(id)fixture];
    SettleChatLayout(window);
}
static void FollowAdd(NSMutableArray* messages, NSString* role, NSString* text) {
    [messages addObject:@{@"role" : role, @"content" : text}];
}
static void RunChatFollowChecks(void) {
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 410, 650)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    SPDFMacAIChatView* view = [[SPDFMacAIChatView alloc] initWithFrame:window.contentView.bounds];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [window.contentView addSubview:view];
    NSMutableArray* messages = [NSMutableArray array];
    for (NSUInteger i = 0; i < 30; i++)
        FollowAdd(messages, i % 2 ? @"assistant" : @"user", [NSString stringWithFormat:@"Message %lu: long enough to "
            "wrap across a few lines of the narrow chat panel, so thirty of them fill several screens.", (unsigned long)i]);
    ChatFixture* fixture = [ChatFixture new];
    FollowShow(view, fixture, messages, window);
    NSScrollView* scroll = [view valueForKey:@"scroll"];
    NSButton* pill = (NSButton*)Find(view, @"newMessagesPill");
    Check(FollowAtEnd(scroll) && pill && pill.hidden, @"a long chat opens at its end, with no pill");
    // Scrolled to the top, the person sends: their message and the reply are at the end, in view.
    [scroll.contentView scrollToPoint:NSZeroPoint]; [scroll reflectScrolledClipView:scroll.contentView];
    FollowAdd(messages, @"user", @"A question sent from the top of the chat");
    fixture.running = YES;
    FollowShow(view, fixture, messages, window);
    Check(FollowAtEnd(scroll), @"sending from the top of a long chat scrolls to its very end");
    // The reply comes in step by step while they stay at the end: it stays in view as it grows.
    FollowAdd(messages, @"assistant", @"The first part of the reply.");
    FollowShow(view, fixture, messages, window);
    NSMutableDictionary* longer = [messages.lastObject mutableCopy];
    longer[@"content"] = [@"The first part of the reply. " stringByPaddingToLength:1600 withString:@"More text. "
                                                                 startingAtIndex:0];
    messages[messages.count - 1] = longer;
    FollowShow(view, fixture, messages, window);
    Check(FollowAtEnd(scroll) && pill.hidden, @"a reply growing at the end stays in view");
    // Scrolled up while a reply is coming: nothing moves, and Jump to latest offers the way back.
    [scroll.contentView scrollToPoint:NSMakePoint(0, 200)]; [scroll reflectScrolledClipView:scroll.contentView];
    FollowAdd(messages, @"assistant", @"");  // a step row's worth of change, no new message
    FollowShow(view, fixture, messages, window);
    Check(fabs(scroll.contentView.bounds.origin.y - 200) < 2 && !pill.hidden && [pill.title isEqual:@"Jump to latest ↓"],
          @"scrolled up during a reply, the person stays put and sees Jump to latest");
    // New messages arrive below: the pill counts them.
    FollowAdd(messages, @"assistant", @"First new answer below.");
    FollowShow(view, fixture, messages, window);
    Check(!pill.hidden && [pill.title isEqual:@"New message ↓"] && fabs(scroll.contentView.bounds.origin.y - 200) < 2,
          @"one message arriving below shows New message, and nothing moves");
    FollowAdd(messages, @"user", @"(sent from elsewhere)");
    messages[messages.count - 1] = @{@"role" : @"assistant", @"content" : @"Second new answer below."};
    FollowAdd(messages, @"assistant", @"Third new answer below.");
    FollowShow(view, fixture, messages, window);
    Check(!pill.hidden && [pill.title isEqual:@"3 new messages ↓"], @"several show their count");
    // The pill scrolls smoothly to the first of them, and goes once it is in view.
    [pill performClick:nil];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];
    SettleChatLayout(window);
    NSTextView* first = nil;
    for (NSView* row in [(NSStackView*)[view valueForKey:@"messages"] arrangedSubviews])
        if ([row isKindOfClass:NSTextView.class] && [[(NSTextView*)row string] hasPrefix:@"First new answer"]) first = (id)row;
    NSRect frame = [first convertRect:first.bounds toView:scroll.documentView];
    Check(first && NSMinY(frame) >= NSMinY(scroll.contentView.bounds) - 1 &&
          NSMinY(frame) < NSMaxY(scroll.contentView.bounds) && pill.hidden,
          @"the pill scrolls to the first unseen message and goes once it is in view");
    // Paused before finishing: Continue beside what is left, and sending Continue goes to the end.
    fixture.running = NO;
    fixture.canContinue = YES;
    fixture.status = @"Not finished yet. Continue picks up where it stopped.";
    fixture.activityState = SPDFMacAIChatActivityPaused;
    [scroll.contentView scrollToPoint:NSZeroPoint]; [scroll reflectScrolledClipView:scroll.contentView];
    FollowShow(view, fixture, messages, window);
    NSButton* recovery = (NSButton*)Find(view, @"continue");
    Check([recovery.title isEqual:@"Continue"] && !recovery.hiddenOrHasHiddenAncestor,
          @"a paused request offers Continue");
    fixture.canContinue = NO;
    fixture.running = YES;
    FollowAdd(messages, @"user", @"Continue");
    FollowShow(view, fixture, messages, window);
    Check(FollowAtEnd(scroll), @"Continue, like Retry and Send, goes to the end of the chat");
    Check(!window.visible, @"the follow fixture never presents a window");
}
