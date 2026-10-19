// run_python in requests that include Friends chats, through a real chat session and chat store with the real provider
// and a scripted runner: the chat file must keep neither the code nor what it printed, and each run must reopen under
// its own title. Included by SPDFMacAIPythonTests.mm.
#pragma once
#import "SPDFMacAIPythonFakes.h"
#import "SPDFMacAIChatSession.h"
#import "SPDFMacAIChatStore.h"
#import "SPDFMacAITransport.h"

// Answers each model turn with whatever the check passes to `reply`; nothing leaves the Mac.
@interface PythonScriptedModel : SPDFMacAITransport
@property(nonatomic, copy) void (^reply)(NSDictionary*, NSError*);
@property(nonatomic) NSArray* messages;
@property(nonatomic) NSArray* definitions;
@property(nonatomic) NSUInteger sends;
@end
@implementation PythonScriptedModel
- (SPDFMacAIRequestToken*)sendMessages:(NSArray*)messages tools:(NSArray*)tools model:(NSString*)model
                                apiKey:(NSString*)key completion:(void (^)(NSDictionary*, NSError*))completion {
    (void)model;
    (void)key;
    self.messages = messages;
    self.definitions = tools;
    self.reply = completion;
    self.sends++;
    return [SPDFMacAIRequestToken new];
}
@end

// A Friends chip in the AI chat, or `/` typed in Mei's conversation.
static SPDFMacAIRequestContext* PythonFriendsContext(BOOL slash, id<SPDFMacAIActivityReporting> activity) {
    SPDFMacAIRequestChip* chip = [SPDFMacAIRequestChip friendsChipWithConversationIDs:@[ @"c_mei" ]
                                                                          displayName:@"Mei"];
    return [[SPDFMacAIRequestContext alloc] initWithText:@"Add up what Mei says I owe her" chips:slash ? nil : @[ chip ]
        origin:slash ? SPDFMacAIRequestOriginFriendComposer : SPDFMacAIRequestOriginChat
        friendConversation:slash ? chip : nil settings:FakeSettings(YES) budget:nil activity:activity];
}

static NSDictionary* PythonCall(NSString* identifier, NSString* code) {
    NSData* arguments = [NSJSONSerialization dataWithJSONObject:@{@"code" : code} options:0 error:nil];
    return @{@"role" : @"assistant", @"content" : @"", @"tool_calls" : @[ @{@"id" : identifier, @"type" : @"function",
        @"function" : @{@"name" : SPDFMacAIPythonToolName,
                        @"arguments" : [[NSString alloc] initWithData:arguments encoding:NSUTF8StringEncoding]}} ]};
}

static NSString* PythonSavedText(NSString* folder) {
    NSMutableString* saved = [NSMutableString string];
    for (NSString* name in [NSFileManager.defaultManager enumeratorAtPath:folder]) {
        NSString* text = [NSString stringWithContentsOfFile:[folder stringByAppendingPathComponent:name]
                                                   encoding:NSUTF8StringEncoding error:nil];
        if (text) [saved appendString:text];
    }
    return saved;
}

// D4 from the person's side: the step says the code and its output aren't kept, so the chat file must not hold them.
// One run succeeds and one fails; the failed one must reopen as 'Python run failed', not as a title set beforehand.
static void CheckFriendsSavedChat(void) {
    for (int slash = 0; slash < 2; slash++) {
        const char* origin = slash ? "`/` in a friend's conversation" : "a Friends chip";
        NSString* folder = SandboxTemporaryDirectory(@"aipython-chats");
        FakeRunner* runner = [FakeRunner new];
        runner.reply = @{@"ok" : @YES, @"status" : @"completed", @"exit_code" : @0, @"seconds" : @0.1,
                         @"stdout" : @"OUTPUT-4417 owed 42\n", @"stderr" : @""};
        FakeEnvironment* environment = [FakeEnvironment new];
        environment.installed = YES;
        environment.interpreterPath = @"/fake/bin/python3";
        SPDFMacAIPythonToolProvider* provider = [[SPDFMacAIPythonToolProvider alloc] initWithRunner:runner
                                                                                        environment:environment];
        SPDFMacAIToolRegistry* registry = [SPDFMacAIToolRegistry new];
        [registry registerProvider:provider error:nil];
        PythonScriptedModel* model = [PythonScriptedModel new];
        SPDFMacAIChatStore* store = [[SPDFMacAIChatStore alloc] initWithDirectory:[NSURL fileURLWithPath:folder]];
        SPDFMacAIChatSession* session = [[SPDFMacAIChatSession alloc] initWithTransport:model registry:registry
                                                                                  store:store];
        SPDFMacAIRequestContext* context = PythonFriendsContext(slash, session.activity);
        CHECK([registry isRequestOnlyTool:SPDFMacAIPythonToolName context:context] &&
              ![registry isRequestOnlyTool:SPDFMacAIPythonToolName context:FakeContext(session.activity, YES, nil)] &&
              ![provider isRequestOnlyTool:@"web_search" context:context],
              "run_python calls are kept for the request only when it includes Friends chats");
        [session sendContext:context model:@"example/model-for-tests" apiKey:@"sk-or-v1-test-key-not-real-000000"];
        CHECK(SandboxWait(^BOOL { return model.sends == 1; }) &&
              [[model.definitions valueForKeyPath:@"function.name"] containsObject:SPDFMacAIPythonToolName], origin);
        model.reply(PythonCall(@"call-1", @"print('CODE-7781', 42)"), nil);
        CHECK(SandboxWait(^BOOL { return model.sends == 2; }), "the run is answered");
        CHECK([[model.messages.lastObject[@"content"] description] containsString:@"OUTPUT-4417"],
              "within the request the model reads what the code printed");
        runner.reply = @{@"ok" : @YES, @"status" : @"failed", @"exit_code" : @1, @"seconds" : @0.1, @"stdout" : @"",
                         @"stderr" : @"ZeroDivisionError: CODE-5523"};
        model.reply(PythonCall(@"call-2", @"print('CODE-5523', 1 / 0)"), nil);
        CHECK(SandboxWait(^BOOL { return model.sends == 3; }), "the failed run is answered");
        model.reply(@{@"role" : @"assistant", @"content" : @"She says you owe her 42 yuan."}, nil);
        CHECK(SandboxWait(^BOOL { return !session.running; }), "the request finishes");
        NSString* saved = PythonSavedText(folder);
        CHECK([saved containsString:@"Add up what Mei says I owe her"] && [saved containsString:@"run_python"] &&
              ![saved containsString:@"CODE-7781"] && ![saved containsString:@"CODE-5523"] &&
              ![saved containsString:@"OUTPUT-4417"] && ![saved containsString:@"ZeroDivisionError"],
              "the saved chat file keeps each run_python call as a stub, without the code or what it printed");
        NSString* chatID = [store.chats.firstObject[@"id"] description];
        SPDFMacAIChatSession* reopened = [[SPDFMacAIChatSession alloc] initWithTransport:model registry:registry
                                                                                   store:store];
        if (chatID) [reopened loadChat:[store chatWithID:chatID]];
        NSArray* steps = FakeEntries(reopened.activity, SPDFMacAIActivityKindStep);
        CHECK([[steps valueForKey:SPDFMacAIActivityTitleKey] isEqual:(@[ @"Ran Python", @"Python run failed" ])] &&
              [[steps valueForKey:SPDFMacAIActivityStateKey]
                  isEqual:(@[ SPDFMacAIActivityStateDone, SPDFMacAIActivityStateFailed ])],
              "reopened, each run keeps its own title: the failed one reads 'Python run failed'");
        [session cancel];
        [NSFileManager.defaultManager removeItemAtPath:folder error:nil];
    }
}
