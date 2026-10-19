// A summary or an edited question rewrites the chat: activity rows stay beside the messages they followed, rows
// after an edited question go with the replies they belonged to, and a summary is written only from what the chat
// file keeps (what a tool keeps for its request only never reaches the summary that is saved and sent later).
@interface RequestOnlyTools : FakeTools
@end
@implementation RequestOnlyTools
- (NSDictionary*)chatForStorage:(NSDictionary*)chat {
    NSMutableArray* messages=[NSMutableArray array];
    for (NSDictionary* message in chat[@"messages"]) {
        if (![message[@"content"] isKindOfClass:NSString.class] || ![message[@"content"] containsString:@"Mei says"]) {
            [messages addObject:message]; continue;
        }
        NSMutableDictionary* stub=[message mutableCopy]; stub[@"content"]=@"{\"notice\":\"read for one request\"}";
        [messages addObject:[stub copy]];
    }
    NSMutableDictionary* stored=[chat mutableCopy]; stored[@"messages"]=messages; return stored;
}
@end
static NSArray* ActivityAnchors(SPDFMacAIChatSession* session) {
    NSMutableArray* anchors=[NSMutableArray array];
    for (NSDictionary* entry in session.activity.entries)
        [anchors addObject:@[entry[SPDFMacAIActivityIDKey],entry[SPDFMacAIActivityAnchorKey]]];
    return anchors;
}
static void CheckHistoryRewrites(NSURL* root) {
    SPDFMacAIChatStore* store=[[SPDFMacAIChatStore alloc] initWithDirectory:root];
    FakeTransport* transport=[FakeTransport new]; RequestOnlyTools* tools=[RequestOnlyTools new];
    SPDFMacAIChatSession* session=CompactionSession(transport,tools,store);
    NSArray* turns=@[Turn(@"user",@"Ask Mei about the part"),
        @{@"role":@"assistant",@"content":@"",@"tool_calls":@[ToolCall(@"mei")]},
        @{@"role":@"tool",@"tool_call_id":@"mei",@"content":@"Mei says the part ships Friday"},
        Turn(@"assistant",@"It ships at the end of the week."),Turn(@"user",@"And the price?"),
        Turn(@"assistant",@"Not known yet.")];
    NSArray* activity=@[@{@"id":@"early",@"kind":@"card",@"after":@2,@"title":@"Asked Mei"},
        @{@"id":@"late",@"kind":@"card",@"after":@6,@"title":@"Price lookup"}];
    [session loadChat:@{@"id":NSUUID.UUID.UUIDString,@"title":@"Part",@"messages":turns,@"activity":activity}];
    [session compactWithModel:@"fake/model" apiKey:@"fixture"];
    NSString* request=transport.messages.lastObject[@"content"];
    CHECK([request containsString:@"Ask Mei about the part"] && ![request containsString:@"Mei says"],
        "a summary is written from what the chat file keeps, never from what one request alone could read");
    transport.reply(Turn(@"assistant",@"- Asked Mei when the part ships."),nil);
    CHECK([session.chat[@"messages"][4][@"role"] isEqual:@"compaction"] &&
        [ActivityAnchors(session) isEqual:(@[@[@"early",@2],@[@"late",@7]])],
        "after a summary, activity rows stay beside the messages they followed");
    CHECK([session resendFromMessageAtIndex:5 text:@"And the weight?" model:@"fake/model" apiKey:@"fixture"] &&
        [ActivityAnchors(session) isEqual:(@[@[@"early",@2]])],
        "an edited question drops the activity of the replies it replaces");
    [session cancel];
}
