// Production dock lifecycle regression: zero-width hidden layout must never leave
// NSTextView frames at the huge heights measured while the dock was collapsed.
static void SettleChatLayout(NSWindow* window) {
    for(NSUInteger pass=0;pass<3;pass++) {
        [window.contentView layoutSubtreeIfNeeded];
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
    }
}
static void CheckChatBubbleGeometry(SPDFMacAIChatView* view,NSString* stage) {
    NSStackView* stack=[view valueForKey:@"messages"];
    NSUInteger bubbles=0;
    for(NSView* item in stack.arrangedSubviews) {
        if(![item isKindOfClass:NSTextView.class])continue;
        NSTextView* text=(id)item; bubbles++;
        NSRect used=[text.layoutManager usedRectForTextContainer:text.textContainer];
        CGFloat expected=MAX(18,ceil(NSMaxY(used)))+2*text.textContainerInset.height;
        Check(fabs(NSHeight(text.frame)-expected)<=1,
            [stage stringByAppendingString:@": bubble frame matches wrapped text, without blank stretched space"]);
        Check(NSMinY(text.frame)>=-.5 && NSMaxY(text.frame)<=NSHeight(stack.bounds)+.5,
            [stage stringByAppendingString:@": every bubble remains inside the transcript"]);
        Check(text.layoutManager.numberOfGlyphs>0,[stage stringByAppendingString:@": message glyphs remain present"]);
        if(text.layoutManager.numberOfGlyphs) {
            NSRect final=[text.layoutManager boundingRectForGlyphRange:NSMakeRange(text.layoutManager.numberOfGlyphs-1,1)
                inTextContainer:text.textContainer];
            Check(NSMaxY(final)+text.textContainerOrigin.y<=NSHeight(text.bounds)+.5,
                [stage stringByAppendingString:@": final glyph remains inside its bubble"]);
        }
    }
    Check(bubbles==4,[stage stringByAppendingString:@": all four user and assistant messages survive"]);
}
static void RunChatReopenChecks(void) {
    NSWindow* window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1200,980)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    window.contentView.wantsLayer=YES;
    window.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    NSView* reader=[[NSView alloc] initWithFrame:window.contentView.bounds]; [window.contentView addSubview:reader];
    SPDFMacAIChatView* view=[[SPDFMacAIChatView alloc] initWithFrame:NSZeroRect];
    SPDFMacAIChatDock* dock=[[SPDFMacAIChatDock alloc] initWithReaderView:reader chatView:view width:400];
    ChatFixture* fixture=[ChatFixture new];
    fixture.chat=@{@"id":@"reopen-lifecycle",@"messages":@[
        @{@"role":@"user",@"content":@"What is the travel of the switch actuator?"},
        @{@"role":@"assistant",@"content":@"## Travel specifications\nThe drawing shows **1.4 ± 0.1 mm**. See [page 1](spdf-ai://document?path=fixture.pdf&page=1).\n\nThis is the travel to closure. The drawing provides no separate full-travel specification.\n\n| Item | Value |\n|---|---|\n| Closure | 1.4 mm |\n| Full travel | Not specified |"},
        @{@"role":@"user",@"content":@"This is travel to closure. What is the full travel range?"},
        @{@"role":@"assistant",@"content":@"The document specifies only closure travel. **Full travel is not provided.** I checked the dimensional drawing and the operating characteristics table."}
    ]};
    [view displaySession:(id)fixture]; SettleChatLayout(window); CheckChatBubbleGeometry(view,@"Initial transcript");
    for(NSUInteger cycle=0;cycle<3;cycle++) {
        [dock setVisible:NO]; SettleChatLayout(window);
        // Return to the same persisted transcript: displaySession's equality
        // optimization must be safe even when no rows are rebuilt.
        [view displaySession:(id)fixture]; [dock setVisible:YES]; SettleChatLayout(window);
        CheckChatBubbleGeometry(view,@"Reopened transcript");
    }
    [window setContentSize:NSMakeSize(650,780)]; SettleChatLayout(window);
    CheckChatBubbleGeometry(view,@"Narrow reader workspace");
    [window setContentSize:NSMakeSize(1200,980)]; SettleChatLayout(window);
    CheckChatBubbleGeometry(view,@"Restored reader workspace");
    Capture(view,@"reopen-regression-dark");
    [dock setVisible:NO]; SettleChatLayout(window);
    NSMutableDictionary* replacement=[fixture.chat mutableCopy]; replacement[@"id"]=@"loaded-while-hidden";
    fixture.chat=replacement; [view displaySession:(id)fixture]; SettleChatLayout(window);
    [dock setVisible:YES]; SettleChatLayout(window);
    CheckChatBubbleGeometry(view,@"Different chat loaded while hidden");
}
