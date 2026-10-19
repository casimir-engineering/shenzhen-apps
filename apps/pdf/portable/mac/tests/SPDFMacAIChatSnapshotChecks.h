#import <Cocoa/Cocoa.h>
static BOOL ChatWait(BOOL (^predicate)(void)) {
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:2];
    while(!predicate() && deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
    return predicate();
}
static void CheckChatSnapshots(NSURL* parent) {
    [NSApplication sharedApplication];
    for(NSNumber* native in @[@0,@1,@2]) {
        fprintf(stderr,"Snapshot fixture path: %ld\n",(long)native.integerValue);
        NSURL* root=[parent URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
        SPDFMacAIChatStore* store=[[SPDFMacAIChatStore alloc] initWithDirectory:root];
        FakeTransport* transport=[FakeTransport new];FakeTools* tools=[FakeTools new];
        SPDFMacAIChatSession* session=[[SPDFMacAIChatSession alloc] initWithTransport:transport tools:tools definitions:@[] store:store];
        NSTextView* composer=[[NSTextView alloc] initWithFrame:NSMakeRect(0,0,320,80)];
        [composer insertText:@"Read this PDF now" replacementRange:NSMakeRange(0,0)];
        NSMutableString* raw=[@"Read this PDF now" mutableCopy];
        NSString* submitted=native.integerValue==1 ? [composer.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] :
            native.integerValue==2 ? composer.string : raw;
        [session send:submitted model:@"fake/model" apiKey:@"fixture"];
        CHECK(session.activityState==SPDFMacAIChatActivityThinking,"submitted request reports thinking");
        NSDictionary* firstSnapshot=session.chat;
        composer.string=@"";[raw setString:@""];
        CHECK([session.chat[@"messages"][0][@"content"] isEqual:@"Read this PDF now"],"clearing native or mutable composer preserves submitted user text");
        NSMutableString* assistant=[@"I'll check the selected document." mutableCopy];
        NSMutableString* identifier=[@"snapshot-call" mutableCopy];
        NSMutableDictionary* call=[@{@"id":identifier,@"type":@"function",@"function":
            [@{@"name":@"read_pages",@"arguments":@"{}"} mutableCopy]} mutableCopy];
        NSMutableArray* calls=[NSMutableArray arrayWithObject:call];
        void (^firstReply)(NSDictionary*,NSError*)=transport.reply;
        dispatch_async(dispatch_get_main_queue(),^{firstReply(@{@"content":assistant,@"tool_calls":calls},nil);});
        CHECK(ChatWait(^BOOL{return tools.calls==1 || !session.running;}) && tools.calls==1,"assistant action persists and starts its tool after draft clearing");
        CHECK(session.activityState==SPDFMacAIChatActivityWorking,"tool execution reports working");
        CHECK([firstSnapshot[@"messages"] count]==1,"published chat snapshots do not grow when session appends");
        [assistant setString:@"Changed externally"];[identifier setString:@"changed-call"];[calls removeAllObjects];
        if(tools.reply) {
            void (^toolReply)(NSDictionary*)=tools.reply;
            dispatch_async(dispatch_get_main_queue(),^{toolReply(@{@"pages":@[@{@"page":@1,@"text":@"Fixture evidence"}]});});
        }
        CHECK(ChatWait(^BOOL{return transport.sends==2 || !session.running;}) && transport.sends==2,
            "asynchronous tool result persists and starts final model request without false conflict");
        if(transport.sends==2) {
            void (^finalReply)(NSDictionary*,NSError*)=transport.reply;
            dispatch_async(dispatch_get_main_queue(),^{finalReply(@{@"content":@"Final answer with evidence"},nil);});
        }
        CHECK(ChatWait(^BOOL{return !session.running;}),"tool loop reaches a terminal state");
        CHECK(session.activityState==SPDFMacAIChatActivityCompleted,"final answer reports completed");
        NSArray* live=session.chat[@"messages"],*saved=[store chatWithID:session.chat[@"id"]][@"messages"];
        CHECK(live.count==4 && [live[0][@"content"] isEqual:@"Read this PDF now"] &&
            [live.lastObject[@"content"] isEqual:@"Final answer with evidence"] && [live isEqual:saved] && !session.status.length,
            "user, assistant tool call, tool result, and final answer remain visible and saved");
        CHECK(([[live valueForKey:@"role"] isEqual:@[@"user",@"assistant",@"tool",@"assistant"]]),"complete persisted tool transcript has expected roles");
        [session cancel];
    }
}

@interface SPDFMacAIChatStore (SnapshotLockTest)
- (int)lockStore:(NSError**)error;
@end
@interface SnapshotMutationStore : SPDFMacAIChatStore
@property(copy) void (^beforeLock)(void);
@end
@implementation SnapshotMutationStore
- (int)lockStore:(NSError**)error {
    if(self.beforeLock)self.beforeLock();
    return [super lockStore:error];
}
@end
static void CheckStoreSnapshot(NSURL* root) {
    SnapshotMutationStore* store=[[SnapshotMutationStore alloc] initWithDirectory:root];
    NSMutableString* content=[@"Committed" mutableCopy];
    NSMutableArray* messages=[NSMutableArray arrayWithObject:@{@"role":@"user",@"content":content}];
    NSMutableDictionary* chat=[@{@"id":NSUUID.UUID.UUIDString,@"messages":messages} mutableCopy];
    CHECK([store saveChat:chat error:nil],"snapshot fixture commits initial user");
    [messages addObject:@{@"role":@"assistant",@"content":@"Answer"}];
    store.beforeLock=^{[content setString:@"Caller changed while waiting for the lock"];};
    CHECK([store saveChat:chat error:nil],"store compares serialized snapshot even if caller mutates before lock acquisition");
    store.beforeLock=nil;
    NSDictionary* loaded=[store chatWithID:chat[@"id"]];
    CHECK([loaded[@"messages"] count]==2 && [loaded[@"messages"][0][@"content"] isEqual:@"Committed"],"committed bytes equal the checked prefix");
    FakeTransport* transport=[FakeTransport new];FakeTools* tools=[FakeTools new];
    SPDFMacAIChatSession* session=[[SPDFMacAIChatSession alloc] initWithTransport:transport tools:tools definitions:@[] store:store];
    [session loadChat:loaded];
    [loaded[@"messages"][0] setObject:@"Outside mutation" forKey:@"content"];
    CHECK([session.chat[@"messages"][0][@"content"] isEqual:@"Committed"],"loaded transcript owns immutable nested messages");
}

static void CheckSessionConflict(NSURL* root) {
    SPDFMacAIChatStore* store=[[SPDFMacAIChatStore alloc] initWithDirectory:root];
    FakeTransport* transport=[FakeTransport new];FakeTools* tools=[FakeTools new];
    SPDFMacAIChatSession* session=[[SPDFMacAIChatSession alloc] initWithTransport:transport tools:tools definitions:@[] store:store];
    [session send:@"Inspect" model:@"fake/model" apiKey:@"fixture"];
    NSMutableDictionary* competing=[session.chat mutableCopy];
    competing[@"messages"]=[competing[@"messages"] arrayByAddingObject:@{@"role":@"assistant",@"content":@"Other window"}];
    CHECK([store saveChat:competing error:nil],"other window commits its answer");
    transport.reply(@{@"content":@"I will inspect",@"tool_calls":@[@{@"id":@"conflict",@"function":
        @{@"name":@"read_pages",@"arguments":@"{}"}}]},nil);
    CHECK(!session.running && session.activityState==SPDFMacAIChatActivityError && tools.calls==0,
        "genuine competing append stops before tool execution and reports error");
    CHECK([[[store chatWithID:competing[@"id"]][@"messages"] lastObject][@"content"] isEqual:@"Other window"],
        "conflict leaves the other window's saved answer intact");
}
