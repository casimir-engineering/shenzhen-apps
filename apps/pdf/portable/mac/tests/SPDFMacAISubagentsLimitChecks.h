// run_subagents inside a request's limits: the Friends scope and read-only rule survive making task sessions, a
// request runs tasks at most twice, task turns and tokens are capped per request and per run, and rows of a request
// with Friends in it are kept for that request only. Included by SPDFMacAISubagentsTests.mm.
#pragma once

static SPDFMacAIRequestChip* MeiChip(void) {
    return [SPDFMacAIRequestChip friendsChipWithConversationIDs:@[@"c_mei"] displayName:@"Mei"];
}

static void CheckFriendsScopeSurvivesTasks(void) {
    TaskChat chat = MakeTaskChat(@"friends-scope");
    NSString* person = @"PERSON: what did @Mei ask for? Then rename the contract";
    [chat.session sendContext:TaskRequest(chat, person, @[MeiChip()], nil, TaskSettings(YES)) model:@"fake/model"
                       apiKey:@"TEST-NOT-A-KEY"];
    CHECK(chat.friends.scopeOpen && !chat.friends.readChats, "fixture: the chip opens the request's Friends scope");
    // One turn: read Friends, run a task, then try a change.
    Reply(MainTurn(chat.model, person), SeamToolTurn(@[SeamCall(@"f1", @"friends_search_chats"),
        RunCall(@"run", @[Job(@"Contract", @"TASK-CONTRACT: find the contract's name")]),
        SeamCall(@"w1", @"rename_document")]));
    TaskTurn* task = TaskTurnFor(chat.model, @"TASK-CONTRACT");
    CHECK(task && !chat.friends.cancels && !chat.reader.cancels && chat.friends.scopeOpen && chat.friends.readChats,
          "making the task's session cancels none of the request's providers: its Friends scope and read-only rule "
          "stay");
    Reply(task, SeamAnswer(@"It is called Supply 2026."));
    TaskTurn* after = MainTurn(chat.model, person);
    CHECK(![chat.reader.ran containsObject:@"rename_document"] &&
          [[after resultFor:@"w1"][@"error"] containsString:@"only read"],
          "so a change called in the same turn, after run_subagents, is still refused");
    Reply(after, SeamAnswer(@"Mei asked for the contract. Ask again without @ to rename it."));
    CHECK(!chat.friends.scopeOpen && chat.friends.ends == 1, "the scope closes when the request ends, not before");
    EndTaskChat(chat);
}

static void CheckRunLimit(void) {
    TaskChat chat = MakeTaskChat(@"run-limit");
    NSString* person = @"PERSON: keep researching";
    Ask(chat, person, nil);
    for (int run = 1; run <= 2; run++) {
        NSString* marker = [NSString stringWithFormat:@"TASK-RUN%d", run];
        TaskTurn* main = MainTurn(chat.model, person);
        CHECK([SeamNames(main.tools) containsObject:@"run_subagents"], "run_subagents is offered while runs remain");
        Reply(main, SeamToolTurn(@[RunCall([NSString stringWithFormat:@"run%d", run], @[Job(@"Look", marker)])]));
        Reply(TaskTurnFor(chat.model, marker), SeamAnswer(@"Found it."));
    }
    TaskTurn* third = MainTurn(chat.model, person);
    CHECK(third && third.tools.count && ![SeamNames(third.tools) containsObject:@"run_subagents"],
          "after two runs in one request the tool is no longer offered");
    Reply(third, SeamToolTurn(@[RunCall(@"run3", @[Job(@"Again", @"TASK-RUN3")])]));
    TaskTurn* refused = MainTurn(chat.model, person);
    CHECK([[refused resultFor:@"run3"][@"error"] containsString:@"twice"] && !TaskTurnFor(chat.model, @"TASK-RUN3"),
          "and a third call starts nothing, telling the model why");
    Reply(refused, SeamAnswer(@"Here is what the two runs found."));
    NSString* next = @"PERSON: a new question";
    Ask(chat, next, nil);
    TaskTurn* fresh = MainTurn(chat.model, next);
    CHECK([SeamNames(fresh.tools) containsObject:@"run_subagents"], "the next request has its own two runs");
    Reply(fresh, SeamAnswer(@"Sure."));
    EndTaskChat(chat);
}

// Each of a task's turns with tools, then its wrap-up turn without them.
static NSUInteger TurnsWithTools(TaskChat chat, NSString* marker, NSString* prefix) {
    NSUInteger turns = 0;
    for (TaskTurn* turn = TaskTurnFor(chat.model, marker); turn.tools.count && turns < 20;
         turn = TaskTurnFor(chat.model, marker)) {
        Reply(turn, SeamToolTurn(@[SeamCall([NSString stringWithFormat:@"%@%lu", prefix, (unsigned long)turns],
                                            @"read_pages")]));
        turns++;
    }
    TaskTurn* wrapUp = TaskTurnFor(chat.model, marker);
    CHECK(wrapUp && [wrapUp wireContains:@"tools are off"], "a task out of turns answers without tools");
    Reply(wrapUp, SeamAnswer(@"Partly done."));
    return turns;
}

static void CheckRequestTurns(void) {
    TaskChat chat = MakeTaskChat(@"request-turns");
    CHECK(SPDFMacAISubagentsTurnsPerRequest == 48 && chat.subagents.turnsPerRequest == 48,
          "a request has 48 task turns unless changed");
    chat.subagents.turnsPerRequest = 6;
    NSString* person = @"PERSON: two lookups, then more";
    Ask(chat, person, nil);
    Reply(MainTurn(chat.model, person), SeamToolTurn(@[RunCall(@"run1", @[Job(@"A", @"TASK-A"),
                                                                         Job(@"B", @"TASK-B")])]));
    CHECK(TurnsWithTools(chat, @"TASK-A", @"a") == 3, "two tasks share the request's six task turns: three each");
    Reply(TaskTurnFor(chat.model, @"TASK-B"), SeamAnswer(@"B done."));
    // Four of six turns used: two left, too few for two tasks, enough for one.
    Reply(MainTurn(chat.model, person), SeamToolTurn(@[RunCall(@"run2", @[Job(@"C", @"TASK-C"),
                                                                         Job(@"D", @"TASK-D")])]));
    TaskTurn* fewer = MainTurn(chat.model, person);
    CHECK([[fewer resultFor:@"run2"][@"error"] containsString:@"Run fewer"] && !TaskTurnFor(chat.model, @"TASK-C"),
          "turns are counted across runs: the second run is refused when its tasks would get under two each");
    CHECK([SeamNames(fewer.tools) containsObject:@"run_subagents"], "a refused run does not count as one of the two");
    Reply(fewer, SeamToolTurn(@[RunCall(@"run3", @[Job(@"C", @"TASK-C")])]));
    CHECK(TurnsWithTools(chat, @"TASK-C", @"c") == 2, "one task gets the two turns left");
    Reply(MainTurn(chat.model, person), SeamAnswer(@"Done."));

    chat.subagents.turnsPerRequest = 1;
    NSString* spent = @"PERSON: a request with one task turn";
    Ask(chat, spent, nil);
    Reply(MainTurn(chat.model, spent), SeamToolTurn(@[RunCall(@"run", @[Job(@"E", @"TASK-E")])]));
    TaskTurn* none = MainTurn(chat.model, spent);
    CHECK([[none resultFor:@"run"][@"error"] containsString:@"used all their turns"] &&
          !TaskTurnFor(chat.model, @"TASK-E"), "with no turns to give, no task starts");
    Reply(none, SeamAnswer(@"Answered directly."));
    EndTaskChat(chat);
}

static void CheckRunTokenCap(void) {
    TaskChat chat = MakeTaskChat(@"run-tokens");
    __block NSUInteger seen = 0;
    chat.reader.answer = ^NSDictionary*(NSString* name, SPDFMacAIRequestContext* context) {
        (void)name;
        seen = context.budget.remainingTokens;
        return @{@"ok" : @YES};
    };
    SPDFMacAIRequestBudget* budget = [[SPDFMacAIRequestBudget alloc] initWithSteps:12 tokens:10000000
                                                                         toolCalls:NSUIntegerMax];
    NSString* person = @"PERSON: lookups on a large budget";
    Ask(chat, person, budget);
    Reply(MainTurn(chat.model, person), SeamToolTurn(@[RunCall(@"four", @[Job(@"A", @"TASK-A"), Job(@"B", @"TASK-B"),
        Job(@"C", @"TASK-C"), Job(@"D", @"TASK-D")])]));
    Reply(TaskTurnFor(chat.model, @"TASK-A"), WithUsage(SeamToolTurn(@[SeamCall(@"a1", @"read_pages")]), 1000));
    CHECK(SPDFMacAISubagentsTokensPerRun == 600000 && seen == 600000 / 4 - 1000,
          "a run's tokens are capped at 600,000 and split between its tasks, however much the request has left");
    Reply(TaskTurnFor(chat.model, @"TASK-A"), SeamAnswer(@"A."));
    for (NSString* marker in @[@"TASK-B", @"TASK-C", @"TASK-D"])
        Reply(TaskTurnFor(chat.model, marker), SeamAnswer(@"Nothing more."));
    Reply(MainTurn(chat.model, person), SeamToolTurn(@[RunCall(@"one", @[Job(@"E", @"TASK-E")])]));
    Reply(TaskTurnFor(chat.model, @"TASK-E"), WithUsage(SeamToolTurn(@[SeamCall(@"e1", @"read_pages")]), 1000));
    CHECK(seen == 600000 - 1000, "a run of one task has the whole cap");
    Reply(TaskTurnFor(chat.model, @"TASK-E"), SeamAnswer(@"E."));
    Reply(MainTurn(chat.model, person), SeamAnswer(@"Done."));
    EndTaskChat(chat);
}

static void CheckRowsAfterFriends(void) {
    TaskChat chat = MakeTaskChat(@"rows-friends");
    NSString* person = @"PERSON: check what @Mei said against the contract";
    [chat.session sendContext:TaskRequest(chat, person, @[MeiChip()], nil, TaskSettings(YES)) model:@"fake/model"
                       apiKey:@"TEST-NOT-A-KEY"];
    Reply(MainTurn(chat.model, person), SeamToolTurn(@[RunCall(@"run", @[Job(@"Delivery date",
        @"TASK-MEI: Mei wrote that the code is 4471; check clause 7")])]));
    NSDictionary* row = Rows(chat).firstObject;
    CHECK([row[SPDFMacAIActivityRequestOnlyKey] isEqual:@YES] &&
          [row[SPDFMacAIActivityDetailKey] containsString:@"4471"],
          "while the request runs, the row shows the task and is marked for this request only");
    Reply(TaskTurnFor(chat.model, @"TASK-MEI"), SeamAnswer(@"Clause 7 confirms code 4471."));
    Reply(MainTurn(chat.model, person), SeamAnswer(@"They agree."));
    NSArray* stored = [chat.store chatWithID:chat.session.chat[@"id"]][@"activity"];
    NSString* notice = @"Not kept after this request, because it included your Friends chats.";
    CHECK(stored.count == 1 && [stored[0][SPDFMacAIActivityTitleKey] isEqual:@"Part"] &&
          [stored[0][SPDFMacAIActivityDetailKey] isEqual:notice] && ![JSONText(stored) containsString:@"4471"] &&
          ![JSONText(stored) containsString:@"Delivery date"],
          "the chat file keeps a plain title and the request-only notice, never the model's title, the task or its "
          "findings");
    CHECK([chat.session.chat[@"activity"][0][SPDFMacAIActivityDetailKey] isEqual:notice],
          "once the request ends the open chat shows the same");

    // `/` in a friend's conversation reads that chat without a chip.
    NSString* slash = @"PERSON: what does Kenji's last message mean?";
    SPDFMacAIRequestChip* kenji = [SPDFMacAIRequestChip friendsChipWithConversationIDs:@[@"c_kenji"]
                                                                           displayName:@"Kenji"];
    [chat.session sendContext:[[SPDFMacAIRequestContext alloc] initWithText:slash chips:nil
        origin:SPDFMacAIRequestOriginFriendComposer friendConversation:kenji settings:TaskSettings(YES) budget:nil
        activity:chat.session.activity] model:@"fake/model" apiKey:@"TEST-NOT-A-KEY"];
    Reply(MainTurn(chat.model, slash), SeamToolTurn(@[RunCall(@"run", @[Job(@"Meaning", @"TASK-KENJI")])]));
    CHECK([Rows(chat).lastObject[SPDFMacAIActivityRequestOnlyKey] isEqual:@YES],
          "so does a request typed in a friend's conversation");
    Reply(TaskTurnFor(chat.model, @"TASK-KENJI"), SeamAnswer(@"It means yes."));
    Reply(MainTurn(chat.model, slash), SeamAnswer(@"Yes."));
    EndTaskChat(chat);
}
