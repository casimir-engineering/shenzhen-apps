// run_python with a scripted runner and environment: when it is offered, consent before any install, arguments,
// presenting results, Friends-scoped requests, sandbox failures, concurrency and Stop. Included by
// SPDFMacAIPythonTests.mm.
#pragma once
#import "SPDFMacAIPythonFakes.h"

static void CheckOffering(void) {
    FakeRunner* runner = [FakeRunner new];
    FakeEnvironment* environment = [FakeEnvironment new];
    SPDFMacAIPythonToolProvider* provider = [[SPDFMacAIPythonToolProvider alloc] initWithRunner:runner
                                                                                    environment:environment];
    SPDFMacAIChatActivity* activity = FakeActivity();
    NSArray* offered = [provider toolDefinitionsForContext:FakeContext(activity, YES, nil)];
    CHECK([[offered valueForKeyPath:@"function.name"] isEqual:@[ @"run_python" ]],
          "run_python is offered while the switch is on, installed or not (the first call asks to install)");
    CHECK(environment.checks == 0 && runner.requests.count == 0,
          "offering the tool never looks at the Python environment: only a run or an Install does");
    CHECK([provider toolDefinitionsForContext:FakeContext(activity, NO, nil)].count == 0,
          "switched off in Settings, it is not offered");
    CHECK([provider isReadOnlyTool:@"run_python"] && [provider providesTool:@"run_python"] &&
          ![provider providesTool:@"web_search"], "it only reads, so subagents may use it");
    SPDFMacAIToolRegistry* registry = [SPDFMacAIToolRegistry new];
    [registry registerProvider:provider error:nil];
    __block NSDictionary* refused = nil;
    [registry performTool:@"run_python" arguments:@{@"code" : @"print(1)"} context:FakeContext(activity, NO, nil)
               completion:^(NSDictionary* result) { refused = result; }];
    SandboxWait(^BOOL { return refused != nil; });
    CHECK([refused[@"error"] containsString:@"switched off"] && runner.requests.count == 0,
          "a call while switched off is refused before it reaches the sandbox");
    NSString* description = SPDFMacAIPythonToolDefinition()[@"function"][@"description"];
    CHECK([description containsString:@"no network"] && [description containsString:@"30 seconds"] &&
          [description containsString:@"512 MB"] && [description containsString:@"64 KB"],
          "the model is told the limits the helper enforces");
}

static void CheckConsent(void) {
    FakeRunner* runner = [FakeRunner new];
    FakeEnvironment* environment = [FakeEnvironment new];
    SPDFMacAIPythonToolProvider* provider = [[SPDFMacAIPythonToolProvider alloc] initWithRunner:runner
                                                                                    environment:environment];
    SPDFMacAIChatActivity* activity = FakeActivity();
    NSDictionary* first = FakeCall(provider, @{@"code" : @"print(1)"}, FakeContext(activity, YES, nil));
    NSDictionary* second = FakeCall(provider, @{@"code" : @"print(2)"}, FakeContext(activity, YES, nil));
    NSArray* cards = FakeEntries(activity, SPDFMacAIActivityKindCard);
    CHECK([first[@"install_offered"] boolValue] && [first[@"error"] containsString:@"not installed"] &&
          [second[@"error"] containsString:@"not installed"], "without Python the code does not run, and the model "
          "is told the person was asked");
    CHECK(cards.count == 1 && [cards[0][SPDFMacAIActivityTitleKey] isEqual:@"Install Python for the assistant?"] &&
          [cards[0][SPDFMacAIActivityBodyKey] containsString:@"pypi.org"], "one card asks, and says what it fetches");
    CHECK(environment.installs == 0 && runner.requests.count == 0, "nothing is installed or run before consent");
    NSString* card = cards[0][SPDFMacAIActivityIDKey];
    CHECK([[[activity liveActionsForEntry:card] valueForKey:@"title"] isEqual:@[ @"Install" ]], "it offers Install");
    CHECK([activity performAction:@"install" forEntry:card] && environment.installs == 1,
          "pressing Install starts the installer");
    environment.progress(@"Downloading numpy, pandas and matplotlib");
    NSDictionary* entry = FakeEntries(activity, SPDFMacAIActivityKindCard)[0];
    CHECK([entry[SPDFMacAIActivityStatusKey] isEqual:@"Downloading numpy, pandas and matplotlib…"] &&
          [activity liveActionsForEntry:card].count == 0, "the card shows each stage and no second Install");
    NSDictionary* during = FakeCall(provider, @{@"code" : @"print(3)"}, FakeContext(activity, YES, nil));
    CHECK([during[@"error"] containsString:@"being installed"] &&
          FakeEntries(activity, SPDFMacAIActivityKindCard).count == 1,
          "a call during the install says so without another card");
    environment.installing = NO;
    environment.completion(@"Could not download. Check the internet connection, then try again.");
    entry = FakeEntries(activity, SPDFMacAIActivityKindCard)[0];
    CHECK([entry[SPDFMacAIActivityStateKey] isEqual:SPDFMacAIActivityStateFailed] &&
          [[[activity liveActionsForEntry:card] valueForKey:@"title"] isEqual:@[ @"Try Again" ]],
          "a failed install says why and offers Try Again");
    [activity performAction:@"install" forEntry:card];
    environment.installing = NO;
    environment.installed = YES;
    environment.completion(nil);
    entry = FakeEntries(activity, SPDFMacAIActivityKindCard)[0];
    CHECK(environment.installs == 2 && [entry[SPDFMacAIActivityStateKey] isEqual:SPDFMacAIActivityStateDone] &&
          [entry[SPDFMacAIActivityStatusKey] containsString:@"Ask again"], "once installed, the card says what next");
}

static void CheckArguments(void) {
    FakeRunner* runner = [FakeRunner new];
    FakeEnvironment* environment = [FakeEnvironment new];
    environment.installed = YES;
    environment.interpreterPath = @"/fake/assistant-python/bin/python3";
    SPDFMacAIPythonToolProvider* provider = [[SPDFMacAIPythonToolProvider alloc] initWithRunner:runner
                                                                                    environment:environment];
    SPDFMacAIRequestContext* context = FakeContext(FakeActivity(), YES, nil);
    NSArray* bad = @[ @{}, @{@"code" : @""}, @{@"code" : @3}, @{@"code" : @"1", @"shell" : @"ls"},
                      @{@"code" : @"1", @"files" : @[ @{@"name" : @"../x.csv", @"content" : @""} ]},
                      @{@"code" : @"1", @"files" : @[ @{@"name" : @"main.py", @"content" : @""} ]},
                      @{@"code" : @"1", @"files" : @[ @{@"name" : @"a.csv", @"content" : @1} ]},
                      @{@"code" : @"1", @"files" : @[ @{@"name" : @"a.csv", @"content" : @"", @"path" : @"/x"} ]} ];
    for (NSDictionary* arguments in bad)
        CHECK([FakeCall(provider, arguments, context)[@"error"] length] > 0, "malformed arguments are refused");
    CHECK(runner.requests.count == 0, "nothing malformed reaches the sandbox");
    runner.reply = @{@"ok" : @YES, @"status" : @"completed", @"exit_code" : @0, @"stdout" : @"ok\n"};
    FakeCall(provider, @{@"code" : @"print(1)", @"files" : @[ @{@"name" : @"data.csv", @"content" : @"a\n1\n"} ]},
             context);
    CHECK([runner.requests.lastObject isEqual:(@{@"interpreter" : @"/fake/assistant-python/bin/python3",
                                                 @"code" : @"print(1)",
                                                 @"files" : @[ @{@"name" : @"data.csv", @"text" : @"a\n1\n"} ]})],
          "the sandbox gets the environment's interpreter, the code and the files, and nothing the model chose");
}

static void CheckPresentation(void) {
    FakeRunner* runner = [FakeRunner new];
    FakeEnvironment* environment = [FakeEnvironment new];
    environment.installed = YES;
    environment.interpreterPath = @"/fake/bin/python3";
    SPDFMacAIPythonToolProvider* provider = [[SPDFMacAIPythonToolProvider alloc] initWithRunner:runner
                                                                                    environment:environment];
    NSArray* files = @[ @{@"name" : @"chart.png", @"size" : @73, @"data" : FakePNG()},
                        @{@"name" : @"summary.csv", @"size" : @20, @"data" : FakeBase64(@"month,total\n1,4\n2,9\n")},
                        @{@"name" : @"notes.txt", @"size" : @5, @"data" : FakeBase64(@"hello")},
                        @{@"name" : @"leak.txt", @"size" : @10, @"omitted" : @"link"},
                        @{@"name" : @"empty.csv", @"size" : @0, @"data" : @""} ];
    runner.reply = @{@"ok" : @YES, @"status" : @"completed", @"exit_code" : @0, @"seconds" : @0.42,
                     @"stdout" : @"total 13\n", @"stderr" : @"", @"files" : files, @"files_omitted" : @3};
    SPDFMacAIChatActivity* activity = FakeActivity();
    NSDictionary* result = FakeCall(provider, @{@"code" : @"print('total', 13)"}, FakeContext(activity, YES, nil));
    CHECK([result[@"stdout"] isEqual:@"total 13\n"] && [result[@"status"] isEqual:@"completed"],
          "the model reads what the code printed");
    CHECK([result[@"images"] isEqual:(@[ @{@"name" : @"chart.png", @"shown_to_person" : @YES} ])] &&
          FakeEntries(activity, SPDFMacAIActivityKindImage).count == 1, "a PNG is shown in the chat, with Save");
    NSDictionary* table = [result[@"tables"] firstObject];
    CHECK([table[@"rows"] isEqual:(@[ @[ @"month", @"total" ], @[ @"1", @"4" ], @[ @"2", @"9" ] ])] &&
          [table[@"row_count"] isEqual:@2], "a CSV comes back to the model as a table");
    NSArray* cards = FakeEntries(activity, SPDFMacAIActivityKindCard);
    CHECK(cards.count == 1 && [cards[0][SPDFMacAIActivityBodyKey] hasPrefix:@"| month | total |\n| --- | --- |\n"] &&
          [cards[0][SPDFMacAIActivityStatusKey] isEqual:@"2 rows"], "and to the person as a table card");
    CHECK([result[@"files"] containsObject:(@{@"name" : @"notes.txt", @"size" : @5, @"text" : @"hello"})] &&
          [result[@"files"] containsObject:(@{@"name" : @"leak.txt", @"size" : @10, @"returned" : @NO})] &&
          [result[@"files"] containsObject:(@{@"name" : @"empty.csv", @"size" : @0, @"text" : @""})] &&
          [result[@"files_not_listed"] isEqual:@3],
          "text files come back as text; what the helper withheld or did not list is still mentioned");
    NSDictionary* step = FakeEntries(activity, SPDFMacAIActivityKindStep).firstObject;
    CHECK([step[SPDFMacAIActivityTitleKey] isEqual:@"Ran Python"] &&
          [step[SPDFMacAIActivityStatusKey] isEqual:@"Finished in 0.4 s"] &&
          [step[SPDFMacAIActivityDetailStyleKey] isEqual:@"python"] &&
          [step[SPDFMacAIActivityDetailKey] isEqual:@"print('total', 13)"] &&
          [step[SPDFMacAIActivityOutputKey] isEqual:@"total 13\n"] && !step[SPDFMacAIActivityNoteKey],
          "a finished step reads 'Ran Python', with only the code in the code box and its printed output apart");
    CHECK(!cards[0][SPDFMacAIActivityStoredTitleKey] && !cards[0][SPDFMacAIActivityStoredNoticeKey] &&
          !step[SPDFMacAIActivityStoredNoticeKey], "outside a request with Friends chats nothing is set to replace");

    // A request that read Friends chats: nothing it printed or drew may outlive the request.
    SPDFMacAIChatActivity* scoped = FakeActivity();
    NSArray* chips = @[ [SPDFMacAIRequestChip friendsChipWithConversationIDs:@[ @"c_mei" ] displayName:@"Mei"] ];
    NSDictionary* friendly = FakeCall(provider, @{@"code" : @"print('total', 13)"}, FakeContext(scoped, YES, chips));
    NSData* stored = [NSJSONSerialization dataWithJSONObject:SPDFMacAIActivityEntriesForStorage(scoped.entries)
                                                     options:0 error:nil];
    NSString* storedText = [[NSString alloc] initWithData:stored encoding:NSUTF8StringEncoding];
    NSDictionary* scopedStep = FakeEntries(scoped, SPDFMacAIActivityKindStep).firstObject;
    CHECK(FakeEntries(scoped, SPDFMacAIActivityKindImage).count == 0 &&
          [friendly[@"images"][0][@"shown_to_person"] isEqual:@NO] && [friendly[@"note"] containsString:@"Friends"],
          "images are not shown for a request that read Friends chats, and the model is told why");
    CHECK([scopedStep[SPDFMacAIActivityNoteKey] isEqual:
              @"Charts aren’t shown for requests that include your Friends chats."] &&
          [scopedStep[SPDFMacAIActivityDetailKey] isEqual:@"print('total', 13)"] &&
          !scopedStep[SPDFMacAIActivityStoredTitleKey],
          "the step says in its own line that a chart was withheld, so the person is not left wondering");
    CHECK(![storedText containsString:@"total 13"] && ![storedText containsString:@"month"] &&
          ![storedText containsString:@"summary.csv"] && [storedText containsString:@"Ran Python"] &&
          [storedText containsString:@"Table from Python"],
          "its code, output and tables are kept for the request only, under titles the model did not write");
    CHECK([storedText containsString:@"Not kept after this request, because it included your Friends chats."]
          && ![storedText containsString:@"because it read"],
          "what replaces them says the request included the Friends chats, not that the code read them");

    NSString* longOutput = [@"" stringByPaddingToLength:65536 withString:@"\"\\" startingAtIndex:0];
    NSString* longText = [@"" stringByPaddingToLength:60000 withString:@"\"" startingAtIndex:0];
    runner.reply = @{@"ok" : @YES, @"status" : @"completed", @"exit_code" : @0, @"stdout" : longOutput,
                     @"stderr" : longOutput, @"files" : @[ @{@"name" : @"a.txt", @"size" : @60000,
                                                             @"data" : FakeBase64(longText)} ]};
    NSDictionary* huge = FakeCall(provider, @{@"code" : @"print(1)"}, FakeContext(FakeActivity(), YES, nil));
    NSData* json = [NSJSONSerialization dataWithJSONObject:huge options:0 error:nil];
    CHECK(json.length <= SPDFMacAIPythonResultBudget && [huge[@"stdout"] length] > 1000,
          "the model's result always fits the chat's tool-result budget, keeping as much output as fits");
}
