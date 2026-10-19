static void CheckCitationRecovery(NSURL* root) {
    NSString* page=@"spdf-ai://document?path=doc:drawing&page=3&revision=rev";
    NSString* invented=[page stringByAppendingString:@"&query=%E5%8A%A8%E4%BD%9C%E8%A1%8C%E7%A8%8B"];
    NSString* text=[NSString stringWithFormat:@"Answer [Drawing · p. 3](%@).",invented];
    NSData* result=[NSJSONSerialization dataWithJSONObject:@{@"pages":@[@{@"citation":page}]} options:0 error:nil];
    NSDictionary* chat=@{@"messages":@[@{@"role":@"tool",@"content":[[NSString alloc] initWithData:result encoding:NSUTF8StringEncoding]}]};
    NSDictionary* pageArgs=SPDFMacAICitationArguments([NSURL URLWithString:page]);
    NSDictionary* badArgs=SPDFMacAICitationArguments([NSURL URLWithString:invented]);
    CHECK(!SPDFMacAIChatContainsCitation(chat,badArgs),"invented highlight is never treated as retrieved evidence");
    CHECK([SPDFMacAIResolveCitation(chat,badArgs) isEqual:pageArgs],"legacy links recover a verified page without invented highlight");
    NSString* expected=[NSString stringWithFormat:@"Answer [Drawing · p. 3](%@).",page];
    CHECK([SPDFMacAIRepairCitationLinks(text,chat) isEqual:expected],"reply preserves prose and replaces invented highlight with retrieved page");
    NSMutableDictionary* other=[badArgs mutableCopy];
    for(NSString* field in @[@"path",@"page",@"revision",@"layoutIdentity"]) {
        other=[badArgs mutableCopy];other[field]=[field isEqual:@"page"] ? (id)@4 : @"other";
        CHECK(!SPDFMacAIResolveCitation(chat,other),"recovery never relaxes document, page, revision or layout identity");
    }
    CHECK(!SPDFMacAIResolveCitation(chat,nil),"malformed URL remains blocked");
    NSDictionary* fabricated=@{@"messages":@[@{@"role":@"assistant",@"content":page}]};
    CHECK(!SPDFMacAIResolveCitation(fabricated,badArgs),"assistant prose cannot authorize a destination");
    NSString* exact=[page stringByAppendingString:@"&query=travel"];
    NSData* search=[NSJSONSerialization dataWithJSONObject:@{@"matches":@[@{@"citation":exact}]} options:0 error:nil];
    NSDictionary* searched=@{@"messages":@[@{@"role":@"tool",@"content":[[NSString alloc] initWithData:search encoding:NSUTF8StringEncoding]}]};
    NSString* highlighted=[NSString stringWithFormat:@"[Travel](%@)",exact];
    CHECK([SPDFMacAIRepairCitationLinks(highlighted,searched) isEqual:highlighted],"verified search highlights stay intact");
    CHECK(!SPDFMacAIResolveCitation(searched,badArgs),"unrelated search result is not a page-only fallback");
    NSDictionary* preview=@{@"messages":@[@{@"role":@"preview",@"local":@YES,@"preview":@{@"citation":pageArgs}}]};
    CHECK([SPDFMacAIResolveCitation(preview,badArgs) isEqual:pageArgs],"trusted saved image page can recover an old citation");
    CHECK([SPDFMacAIRepairCitationLinks(text,@{}) isEqual:text],"unverified destinations are not rewritten or authorized");
    SPDFMacAIChatStore* store=[[SPDFMacAIChatStore alloc] initWithDirectory:root];
    FakeTransport* transport=[FakeTransport new];FakeTools* tools=[FakeTools new];
    SPDFMacAIChatSession* session=[[SPDFMacAIChatSession alloc] initWithTransport:transport tools:tools definitions:@[] store:store];
    [session send:@"Read this" model:@"test" apiKey:@"test"];
    transport.reply(@{@"content":@"",@"tool_calls":@[@{@"id":@"read",@"function":@{@"name":@"read_pages",@"arguments":@"{}"}}]},nil);
    tools.reply(@{@"pages":@[@{@"citation":page}]});
    NSUInteger sends=transport.sends;
    transport.reply(@{@"content":text},nil);
    CHECK([[session.chat[@"messages"] lastObject][@"content"] isEqual:expected],"session repairs citation before displaying and persisting answer");
    CHECK(transport.sends<=sends+1,"citation recovery adds no model round beyond optional title generation");
    NSDictionary* saved=[store chatWithID:session.chat[@"id"]];
    CHECK([[saved[@"messages"] lastObject][@"content"] isEqual:expected],"reopened chat retains repaired page link");
    [session cancel];
}
