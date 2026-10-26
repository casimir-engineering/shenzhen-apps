// The owner's long requests through the real app (run_e2e.py --scenario long, model_stub_long.py), included by
// driver.m: sixteen documents open in General, then the chat as the owner used it. Sort them into groups (one reply
// reads all sixteen; a loop is pointed out and the model changes approach); rename the UUID-named ones (a runaway on
// the read-only one is wound up into an answer with Continue, and Continue finishes); save to Downloads from Python,
// read back by this chat and refused to another; and the transcript's end: sending from the top of a long chat, and
// the pill for what arrives below while the person reads above.

static NSScrollView* Transcript(void) { return [ChatView() valueForKey:@"scroll"]; }

static void ScrollTranscriptTo(CGFloat y) {
    Main(^id {
        NSScrollView* scroll = Transcript();
        [scroll.contentView scrollToPoint:NSMakePoint(0, y)];
        [scroll reflectScrolledClipView:scroll.contentView];
        return nil;
    });
    [NSThread sleepForTimeInterval:0.3];
}

static BOOL TranscriptAtEnd(void) {
    return [Main(^id {
        NSScrollView* scroll = Transcript();
        [scroll.documentView layoutSubtreeIfNeeded];
        return @(NSMaxY(scroll.contentView.bounds) >= NSHeight(scroll.documentView.bounds) - 2);
    }) boolValue];
}

static NSString* PillTitle(void) {
    return Main(^id {
        NSButton* pill = (NSButton*)[ChatView() valueForKey:@"newMessagesPill"];
        return pill.hiddenOrHasHiddenAncestor ? @"" : pill.title ?: @"";
    });
}

// Types and presses Return, then reports whether the end of the chat was in view a moment later.
static BOOL AskFromTop(NSString* text, BOOL wait) {
    ScrollTranscriptTo(0);
    Log([@"ask from the top: " stringByAppendingString:text]);
    Main(^id {
        NSTextView* composer = [ChatView() valueForKey:@"composer"];
        [composer.window makeFirstResponder:composer];
        [composer insertText:text replacementRange:NSMakeRange(NSNotFound, 0)];
        NSEvent* enter = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
            timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:composer.window.windowNumber context:nil
            characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36];
        [composer keyDown:enter];
        return nil;
    });
    WaitFor(10, ^BOOL { return [[Session() valueForKey:@"running"] boolValue]; });
    [NSThread sleepForTimeInterval:0.8];
    BOOL atEnd = TranscriptAtEnd();
    if (wait) WaitFor(240, ^BOOL { return ![[Session() valueForKey:@"running"] boolValue]; });
    return atEnd;
}

static NSMutableDictionary* LongExchange(NSString* name) {
    NSMutableDictionary* exchange = [Exchange(name) mutableCopy];
    Main(^id {
        id session = Session();
        exchange[@"canContinue"] = [session valueForKey:@"canContinue"] ?: @NO;
        exchange[@"state"] = [session valueForKey:@"activityState"] ?: @0;
        NSMutableArray* answers = [NSMutableArray array];
        for (NSDictionary* message in [session valueForKey:@"chat"][@"messages"])
            if ([message[@"role"] isEqual:@"assistant"] && [message[@"content"] length])
                [answers addObject:message[@"content"]];
        exchange[@"answers"] = answers;
        return nil;
    });
    gResult[name] = exchange;
    return exchange;
}

static void RunLong(void) {
    NSDictionary* questions = gPlan[@"questions"];
    Main(^id {
        for (NSString* path in gPlan[@"documents"])
            ((void (*)(id, SEL, id))objc_msgSend)(NSApp.delegate, NSSelectorFromString(@"openPath:"), path);
        return nil;
    });
    [NSThread sleepForTimeInterval:6];
    Main(^id { [NSApp sendAction:NSSelectorFromString(@"showAIChat:") to:nil from:nil]; return nil; });
    if (!WaitFor(20, ^BOOL { return ChatView() != nil; })) { Log(@"no chat view"); return; }
    [NSThread sleepForTimeInterval:1];
    Shot(@"long-0-open");

    // 1. Sort General into groups: a reply with 16 actions, then a loop the app points out.
    Ask(questions[@"sort"]);
    LongExchange(@"sort");
    Shot(@"long-1-sorted");

    // 2. "still UUIDs": renames in one reply, then a runaway on the read-only one, wound up with Continue.
    gResult[@"uuids_sent_at_end"] = @(AskFromTop(questions[@"uuids"], YES));
    LongExchange(@"uuids");
    Shot(@"long-2-paused-with-continue");

    // 3. Continue, from the top of the chat: it goes to the end and finishes the work.
    ScrollTranscriptTo(0);
    Click(@"continue");
    WaitFor(10, ^BOOL { return [[Session() valueForKey:@"running"] boolValue]; });
    [NSThread sleepForTimeInterval:0.8];
    gResult[@"continue_at_end"] = @(TranscriptAtEnd());
    WaitFor(240, ^BOOL { return ![[Session() valueForKey:@"running"] boolValue]; });
    LongExchange(@"continued");
    Shot(@"long-3-continued");

    // 4. Downloads from Python: saved twice, Downloads refused, its own file read back.
    gResult[@"reports_sent_at_end"] = @(AskFromTop(questions[@"reports"], YES));
    LongExchange(@"reports");
    Shot(@"long-4-reports");

    // 5. A slow reply while the person reads above: Jump to latest, then New message, then the pill's scroll.
    AskFromTop(questions[@"slow"], NO);
    ScrollTranscriptTo(0);
    [NSThread sleepForTimeInterval:0.5];
    gResult[@"pill_while_running"] = PillTitle();
    Shot(@"long-5-jump-to-latest");
    WaitFor(60, ^BOOL { return ![[Session() valueForKey:@"running"] boolValue]; });
    [NSThread sleepForTimeInterval:0.8];
    gResult[@"pill_after_reply"] = PillTitle();
    gResult[@"stayed_up"] = @(!TranscriptAtEnd());
    Shot(@"long-6-new-message-pill");
    Main(^id { [(NSButton*)[ChatView() valueForKey:@"newMessagesPill"] performClick:nil]; return nil; });
    [NSThread sleepForTimeInterval:1.2];
    gResult[@"pill_after_click"] = PillTitle();
    gResult[@"end_after_click"] = @(TranscriptAtEnd());
    Shot(@"long-7-after-pill");

    // 6. Another chat asks for the file chat A saved.
    NSString* saved = @"attachment:saved-none";
    for (NSString* tool in gResult[@"reports"][@"tools"]) {
        NSRange found = [tool rangeOfString:@"attachment:saved-[0-9a-f]+" options:NSRegularExpressionSearch];
        if (found.location != NSNotFound) { saved = [tool substringWithRange:found]; break; }
    }
    Click(@"new");
    Ask([NSString stringWithFormat:questions[@"other"], saved]);
    LongExchange(@"other");
    Shot(@"long-8-other-chat");
}
