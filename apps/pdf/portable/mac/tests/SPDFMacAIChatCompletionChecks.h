static void CheckChatCompletion(NSURL* root) {
    SPDFMacAIChatStore* store=[[SPDFMacAIChatStore alloc] initWithDirectory:root];
    FakeTransport* transport=[FakeTransport new]; FakeTools* tools=[FakeTools new];
    SPDFMacAIChatSession* session=[[SPDFMacAIChatSession alloc] initWithTransport:transport tools:tools
        definitions:@[@{@"type":@"function"}] store:store];
    CHECK(!transport.sends,"title generation adds no request to construction");
    [session send:@"Test empty reply" model:@"fake/model" apiKey:@"fixture"];
    transport.reply(@{@"content":@"  "},nil);
    CHECK(session.running && [session.chat[@"messages"] count]==1 && transport.definitions.count &&
        [transport.messages.lastObject[@"content"] containsString:@"it was empty"],
        "an empty reply is never kept as a blank bubble; the model is asked again, told why");
    for (int attempt=0;attempt<3;attempt++) transport.reply(@{@"content":@""},nil);
    CHECK(session.running && !transport.definitions.count,"replies that stay empty wind the request up");
    transport.reply(@{@"content":@""},nil);
    CHECK(!session.running && session.activityState==SPDFMacAIChatActivityPaused && session.canContinue &&
        [session.chat[@"messages"] count]==2 && [[session.chat[@"messages"] lastObject][@"content"]
        containsString:@"Press Continue"],"when even the wind-up is empty the app says so itself and offers Continue");
    [session newChat];[session send:@"Read evidence" model:@"fake/model" apiKey:@"fixture"];
    transport.reply(@{@"content":@"\n\n",@"tool_calls":@[@{@"id":@"blank-round",@"function":@{@"name":@"read_pages",@"arguments":@"{}"}}]},nil);
    CHECK([session.chat[@"messages"][1][@"content"] isEqual:@""] && [session.chat[@"messages"][1][@"tool_calls"] count]==1,
        "whitespace narration is normalized while the tool call remains intact");
    tools.reply(@{@"pages":@[]});
    CHECK([transport.messages[2][@"tool_calls"] count]==1 && [transport.messages[3][@"role"] isEqual:@"tool"],
        "normalization preserves tool call/result protocol on continuation");
    transport.reply(@{@"content":@"  The real answer stays.\n"},nil);
    CHECK([[session.chat[@"messages"] lastObject][@"content"] isEqual:@"  The real answer stays.\n"],
        "meaningful assistant text is preserved verbatim");
    // The same failing call again and again: the model is told after three, and the request winds up after three
    // more, saying what was done and what is left, with Continue.
    for (NSNumber* wrapFailure in @[@NO,@YES]) {
        [session newChat]; [session send:@"Rewrite generated chapters" model:@"fake/model" apiKey:@"fixture"];
        for (NSUInteger index=0;index<7;index++) {
            transport.reply(@{@"content":@"",@"tool_calls":@[@{@"id":[NSString stringWithFormat:@"step-%lu",index],
                @"function":@{@"name":@"update_document_metadata",@"arguments":@"{}"}}]},nil);
            tools.reply(index==0 ? @{@"changed":@YES} : @{@"error":@"Analysis is pending"});
            if (index==3) CHECK(session.running && transport.definitions.count &&
                [transport.messages.lastObject[@"content"] containsString:@"has failed 3 times"] &&
                [transport.messages.lastObject[@"content"] containsString:@"Analysis is pending"] &&
                [transport.messages.lastObject[@"content"] containsString:@"Change approach"],
                "a call failing the same way three times is pointed out to the model, which keeps its tools");
        }
        CHECK(session.running && !transport.definitions.count,"a loop that goes on gets one reply without tools");
        CHECK([transport.messages.lastObject[@"content"] containsString:@"what is still left"] &&
            [transport.messages.lastObject[@"content"] containsString:@"stops here"],
            "the wind-up asks what was done and what is left, and says why");
        NSUInteger calls=tools.calls;
        transport.reply(wrapFailure.boolValue ? @{@"content":@"",@"tool_calls":@[@{@"id":@"forbidden",@"function":
            @{@"name":@"update_document_metadata",@"arguments":@"{}"}}]} :
            @{@"content":@"- Updated chapter 1.\n- Left: chapters 2-5, analysis still pending."},nil);
        CHECK(!session.running && session.activityState==SPDFMacAIChatActivityPaused && session.canContinue &&
            [session.status containsString:@"Changes so far are kept"] && tools.calls==calls &&
            [[session.chat[@"messages"] lastObject][@"content"] length],
            "a wound-up request keeps its success, runs nothing more, and offers Continue with an answer");
    }
    // The ceiling: a request still making progress pauses there with an answer and Continue.
    [session newChat];
    [session sendContext:[[SPDFMacAIRequestContext alloc] initWithText:@"Read every page" chips:nil
        origin:SPDFMacAIRequestOriginChat friendConversation:nil settings:nil
        budget:[[SPDFMacAIRequestBudget alloc] initWithSteps:3 tokens:1000000 toolCalls:NSUIntegerMax]
        activity:session.activity] model:@"fake/model" apiKey:@"fixture"];
    for (NSUInteger index=0;index<3;index++) {
        transport.reply(@{@"content":@"",@"tool_calls":@[@{@"id":[NSString stringWithFormat:@"page-%lu",index],
            @"function":@{@"name":@"read_pages",@"arguments":[NSString stringWithFormat:@"{\"page\":%lu}",index+1]}}]},nil);
        tools.reply(@{@"pages":@[]});
    }
    CHECK(session.running && !transport.definitions.count,"reaching the ceiling gets one reply without tools");
    transport.reply(@{@"content":@"Read pages 1-3; 4-9 are left."},nil);
    CHECK(session.activityState==SPDFMacAIChatActivityPaused && session.canContinue,"then Continue is offered");
    // A plain answer completes and gets a title.
    [session newChat]; [session send:@"Rewrite generated chapters" model:@"fake/model" apiKey:@"fixture"];
    transport.reply(@{@"content":@"Updated the chapters."},nil);
    CHECK(!session.running && session.activityState==SPDFMacAIChatActivityCompleted && !session.status.length,
        "successful final update clears stale error and completes normally");
    CHECK([transport.messages.firstObject[@"content"] containsString:@"plain title"] && !transport.definitions.count,
        "title request starts only after answer completes and cannot use tools");
    transport.reply(@{@"content":@"Rewrite circuit board chapter titles"},nil);
    CHECK([session.chat[@"title"] isEqual:@"Rewrite circuit board chapter titles"] &&
        [[store chatWithID:session.chat[@"id"]][@"title"] isEqual:session.chat[@"title"]],
        "summarized title updates live chat and persistent history");
    [session send:@"Thanks" model:@"fake/model" apiKey:@"fixture"];
    NSUInteger sends=transport.sends;transport.reply(@{@"content":@"Done."},nil);
    CHECK(transport.sends==sends,"already titled chat makes no additional title request");
    [session newChat];[session send:@"Explain the board" model:@"fake/model" apiKey:@"fixture"];
    transport.reply(@{@"content":@"It is a circuit board."},nil);
    void (^lateTitle)(NSDictionary*,NSError*)=transport.reply;
    [session newChat];lateTitle(@{@"content":@"Late title must be ignored"},nil);
    CHECK([session.chat[@"title"] isEqual:@"New chat"],"switching chats cancels and rejects late title results");
    [session send:@"Rename race" model:@"fake/model" apiKey:@"fixture"];
    transport.reply(@{@"content":@"Answer."},nil);
    NSString* identifier=session.chat[@"id"];
    CHECK([store renameChat:identifier title:@"My chosen title" error:nil],"user can rename while suggested title is in flight");
    transport.reply(@{@"content":@"Model proposed title"},nil);
    CHECK([[store chatWithID:identifier][@"title"] isEqual:@"My chosen title"],"automatic title cannot overwrite user's name");
}
