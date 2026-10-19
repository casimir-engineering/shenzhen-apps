// A provider that reads less than the app expected refuses the request; the chat summarizes once and retries.
static SPDFMacAIChatSession* ContextRetrySession(NSURL* root,FakeTransport* transport,NSString* chatID) {
    SPDFMacAIChatStore* store=[[SPDFMacAIChatStore alloc] initWithDirectory:root];
    NSMutableArray* history=[NSMutableArray array];
    for (NSUInteger i=0;i<3;i++) {
        [history addObject:Turn(@"user",[NSString stringWithFormat:@"Question %lu",(unsigned long)i])];
        [history addObject:Turn(@"assistant",[NSString stringWithFormat:@"Answer %lu",(unsigned long)i])];
    }
    [store saveChat:@{@"id":chatID,@"title":@"Retry",@"messages":history} error:nil];
    SPDFMacAIChatSession* session=CompactionSession(transport,[FakeTools new],store);
    [session loadChat:[store chatWithID:chatID]];
    [session send:@"Next question" model:@"fake/model" apiKey:@"fixture"];
    return session;
}
static void CheckContextLengthRetry(NSURL* root) {
    NSError* tooLong=SPDFMacAIError(SPDFMacAIContextLengthErrorCode,
        @"This conversation no longer fits the selected model.");
    FakeTransport* transport=[FakeTransport new];
    SPDFMacAIChatSession* session=ContextRetrySession(root,transport,NSUUID.UUID.UUIDString);
    CHECK(transport.sends==1 &&
        ![transport.messages.firstObject[@"content"] containsString:@"Summarize the conversation"],
        "a short chat is sent without summarizing first");
    transport.reply(nil,tooLong);
    CHECK(transport.sends==2 && session.running && session.activityState==SPDFMacAIChatActivitySummarizing &&
        [transport.messages.firstObject[@"content"] containsString:@"Summarize the conversation"] &&
        [transport.messages.lastObject[@"content"] containsString:@"Question 0"],
        "a context-length refusal summarizes earlier messages");
    transport.reply(Turn(@"assistant",@"- Earlier questions answered."),nil);
    CHECK(session.currentContext.budget.usedSteps==1,
        "the refused request's step is given back: the retry is the request's one step");
    CHECK(transport.sends==3 &&
        [transport.messages.firstObject[@"content"] containsString:@"Earlier questions answered"] &&
        ![Wire(transport) containsString:@"Question 0"] &&
        [transport.messages.lastObject[@"content"] isEqual:@"Next question"],
        "the question is sent again after the summary");
    transport.reply(Turn(@"assistant",@"Done."),nil);
    CHECK(!session.running && session.activityState==SPDFMacAIChatActivityCompleted &&
        SPDFMacAICompactionSummary(session.chat[@"messages"]),"the retried question gets its answer");
    FakeTransport* refusing=[FakeTransport new];
    SPDFMacAIChatSession* again=ContextRetrySession(root,refusing,NSUUID.UUID.UUIDString);
    refusing.reply(nil,tooLong); refusing.reply(Turn(@"assistant",@"- Summary."),nil);
    CHECK(refusing.sends==3,"the summarized chat is retried");
    refusing.reply(nil,tooLong);
    CHECK(refusing.sends==3 && !again.running && again.activityState==SPDFMacAIChatActivityError &&
        [again.status containsString:@"no longer fits"],"a second refusal stops instead of summarizing again");
}
