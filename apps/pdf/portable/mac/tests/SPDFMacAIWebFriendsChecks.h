// Requests that include Friends chats: an @ chip (one friend or All Friends chats), or `/` typed in a friend's
// conversation. Their model may have read a friend's messages, so no web tool is offered or runs in them, their
// subagents included, the model is told why, and a web call it makes anyway is saved only as a stub.
#pragma once
#import "SPDFMacAIWebSessionChecks.h"
#import "SPDFMacAIChatStore.h"

static NSString* const kWebFriendsWords = @"include the user's Friends chats";

typedef struct {
    const char* name;
    BOOL chip, all, slash, conversation;
} WebFriendsOrigin;

static const WebFriendsOrigin kWebFriendsOrigins[] = {
    {"a Friends chip", YES, NO, NO, NO},
    {"an All Friends chats chip", YES, YES, NO, NO},
    {"`/` in a friend's conversation", NO, NO, YES, YES},
    {"`/` without a conversation named", NO, NO, YES, NO},
};

static SPDFMacAIRequestContext* WebFriendsContext(WebFriendsOrigin origin, NSString* text, BOOL web,
                                                  id<SPDFMacAIActivityReporting> activity) {
    SPDFMacAIRequestChip* chip = [SPDFMacAIRequestChip friendsChipWithConversationIDs:
        origin.all ? nil : @[@"conversation-mei"] displayName:origin.all ? @"All Friends chats" : @"Mei"];
    return [[SPDFMacAIRequestContext alloc] initWithText:text chips:origin.chip ? @[chip] : nil
        origin:origin.slash ? SPDFMacAIRequestOriginFriendComposer : SPDFMacAIRequestOriginChat
        friendConversation:origin.conversation ? chip : nil settings:WebSettings(web) budget:nil activity:activity];
}

static BOOL WebToldFriends(NSArray<NSDictionary*>* sent, NSArray<NSDictionary*>* built) {
    NSDictionary* note = sent.count == built.count + 1 ? sent[1] : nil;
    return [note[@"role"] isEqual:@"system"] && [note[@"content"] containsString:kWebFriendsWords] &&
        [sent[0] isEqual:built[0]] && [[sent subarrayWithRange:NSMakeRange(2, built.count - 1)]
                                       isEqual:[built subarrayWithRange:NSMakeRange(1, built.count - 1)]];
}

static void CheckFriendsNoWeb(void) {
    WebRig* rig = [WebRig new];
    [rig page:@"bakery.example.com" path:@"/hours" html:@"<p>Sunday 8-14</p>"];
    NSString* text = @"@Mei is the bakery she mentioned open on Sunday? https://bakery.example.com/hours";
    NSArray* built = @[@{@"role" : @"system", @"content" : @"You are the assistant."},
                       @{@"role" : @"user", @"content" : text}];
    for (WebFriendsOrigin origin : kWebFriendsOrigins) {
        SPDFMacAIRequestContext* context = WebFriendsContext(origin, text, YES, rig.recorder);
        [rig.registry beginRequestWithContext:context];
        NSArray* sent = [rig.registry messagesForRequest:built context:context];
        CHECK(![rig.registry toolDefinitionsForContext:context].count, origin.name);
        CHECK(WebToldFriends(sent, built), "the turn tells the model why, after its instructions");
        for (NSArray* call in @[@[@"web_search", @{@"query" : @"Lin's bakery Futian"}],
                                @[@"open_page", @{@"url" : @"https://bakery.example.com/hours"}]]) {
            CHECK(WebRefused([rig call:call[0] arguments:call[1] context:context], kWebFriendsWords),
                  "a web call is refused with the same reason, even for an address the person typed");
            __block NSDictionary* direct = nil;
            [rig.provider performTool:call[0] arguments:call[1] context:context
                           completion:^(NSDictionary* value) { direct = value; }];
            CHECK(WebRefused(direct, kWebFriendsWords), "by the provider on its own as well");
            CHECK([rig.registry isRequestOnlyTool:call[0] context:context],
                  "and the call is kept for the request only, so the chat file never holds its arguments");
        }
        NSError* error = nil;
        SPDFMacAIRequestContext* child = [context childContextWithText:@"look up the bakery"
            budget:[context.budget childBudgetWithSteps:2 tokens:1000 toolCalls:2] error:&error];
        SPDFMacAIToolRegistry* helper = [rig.registry registryWithFilter:[SPDFMacAIToolFilter readOnlyFromProviders:
            [NSSet setWithObject:SPDFMacAIWebToolProviderIdentifier]]];
        CHECK(child && ![helper toolDefinitionsForContext:child].count &&
              WebToldFriends([helper messagesForRequest:built context:child], built),
              "a subagent of such a request has no web tools either, and is told why");
        CHECK(WebRefused([rig call:@"web_search" arguments:@{@"query" : @"bakery"} context:child], kWebFriendsWords),
              "and its calls are refused");
        [rig.registry endRequestWithContext:context];
    }
    CHECK(!rig.keyReads && !rig.transport.requests.count && !rig.resolver.asked.count &&
          !rig.connector.connections.count && !rig.activity.entries.count,
          "nothing is read, sent, looked up or shown for any of them");

    SPDFMacAIRequestContext* off = WebFriendsContext(kWebFriendsOrigins[0], text, NO, rig.recorder);
    CHECK(WebRefused([rig call:@"web_search" arguments:@{@"query" : @"x"} context:off], kWebFriendsWords),
          "with the switch off too, the reason given is the one turning it on would not change");
    SPDFMacAIRequestContext* plain = [rig begin:text web:YES];
    CHECK([rig.registry toolDefinitionsForContext:plain].count == 2 &&
          [[rig.registry messagesForRequest:built context:plain] isEqual:built] &&
          ![rig.registry isRequestOnlyTool:@"web_search" context:plain],
          "a request without Friends chats is offered both tools, told nothing, and keeps its calls");
}

static NSString* WebSavedText(NSString* folder) {
    NSMutableString* saved = [NSMutableString string];
    NSDirectoryEnumerator* files = [NSFileManager.defaultManager enumeratorAtPath:folder];
    for (NSString* name in files) {
        NSString* text = [NSString stringWithContentsOfFile:[folder stringByAppendingPathComponent:name]
                                                   encoding:NSUTF8StringEncoding error:nil];
        if (text) [saved appendString:text];
    }
    return saved;
}

// D4 from the person's side: Friends says the messages it read aren't kept, so nothing the model wrote for the web
// after reading them may stay in the chat file. Here the model asks for a search and a page anyway.
static void CheckFriendsSavedChat(void) {
    const WebFriendsOrigin origins[] = {kWebFriendsOrigins[0], kWebFriendsOrigins[2]}; // a chip, and `/`
    for (WebFriendsOrigin origin : origins) {
        NSString* folder = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"spdf-ai-web-chats-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil
                                                      error:nil];
        WebRig* rig = [WebRig new];
        WebScriptedModel* model = [WebScriptedModel new];
        SPDFMacAIChatSession* session = [[SPDFMacAIChatSession alloc] initWithTransport:model registry:rig.registry
            store:[[SPDFMacAIChatStore alloc] initWithDirectory:[NSURL fileURLWithPath:folder]]];
        SPDFMacAIRequestContext* context = WebFriendsContext(origin, @"Is the bakery she mentioned open on Sunday?",
            YES, [[WebActivityRecorder alloc] initWithActivity:session.activity]);
        [session sendContext:context model:@"example/model-for-tests" apiKey:@"sk-or-v1-test-key-not-real-000000"];
        CHECK(WebWait(^BOOL { return model.sends == 1; }, 2), "the model is asked");
        NSArray* names = [model.definitions valueForKeyPath:@"function.name"] ?: @[];
        CHECK(![names containsObject:@"web_search"] && ![names containsObject:@"open_page"], origin.name);
        CHECK(model.messages.count > 1 && [model.messages[1][@"content"] containsString:kWebFriendsWords],
              "the model's turn says the web is unavailable and why");
        model.reply(@{@"role" : @"assistant", @"content" : @"", @"tool_calls" : @[
            @{@"id" : @"call-1", @"type" : @"function", @"function" : @{@"name" : @"web_search",
              @"arguments" : @"{\"query\":\"Lin's bakery Futian Sunday hours\"}"}},
            @{@"id" : @"call-2", @"type" : @"function", @"function" : @{@"name" : @"open_page",
              @"arguments" : @"{\"url\":\"https://bakery.example.com/hours?near=Futian\"}"}}]}, nil);
        CHECK(WebWait(^BOOL { return model.sends == 2; }, 5), "both calls are answered");
        NSUInteger refusals = 0;
        for (NSDictionary* message in model.messages)
            refusals += [message[@"role"] isEqual:@"tool"] && [message[@"content"] containsString:kWebFriendsWords];
        CHECK(refusals == 2 && !rig.transport.requests.count && !rig.resolver.asked.count &&
              !session.activity.entries.count, "both are refused: nothing searched, opened or shown");
        model.reply(@{@"role" : @"assistant", @"content" : @"I can't use the web in this request."}, nil);
        CHECK(WebWait(^BOOL { return !session.running; }, 2), "the request finishes");
        NSString* saved = WebSavedText(folder);
        CHECK([saved containsString:@"Is the bakery she mentioned open on Sunday?"] &&
              ![saved containsString:@"Futian"], "the saved chat file holds neither the query nor the address");
        [session cancel];
        [NSFileManager.defaultManager removeItemAtPath:folder error:nil];
    }
}
