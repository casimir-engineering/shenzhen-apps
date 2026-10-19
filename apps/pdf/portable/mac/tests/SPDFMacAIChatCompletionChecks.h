static void CheckChatCompletion(NSURL* root) {
    SPDFMacAIChatStore* store=[[SPDFMacAIChatStore alloc] initWithDirectory:root];
    FakeTransport* transport=[FakeTransport new]; FakeTools* tools=[FakeTools new];
    SPDFMacAIChatSession* session=[[SPDFMacAIChatSession alloc] initWithTransport:transport tools:tools
        definitions:@[@{@"type":@"function"}] store:store];
    CHECK(!transport.sends,"title generation adds no request to construction");
    [session send:@"Test empty reply" model:@"fake/model" apiKey:@"fixture"];
    transport.reply(@{@"content":@"  "},nil);
    CHECK(!session.running && session.activityState==SPDFMacAIChatActivityError && [session.chat[@"messages"] count]==1,
        "empty response never persists a blank assistant bubble or reports completion");
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
    for (NSNumber* wrapFailure in @[@NO,@YES]) {
        [session newChat]; [session send:@"Rewrite generated chapters" model:@"fake/model" apiKey:@"fixture"];
        for (NSUInteger index=0;index<12;index++) {
            transport.reply(@{@"content":@"",@"tool_calls":@[@{@"id":[NSString stringWithFormat:@"step-%lu",index],
                @"function":@{@"name":@"update_document_metadata",@"arguments":@"{}"}}]},nil);
            tools.reply(index==11 ? @{@"changed":@YES} : @{@"error":@"Analysis is pending"});
        }
        CHECK(session.running && !transport.definitions.count,"last successful action gets a bounded tools-disabled final response");
        CHECK([transport.messages.lastObject[@"content"] containsString:@"action budget is exhausted"],"wrap-up must explain results instead of retrying actions");
        if (wrapFailure.boolValue) {
            NSUInteger calls=tools.calls;
            transport.reply(@{@"content":@"Retry",@"tool_calls":@[@{@"id":@"forbidden",@"function":
                @{@"name":@"update_document_metadata",@"arguments":@"{}"}}]},nil);
            CHECK(!session.running && session.activityState==SPDFMacAIChatActivityPaused &&
                [session.status containsString:@"Changes saved"] && tools.calls==calls,
                "exhausted budget retains success without reporting Error or executing another tool");
        } else {
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
        }
    }
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
