// Context budget, compaction and edit-and-resend checks for the chat session.
#import "SPDFMacAIChatBudget.h"
static NSDictionary* ToolCall(NSString* identifier) {
    return @{@"id":identifier,@"type":@"function",@"function":@{@"name":@"read_pages",@"arguments":@"{}"}};
}
static NSString* Words(NSString* prefix,NSUInteger length) {
    return [[prefix stringByAppendingString:@" "] stringByPaddingToLength:length withString:@"evidence "
        startingAtIndex:0];
}
static NSDictionary* Turn(NSString* role,NSString* content) { return @{@"role":role,@"content":content}; }
static SPDFMacAIChatSession* CompactionSession(FakeTransport* transport,FakeTools* tools,SPDFMacAIChatStore* store) {
    return [[SPDFMacAIChatSession alloc] initWithTransport:transport tools:tools definitions:@[] store:store];
}
static NSString* Wire(FakeTransport* transport) { return [transport.messages componentsJoinedByString:@" "]; }
// Every tool result stays on the same side of the cut as the call that produced it.
static BOOL CutKeepsToolPairs(NSArray* messages,NSUInteger cut) {
    NSMutableDictionary* callIndex=[NSMutableDictionary dictionary];
    for (NSUInteger i=0;i<messages.count;i++) {
        for (NSDictionary* call in messages[i][@"tool_calls"]) callIndex[call[@"id"]]=@(i);
        if (![messages[i][@"role"] isEqual:@"tool"]) continue;
        NSUInteger call=[callIndex[messages[i][@"tool_call_id"]] unsignedIntegerValue];
        if ((call<cut)!=(i<cut)) return NO;
    }
    return YES;
}
static void CheckBudgetMath(void) {
    CHECK(SPDFMacAIContextTokens(0)==SPDFMacAIDefaultContextTokens && SPDFMacAIDefaultContextTokens>=128000,
        "unknown models get a large default window");
    CHECK(SPDFMacAIContextTokens(1048576)==1000000 && SPDFMacAIContextTokens(200000)==200000 &&
        SPDFMacAIContextTokens(1000)==16384,"catalog windows are used, within sane bounds");
    NSUInteger large=SPDFMacAIInputBudget(1000000), standard=SPDFMacAIInputBudget(0);
    CHECK(large>950000 && standard>100000 && standard<128000,"input budget keeps room for the reply");
    CHECK(SPDFMacAICompactionThreshold(standard)<standard && SPDFMacAICompactionThreshold(standard)>standard/2,
        "automatic compaction starts before the budget is reached");
    CHECK(SPDFMacAIToolResultLimit(SPDFMacAIInputBudget(16384))*2/3<SPDFMacAIInputBudget(16384) &&
        SPDFMacAIToolResultLimit(large)>=SPDFMacAIToolResultLimit(standard),
        "one tool result never fills a small window");
    NSString* bulk=Words(@"bulk",9000);
    NSArray* messages=@[Turn(@"user",@"First question"),
        @{@"role":@"assistant",@"content":@"",@"tool_calls":@[ToolCall(@"a"),ToolCall(@"b")]},
        @{@"role":@"tool",@"tool_call_id":@"a",@"content":bulk},@{@"role":@"tool",@"tool_call_id":@"b",@"content":bulk},
        @{@"role":@"assistant",@"content":@"",@"tool_calls":@[ToolCall(@"c")]},
        @{@"role":@"preview",@"local":@YES,@"preview":@{@"caption":@"Page 2"},@"tool_call_id":@"c"},
        @{@"role":@"tool",@"tool_call_id":@"c",@"content":bulk},
        Turn(@"assistant",@"First answer"),Turn(@"user",@"Second question"),
        @{@"role":@"assistant",@"content":@"",@"tool_calls":@[ToolCall(@"d")]},
        @{@"role":@"tool",@"tool_call_id":@"d",@"content":bulk},Turn(@"assistant",@"Second answer")];
    BOOL paired=YES, verbatimTail=YES;
    for (NSUInteger keep=0;keep<=20000;keep+=250) {
        NSUInteger cut=SPDFMacAICompactionCut(messages,keep);
        if (cut==NSNotFound || !cut || cut>=messages.count) { paired=NO; break; }
        NSString* role=messages[cut][@"role"];
        paired=paired && CutKeepsToolPairs(messages,cut) && ([role isEqual:@"user"] || [role isEqual:@"assistant"]);
        if (keep>=8000) verbatimTail=verbatimTail && cut<=8;
    }
    CHECK(paired,"compaction cuts land on turns and never split a tool call from its result");
    CHECK(verbatimTail,"recent turns that fit stay verbatim");
    CHECK(SPDFMacAICompactionCut(messages,4000)==8,"cuts prefer the start of a user turn");
    CHECK(SPDFMacAIManualCompactionCut(messages)==8 &&
        SPDFMacAIManualCompactionCut(@[Turn(@"user",@"Only"),Turn(@"assistant",@"One")])==NSNotFound,
        "manual compaction keeps the latest question and needs an earlier turn");
    NSString* padding=[@"" stringByPaddingToLength:600 withString:@"." startingAtIndex:0];
    NSString* cited=[NSString stringWithFormat:@"{\"pages\":[{\"citation\":"
        "\"spdf-ai://document?path=doc:x&page=2&revision=r\",\"text\":\"long\"}],\"padding\":\"%@\"}",padding];
    NSMutableArray* withCitation=[messages mutableCopy];
    withCitation[2]=@{@"role":@"tool",@"tool_call_id":@"a",@"content":cited};
    NSArray* compacted=SPDFMacAICompactedMessages(withCitation,8,@"Earlier: the board needs 5 V.");
    CHECK(compacted.count==messages.count+1 && [compacted[8][@"role"] isEqual:@"compaction"] &&
        [compacted[9][@"content"] isEqual:@"Second question"],"one summary marker replaces the summarized span");
    CHECK(SPDFMacAICompactionStart(compacted)==9 && [SPDFMacAICompactionSummary(compacted) containsString:@"5 V"],
        "the newest summary and its verbatim tail are found");
    CHECK([compacted[3][@"content"] length]<1000 && [compacted[2][@"content"] containsString:@"page=2"] &&
        SPDFMacAIChatContainsCitation(@{@"messages":compacted},
            SPDFMacAICitationArguments([NSURL URLWithString:@"spdf-ai://document?path=doc:x&page=2&revision=r"])),
        "summarized tool results shrink but their citations stay verifiable");
    NSString* input=SPDFMacAICompactionInput(messages,8,4000);
    CHECK(input && SPDFMacAIEstimateTokens(input)<=4000 && [input containsString:@"First question"] &&
        ![input containsString:@"Second question"],"summarizer input clips bulky results to fit and stops at the cut");
    CHECK(!SPDFMacAICompactionInput(messages,8,20),"input that cannot fit is refused");
}
static NSDictionary* StoredChat(NSURL* root,NSArray* messages) {
    NSDictionary* chat=@{@"id":NSUUID.UUID.UUIDString,@"title":@"Long chat",@"messages":messages};
    [[[SPDFMacAIChatStore alloc] initWithDirectory:root] saveChat:chat error:nil];
    return chat;
}
static void CheckAutomaticCompaction(NSURL* root) {
    SPDFMacAIChatStore* store=[[SPDFMacAIChatStore alloc] initWithDirectory:root];
    NSMutableArray* history=[NSMutableArray array];
    for (NSUInteger i=0;i<4;i++) {
        [history addObject:Turn(@"user",Words([NSString stringWithFormat:@"Question %lu",(unsigned long)i],3000))];
        [history addObject:Turn(@"assistant",Words([NSString stringWithFormat:@"Answer %lu",(unsigned long)i],3000))];
    }
    NSDictionary* chat=StoredChat(root,history);
    FakeTransport* transport=[FakeTransport new]; FakeTools* tools=[FakeTools new];
    SPDFMacAIChatSession* session=CompactionSession(transport,tools,store);
    session.contextTokens=16384; [session loadChat:[store chatWithID:chat[@"id"]]];
    [session send:@"Next question" model:@"fake/model" apiKey:@"fixture"];
    CHECK(transport.sends==1 &&
        [transport.messages.firstObject[@"content"] containsString:@"Summarize the conversation"] &&
        [transport.messages.lastObject[@"content"] containsString:@"Question 0"] && !transport.definitions,
        "a chat near its budget is summarized by the model first, without tools");
    CHECK(session.activityState==SPDFMacAIChatActivitySummarizing && session.running,
        "the chat says it is summarizing earlier messages");
    NSString* summary=@"- Earlier: the board needs 5 V (spdf-ai://document?path=doc:x&page=2&revision=r).";
    transport.reply(Turn(@"assistant",summary),nil);
    NSArray* messages=session.chat[@"messages"]; NSUInteger marker=SPDFMacAICompactionStart(messages);
    CHECK(transport.sends==2 && marker>1 && [messages[marker-1][@"role"] isEqual:@"compaction"] &&
        [messages[marker][@"role"] isEqual:@"user"],"one summary replaces older turns at a question boundary");
    NSString* system=transport.messages.firstObject[@"content"];
    CHECK([system containsString:@"board needs 5 V"] && ![Wire(transport) containsString:@"Question 0"] &&
        [transport.messages.lastObject[@"content"] isEqual:@"Next question"] &&
        [Wire(transport) containsString:@"Answer 3"],
        "the model sees the summary, recent turns verbatim, and no summarized message");
    CHECK([[store chatWithID:chat[@"id"]][@"messages"] isEqual:messages],"the summary is saved with the chat");
    transport.reply(Turn(@"assistant",@"Done."),nil);
    CHECK(!session.running && session.activityState==SPDFMacAIChatActivityCompleted,
        "the reply completes after compaction");
    NSDictionary* reopened=[store chatWithID:chat[@"id"]];
    CHECK(reopened && [reopened[@"messages"] isEqual:session.chat[@"messages"]],
        "a saved chat with a summary reloads intact");
    SPDFMacAIChatSession* again=CompactionSession(transport,tools,store);
    again.contextTokens=16384; [again loadChat:reopened]; NSUInteger sends=transport.sends;
    [again send:@"Short follow-up" model:@"fake/model" apiKey:@"fixture"];
    CHECK(transport.sends==sends+1 && [transport.messages.firstObject[@"content"] containsString:@"board needs 5 V"] &&
        ![Wire(transport) containsString:@"Question 0"],"a reopened chat continues from its saved summary");
    [again cancel];
    NSMutableArray* split=[history mutableCopy];
    [split addObject:@{@"role":@"assistant",@"content":@"",@"tool_calls":@[ToolCall(@"open")]}];
    [split addObject:@{@"role":@"compaction",@"local":@YES,@"summary":@"Summary"}];
    [split addObject:@{@"role":@"tool",@"tool_call_id":@"open",@"content":@"{}"}];
    CHECK(![store chatWithID:StoredChat(root,split)[@"id"]],
        "a saved summary between an action and its result is rejected");
    SPDFMacAIChatSession* failing=CompactionSession(transport,tools,store);
    failing.contextTokens=16384; [failing loadChat:[store chatWithID:StoredChat(root,history)[@"id"]]];
    [failing send:@"Next question" model:@"fake/model" apiKey:@"fixture"];
    transport.reply(nil,SPDFMacAIError(9,@"offline"));
    CHECK(!SPDFMacAICompactionSummary(failing.chat[@"messages"]) && [failing.chat[@"messages"] count]==history.count+1,
        "a failed summary leaves the transcript unchanged");
    [failing cancel];
}
static void CheckManualCompaction(NSURL* root) {
    SPDFMacAIChatStore* store=[[SPDFMacAIChatStore alloc] initWithDirectory:root];
    FakeTransport* transport=[FakeTransport new]; FakeTools* tools=[FakeTools new];
    SPDFMacAIChatSession* session=CompactionSession(transport,tools,store);
    NSDictionary* single=StoredChat(root,@[Turn(@"user",@"Only"),Turn(@"assistant",@"One")]);
    [session loadChat:[store chatWithID:single[@"id"]]];
    CHECK(!session.canCompact,"a single turn has nothing earlier to summarize");
    NSArray* turns=@[Turn(@"user",@"Plan the review"),Turn(@"assistant",@"Step one."),
        Turn(@"user",@"Add the costs"),Turn(@"assistant",@"Costs added.")];
    NSDictionary* chat=StoredChat(root,turns);
    [session loadChat:[store chatWithID:chat[@"id"]]];
    CHECK(session.canCompact,"earlier turns can be summarized on request");
    [session compactWithModel:@"fake/model" apiKey:@"fixture"];
    NSString* request=transport.messages.lastObject[@"content"];
    CHECK(session.running && !session.canCompact && [request containsString:@"Plan the review"] &&
        ![request containsString:@"Add the costs"],"manual summary covers turns before the latest question");
    transport.reply(nil,SPDFMacAIError(9,@"offline"));
    CHECK(!session.running && session.activityState==SPDFMacAIChatActivityError &&
        [session.chat[@"messages"] isEqual:turns],"a failed manual summary keeps the chat unchanged");
    [session compactWithModel:@"fake/model" apiKey:@"fixture"];
    transport.reply(Turn(@"assistant",@"- Review plan agreed."),nil);
    NSArray* messages=session.chat[@"messages"];
    CHECK(!session.running && messages.count==5 && [messages[2][@"role"] isEqual:@"compaction"] &&
        [messages[3][@"content"] isEqual:@"Add the costs"] && [session.status isEqual:@"Earlier messages summarized."],
        "manual summary inserts one marker before the latest question");
    CHECK([[store chatWithID:chat[@"id"]][@"messages"] isEqual:messages],"manual summary is saved");
}
// A page picture the chat saved, as a page render leaves one for it.
static NSDictionary* SavedPicture(SPDFMacAIChatStore* store,NSString* chatID) {
    NSString* temp=[NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"ShenzhenPDF-AI-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:temp withIntermediateDirectories:YES attributes:nil error:nil];
    const unsigned char bytes[]={137,80,78,71,13,10,26,10};
    NSString* png=[temp stringByAppendingPathComponent:@"page.png"];
    [[NSData dataWithBytes:bytes length:sizeof(bytes)] writeToFile:png atomically:YES];
    NSDictionary* saved=[store savePreview:@{@"path":png,@"caption":@"Page 1"} chatID:chatID];
    return @{@"role":@"preview",@"local":@YES,@"preview":saved ?: @{}};
}
static void CheckEditRemovesDiscardedPictures(NSURL* root) {
    SPDFMacAIChatStore* store=[[SPDFMacAIChatStore alloc] initWithDirectory:root];
    SPDFMacAIChatSession* session=CompactionSession([FakeTransport new],[FakeTools new],store);
    NSString* chatID=NSUUID.UUID.UUIDString;
    NSDictionary* kept=SavedPicture(store,chatID), *discarded=SavedPicture(store,chatID);
    NSDictionary* chat=@{@"id":chatID,@"title":@"Pictures",@"messages":@[Turn(@"user",@"Show page 1"),kept,
        Turn(@"assistant",@"Here it is."),Turn(@"user",@"Show it again"),discarded,Turn(@"assistant",@"Again.")]};
    CHECK([store saveChat:chat error:nil],"picture fixture saved");
    NSString* assets=[kept[@"preview"][@"path"] stringByDeletingLastPathComponent];
    NSString* note=[assets stringByAppendingPathComponent:@"notes.txt"];
    [@"not a picture" writeToFile:note atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [session loadChat:[store chatWithID:chatID]];
    CHECK([session resendFromMessageAtIndex:3 text:@"Show page 2" model:@"fake/model" apiKey:@"fixture"],
        "a question after a picture is edited");
    NSFileManager* files=NSFileManager.defaultManager;
    CHECK([files fileExistsAtPath:kept[@"preview"][@"path"]] &&
        ![files fileExistsAtPath:discarded[@"preview"][@"path"]],
        "an edit removes the pictures of the replies it discards and keeps the ones still shown");
    CHECK([files fileExistsAtPath:note],"only pictures the chat saved are ever removed");
}
static void CheckEditAndResend(NSURL* root) {
    CheckEditRemovesDiscardedPictures(root);
    SPDFMacAIChatStore* store=[[SPDFMacAIChatStore alloc] initWithDirectory:root];
    FakeTransport* transport=[FakeTransport new]; FakeTools* tools=[FakeTools new];
    SPDFMacAIChatSession* session=CompactionSession(transport,tools,store);
    NSArray* turns=@[Turn(@"user",@"Compare the boards"),Turn(@"assistant",@"Board A is larger."),
        Turn(@"user",@"Which uses less power?"),
        @{@"role":@"assistant",@"content":@"",@"tool_calls":@[ToolCall(@"power")]},
        @{@"role":@"tool",@"tool_call_id":@"power",@"content":@"{\"pages\":[]}"},
        @{@"role":@"compaction",@"local":@YES,@"summary":@"Boards compared; power asked."},
        Turn(@"user",@"And the price?"),Turn(@"assistant",@"Board B is cheaper.")];
    NSDictionary* chat=StoredChat(root,turns);
    [session loadChat:[store chatWithID:chat[@"id"]]];
    CHECK(![session resendFromMessageAtIndex:1 text:@"Not a question" model:@"fake/model" apiKey:@"fixture"] &&
        [session.chat[@"messages"] isEqual:turns],"only your own messages can be edited");
    CHECK([session resendFromMessageAtIndex:2 text:@"Which runs cooler?" model:@"fake/model" apiKey:@"fixture"],
        "an earlier question can be edited and sent again");
    NSArray* messages=session.chat[@"messages"];
    CHECK(messages.count==3 && [messages[2][@"content"] isEqual:@"Which runs cooler?"] && session.running &&
        !SPDFMacAICompactionSummary(messages),
        "everything after the edited question is discarded, including later summaries");
    CHECK([transport.messages.lastObject[@"content"] isEqual:@"Which runs cooler?"] &&
        ![Wire(transport) containsString:@"price"],"the model restarts from the edited question");
    CHECK([[store chatWithID:chat[@"id"]][@"messages"] isEqual:messages],"the shortened history is saved");
    void (^stale)(NSDictionary*,NSError*)=transport.reply;
    CHECK([session resendFromMessageAtIndex:0 text:@"Compare only power" model:@"fake/model" apiKey:@"fixture"] &&
        [session.chat[@"messages"] count]==1,"editing while a reply is in progress stops it first");
    stale(Turn(@"assistant",@"Late reply"),nil);
    CHECK([session.chat[@"messages"] count]==1 && session.running,"the stopped reply cannot reappear");
    transport.reply(Turn(@"assistant",@"Board B uses less power."),nil);
    NSDictionary* reopened=[store chatWithID:chat[@"id"]];
    CHECK([reopened[@"messages"] count]==2 && [reopened[@"messages"][0][@"content"] isEqual:@"Compare only power"] &&
        [reopened[@"messages"][1][@"content"] isEqual:@"Board B uses less power."],
        "the edited chat reloads from its new history");
    SPDFMacAIChatStore* otherWindow=[[SPDFMacAIChatStore alloc] initWithDirectory:root];
    NSMutableDictionary* newer=[reopened mutableCopy];
    newer[@"messages"]=[reopened[@"messages"] arrayByAddingObject:Turn(@"user",@"From another window")];
    [otherWindow saveChat:newer error:nil];
    CHECK(![session resendFromMessageAtIndex:0 text:@"Overwrite" model:@"fake/model" apiKey:@"fixture"] &&
        [[store chatWithID:chat[@"id"]][@"messages"] count]==3,"an edit never erases messages saved by another window");
}
