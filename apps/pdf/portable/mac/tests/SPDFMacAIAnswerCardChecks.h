#import "SPDFMacAIAnswerCard.h"
static void CheckAnswerCards(NSURL* root) {
    SPDFMacAIChatStore* store=[[SPDFMacAIChatStore alloc] initWithDirectory:root];
    FakeTransport* transport=[FakeTransport new]; FakeTools* tools=[FakeTools new];
    SPDFMacAIChatSession* session=[[SPDFMacAIChatSession alloc] initWithTransport:transport tools:tools definitions:@[] store:store];
    CHECK(!transport.sends && !tools.contextReads && ![NSFileManager.defaultManager fileExistsAtPath:root.path],"answer card support is inert before a question");
    [session send:@"Give the result" model:@"test" apiKey:@"test"];
    CHECK([transport.definitions.lastObject[@"function"][@"name"] isEqual:@"present_answer"],"model receives the answer card tool");
    NSString* link=@"spdf-ai://document?path=doc:fixture&page=1&revision=v1";
    transport.reply(@{@"content":@"",@"tool_calls":@[@{@"id":@"read",@"function":@{@"name":@"read_pages",@"arguments":@"{}"}}]},nil);
    tools.reply(@{@"pages":@[@{@"citation":link}]});
    NSDictionary* card=@{@"label":@"Full range travel",@"value":@"3.1 mm",@"citation":link};
    CHECK(SPDFMacAIValidatedAnswerCard(card,session.chat)!=nil,"card accepts exact retrieved evidence");
    for(NSDictionary* invalid in @[@{@"label":@"Result",@"value":@"4",@"citation":[link stringByAppendingString:@"&query=invented"]},
        @{@"label":@"Result",@"value":[@"x" stringByPaddingToLength:49 withString:@"x" startingAtIndex:0],@"citation":link},
        @{@"label":@"Result",@"value":@"a\nb",@"citation":link}, @{@"label":@"Result",@"value":@"4"}])
        CHECK(!SPDFMacAIValidatedAnswerCard(invalid,session.chat),"cards reject oversized, multiline and unsupported evidence payloads");
    NSData* data=[NSJSONSerialization dataWithJSONObject:card options:0 error:nil];
    NSUInteger sends=transport.sends;
    transport.reply(@{@"content":@"",@"tool_calls":@[@{@"id":@"answer",@"function":@{@"name":@"present_answer",@"arguments":[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]}}]},nil);
    CHECK(!session.running && session.activityState==SPDFMacAIChatActivityCompleted,"card is a completed final answer");
    CHECK([[session.chat[@"messages"] lastObject][@"answerCard"] isEqual:card],"validated card persists as an assistant answer");
    CHECK(tools.calls==1 && transport.sends<=sends+1,"card bypasses document tools and needs no additional answer request");
    NSDictionary* saved=[store chatWithID:session.chat[@"id"]];
    CHECK([[saved[@"messages"] lastObject][@"answerCard"] isEqual:card],"saved chat restores structured card");
    CHECK([store chatsMatchingQuery:@"3.1"].count==1,"card value is searchable in chat history");
    [session loadChat:saved];[session send:@"Explain" model:@"test" apiKey:@"test"];
    BOOL leaked=NO; for(NSDictionary* message in transport.messages)if(message[@"answerCard"])leaked=YES;
    CHECK(!leaked,"provider sees normal text history without local presentation fields");[session cancel];
    [session newChat];[session send:@"No source" model:@"test" apiKey:@"test"];
    transport.reply(@{@"content":@"",@"tool_calls":@[@{@"id":@"bad",@"function":@{@"name":@"present_answer",@"arguments":[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]}}]},nil);
    CHECK(session.running && ![session.chat[@"messages"] lastObject][@"answerCard"],"unverified card returns a tool error instead of a misleading answer");
    [session cancel];
}
