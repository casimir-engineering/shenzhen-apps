static void CheckReasoning(NSURL* root) {
    SPDFMacAIChatStore* store=[[SPDFMacAIChatStore alloc] initWithDirectory:root];
    FakeTransport* transport=[FakeTransport new];FakeTools* tools=[FakeTools new];
    SPDFMacAIChatSession* session=[[SPDFMacAIChatSession alloc] initWithTransport:transport tools:tools definitions:@[] store:store];
    [session send:@"Answer this document question" model:@"fake/reasoning" apiKey:@"test"];
    NSString* prompt=transport.messages.firstObject[@"content"];
    CHECK(prompt.length<3400 && [prompt containsString:@"Default to 1-3 short sentences"] &&
          [prompt containsString:@"detailed reasoning, derivations, tables or extra suggestions only when the user asks"] &&
          [prompt containsString:@"Stop inspecting once the answer is supported"],
          "compact request prompt defaults to a short cited answer without unsolicited exposition");
    CHECK([prompt containsString:@"definitions, scope and conditions"] &&
          [prompt containsString:@"Choose text or rendered pages according to where the evidence lives"] &&
          [prompt containsString:@"Never infer absence from a failed search or partial inspection"] &&
          [prompt containsString:@"never add a query"] && [prompt containsString:@"Brevity limits the reply, not the evidence"],
          "brief replies retain general evidence checks and exact citation rules");
    CHECK(![prompt containsString:@"3.1 mm"] && ![prompt containsString:@"MSK13"] &&
          ![prompt containsString:@"total travel"] && ![prompt containsString:@"dimension arrows"] &&
          ![prompt containsString:@"before relying on a table"],
          "general evidence rules do not privilege the engineering test case");
    NSString* baseline=[NSString stringWithContentsOfFile:@"mac/tests/fixtures/ai-system-prompt-pre-card.txt"
        encoding:NSUTF8StringEncoding error:nil];
    baseline=[baseline stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSString* cardHint=@"Use present_answer to finish with an evidence-linked card when the answer fits in a number, range or a few words. Use prose when essential nuance needs more space. ";
    NSRange language=[prompt rangeOfString:@" Default response language:"];
    NSString* core=language.location==NSNotFound ? @"" : [prompt substringToIndex:language.location];
    CHECK([core containsString:cardHint] && [[core stringByReplacingOccurrencesOfString:cardHint withString:@""] isEqual:baseline],
          "system prompt equals the pre-card baseline with only the card instruction added");
    NSArray* details=@[@{@"type":@"reasoning.encrypted",@"data":@"opaque-fixture-state",@"format":@"fixture"}];
    transport.reply(@{@"content":@"",@"reasoning_details":details,@"tool_calls":@[
        @{@"id":@"drawing",@"function":@{@"name":@"render_page",@"arguments":@"{}"}}]},nil);
    tools.reply(@{@"rendered":@YES});
    CHECK([transport.messages[2][@"reasoning_details"] isEqual:details],"tool continuation preserves opaque model reasoning unchanged");
    CHECK(!session.chat[@"messages"][1][@"reasoning_details"],"reasoning stays request-only, outside displayed/saved history");
    [session cancel];[session send:@"Next question" model:@"fake/other" apiKey:@"test"];
    BOOL retained=NO;for(NSDictionary* message in transport.messages)if(message[@"reasoning_details"])retained=YES;
    CHECK(!retained,"reasoning is not replayed to a different model or new user turn");[session cancel];
}
