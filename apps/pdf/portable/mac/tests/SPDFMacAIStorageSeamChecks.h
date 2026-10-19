// Tool calls kept for their request only (SPDFMacAIToolProvider.h § 4): what a provider marks with
// -isRequestOnlyTool:context: never reaches the chat file, from the first save on, while the request itself still
// reads it. Included by SPDFMacAIToolSeamTests.mm, after SPDFMacAISessionSeamChecks.h (SeamChat, SeamRequest).
#pragma once
#import "SPDFMacAICitations.h"

// The chat file exactly as it is on disk, for checks that look for words anywhere in it.
static NSString* SeamChatFile(SeamChat chat) {
    NSString* path = [chat.root stringByAppendingPathComponent:
        [chat.session.chat[@"id"] stringByAppendingPathExtension:@"json"]];
    NSData* data = [NSData dataWithContentsOfFile:path];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
}
static NSString* SeamJSON(id value) {
    NSData* data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}
static NSDictionary* SeamArgumentsCall(NSString* identifier, NSString* name, NSDictionary* arguments) {
    return @{@"id" : identifier, @"type" : @"function",
             @"function" : @{@"name" : name, @"arguments" : SeamJSON(arguments)}};
}
static BOOL SeamTextHasAny(NSString* text, NSArray<NSString*>* words) {
    for (NSString* word in words) if ([text containsString:word]) return YES;
    return NO;
}

static void CheckStoredRequestOnlyMessages(void) {
    NSArray* messages = @[
        @{@"role" : @"assistant", @"content" : @"", @"tool_calls" : @[
            SeamArgumentsCall(@"p1", @"run_python", @{@"code" : @"print('CODE-SECRET')"}),
            SeamArgumentsCall(@"r1", @"read_pages", @{@"page" : @3})]},
        @{@"role" : @"tool", @"tool_call_id" : @"p1", @"content" : @"{\"stdout\":\"OUTPUT-SECRET\",\"nested\":"
          "{\"citation\":\"spdf-ai://document?path=doc:a&page=3&revision=r1&query=WORDS-SECRET\"}}"},
        @{@"role" : @"tool", @"tool_call_id" : @"r1", @"content" : @"{\"text\":\"Clause 7\"}"}];
    CHECK(SPDFMacAIChatStoredRequestOnlyMessages(messages, [NSSet set]) == messages,
          "with no request-only call the messages are kept as they are");
    NSArray* stored = SPDFMacAIChatStoredRequestOnlyMessages(messages, [NSSet setWithObject:@"p1"]);
    NSString* text = SeamJSON(stored);
    CHECK(!SeamTextHasAny(text, @[@"CODE-SECRET", @"OUTPUT-SECRET", @"WORDS-SECRET"]) &&
          [stored[0][@"tool_calls"][0][@"function"] isEqual:@{@"name" : @"run_python", @"arguments" : @"{}"}] &&
          [stored[0][@"tool_calls"][1] isEqual:messages[0][@"tool_calls"][1]] && stored[2] == messages[2],
          "a request-only call keeps its name with no arguments and its result only as a stub; other calls stay");
    NSDictionary* page = SPDFMacAICitationArguments([NSURL URLWithString:
        @"spdf-ai://document?path=doc:a&page=3&revision=r1"]);
    NSDictionary* chat = @{@"messages" : stored};
    CHECK([stored[1][@"content"] containsString:SPDFMacAIChatRequestOnlyNotice] &&
          SPDFMacAIChatContainsCitation(chat, page),
          "the stub tells the model why, and keeps the document citation, without its search words, so links open");
    CHECK([SPDFMacAIChatStoredRequestOnlyMessages(stored, [NSSet setWithObject:@"p1"]) isEqual:stored],
          "a stub stubs to itself, so the next save matches the file");
}

// Searched, opened a page and ran Python in a request with a Friends chip, then a request without one. The model also
// called a tool no provider owns and one its provider held back from that request: nobody vouches for their input.
static void CheckRequestOnlyCallsLeaveNothing(void) {
    SeamChat chat = SeamMakeChat(@"request-only");
    // Stand-ins for any provider that keeps its calls for the request only; the real web tools aren't even offered
    // to a request that includes Friends chats.
    SeamProvider* work = [[SeamProvider alloc] initWithIdentifier:@"work" tools:@{@"web_search" : @YES,
        @"open_page" : @YES, @"run_python" : @YES}];
    work.requestOnly = ^BOOL(NSString* name, SPDFMacAIRequestContext* context) {
        (void)name; return context.includesFriendsChats;
    };
    work.answer = ^NSDictionary*(NSString* name, SPDFMacAIRequestContext* context) {
        (void)context;
        if ([name isEqual:@"web_search"]) return @{@"query" : @"QUERY-SECRET", @"results" : @[@"https://a.example/"]};
        if ([name isEqual:@"open_page"]) return @{@"url" : @"https://a.example/", @"text" : @"PAGE-SECRET"};
        return @{@"stdout" : @"OUTPUT-SECRET"};
    };
    [chat.session.registry registerProvider:work error:nil];
    SeamProvider* notes = [[SeamProvider alloc] initWithIdentifier:@"notes" tools:@{@"export_notes" : @NO}];
    notes.offers = ^BOOL(NSString* name, SPDFMacAIRequestContext* context) {
        (void)name; return !context.includesFriendsChats;
    };
    [chat.session.registry registerProvider:notes error:nil];
    SPDFMacAIRequestChip* mei = [SPDFMacAIRequestChip friendsChipWithConversationIDs:@[@"c_mei"] displayName:@"Mei"];
    [chat.session sendContext:SeamRequest(chat.session, @"Check @Mei's list", @[mei], nil) model:@"fake/model"
                       apiKey:@"TEST-NOT-A-KEY"];
    work.deferCompletion = YES;
    chat.model.reply(SeamToolTurn(@[SeamArgumentsCall(@"w1", @"web_search", @{@"query" : @"QUERY-SECRET"}),
        SeamArgumentsCall(@"w2", @"open_page", @{@"url" : @"https://a.example/"}),
        SeamArgumentsCall(@"p1", @"run_python", @{@"code" : @"print('CODE-SECRET')"}),
        SeamArgumentsCall(@"r1", @"read_pages", @{@"page" : @"KEPT-ARGUMENT"}),
        SeamArgumentsCall(@"u1", @"mystery_tool", @{@"note" : @"UNKNOWN-SECRET"}),
        SeamArgumentsCall(@"h1", @"export_notes", @{@"text" : @"HELDBACK-SECRET"})]), nil);
    NSArray* secrets = @[@"QUERY-SECRET", @"PAGE-SECRET", @"CODE-SECRET", @"OUTPUT-SECRET", @"UNKNOWN-SECRET",
                         @"HELDBACK-SECRET"];
    NSString* first = SeamChatFile(chat);
    CHECK([first containsString:@"web_search"] && [first containsString:@"KEPT-ARGUMENT"] &&
          !SeamTextHasAny(first, secrets), "the file saved before the calls run already holds none of their input");
    for (int call = 0; call < 3 && work.pending; call++) {
        SPDFMacAIToolCompletion pending = work.pending;
        work.pending = nil;
        pending(work.answer(work.ran.lastObject, nil));
    }
    CHECK(SeamWireContains(chat.model, @"PAGE-SECRET") && SeamWireContains(chat.model, @"OUTPUT-SECRET"),
          "while the request runs, the model still reads what its calls found");
    CHECK(SeamWireContains(chat.model, @"UNKNOWN-SECRET") && SeamWireContains(chat.model, @"HELDBACK-SECRET") &&
          !notes.ran.count, "the calls nobody ran are still the request's history, refused rather than run");
    chat.model.reply(SeamAnswer(@"Mei's list matches."), nil);
    NSString* file = SeamChatFile(chat);
    CHECK(chat.session.activityState == SPDFMacAIChatActivityCompleted && !SeamTextHasAny(file, secrets) &&
          [file containsString:@"Mei's list matches."],
          "after the request the saved chat holds none of the query, the page, the code or its output");
    CHECK(!SeamTextHasAny(SeamJSON(chat.session.chat), secrets) &&
          [chat.store chatWithID:chat.session.chat[@"id"]] != nil,
          "the open chat keeps what the file keeps, and the file still opens");

    [chat.session sendContext:SeamRequest(chat.session, @"Search for the standard", nil, nil) model:@"fake/model"
                       apiKey:@"TEST-NOT-A-KEY"];
    CHECK(!SeamTextHasAny(SeamJSON(chat.model.messages), secrets), "the next request's model never reads them");
    work.deferCompletion = NO;
    chat.model.reply(SeamToolTurn(@[SeamArgumentsCall(@"w3", @"web_search", @{@"query" : @"PLAIN-QUERY"}),
        SeamArgumentsCall(@"u2", @"mystery_tool", @{@"note" : @"PLAIN-UNKNOWN"})]), nil);
    chat.model.reply(SeamAnswer(@"Found it."), nil);
    CHECK([SeamChatFile(chat) containsString:@"PLAIN-QUERY"] && [SeamChatFile(chat) containsString:@"PLAIN-UNKNOWN"],
          "a request without Friends chats keeps its calls, even one to a tool nobody owns");

    // Stop while the call runs: no result ever comes, and its code still never reaches the file.
    [chat.session sendContext:SeamRequest(chat.session, @"Run @Mei's numbers", @[mei], nil) model:@"fake/model"
                       apiKey:@"TEST-NOT-A-KEY"];
    work.deferCompletion = YES;
    chat.model.reply(SeamToolTurn(@[SeamArgumentsCall(@"p2", @"run_python", @{@"code" : @"STOPPED-SECRET"})]), nil);
    [chat.session cancel];
    CHECK(work.pending && ![SeamChatFile(chat) containsString:@"STOPPED-SECRET"],
          "a call stopped before its result leaves no input in the file either");
    work.pending = nil;
    [NSFileManager.defaultManager removeItemAtPath:chat.root error:nil];
}
