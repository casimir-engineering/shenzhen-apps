// run_subagents ending early, and what the person sees: the timeout's partial results, Stop, one task's Cancel, the
// rows and the sources the main chat can verify. Included by SPDFMacAISubagentsTests.mm.
#pragma once

static TaskTurn* WaitForMainTurn(TaskChat chat, NSString* person, NSTimeInterval limit) {
    NSDate* start = NSDate.date;
    while (!MainTurn(chat.model, person) && -start.timeIntervalSinceNow < limit) SeamRunLoop(0.02);
    return MainTurn(chat.model, person);
}

static void CheckTimeoutReturnsPartialResults(void) {
    TaskChat chat = MakeTaskChat(@"timeout");
    chat.subagents.timeout = 0.3;
    NSString* person = @"PERSON: one quick lookup, one slow";
    Ask(chat, person, nil);
    Reply(MainTurn(chat.model, person), SeamToolTurn(@[RunCall(@"run", @[Job(@"Quick", @"TASK-QUICK"),
                                                                        Job(@"Slow", @"TASK-SLOW")])]));
    Reply(TaskTurnFor(chat.model, @"TASK-QUICK"), SeamAnswer(@"Quick answer."));
    NSMutableDictionary* halfway = [SeamToolTurn(@[SeamCall(@"s1", @"read_pages")]) mutableCopy];
    halfway[@"content"] = @"So far: clause 7 sets the 20th.";
    Reply(TaskTurnFor(chat.model, @"TASK-SLOW"), halfway);
    TaskTurn* stuck = TaskTurnFor(chat.model, @"TASK-SLOW");
    CHECK(stuck && !MainTurn(chat.model, person), "the run waits for its slow task");
    NSDate* start = NSDate.date;
    TaskTurn* after = WaitForMainTurn(chat, person, 5);
    CHECK(after && -start.timeIntervalSinceNow < 3, "the whole run stops at its timeout");
    NSDictionary* result = [after resultFor:@"run"];
    NSArray* tasks = result[@"tasks"];
    CHECK([result[@"timed_out"] isEqual:@YES] && [tasks[0][@"status"] isEqual:@"answered"] &&
          [tasks[0][@"summary"] isEqual:@"Quick answer."] && [tasks[1][@"status"] isEqual:@"timed_out"] &&
          [tasks[1][@"summary"] isEqual:@"So far: clause 7 sets the 20th."],
          "and returns what each task has: the finished answer and the slow task's partial one");
    NSArray* rows = Rows(chat);
    // Out of time is a limit, as out of steps is, so both rows are failures; Stopped is for the person's Stop.
    CHECK([rows[0][SPDFMacAIActivityStateKey] isEqual:SPDFMacAIActivityStateDone] &&
          [rows[1][SPDFMacAIActivityStateKey] isEqual:SPDFMacAIActivityStateFailed] &&
          [rows[1][SPDFMacAIActivityStatusKey] isEqual:@"Ran out of time"] &&
          [rows[1][SPDFMacAIActivityDetailKey] isEqual:@"So far: clause 7 sets the 20th."],
          "the slow task's row says it ran out of time, as a failure like running out of steps, and shows what it had");
    NSUInteger turns = chat.model.turns.count;
    Reply(stuck, SeamAnswer(@"Too late."));
    SeamRunLoop(0.02);
    CHECK(chat.model.turns.count == turns && [after.tools count], "a stopped task's late reply goes nowhere");
    Reply(after, SeamAnswer(@"The 20th, from what was found in time."));
    EndTaskChat(chat);
}

static void CheckStopStopsEveryTask(void) {
    TaskChat chat = MakeTaskChat(@"stop");
    NSString* person = @"PERSON: three lookups, then Stop";
    Ask(chat, person, nil);
    Reply(MainTurn(chat.model, person), SeamToolTurn(@[RunCall(@"run", @[Job(@"One", @"TASK-ONE"),
        Job(@"Two", @"TASK-TWO"), Job(@"Three", @"TASK-THREE")])]));
    NSArray* pending = @[TaskTurnFor(chat.model, @"TASK-ONE"), TaskTurnFor(chat.model, @"TASK-TWO"),
                         TaskTurnFor(chat.model, @"TASK-THREE")];
    [chat.session cancel];
    CHECK(!chat.session.running && chat.session.activityState == SPDFMacAIChatActivityStopped, "Stop ends the request");
    NSArray* rows = Rows(chat);
    BOOL allStopped = rows.count == 3;
    for (NSDictionary* row in rows)
        allStopped = allStopped && [row[SPDFMacAIActivityStateKey] isEqual:SPDFMacAIActivityStateStopped] &&
            ![chat.session liveActivityActionsForEntry:row[SPDFMacAIActivityIDKey]].count;
    CHECK(allStopped, "every task's row shows it stopped, with no Cancel left");
    NSUInteger turns = chat.model.turns.count;
    for (TaskTurn* turn in pending) Reply(turn, SeamToolTurn(@[SeamCall(@"late", @"read_pages")]));
    SeamRunLoop(0.05);
    CHECK(chat.model.turns.count == turns && !chat.reader.ran.count, "no task goes on after Stop");
    EndTaskChat(chat);
}

// Stop reaches a run two ways: the provider's -cancel, and the request's cancellation token, which alone fires when
// the chat goes away mid-request (its session deallocated, no registry left to tell the providers).
static void CheckAbandonedRunStops(void) {
    TaskChat chat = MakeTaskChat(@"cancel-provider");
    NSString* person = @"PERSON: lookups the provider cancels";
    Ask(chat, person, nil);
    Reply(MainTurn(chat.model, person), SeamToolTurn(@[RunCall(@"run", @[Job(@"One", @"TASK-P1"),
                                                                        Job(@"Two", @"TASK-P2")])]));
    TaskTurn* pending = TaskTurnFor(chat.model, @"TASK-P1");
    [chat.subagents cancel];
    TaskTurn* after = MainTurn(chat.model, person);
    NSArray* tasks = [after resultFor:@"run"][@"tasks"];
    CHECK([tasks[0][@"status"] isEqual:@"stopped"] && [tasks[1][@"status"] isEqual:@"stopped"],
          "the provider's -cancel stops every task at once");
    NSUInteger turns = chat.model.turns.count;
    Reply(pending, SeamToolTurn(@[SeamCall(@"late", @"read_pages")]));
    CHECK(chat.model.turns.count == turns && !chat.reader.ran.count, "and none goes on");
    Reply(after, SeamAnswer(@"Stopped."));
    EndTaskChat(chat);

    TaskChat closing = MakeTaskChat(@"chat-gone");
    NSString* question = @"PERSON: lookups in a chat that closes";
    __weak SPDFMacAIChatSession* gone = closing.session;
    NSArray* waiting = nil;
    @autoreleasepool {
        Ask(closing, question, nil);
        Reply(MainTurn(closing.model, question), SeamToolTurn(@[RunCall(@"run", @[Job(@"One", @"TASK-G1"),
                                                                                  Job(@"Two", @"TASK-G2")])]));
        waiting = @[TaskTurnFor(closing.model, @"TASK-G1"), TaskTurnFor(closing.model, @"TASK-G2")];
    }
    closing.session = nil;
    CHECK(!gone, "fixture: the chat's session is gone");
    NSUInteger before = closing.model.turns.count;
    for (TaskTurn* turn in waiting) Reply(turn, SeamToolTurn(@[SeamCall(@"late", @"read_pages")]));
    SeamRunLoop(0.05);
    CHECK(closing.model.turns.count == before && !closing.reader.ran.count,
          "tasks stop with the request when its chat goes away, rather than running on to the timeout");
    EndTaskChat(closing);
}

static void CheckCancelOneTask(void) {
    TaskChat chat = MakeTaskChat(@"cancel-one");
    NSString* person = @"PERSON: two lookups, cancel one";
    Ask(chat, person, nil);
    Reply(MainTurn(chat.model, person), SeamToolTurn(@[RunCall(@"run", @[Job(@"First", @"TASK-FIRST"),
                                                                        Job(@"Second", @"TASK-SECOND")])]));
    NSArray* rows = Rows(chat);
    NSString* first = rows.firstObject[SPDFMacAIActivityIDKey];
    CHECK(rows.count == 2 && [[[chat.session liveActivityActionsForEntry:first] valueForKey:@"id"]
                                 containsObject:SPDFMacAIActivityActionCancel], "each task's row has Cancel");
    TaskTurn* firstTurn = TaskTurnFor(chat.model, @"TASK-FIRST");
    CHECK([chat.session performActivityAction:SPDFMacAIActivityActionCancel forEntry:first], "the person cancels one");
    CHECK(chat.session.running && !MainTurn(chat.model, person), "the other task and the request go on");
    Reply(TaskTurnFor(chat.model, @"TASK-SECOND"), SeamAnswer(@"Second answer."));
    TaskTurn* after = MainTurn(chat.model, person);
    NSArray* tasks = [after resultFor:@"run"][@"tasks"];
    CHECK([tasks[0][@"status"] isEqual:@"stopped"] && [tasks[1][@"status"] isEqual:@"answered"] &&
          [Rows(chat).firstObject[SPDFMacAIActivityStatusKey] isEqual:@"Stopped"],
          "the main assistant learns the person stopped that task; its row says so");
    NSUInteger turns = chat.model.turns.count;
    Reply(firstTurn, SeamAnswer(@"Too late."));
    CHECK(chat.model.turns.count == turns, "the cancelled task's late reply goes nowhere");
    Reply(after, SeamAnswer(@"Here is the second part."));
    EndTaskChat(chat);
}

static void CheckRowsAndSources(void) {
    TaskChat chat = MakeTaskChat(@"rows");
    NSString* page3 = @"spdf-ai://document?path=doc:a&page=3&revision=r1";
    NSString* page9 = @"spdf-ai://document?path=doc:a&page=9&revision=r1";
    chat.reader.answer = ^NSDictionary*(NSString* name, SPDFMacAIRequestContext* context) {
        (void)name; (void)context;
        return @{@"pages" : @[@{@"page" : @3, @"text" : @"Delivery: the 20th.", @"citation" : page3}]};
    };
    chat.reader.deferCompletion = YES;
    NSString* person = @"PERSON: when is delivery?";
    Ask(chat, person, nil);
    Reply(MainTurn(chat.model, person), SeamToolTurn(@[RunCall(@"run", @[Job(@"Delivery dates",
        @"TASK-DATES: find the delivery date"), Job(@"Fees", @"TASK-FEES")])]));
    NSArray* rows = Rows(chat);
    CHECK(rows.count == 2 && [rows[0][SPDFMacAIActivityTitleKey] isEqual:@"Delivery dates"] &&
          [rows[0][SPDFMacAIActivityDetailKey] isEqual:@"Asked: TASK-DATES: find the delivery date"] &&
          [rows[0][SPDFMacAIActivityStatusKey] isEqual:@"Thinking…"] &&
          [rows[0][SPDFMacAIActivityStateKey] isEqual:SPDFMacAIActivityStateRunning],
          "one row per task: its title, what it was asked as the detail, and what it is doing");
    Reply(TaskTurnFor(chat.model, @"TASK-DATES"), SeamToolTurn(@[SeamCall(@"d1", @"read_pages")]));
    CHECK([Rows(chat)[0][SPDFMacAIActivityStatusKey] isEqual:@"Reading pages…"] &&
          [Rows(chat)[1][SPDFMacAIActivityStatusKey] isEqual:@"Thinking…"], "a row follows the tool its task runs");
    chat.reader.deferCompletion = NO;
    chat.reader.pending(chat.reader.answer(@"read_pages", chat.reader.contexts.lastObject));
    CHECK([Rows(chat)[0][SPDFMacAIActivityStatusKey] isEqual:@"Thinking…"], "and thinking again after it");
    Reply(TaskTurnFor(chat.model, @"TASK-DATES"), SeamAnswer([NSString stringWithFormat:
        @"Delivery is on the 20th [Contract · p. 3](%@), not the 9th [Contract · p. 9](%@).", page3, page9]));
    NSDictionary* done = Rows(chat)[0];
    CHECK([done[SPDFMacAIActivityStateKey] isEqual:SPDFMacAIActivityStateDone] &&
          [done[SPDFMacAIActivityStatusKey] isEqual:@"Done"] &&
          [done[SPDFMacAIActivityDetailKey] isEqual:@"Delivery is on the 20th Contract · p. 3, not the 9th "
                                                     "Contract · p. 9."], "a finished row shows what its task found");
    Reply(TaskTurnFor(chat.model, @"TASK-FEES"), SeamAnswer(@"No fees found."));
    TaskTurn* after = MainTurn(chat.model, person);
    NSDictionary* dates = [after resultFor:@"run"][@"tasks"][0];
    CHECK([dates[@"sources"] isEqual:@[@{@"title" : @"Contract · p. 3", @"citation" : page3}]],
          "the task's sources are the citations its tools returned");
    NSDictionary* chatNow = chat.session.chat;
    CHECK(SPDFMacAIChatContainsCitation(chatNow, SPDFMacAICitationArguments([NSURL URLWithString:page3])) &&
          !SPDFMacAIChatContainsCitation(chatNow, SPDFMacAICitationArguments([NSURL URLWithString:page9])),
          "so the main chat verifies the task's real citation, and never the page it made up");
    Reply(after, SeamAnswer([NSString stringWithFormat:@"The 20th [Contract · p. 3](%@).", page3]));
    NSArray* saved = chat.session.chat[@"activity"];
    CHECK(saved.count == 2 && [saved[0][SPDFMacAIActivityTitleKey] isEqual:@"Delivery dates"] &&
          [saved[1][SPDFMacAIActivityDetailKey] isEqual:@"No fees found."], "the rows are kept with the chat");
    EndTaskChat(chat);
}
