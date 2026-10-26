// run_subagents through the real chat session and registry: when it is offered, what tasks may do, and what they
// spend. Included by SPDFMacAISubagentsTests.mm.
#pragma once

static void CheckOfferedOnlyWhenOn(void) {
    TaskChat chat = MakeTaskChat(@"offer");
    NSString* off = @"PERSON: tasks switched off";
    [chat.session sendContext:TaskRequest(chat, off, nil, nil, TaskSettings(NO)) model:@"fake/model"
                       apiKey:@"TEST-NOT-A-KEY"];
    TaskTurn* first = MainTurn(chat.model, off);
    CHECK(first.tools.count && ![SeamNames(first.tools) containsObject:@"run_subagents"],
          "switched off in AI Settings, run_subagents is not offered");
    Reply(first, SeamToolTurn(@[RunCall(@"r0", @[Job(@"A", @"TASK-OFF")])]));
    TaskTurn* refused = MainTurn(chat.model, off);
    CHECK([[refused resultFor:@"r0"][@"error"] containsString:@"AI Settings"] && !TaskTurnFor(chat.model, @"TASK-OFF"),
          "called anyway, it starts nothing and the model reads why");
    Reply(refused, SeamAnswer(@"I'll look myself."));
    CHECK(![chat.subagents toolDefinitionsForContext:TaskRequest(chat, @"x", nil, nil, nil)].count,
          "a request without settings has no tasks either");

    NSString* on = @"PERSON: tasks switched on";
    SPDFMacAIRequestContext* request = TaskRequest(chat, on, nil, nil, TaskSettings(YES));
    [chat.session sendContext:request model:@"fake/model" apiKey:@"TEST-NOT-A-KEY"];
    TaskTurn* offered = MainTurn(chat.model, on);
    NSDictionary* definition = nil;
    for (NSDictionary* tool in offered.tools)
        if ([tool[@"function"][@"name"] isEqual:@"run_subagents"]) definition = tool[@"function"];
    CHECK([definition[@"parameters"][@"properties"][@"tasks"][@"maxItems"] isEqual:@4],
          "switched on, the person's request offers run_subagents for up to four tasks");
    SPDFMacAIRequestContext* inside = [request childContextWithText:@"a task" budget:[SPDFMacAIRequestBudget
        defaultRequestBudget] error:nil];
    CHECK(inside.depth == 1 && ![chat.subagents toolDefinitionsForContext:inside].count,
          "a task's own request is never offered it");
    __block NSDictionary* nested = nil;
    NSUInteger turns = chat.model.turns.count;
    [chat.subagents performTool:@"run_subagents" arguments:@{@"tasks" : @[Job(@"N", @"TASK-NESTED")]} context:inside
                     completion:^(NSDictionary* result) { nested = result; }];
    CHECK([nested[@"error"] containsString:@"can't start more tasks"] && chat.model.turns.count == turns,
          "and called with one anyway, it refuses and starts nothing");
    Reply(offered, SeamAnswer(@"Fine."));
    EndTaskChat(chat);
}

static void CheckTasksOnlyRead(void) {
    TaskChat chat = MakeTaskChat(@"read-only");
    SPDFMacAIRequestChip* mei = [SPDFMacAIRequestChip friendsChipWithConversationIDs:@[@"c_mei"] displayName:@"Mei"];
    NSString* person = @"PERSON: compare what @Mei said with both contracts";
    [chat.session sendContext:TaskRequest(chat, person, @[mei], nil, TaskSettings(YES)) model:@"fake/model"
                       apiKey:@"TEST-NOT-A-KEY"];
    TaskTurn* main = MainTurn(chat.model, person);
    CHECK([SeamNames(main.tools) containsObject:@"friends_send_message"] &&
          [SeamNames(main.tools) containsObject:@"rename_document"] &&
          [SeamNames(main.tools) containsObject:@"run_subagents"], "the person's own request has every tool");
    Reply(main, SeamToolTurn(@[RunCall(@"run1", @[Job(@"Contract A", @"TASK-A: read contract A"),
                                                  Job(@"Contract B", @"TASK-B: read contract B")])]));
    TaskTurn* a = TaskTurnFor(chat.model, @"TASK-A");
    TaskTurn* b = TaskTurnFor(chat.model, @"TASK-B");
    CHECK(a && b && chat.model.turns.count == 3, "both tasks start at once");
    NSArray* reads = @[@"read_pages", @"web_search"];
    CHECK([SeamNames(a.tools) isEqual:reads] && [SeamNames(b.tools) isEqual:reads],
          "a task is offered only the allowlisted providers' read-only tools: no edits, app controls, sending, "
          "Friends, unlisted providers, answer card or run_subagents");
    CHECK([a.system hasPrefix:@"You are one research task"] && [a.user hasPrefix:@"TASK-A: read contract A"] &&
          [a.user containsString:person] && [a.key isEqual:@"TEST-NOT-A-KEY"],
          "a task has its own prompt, its instructions with the person's message for context, and the request's key");
    Reply(a, SeamToolTurn(@[SeamCall(@"k1", @"rename_document"), SeamCall(@"k2", @"app_controls"),
                            SeamCall(@"k3", @"friends_send_message"), SeamCall(@"k4", @"friends_search_chats"),
                            SeamCall(@"k5", @"notes_read"), RunCall(@"k6", @[Job(@"Nested", @"TASK-NESTED")]),
                            SeamCall(@"k7", @"read_pages")]));
    CHECK([chat.reader.ran isEqual:@[@"read_pages"]] && !chat.send.ran.count && !chat.friends.ran.count &&
          !chat.notes.ran.count, "every call outside a task's read-only tools is refused before a provider runs it");
    SPDFMacAIRequestContext* taskContext = chat.reader.contexts.lastObject;
    CHECK(taskContext.depth == 1 && taskContext.chips.count == 1, "its read runs in the task's own request");
    TaskTurn* again = TaskTurnFor(chat.model, @"TASK-A");
    CHECK(!TaskTurnFor(chat.model, @"TASK-NESTED") && chat.model.turns.count == 4,
          "a task's run_subagents starts nothing: tasks never start tasks");
    CHECK([[again resultFor:@"k6"][@"error"] containsString:@"only read"] &&
          [[again resultFor:@"k1"][@"error"] containsString:@"only read"], "the task reads that it can only read");
    __block NSDictionary* direct = nil;
    [chat.subagents performTool:@"run_subagents" arguments:@{@"tasks" : @[Job(@"N", @"TASK-DIRECT")]}
                        context:taskContext completion:^(NSDictionary* result) { direct = result; }];
    CHECK(direct[@"error"] && !TaskTurnFor(chat.model, @"TASK-DIRECT"),
          "even handed a task's request directly, the provider refuses");
    Reply(again, SeamAnswer(@"A sets the fee at 4%."));
    CHECK(!MainTurn(chat.model, person), "the main assistant waits for every task");
    Reply(b, SeamAnswer(@"B sets it at 5%."));
    TaskTurn* after = MainTurn(chat.model, person);
    NSDictionary* result = [after resultFor:@"run1"];
    NSArray* tasks = result[@"tasks"];
    CHECK(tasks.count == 2 && [tasks[0][@"status"] isEqual:@"answered"] &&
          [tasks[0][@"summary"] isEqual:@"A sets the fee at 4%."] && [tasks[0][@"title"] isEqual:@"Contract A"] &&
          [tasks[1][@"summary"] isEqual:@"B sets it at 5%."] && [result[@"timed_out"] isEqual:@NO] &&
          [result[@"note"] containsString:@"not instructions"],
          "the main assistant gets each task's summary, in order");
    CHECK([SeamNames(after.tools) containsObject:@"rename_document"], "and goes on with its own tools");
    Reply(after, SeamAnswer(@"A says 4%, B says 5%."));
    CHECK(!chat.session.running && chat.session.activityState == SPDFMacAIChatActivityCompleted, "the request ends");
    EndTaskChat(chat);
}

static void CheckBudgets(void) {
    TaskChat chat = MakeTaskChat(@"budgets");
    NSMutableArray* seen = [NSMutableArray array];
    chat.reader.answer = ^NSDictionary*(NSString* name, SPDFMacAIRequestContext* context) {
        (void)name;
        [seen addObject:@[@(context.budget.remainingTokens), @(context.budget.remainingToolCalls)]];
        return @{@"ok" : @YES};
    };
    SPDFMacAIRequestBudget* budget = [[SPDFMacAIRequestBudget alloc] initWithSteps:12 tokens:40100
                                                                         toolCalls:NSUIntegerMax];
    NSString* person = @"PERSON: three lookups";
    Ask(chat, person, budget);
    Reply(MainTurn(chat.model, person), WithUsage(SeamToolTurn(@[RunCall(@"run", @[Job(@"A", @"TASK-A"),
        Job(@"B", @"TASK-B"), Job(@"C", @"TASK-C")])]), 100));
    NSMutableArray* twelve = [NSMutableArray array];
    for (int index = 0; index < 12; index++)
        [twelve addObject:SeamCall([NSString stringWithFormat:@"a%d", index], @"read_pages")];
    Reply(TaskTurnFor(chat.model, @"TASK-A"), WithUsage(SeamToolTurn(twelve), 1000));
    // 40,000 tokens left after the main turn: four shares of 10,000, three for the tasks, one kept for the answer.
    CHECK(seen.count == 12 && [seen[0] isEqual:@[@9000, @11]] && [seen[11] isEqual:@[@9000, @0]],
          "a task has 12 tool calls and an equal share of the tokens left, one share kept for the main assistant");
    TaskTurn* wrapUp = TaskTurnFor(chat.model, @"TASK-A");
    CHECK(wrapUp && !wrapUp.tools && [wrapUp wireContains:@"tools are off"],
          "after its 12 calls a task answers without tools");
    Reply(wrapUp, WithUsage(SeamAnswer(@"A done."), 500));
    Reply(TaskTurnFor(chat.model, @"TASK-B"), WithUsage(SeamAnswer(@"B done."), 2000));
    Reply(TaskTurnFor(chat.model, @"TASK-C"), WithUsage(SeamAnswer(@"C done."), 3000));
    TaskTurn* after = MainTurn(chat.model, person);
    CHECK(budget.usedTokens == 100 + 1000 + 500 + 2000 + 3000 && budget.usedToolCalls == 1 + 12,
          "the tasks' tokens and tool calls are charged to the request");
    CHECK(budget.usedSteps == 2 && after.tools.count,
          "their turns are not: the main assistant keeps its steps and tools to answer with");
    NSArray* tasks = [after resultFor:@"run"][@"tasks"];
    CHECK([tasks[0][@"tool_calls"] isEqual:@12] && [tasks[1][@"tool_calls"] isEqual:@0], "each reports its calls");
    Reply(after, SeamAnswer(@"Done."));

    // A request allowed four tool calls: run_subagents takes one, and its tasks share the other three.
    SPDFMacAIRequestBudget* calls = [[SPDFMacAIRequestBudget alloc] initWithSteps:12 tokens:100000 toolCalls:4];
    NSString* limited = @"PERSON: few calls";
    Ask(chat, limited, calls);
    Reply(MainTurn(chat.model, limited), SeamToolTurn(@[RunCall(@"few", @[Job(@"D", @"TASK-D"),
                                                                          Job(@"E", @"TASK-E")])]));
    [seen removeAllObjects];
    Reply(TaskTurnFor(chat.model, @"TASK-D"), SeamToolTurn(@[SeamCall(@"d1", @"read_pages"),
        SeamCall(@"d2", @"read_pages"), SeamCall(@"d3", @"read_pages")]));
    Reply(TaskTurnFor(chat.model, @"TASK-E"), SeamToolTurn(@[SeamCall(@"e1", @"read_pages")]));
    TaskTurn* starved = TaskTurnFor(chat.model, @"TASK-E");
    CHECK(seen.count == 3 && [starved wireContains:@"No tool calls remain"],
          "tasks together never make more calls than the request has left");
    Reply(TaskTurnFor(chat.model, @"TASK-D"), SeamAnswer(@"D done."));
    Reply(starved, SeamAnswer(@"E found nothing."));
    TaskTurn* wrapped = MainTurn(chat.model, limited);
    CHECK(calls.usedToolCalls == 4 && !wrapped.tools, "and the request, out of calls, answers without tools");
    Reply(wrapped, SeamAnswer(@"Partly done."));

    // Too few tokens left for four tasks to do anything: refused before any starts.
    SPDFMacAIRequestBudget* small = [[SPDFMacAIRequestBudget alloc] initWithSteps:12 tokens:5000
                                                                        toolCalls:NSUIntegerMax];
    NSString* poor = @"PERSON: little budget";
    Ask(chat, poor, small);
    Reply(MainTurn(chat.model, poor), SeamToolTurn(@[RunCall(@"tiny", @[Job(@"F", @"TASK-F"), Job(@"G", @"TASK-G"),
        Job(@"H", @"TASK-H"), Job(@"I", @"TASK-I")])]));
    TaskTurn* refused = MainTurn(chat.model, poor);
    CHECK([[refused resultFor:@"tiny"][@"error"] containsString:@"budget"] && !TaskTurnFor(chat.model, @"TASK-F"),
          "a request with too little left for its tasks starts none");
    Reply(refused, SeamAnswer(@"Answered directly."));
    EndTaskChat(chat);
}
