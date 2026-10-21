// When the assistant splits a request into parts, and what the person sees while they work: the tool offered with
// default settings, the guidance in its description and in the main prompt, the hint a message with several
// documents adds, three parts running at once each in its own conversation, the heading's count and each part's
// row, and Stop ending them all. Included by SPDFMacAISubagentsTests.mm.
#pragma once

static NSDictionary* OfferedDefinition(TaskTurn* turn) {
    for (NSDictionary* tool in turn.tools)
        if ([tool[@"function"][@"name"] isEqual:@"run_subagents"]) return tool[@"function"];
    return nil;
}

static void CheckSplitGuidance(void) {
    TaskChat chat = MakeTaskChat(@"guidance");
    // The settings a new install has, as the owner's: web, Python and parts all on.
    SPDFMacAISettings* fresh = [[SPDFMacAISettings alloc] initWithURL:[NSURL fileURLWithPath:
        [NSTemporaryDirectory() stringByAppendingPathComponent:@"spdf-subagents-unused-defaults.yaml"]]];
    CHECK(fresh.aiWebSearchEnabled && fresh.aiPythonEnabled && fresh.aiSubagentsEnabled,
          "fixture: every capability is on by default");
    NSString* quick = @"PERSON: what is the delivery date?";
    [chat.session sendContext:TaskRequest(chat, quick, nil, nil, fresh.snapshot) model:@"fake/model"
                       apiKey:@"TEST-NOT-A-KEY"];
    TaskTurn* turn = MainTurn(chat.model, quick);
    NSString* description = OfferedDefinition(turn)[@"description"];
    CHECK(description && [description containsString:@"several documents"] &&
          [description containsString:@"more than about 20 pages"] &&
          [description containsString:@"several separate questions"] && [description containsString:@"on the web"] &&
          [description containsString:@"Don't use it for one quick question"],
          "with default settings the person's request offers run_subagents, saying when to split and when not");
    CHECK([turn.system containsString:@"Split big requests with run_subagents"] &&
          [turn.system containsString:@"more than about 20 pages"] && [turn.system containsString:@"one quick question"]
          && [turn.system hasPrefix:@"You are Shenzhen PDF's document assistant."],
          "and the main prompt says the same, after the assistant's own instructions");
    CHECK(![turn.system containsString:@"This message"], "a quick question gets no hint to split");
    Reply(turn, SeamAnswer(@"The 20th."));

    NSString* off = @"PERSON: compare both contracts, parts off";
    [chat.session sendContext:TaskRequest(chat, off, nil, nil, TaskSettings(NO)) model:@"fake/model"
                       apiKey:@"TEST-NOT-A-KEY"];
    TaskTurn* without = MainTurn(chat.model, off);
    CHECK(![without.system containsString:@"run_subagents"] && !OfferedDefinition(without),
          "switched off, the prompt never names the tool");
    Reply(without, SeamAnswer(@"Done."));
    EndTaskChat(chat);
}

static void CheckSplitHint(void) {
    CHECK(!SPDFMacAISubagentSplitHint(@"What is the delivery date?", @[]) &&
          !SPDFMacAISubagentSplitHint(nil, @[@"One.pdf"]) &&
          !SPDFMacAISubagentSplitHint(@"Summarize this", @[@"One.pdf", @"  "]),
          "one question about one document is no reason to split");
    NSString* two = SPDFMacAISubagentSplitHint(@"Which one is cheaper?", @[@"Quote A.pdf", @"Quote B.pdf"]);
    CHECK([two containsString:@"2 documents (Quote A.pdf, Quote B.pdf)"] && [two containsString:@"run_subagents"],
          "two files on the message's chips: the hint names them");
    for (NSString* text in @[@"Compare these three contracts", @"What are the differences between v2 and v3?",
                             @"Summarize each document I have open", @"check all of my datasheets for the voltage",
                             @"对比这两个文件", @"总结所有文件"])
        CHECK(SPDFMacAISubagentSplitHint(text, @[]) != nil, "wording that asks for several documents gets the hint");
    CHECK(!SPDFMacAISubagentSplitHint(@"Is this comparable to last year?", @[]) &&
          !SPDFMacAISubagentSplitHint(@"Open the file", @[]), "a word merely containing one does not");
    CHECK([SPDFMacAISubagentProgressText(3, 0) isEqual:@"Working on 3 parts…"] &&
          [SPDFMacAISubagentProgressText(3, 1) isEqual:@"Working on 3 parts, 1 finished…"] &&
          [SPDFMacAISubagentProgressText(1, 0) isEqual:@"Working on 1 part…"], "the heading's words");

    TaskChat chat = MakeTaskChat(@"hint");
    NSArray* chips = @[
        [SPDFMacAIRequestChip documentChipWithFileURL:[NSURL fileURLWithPath:@"/tmp/spdf-none/a.pdf"] identifier:nil
                                             revision:nil displayName:@"Contract A.pdf"],
        [SPDFMacAIRequestChip attachmentChipWithFileURL:[NSURL fileURLWithPath:@"/tmp/spdf-none/b.pdf"]
                                            displayName:@"Contract B.pdf"]];
    NSString* person = @"PERSON: which has the shorter notice period?";
    [chat.session sendContext:TaskRequest(chat, person, chips, nil, TaskSettings(YES)) model:@"fake/model"
                       apiKey:@"TEST-NOT-A-KEY"];
    TaskTurn* first = MainTurn(chat.model, person);
    CHECK([first.system containsString:@"comes with 2 documents (Contract A.pdf, Contract B.pdf)"],
          "in the session, a message with two documents tells the main assistant that parts fit it");
    Reply(first, SeamToolTurn(@[RunCall(@"run", @[Job(@"A", @"TASK-HA"), Job(@"B", @"TASK-HB")])]));
    TaskTurn* part = TaskTurnFor(chat.model, @"TASK-HA");
    CHECK(part && ![part.system containsString:@"run_subagents"] && ![part.system containsString:@"This message"],
          "a part's own prompt carries neither the guidance nor the hint");
    Reply(part, SeamAnswer(@"30 days."));
    Reply(TaskTurnFor(chat.model, @"TASK-HB"), SeamAnswer(@"60 days."));
    TaskTurn* after = MainTurn(chat.model, person);
    CHECK([after.system containsString:@"Split big requests"] && ![after.system containsString:@"This message"],
          "once the request has split, the hint goes; the guidance stays while the tool is offered");
    Reply(after, SeamAnswer(@"A: 30 days."));
    EndTaskChat(chat);
}

static void CheckThreePartsInParallel(void) {
    TaskChat chat = MakeTaskChat(@"three");
    NSString* earlier = @"PERSON: EARLIER-QUESTION";
    Ask(chat, earlier, nil);
    Reply(MainTurn(chat.model, earlier), SeamAnswer(@"EARLIER-ANSWER"));
    NSString* person = @"PERSON: compare the three supplier quotes";
    Ask(chat, person, nil);
    Reply(MainTurn(chat.model, person), SeamToolTurn(@[RunCall(@"run", @[Job(@"Quote A", @"TASK-QA: read quote A"),
        Job(@"Quote B", @"TASK-QB: read quote B"), Job(@"Quote C", @"TASK-QC: read quote C")])]));
    NSArray<NSString*>* markers = @[@"TASK-QA", @"TASK-QB", @"TASK-QC"];
    NSMutableArray<TaskTurn*>* parts = [NSMutableArray array];
    for (NSString* marker in markers)
        if (TaskTurnFor(chat.model, marker)) [parts addObject:TaskTurnFor(chat.model, marker)];
    CHECK(parts.count == 3, "all three parts are waiting on the model at once, before any has answered");
    BOOL separate = parts.count == 3;
    for (NSUInteger index = 0; index < parts.count; index++) {
        TaskTurn* turn = parts[index];
        separate = separate && turn.messages.count == 2 && ![turn wireContains:@"EARLIER-ANSWER"] &&
            [SeamNames(turn.tools) isEqual:(@[@"read_pages", @"web_search"])];
        for (NSUInteger other = 0; other < markers.count; other++)
            if (other != index) separate = separate && ![turn wireContains:markers[other]];
    }
    CHECK(separate, "each part has its own conversation (its prompt and its task, no earlier chat, no other part) "
          "and only read-only tools, never run_subagents");
    CHECK([chat.session.runningTool isEqual:@"run_subagents"] &&
          [chat.session.runningToolProgress isEqual:@"Working on 3 parts…"],
          "the heading says how many parts are working");
    NSArray* rows = Rows(chat);
    BOOL running = rows.count == 3;
    for (NSDictionary* row in rows)
        running = running && [row[SPDFMacAIActivityStateKey] isEqual:SPDFMacAIActivityStateRunning] &&
            [row[SPDFMacAIActivityStatusKey] isEqual:@"Thinking…"];
    CHECK(running, "one row per part, each running");

    NSString* longAnswer = [@"A quotes 4.20 a unit. " stringByPaddingToLength:5000 withString:@"x" startingAtIndex:0];
    Reply(parts[0], SeamAnswer(longAnswer));
    CHECK([chat.session.runningToolProgress isEqual:@"Working on 3 parts, 1 finished…"] &&
          [Rows(chat)[0][SPDFMacAIActivityStateKey] isEqual:SPDFMacAIActivityStateDone] &&
          [Rows(chat)[0][SPDFMacAIActivityStatusKey] isEqual:@"Done"], "a part that answers is Done, and counted");
    parts[1].answered = YES;
    parts[1].reply(nil, [NSError errorWithDomain:@"test" code:1
                                         userInfo:@{NSLocalizedDescriptionKey : @"The model service is busy."}]);
    NSDictionary* failed = Rows(chat)[1];
    CHECK([failed[SPDFMacAIActivityStateKey] isEqual:SPDFMacAIActivityStateFailed] &&
          [failed[SPDFMacAIActivityStatusKey] isEqual:@"Didn’t finish"] &&
          [chat.session.runningToolProgress isEqual:@"Working on 3 parts, 2 finished…"],
          "a part that fails says it didn't finish");
    Reply(parts[2], SeamAnswer(@"C quotes 3.90."));
    TaskTurn* after = MainTurn(chat.model, person);
    NSArray* results = [after resultFor:@"run"][@"tasks"];
    CHECK(results.count == 3 && [results[0][@"summary"] length] <= SPDFMacAISubagentSummaryLimit &&
          [results[0][@"summary"] hasPrefix:@"A quotes 4.20"] && [results[1][@"status"] isEqual:@"failed"] &&
          [results[2][@"summary"] isEqual:@"C quotes 3.90."],
          "the main assistant gets each part's short findings, in order");
    CHECK(!chat.session.runningToolProgress && chat.session.activityState == SPDFMacAIChatActivityThinking,
          "the count leaves the heading with the tool");
    Reply(after, SeamAnswer(@"C is cheapest."));
    EndTaskChat(chat);
}

static void CheckStopEndsEveryPart(void) {
    TaskChat chat = MakeTaskChat(@"stop-parts");
    NSString* person = @"PERSON: three parts, one done, then Stop";
    Ask(chat, person, nil);
    Reply(MainTurn(chat.model, person), SeamToolTurn(@[RunCall(@"run", @[Job(@"One", @"TASK-S1"),
        Job(@"Two", @"TASK-S2"), Job(@"Three", @"TASK-S3")])]));
    Reply(TaskTurnFor(chat.model, @"TASK-S1"), SeamAnswer(@"One answered."));
    NSArray* pending = @[TaskTurnFor(chat.model, @"TASK-S2"), TaskTurnFor(chat.model, @"TASK-S3")];
    [chat.session cancel];
    NSArray* rows = Rows(chat);
    CHECK(rows.count == 3 && [rows[0][SPDFMacAIActivityStatusKey] isEqual:@"Done"] &&
          [rows[1][SPDFMacAIActivityStateKey] isEqual:SPDFMacAIActivityStateStopped] &&
          [rows[1][SPDFMacAIActivityStatusKey] isEqual:@"Stopped"] &&
          [rows[2][SPDFMacAIActivityStateKey] isEqual:SPDFMacAIActivityStateStopped],
          "Stop stops every part still working; the finished one stays Done");
    CHECK(!chat.session.running && !chat.session.runningToolProgress &&
          chat.session.activityState == SPDFMacAIChatActivityStopped, "and the request, its heading count gone");
    NSUInteger turns = chat.model.turns.count;
    for (TaskTurn* turn in pending) Reply(turn, SeamToolTurn(@[SeamCall(@"late", @"read_pages")]));
    SeamRunLoop(0.05);
    CHECK(chat.model.turns.count == turns && !chat.reader.ran.count, "no part goes on after Stop");
    EndTaskChat(chat);
}
