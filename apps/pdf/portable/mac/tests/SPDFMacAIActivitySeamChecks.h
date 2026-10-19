// Chat activity: reporting, actions, saving, redaction and reopening. Included by SPDFMacAIToolSeamTests.mm.
#pragma once

static NSString* SeamWritePNG(NSString* directory) {
    NSBitmapImageRep* pixels = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nil pixelsWide:2 pixelsHigh:2
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
        bytesPerRow:8 bitsPerPixel:32];
    memset(pixels.bitmapData, 200, 16);
    NSString* path = [directory stringByAppendingPathComponent:@"plot.png"];
    [[pixels representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
    return path;
}

static NSDictionary* SeamEntry(NSArray* entries, NSString* identifier) {
    for (NSDictionary* entry in entries) if ([entry[SPDFMacAIActivityIDKey] isEqual:identifier]) return entry;
    return nil;
}

static void CheckActivity(void) {
    SeamChat chat = SeamMakeChat(@"activity");
    SPDFMacAIChatSession* session = chat.session;
    NSString* scratch = SeamTemporaryDirectory(@"activity-output");
    __block NSString* step = nil, *card = nil, *quote = nil, *image = nil, *web = nil, *helper = nil, *run = nil;
    __block NSUInteger stepCancels = 0;
    __block NSMutableArray* cardActions = [NSMutableArray array];
    chat.reader.answer = ^NSDictionary*(NSString* name, SPDFMacAIRequestContext* context) {
        (void)name;
        id<SPDFMacAIActivityReporting> activity = context.activity;
        step = [activity beginStepWithTitle:@"Searching the web" detail:@"delivery dates 2026"
                                    options:SPDFMacAIActivityOptionsNone cancel:^{ stepCancels++; }];
        [activity updateEntry:step changes:@{SPDFMacAIActivityDetailStyleKey : @"python",
                                             SPDFMacAIActivityStatusKey : @"Reading results…"}];
        card = [activity addCard:@{SPDFMacAIActivityTitleKey : @"Sent to Mei",
            SPDFMacAIActivityBodyKey : @"**Done** today.",
            SPDFMacAIActivityCardKindKey : @"friends.send", SPDFMacAIActivityStateKey : SPDFMacAIActivityStateRunning,
            SPDFMacAIActivityBodyStyleKey : SPDFMacAIActivityBodyStyleLiteral,
            SPDFMacAIActivityStatusKey : @"Sends when Mei is nearby",
            SPDFMacAIActivityAttachmentsKey : @[@{@"name" : @"contract.pdf", @"detail" : @"PDF · 2 MB"}],
            SPDFMacAIActivityActionsKey : @[@{@"id" : @"cancel", @"title" : @"Cancel"}],
            SPDFMacAIActivityInterruptedStatusKey : @"See your chat with Mei for delivery"}
            options:SPDFMacAIActivityOptionsNone handler:^(NSString* action) { [cardActions addObject:action]; }];
        quote = [activity addCard:@{SPDFMacAIActivityTitleKey : @"Read your chat with Mei",
            SPDFMacAIActivityBodyKey : @"Mei: the code is 4471", SPDFMacAIActivityLinksKey :
            @[@"shenzhenpdf-friends://message?conversation=c_mei&message=m_1"]}
            options:SPDFMacAIActivityRequestOnly handler:nil];
        // Request-only without a notice of its own, and a link title quoting what the page said.
        web = [activity addCard:@{SPDFMacAIActivityTitleKey : @"Pages it opened", SPDFMacAIActivityBodyKey : @"Tea",
            SPDFMacAIActivityLinksKey : @[@{@"url" : @"https://tea.example.com/prices",
                                            @"title" : @"Mei: the code is 4471", @"host" : @"tea.example.com"}],
            SPDFMacAIActivityActionsKey : @[@{@"id" : @"open", @"title" : @"Open", @"primary" : @YES}]}
            options:SPDFMacAIActivityRequestOnly handler:nil];
        image = [activity addImageAtPath:SeamWritePNG(scratch) caption:@"Deliveries by month"
                                 options:SPDFMacAIActivityOptionsNone];
        // A helper's row: its title is the task the model wrote, which can quote a friend.
        helper = [activity beginStepWithTitle:@"Ask whether 4471 is the door code" detail:@"Find 4471"
                                      options:SPDFMacAIActivityRequestOnly cancel:nil];
        [activity updateEntry:helper changes:@{SPDFMacAIActivityStoredTitleKey : @"Helper",
                                               SPDFMacAIActivityStateKey : SPDFMacAIActivityStateDone}];
        // A run's printed output and note, which can quote a friend as well as its code can.
        run = [activity beginStepWithTitle:@"Ran Python" detail:@"print(code)"
                                   options:SPDFMacAIActivityRequestOnly cancel:nil];
        [activity updateEntry:run changes:@{SPDFMacAIActivityOutputKey : @"Mei: the code is 4471",
            SPDFMacAIActivityNoteKey : @"Charts about 4471 aren’t shown.", SPDFMacAIActivityStateKey :
            SPDFMacAIActivityStateDone}];
        return @{@"ok" : @YES};
    };
    [session sendContext:SeamRequest(session, @"Check deliveries", nil, nil) model:@"fake/model" apiKey:@"TEST"];
    chat.model.reply(SeamToolTurn(@[SeamCall(@"a1", @"read_pages")]), nil);
    NSArray* live = session.chat[@"activity"];
    // Saved after the tool result, while the request still runs.
    NSDictionary* savedChat = [chat.store chatWithID:session.chat[@"id"]];
    NSData* fileData = [NSJSONSerialization dataWithJSONObject:savedChat options:0 error:nil];
    NSString* storedMidRequest = [[NSString alloc] initWithData:fileData encoding:NSUTF8StringEncoding];
    CHECK(live.count == 7 && [SeamEntry(live, step)[SPDFMacAIActivityAnchorKey] isEqual:@2],
          "entries are kept in order, anchored after the messages before them");
    NSDictionary* titled = @{@"url" : @"https://tea.example.com/prices", @"title" : @"Mei: the code is 4471",
                             @"host" : @"tea.example.com"};
    CHECK([SeamEntry(live, step)[SPDFMacAIActivityDetailStyleKey] isEqual:@"python"] &&
          [SeamEntry(live, web)[SPDFMacAIActivityLinksKey] isEqual:@[titled]] &&
          [SeamEntry(live, web)[SPDFMacAIActivityActionsKey][0][@"primary"] isEqual:@YES] &&
          [SeamEntry(live, card)[SPDFMacAIActivityBodyStyleKey] isEqual:SPDFMacAIActivityBodyStyleLiteral],
          "a step's code style, a link's title and host, a card's primary action and literal body are kept");
    CHECK(SPDFMacAIActivityBodyIsLiteral(SeamEntry(live, card)) &&
          SPDFMacAIActivityBodyIsLiteral(@{SPDFMacAIActivityCardKindKey : @"friends.send"}) &&
          !SPDFMacAIActivityBodyIsLiteral(SeamEntry(live, quote)),
          "a send card is always shown literally, with or without the style; other cards only when they ask");
    CHECK([SeamEntry(live, helper)[SPDFMacAIActivityTitleKey] containsString:@"4471"] &&
          ![storedMidRequest containsString:@"door code"] && [storedMidRequest containsString:@"\"Helper\""],
          "a request-only row shows its own title while the request runs; the chat file keeps its stored title");
    CHECK([SeamEntry(live, run)[SPDFMacAIActivityOutputKey] isEqual:@"Mei: the code is 4471"] &&
          [SeamEntry(live, run)[SPDFMacAIActivityNoteKey] hasPrefix:@"Charts"],
          "a step keeps what its run printed and its note while the request runs");
    CHECK([SeamEntry(live, quote)[SPDFMacAIActivityBodyKey] containsString:@"4471"] &&
          ![storedMidRequest containsString:@"4471"] && [storedMidRequest containsString:@"Read your chat with Mei"],
          "request-only content shows while its request runs but never reaches the chat file");
    CHECK(!SeamWireContains(chat.model, @"Sends when Mei is nearby") &&
          !SeamWireContains(chat.model, @"Searching the web"),
          "activity is for the person: the model never reads it");
    NSString* saved = SeamEntry(live, image)[SPDFMacAIActivityImageKey][@"path"];
    CHECK([saved hasPrefix:chat.root] && [NSFileManager.defaultManager fileExistsAtPath:saved] &&
          [NSFileManager.defaultManager fileExistsAtPath:[scratch stringByAppendingPathComponent:@"plot.png"]],
          "an image is copied into the chat's own storage; the provider keeps its file");
    CHECK([[session liveActivityActionsForEntry:step] count] == 1 &&
          [session performActivityAction:@"cancel" forEntry:step] &&
          stepCancels == 1 && ![session performActivityAction:@"delete" forEntry:card],
          "a step's Cancel runs its handler; an action the entry does not list does nothing");
    [session.activity updateEntry:card changes:@{SPDFMacAIActivityStatusKey : @"Delivered"}];
    CHECK([session performActivityAction:@"cancel" forEntry:card] && [cardActions isEqual:@[@"cancel"]],
          "a card's action reaches its provider while it runs");
    chat.model.reply(SeamAnswer(@"Sent and charted."), nil);
    NSArray* after = session.chat[@"activity"];
    CHECK([SeamEntry(after, step)[SPDFMacAIActivityStateKey] isEqual:SPDFMacAIActivityStateStopped] &&
          [SeamEntry(after, step)[SPDFMacAIActivityStatusKey] isEqual:@"Stopped"] &&
          ![session liveActivityActionsForEntry:step].count,
          "a step still running when its request ends is stopped, and no longer says what it was doing");
    CHECK([[session liveActivityActionsForEntry:card] count] == 1,
          "a card outlives its request: a queued send can still be cancelled");
    NSDictionary* redacted = SeamEntry(after, quote);
    CHECK(![redacted[SPDFMacAIActivityBodyKey] containsString:@"4471"] &&
          [redacted[SPDFMacAIActivityTitleKey] isEqual:@"Read your chat with Mei"] &&
          [redacted[SPDFMacAIActivityLinksKey] count] == 1,
          "once the request ends the open chat keeps what the file keeps: title and links, not the words");
    NSString* notice = @"Not kept after this request, because it included your Friends chats.";
    CHECK([redacted[SPDFMacAIActivityBodyKey] isEqual:
              @"The messages it read aren’t kept after this request, because it included your Friends chats."] &&
          [SeamEntry(after, web)[SPDFMacAIActivityBodyKey] isEqual:notice] &&
          [SeamEntry(after, helper)[SPDFMacAIActivityDetailKey] isEqual:notice] &&
          [SeamEntry(after, helper)[SPDFMacAIActivityTitleKey] isEqual:@"Helper"] &&
          !SeamEntry(after, helper)[SPDFMacAIActivityStoredTitleKey],
          "a Friends excerpt says the messages it read aren't kept and why; anything else says why, under its stored "
          "title");
    CHECK([SeamEntry(after, run)[SPDFMacAIActivityDetailKey] isEqual:notice] &&
          !SeamEntry(after, run)[SPDFMacAIActivityOutputKey] && !SeamEntry(after, run)[SPDFMacAIActivityNoteKey],
          "a request-only step keeps neither what its run printed nor its note");
    CHECK([SeamEntry(after, web)[SPDFMacAIActivityLinksKey] isEqual:@[@"https://tea.example.com/prices"]],
          "a redacted entry keeps its link's address but not the title, which can quote the page");
    [session.activity updateEntry:card changes:@{SPDFMacAIActivityStateKey : SPDFMacAIActivityStateDone,
                                                 SPDFMacAIActivityStatusKey : @"Delivered"}];
    NSDictionary* file = [chat.store chatWithID:session.chat[@"id"]];
    CHECK([SeamEntry(file[@"activity"], card)[SPDFMacAIActivityStatusKey] isEqual:@"Delivered"] &&
          ![session liveActivityActionsForEntry:card].count,
          "a card that changes later is saved at once and loses Cancel");

    NSMutableDictionary* edited = [file mutableCopy];
    NSMutableArray* entries = [file[@"activity"] mutableCopy];
    NSMutableDictionary* running = [SeamEntry(entries, card) mutableCopy];
    running[SPDFMacAIActivityStateKey] = SPDFMacAIActivityStateRunning;
    entries[[entries indexOfObject:SeamEntry(entries, card)]] = running;
    [entries addObject:@{@"id" : @"bad", @"kind" : @"script", @"after" : @1}];
    [entries addObject:@{@"id" : @"long", @"kind" : @"step", @"after" : @1,
                         @"title" : [@"" stringByPaddingToLength:900 withString:@"x" startingAtIndex:0]}];
    [entries addObject:@{@"id" : @"elsewhere", @"kind" : @"image", @"after" : @1, @"image" : @{@"path" : @7}}];
    edited[@"activity"] = entries;
    [session loadChat:edited];
    NSArray* reopened = session.chat[@"activity"];
    CHECK([SeamEntry(reopened, card)[SPDFMacAIActivityStateKey] isEqual:SPDFMacAIActivityStateStopped] &&
          [SeamEntry(reopened, card)[SPDFMacAIActivityStatusKey] isEqual:@"See your chat with Mei for delivery"] &&
          ![session liveActivityActionsForEntry:card].count,
          "reopened while running, an entry says what its provider wrote for that case and offers no buttons");
    CHECK(!SeamEntry(reopened, @"bad") && !SeamEntry(reopened, @"elsewhere") &&
          [SeamEntry(reopened, @"long")[SPDFMacAIActivityTitleKey] length] == 200,
          "entries read from a file are validated and clipped");
    NSString* identifier = session.chat[@"id"];
    [session newChat];
    CHECK(![session.chat[@"activity"] count], "a new chat starts without activity");
    CHECK([chat.store deleteChatWithID:identifier error:nil] && ![NSFileManager.defaultManager fileExistsAtPath:saved],
          "deleting a chat deletes its images");
    SPDFMacAIChatActivity* detached = [SPDFMacAIChatActivity new];
    CHECK(![detached addImageAtPath:SeamWritePNG(scratch) caption:@"x" options:SPDFMacAIActivityOptionsNone] &&
          ![session.activity addImageAtPath:SeamWritePNG(scratch) caption:@"quote"
                                    options:SPDFMacAIActivityRequestOnly],
          "an image needs a chat to keep it, and request-only content never becomes a saved file");
    // Friends' 32 KiB of UTF-8: a message from AI chat is refused at the length `/` refuses it, never cut short.
    NSString* whole = [[@"" stringByPaddingToLength:10922 withString:@"中" startingAtIndex:0]
        stringByAppendingString:@"ab"];  // 32,768 bytes
    NSString* longer = [whole stringByAppendingString:@"c"];
    NSString* (^send)(NSString*) = ^NSString*(NSString* body) {
        return [detached addCard:@{SPDFMacAIActivityTitleKey : @"Message for Mei", SPDFMacAIActivityBodyKey : body,
            SPDFMacAIActivityCardKindKey : @"friends.send"} options:SPDFMacAIActivityOptionsNone handler:nil];
    };
    NSString* longest = [@"" stringByPaddingToLength:8001 withString:@"a" startingAtIndex:0];
    NSString* sent = send(whole), *ascii = send(longest);
    NSString* styled = [detached addCard:@{SPDFMacAIActivityTitleKey : @"Quote", SPDFMacAIActivityBodyKey : longer,
        SPDFMacAIActivityBodyStyleKey : SPDFMacAIActivityBodyStyleLiteral} options:SPDFMacAIActivityOptionsNone
                                 handler:nil];
    NSString* table = [detached addCard:@{SPDFMacAIActivityTitleKey : @"Table", SPDFMacAIActivityBodyKey : longest}
                                options:SPDFMacAIActivityOptionsNone handler:nil];
    CHECK([whole lengthOfBytesUsingEncoding:NSUTF8StringEncoding] == 32768 &&
          [SeamEntry(detached.entries, sent)[SPDFMacAIActivityBodyKey] isEqual:whole] &&
          [SeamEntry(detached.entries, ascii)[SPDFMacAIActivityBodyKey] isEqual:longest] && !send(longer) && !styled &&
          [SeamEntry(detached.entries, table)[SPDFMacAIActivityBodyKey] length] == 8000,
          "a literal body holds 32 KiB of UTF-8 whole and refuses more, while a Markdown body is clipped");
    NSString* printed = [@"" stringByPaddingToLength:5000 withString:@"7" startingAtIndex:0];
    NSDictionary* noted = SPDFMacAIActivitySanitizedEntry(@{@"id" : @"o", @"kind" : @"step", @"after" : @0,
        SPDFMacAIActivityOutputKey : printed, SPDFMacAIActivityNoteKey : printed});
    CHECK([noted[SPDFMacAIActivityOutputKey] length] == 4000 && [noted[SPDFMacAIActivityNoteKey] length] == 400,
          "what a run printed is kept up to 4,000 characters and a note up to 400");
    [NSFileManager.defaultManager removeItemAtPath:scratch error:nil];
    [NSFileManager.defaultManager removeItemAtPath:chat.root error:nil];
}
