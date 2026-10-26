// Long tasks (SPDFMacAIChatSessionRecovery.mm, SPDFMacAIChatProgress.h): the owner asked to sort 31 documents into
// groups and rename them, and the chat ended on "The assistant tried to take too many steps at once. Try again." when
// one reply held more than 12 actions, after earlier requests had stopped at 12 steps. A reply's actions all run now
// (up to 64; the rest are asked for again), a request keeps going while it gets somewhere, and nothing it ends on reads
// as an internal limit.
#import "SPDFMacAIChatProgress.h"
#import "SPDFMacAIRequestContext.h"

static NSDictionary* LongTaskTurn(NSString* prefix, NSUInteger count, NSString* name) {
    NSMutableArray* calls=[NSMutableArray array];
    for (NSUInteger index=0;index<count;index++)
        [calls addObject:@{@"id":[NSString stringWithFormat:@"%@-%lu",prefix,index],@"type":@"function",
            @"function":@{@"name":name,@"arguments":[NSString stringWithFormat:@"{\"path\":\"doc:%lu\"}",index]}}];
    return @{@"role":@"assistant",@"content":@"",@"tool_calls":calls};
}
static void CheckProgressGuard(void) {
    SPDFMacAIProgressGuard* guard=[SPDFMacAIProgressGuard new];
    for (NSUInteger step=0;step<40;step++) {
        [guard recordCall:@"rename_document" arguments:@{@"path":@(step)} result:@{@"changed":@YES}];
        CHECK([guard endStep]==SPDFMacAIProgressGoing,"forty steps that each change something keep going");
    }
    guard=[SPDFMacAIProgressGuard new];
    SPDFMacAIProgressVerdict verdict=SPDFMacAIProgressGoing;
    for (int step=0;step<3;step++) {
        [guard recordCall:@"document_job" arguments:@{@"kind":@"export-pdf"} result:@{@"error":@"Show the document"}];
        verdict=[guard endStep];
    }
    CHECK(verdict==SPDFMacAIProgressNudge && [guard.note containsString:@"document_job"] &&
        [guard.note containsString:@"Show the document"],"the third identical failure is pointed out, naming it");
    for (int step=0;step<3;step++) {
        [guard recordCall:@"document_job" arguments:@{@"kind":@"export-pdf"} result:@{@"error":@"Show the document"}];
        verdict=[guard endStep];
    }
    CHECK(verdict==SPDFMacAIProgressStop,"the same failure three more times after being told stops the request");
    guard=[SPDFMacAIProgressGuard new];
    for (int step=0;step<5;step++) {
        [guard recordCall:@"app_controls" arguments:@{@"operation":@"inspect"} result:@{@"menus":@[]}];
        verdict=[guard endStep];
    }
    CHECK(verdict==SPDFMacAIProgressNudge && [guard.note containsString:@"did nothing new"],
        "the same successful read again and again is a stall");
    CHECK([SPDFMacAIProgressSignature(@"x",@{@"b":@1,@"a":@2}) isEqual:SPDFMacAIProgressSignature(@"x",@{@"a":@2,@"b":@1})],
        "a call's signature does not depend on key order");
}
static void CheckLongTasks(NSURL* root) {
    CheckProgressGuard();
    SPDFMacAIChatStore* store=[[SPDFMacAIChatStore alloc] initWithDirectory:root];
    FakeTransport* transport=[FakeTransport new]; FakeTools* tools=[FakeTools new];
    SPDFMacAIChatSession* session=[[SPDFMacAIChatSession alloc] initWithTransport:transport tools:tools
        definitions:@[@{@"type":@"function",@"function":@{@"name":@"organize_groups"}}] store:store];
    // The owner's request, with one reply moving 31 documents at once.
    [session send:@"sort all documents in the general group into groups that make sense" model:@"fake/model"
        apiKey:@"fixture"];
    transport.reply(LongTaskTurn(@"move",31,@"organize_groups"),nil);
    for (NSUInteger index=0;index<31;index++) tools.reply(@{@"changed":@YES,@"undoable":@YES});
    CHECK(tools.calls==31 && session.running && transport.definitions.count,
        "a reply with 31 actions runs all of them and the request goes on");
    CHECK([store chatWithID:session.chat[@"id"]] != nil,"a chat holding a reply with 31 actions still opens");
    // 70 at once: 64 run, the other six are asked for again rather than refused.
    transport.reply(LongTaskTurn(@"more",70,@"organize_groups"),nil);
    for (NSUInteger index=0;index<64;index++) tools.reply(@{@"changed":@YES});
    NSUInteger later=0;
    for (NSDictionary* message in transport.messages)
        if ([message[@"role"] isEqual:@"tool"] && [message[@"content"] containsString:@"Send this call again"]) later++;
    CHECK(tools.calls==95 && later==6 && session.running,"past 64 in one reply, the rest are asked for in the next");
    transport.reply(@{@"content":@"Sorted 31 documents into 5 groups; General is empty."},nil);
    CHECK(session.activityState==SPDFMacAIChatActivityCompleted && !session.canContinue,"the long task completes");
    // A dropped connection is tried again after a pause, and the person reads that it is reconnecting.
    [session send:@"Rename the rest" model:@"fake/model" apiKey:@"fixture"];
    NSUInteger sends=transport.sends;
    transport.reply(nil,[NSError errorWithDomain:@"SPDFMacAI" code:5 userInfo:@{NSLocalizedDescriptionKey:@"down"}]);
    CHECK(session.running && [session.status isEqual:@"Reconnecting…"] && transport.sends==sends,
        "a dropped connection waits, saying it is reconnecting");
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2.5]];
    CHECK(transport.sends==sends+1 && session.running,"then the same request is sent again");
    transport.reply(@{@"content":@"Renamed."},nil);
    CHECK(session.activityState==SPDFMacAIChatActivityCompleted,"and it completes");
    // Too large, cut off, unreadable: asked again with what went wrong; nothing shown to the person.
    [session send:@"Summarize every document" model:@"fake/model" apiKey:@"fixture"];
    for (NSNumber* code in @[@4,@7,@6]) {
        transport.reply(nil,[NSError errorWithDomain:@"SPDFMacAI" code:code.integerValue userInfo:nil]);
        CHECK(session.running && session.activityState!=SPDFMacAIChatActivityError &&
            [transport.messages.lastObject[@"content"] containsString:@"could not be used"],
            "an unusable reply is asked for again within the request");
    }
    [session cancel];
    // Every status a request can end on is written for the person: no internal limit, no bare "Try again".
    for (NSString* forbidden in @[@"too many steps",@"step limit",@"malformed",@"Try again.",@"action budget"]) {
        NSString* source=[NSString stringWithContentsOfFile:@"mac/SPDFMacAIChatSession.mm" encoding:NSUTF8StringEncoding
            error:nil];
        source=[source stringByAppendingString:[NSString stringWithContentsOfFile:@"mac/SPDFMacAIChatSessionCalls.mm"
            encoding:NSUTF8StringEncoding error:nil] ?: @""];
        CHECK(source.length && [source rangeOfString:forbidden options:NSCaseInsensitiveSearch].location==NSNotFound,
            "the chat session never ends on an internal limit's wording");
    }
}
