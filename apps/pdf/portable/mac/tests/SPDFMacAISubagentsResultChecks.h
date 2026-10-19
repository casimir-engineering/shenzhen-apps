// The pure parts of run_subagents (mac/SPDFMacAISubagentsResults.h): arguments, findings and sources, row words.
// Included by SPDFMacAISubagentsTests.mm.
#pragma once

static void CheckTaskArguments(void) {
    NSString* refusal = nil;
    NSDictionary* one = Job(@"Delivery dates", @"Find the delivery dates.");
    CHECK(!SPDFMacAISubagentTasks(nil, &refusal) && refusal.length, "no arguments: refused, with what to pass");
    refusal = nil;
    CHECK(!SPDFMacAISubagentTasks(@{@"tasks" : @[]}, &refusal) && [refusal containsString:@"1 to 4"],
          "no tasks: refused");
    CHECK(!SPDFMacAISubagentTasks(@{@"tasks" : @[one, one, one, one, one]}, &refusal) &&
          [refusal containsString:@"1 to 4"], "five tasks: refused, four at most");
    CHECK(SPDFMacAISubagentTasks(@{@"tasks" : @[one, one, one, one]}, &refusal).count == 4, "four tasks run");
    CHECK(!SPDFMacAISubagentTasks(@{@"tasks" : @[one], @"depth" : @2}, &refusal), "an unknown field is refused");
    CHECK(!SPDFMacAISubagentTasks(@{@"tasks" : @[@{@"title" : @"A", @"instructions" : @"B", @"tools" : @"all"}]},
                                  &refusal), "a task asking for more tools is refused, not quietly ignored");
    CHECK(!SPDFMacAISubagentTasks(@{@"tasks" : @[@{@"title" : @"A"}]}, &refusal), "a task needs instructions");
    CHECK(!SPDFMacAISubagentTasks(@{@"tasks" : @[@{@"title" : @"  ", @"instructions" : @"B"}]}, &refusal),
          "a blank title is refused");
    CHECK(!SPDFMacAISubagentTasks(@{@"tasks" : @[@{@"title" : @3, @"instructions" : @"B"}]}, &refusal),
          "a title must be text");
    NSString* longTitle = [@"" stringByPaddingToLength:81 withString:@"t" startingAtIndex:0];
    CHECK(!SPDFMacAISubagentTasks(@{@"tasks" : @[Job(longTitle, @"B")]}, &refusal) &&
          [refusal containsString:@"80"], "a title over 80 characters is refused");
    NSString* longTask = [@"" stringByPaddingToLength:4001 withString:@"i" startingAtIndex:0];
    CHECK(!SPDFMacAISubagentTasks(@{@"tasks" : @[Job(@"A", longTask)]}, &refusal), "instructions over 4,000");
    NSArray* tasks = SPDFMacAISubagentTasks(@{@"tasks" : @[Job(@" Delivery\n dates ", @" Find them. ")]}, &refusal);
    CHECK([tasks isEqual:@[@{@"title" : @"Delivery dates", @"instructions" : @"Find them."}]],
          "a title becomes one trimmed line for its row");
}

static void CheckFindings(void) {
    NSString* page3 = @"spdf-ai://document?path=doc:a&page=3&revision=r1";
    NSString* page9 = @"spdf-ai://document?path=doc:a&page=9&revision=r1";
    NSMutableArray* web = [NSMutableArray arrayWithObject:@{@"title" : @"Report", @"url" : @"https://example.org/r"}];
    for (int index = 0; index < 10; index++)
        [web addObject:@{@"url" : [NSString stringWithFormat:@"https://example.org/%d", index]}];
    NSString* webResult = JSONText(@{@"results" : web});
    CHECK([webResult containsString:@"https:\\/\\/example.org"],
          "fixture: tool results carry escaped slashes, the way the session writes them");
    NSString* readResult = JSONText(@{@"pages" : @[@{@"page" : @3, @"citation" : page3}]});
    NSDictionary* chat = @{@"messages" : @[@{@"role" : @"user", @"content" : @"task"},
        @{@"role" : @"tool", @"tool_call_id" : @"1", @"content" : readResult},
        @{@"role" : @"tool", @"tool_call_id" : @"2", @"content" : webResult}]};
    NSString* answer = [NSString stringWithFormat:@"The fee is 4%% [Contract · p. 3](%@), "
        "not 5%% [Contract · p. 9](%@). See [Report](https://example.org/r), [Blog](https://invented.example/post), "
        "https://example.org/r and [the report again](https://example.org/r).", page3, page9];
    NSDictionary* findings = SPDFMacAISubagentFindings(answer, chat);
    NSArray* expected = @[@{@"title" : @"Contract · p. 3", @"citation" : page3},
                          @{@"title" : @"Report", @"url" : @"https://example.org/r"}];
    CHECK([findings[@"sources"] isEqual:expected], "sources: only what a tool returned, in order, each once");
    NSString* summary = findings[@"summary"];
    CHECK([summary containsString:[NSString stringWithFormat:@"[Contract · p. 3](%@)", page3]] &&
          [summary containsString:@"not 5% Contract · p. 9."] && ![summary containsString:page9],
          "a page no tool returned keeps its words but loses its link");
    CHECK([summary containsString:@", Blog,"] && ![summary containsString:@"invented.example"],
          "so does a web address no tool returned");
    NSDictionary* repaired = SPDFMacAISubagentFindings([NSString stringWithFormat:@"[p. 3](%@&query=made%%20up)",
                                                        page3], chat);
    CHECK([repaired[@"sources"] isEqual:@[@{@"title" : @"p. 3", @"citation" : page3}]],
          "an invented highlight on a real page keeps the page, as in the main chat");
    NSMutableString* many = [NSMutableString string];
    for (int index = 0; index < 10; index++) [many appendFormat:@"[%d](https://example.org/%d) ", index, index];
    CHECK([SPDFMacAISubagentFindings(many, chat)[@"sources"] count] == SPDFMacAISubagentSourceLimit,
          "at most 8 sources per task");
    CHECK(![SPDFMacAISubagentFindings(answer, @{})[@"sources"] count], "a task that ran no tool cites nothing");
    NSString* essay = [@"" stringByPaddingToLength:5000 withString:@"word " startingAtIndex:0];
    NSString* clipped = SPDFMacAISubagentFindings(essay, chat)[@"summary"];
    CHECK(clipped.length == SPDFMacAISubagentSummaryLimit && [clipped hasSuffix:@"…"], "summaries are short");
    NSString* emoji = [[@"" stringByPaddingToLength:1998 withString:@"a" startingAtIndex:0]
        stringByAppendingString:@"😀😀😀"];
    NSString* cut = SPDFMacAISubagentClipped(emoji, 2000);
    CHECK(cut.length <= 2000 && [cut hasSuffix:@"…"] && [cut canBeConvertedToEncoding:NSUTF8StringEncoding],
          "clipping never splits an emoji");
}

static void CheckRowWords(void) {
    NSArray* messages = @[@{@"role" : @"user", @"content" : @"x"},
        @{@"role" : @"assistant", @"content" : @"", @"tool_calls" : @[SeamCall(@"1", @"search_documents"),
                                                                       SeamCall(@"2", @"read_pages")]},
        @{@"role" : @"tool", @"tool_call_id" : @"1", @"content" : @"{}"}];
    CHECK([SPDFMacAISubagentCurrentTool(messages) isEqual:@"read_pages"], "the call after the answered ones runs");
    CHECK([SPDFMacAISubagentCurrentTool([messages subarrayWithRange:NSMakeRange(0, 2)]) isEqual:@"search_documents"],
          "the first call runs before any answer");
    NSArray* done = [messages arrayByAddingObject:@{@"role" : @"tool", @"tool_call_id" : @"2", @"content" : @"{}"}];
    CHECK(!SPDFMacAISubagentCurrentTool(done) && !SPDFMacAISubagentCurrentTool(@[messages[0]]) &&
          !SPDFMacAISubagentCurrentTool(nil), "no tool runs once every call is answered, or before any");
    CHECK([SPDFMacAISubagentStepText(@"read_pages") isEqual:@"Reading pages…"] &&
          [SPDFMacAISubagentStepText(@"web_search") isEqual:@"Searching the web…"] &&
          [SPDFMacAISubagentStepText(@"run_python") isEqual:@"Running Python…"] &&
          [SPDFMacAISubagentStepText(@"mystery_tool") isEqual:@"Working…"] &&
          [SPDFMacAISubagentStepText(nil) isEqual:@"Working…"],
          "rows say what a task is doing, in plain words that end in an ellipsis while it works");
    CHECK([SPDFMacAISubagentProblemLine(@"This chat reached its context limit. Start a new chat to continue.")
              isEqual:@"This chat reached its context limit."] &&
          [SPDFMacAISubagentProblemLine(@"  The model returned an invalid response.\nDetails") isEqual:
              @"The model returned an invalid response."] && !SPDFMacAISubagentProblemLine(@" \n ") &&
          [SPDFMacAISubagentProblemLine([@"" stringByPaddingToLength:300 withString:@"x" startingAtIndex:0])
              length] == 160, "a failed helper's row gets the problem's first sentence, short, and no advice");
    CHECK([SPDFMacAISubagentPlainText(@"See [Contract · p. 3](spdf-ai://document?x) now.")
              isEqual:@"See Contract · p. 3 now."], "a row's detail shows a link's words, not its address");
    NSString* findings = @"## Delivery dates ##\n**Due 20 March** per *clause 7* and __Annex B__, see _note_.\n"
        "Run `total_due **2` for 2 * 3 * 4; file_name_here stays.";
    CHECK([SPDFMacAISubagentPlainText(findings) isEqual:@"Delivery dates\nDue 20 March per clause 7 and Annex B, see "
              "note.\nRun total_due **2 for 2 * 3 * 4; file_name_here stays."],
          "a row's detail drops heading, strong, emphasis and code marks, keeping code, sums and names as written");
}
