// What a helper's row says when it doesn't finish, and what a request that includes Friends chats leaves in the chat
// file after searching, opening a page, running Python and running helpers. Included by SPDFMacAISubagentsTests.mm,
// after SPDFMacAISubagentsLimitChecks.h (MeiChip).
#pragma once

static void CheckFailedRows(void) {
    TaskChat chat = MakeTaskChat(@"failed-rows");
    chat.subagents.turnsPerRequest = 4;
    NSString* person = @"PERSON: two lookups that go wrong";
    Ask(chat, person, nil);
    Reply(MainTurn(chat.model, person), SeamToolTurn(@[RunCall(@"run", @[Job(@"Long", @"TASK-OUT: read everything"),
                                                                        Job(@"Broken", @"TASK-FAIL: look it up")])]));
    // Out of turns: its tools-off turn asks for a tool again, so the session pauses it.
    for (int turn = 0; turn < 2; turn++)
        Reply(TaskTurnFor(chat.model, @"TASK-OUT"), SeamToolTurn(@[SeamCall([NSString stringWithFormat:@"o%d", turn],
                                                                             @"read_pages")]));
    Reply(TaskTurnFor(chat.model, @"TASK-OUT"), SeamToolTurn(@[SeamCall(@"o9", @"read_pages")]));
    TaskTurn* broken = TaskTurnFor(chat.model, @"TASK-FAIL");
    broken.answered = YES;
    broken.reply(nil, [NSError errorWithDomain:@"test" code:1 userInfo:@{NSLocalizedDescriptionKey :
        @"The model is busy. Start a new chat to continue."}]);
    NSArray* rows = Rows(chat);
    CHECK(rows.count == 2 && [rows[0][SPDFMacAIActivityStatusKey] isEqual:@"Partly done"] &&
          [rows[0][SPDFMacAIActivityStateKey] isEqual:SPDFMacAIActivityStateDone] &&
          [rows[0][SPDFMacAIActivityDetailKey] hasPrefix:@"Stopped before finishing. So far 2 actions worked."] &&
          ![rows[0][SPDFMacAIActivityDetailKey] containsString:@"Continue"],
          "a helper out of turns is partly done and says what it did, never the limit or a Continue it hasn't");
    CHECK([rows[1][SPDFMacAIActivityStatusKey] isEqual:@"Didn’t finish"] &&
          [rows[1][SPDFMacAIActivityDetailKey] isEqual:@"Asked: TASK-FAIL: look it up\n\nThe model is busy."],
          "a failed helper adds its problem's first sentence, without advice meant for the main chat");
    TaskTurn* after = MainTurn(chat.model, person);
    NSArray* tasks = [after resultFor:@"run"][@"tasks"];
    CHECK([tasks[0][@"status"] isEqual:@"out_of_budget"] && [tasks[1][@"status"] isEqual:@"failed"] &&
          [tasks[1][@"problem"] containsString:@"busy"], "the model still gets each status and the whole problem");
    Reply(after, SeamAnswer(@"Neither lookup finished."));
    EndTaskChat(chat);
}

static void CheckFriendsRequestKeepsNothing(void) {
    TaskChat chat = MakeTaskChat(@"friends-storage");
    // Stand-ins for the web and Python providers, marking their calls as the seam asks (the real web tools aren't
    // even offered to a request that includes Friends chats). The search tool is TaskChat's own.
    SeamProvider* pages = [[SeamProvider alloc] initWithIdentifier:@"pages" tools:@{@"open_page" : @YES}];
    SeamProvider* python = [[SeamProvider alloc] initWithIdentifier:@"python" tools:@{@"run_python" : @YES}];
    BOOL (^friendsOnly)(NSString*, SPDFMacAIRequestContext*) = ^BOOL(NSString* name, SPDFMacAIRequestContext* c) {
        (void)name; return c.includesFriendsChats;
    };
    for (SeamProvider* provider in @[chat.web, pages, python]) provider.requestOnly = friendsOnly;
    [chat.session.registry registerProvider:pages error:nil];
    [chat.session.registry registerProvider:python error:nil];
    chat.web.answer = ^NSDictionary*(NSString* n, SPDFMacAIRequestContext* c) {
        (void)n; (void)c; return @{@"query" : @"QUERY-SECRET", @"results" : @[@"https://a.example/"]};
    };
    pages.answer = ^NSDictionary*(NSString* n, SPDFMacAIRequestContext* c) {
        (void)n; (void)c; return @{@"text" : @"PAGE-SECRET"};
    };
    python.answer = ^NSDictionary*(NSString* n, SPDFMacAIRequestContext* c) {
        (void)n; (void)c; return @{@"stdout" : @"OUTPUT-SECRET"};
    };
    NSString* page3 = @"spdf-ai://document?path=doc:a&page=3&revision=r1";
    chat.reader.answer = ^NSDictionary*(NSString* n, SPDFMacAIRequestContext* c) {
        (void)n; (void)c;
        return @{@"pages" : @[@{@"text" : @"Clause 7", @"citation" : [page3 stringByAppendingString:
            @"&query=SEARCHWORDS-SECRET"]}]};
    };
    NSString* person = @"PERSON: check @Mei's numbers";
    [chat.session sendContext:TaskRequest(chat, person, @[MeiChip()], nil, TaskSettings(YES)) model:@"fake/model"
                       apiKey:@"TEST-NOT-A-KEY"];
    Reply(MainTurn(chat.model, person), SeamToolTurn(@[SeamCall(@"f1", @"friends_search_chats"),
        @{@"id" : @"w1", @"type" : @"function", @"function" : @{@"name" : @"web_search",
          @"arguments" : JSONText(@{@"query" : @"QUERY-SECRET"})}},
        @{@"id" : @"o1", @"type" : @"function", @"function" : @{@"name" : @"open_page",
          @"arguments" : JSONText(@{@"url" : @"https://a.example/"})}},
        @{@"id" : @"p1", @"type" : @"function", @"function" : @{@"name" : @"run_python",
          @"arguments" : JSONText(@{@"code" : @"print('CODE-SECRET')"})}},
        RunCall(@"run", @[Job(@"Clause check", @"TASK-SECRET: Mei wrote 4471; find it in the contract")])]));
    Reply(TaskTurnFor(chat.model, @"TASK-SECRET"), SeamToolTurn(@[SeamCall(@"t1", @"read_pages")]));
    Reply(TaskTurnFor(chat.model, @"TASK-SECRET"), SeamAnswer([NSString stringWithFormat:
        @"FINDING-SECRET: clause 7 says 4471 [Contract · p. 3](%@&query=SEARCHWORDS-SECRET).", page3]));
    TaskTurn* after = MainTurn(chat.model, person);
    CHECK([after wireContains:@"FINDING-SECRET"] && [after wireContains:@"PAGE-SECRET"],
          "while the request runs, the main assistant reads every result");
    Reply(after, SeamAnswer([NSString stringWithFormat:@"They agree [Contract · p. 3](%@).", page3]));
    NSString* path = [chat.root stringByAppendingPathComponent:
        [chat.session.chat[@"id"] stringByAppendingPathExtension:@"json"]];
    NSString* file = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSArray* secrets = @[@"QUERY-SECRET", @"PAGE-SECRET", @"CODE-SECRET", @"OUTPUT-SECRET", @"TASK-SECRET", @"4471",
                         @"FINDING-SECRET", @"SEARCHWORDS-SECRET", @"Clause check"];
    NSMutableArray* found = [NSMutableArray array];
    for (NSString* secret in secrets) if ([file containsString:secret]) [found addObject:secret];
    CHECK(file.length && !found.count && [file containsString:@"They agree"] && [file containsString:@"\"Part\""],
          "the saved chat holds none of the query, the page, the code, its output, the part's task, its findings "
          "or the title the model gave it");
    if (found.count) fprintf(stderr, "  still in the file: %s\n", [found componentsJoinedByString:@", "].UTF8String);
    NSDictionary* reopened = [chat.store chatWithID:chat.session.chat[@"id"]];
    CHECK(reopened && SPDFMacAIResolveCitation(reopened, SPDFMacAICitationArguments([NSURL URLWithString:page3])),
          "the reopened chat still opens the page the answer cites");
    EndTaskChat(chat);
}
