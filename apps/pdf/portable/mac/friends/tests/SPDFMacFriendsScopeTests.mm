// AI scope enforcement, instrumented (brief § Release gates, Assistant track): a request without an `@` scope has no
// Friends tools; scoped calls cannot read outside the scope; the scope ends with the request; instructions inside a
// friend's message call no tools. The end-to-end cases run ShenzhenPDF's real SPDFMacAIChatSession against a
// scripted model, so what is enforced is what the reader would do, not what a prompt asks for.

#import <AppKit/AppKit.h>
#import "SPDFMacAIChatSession.h"
#import "SPDFMacAIChatStore.h"
#import "SPDFMacFriendsChatTools.h"
#import "SPDFMacFriendsComposerText.h"
#import "SPDFMacFriendsTestSupport.h"
#import "SPDFMacFriendsScopeFakes.h"

static NSArray* ToolNames(NSArray* definitions) { return [definitions valueForKeyPath:@"function.name"] ?: @[]; }

static NSDictionary* Run(SPDFMacFriendsChatScopeGate* gate, NSString* tool, NSDictionary* arguments) {
    __block NSDictionary* result = nil;
    [gate performTool:tool arguments:arguments completion:^(NSDictionary* r) { result = r; }];
    SPDFMacFriendsTestRunUntil(5, ^BOOL { return result != nil; });
    Expect(result, @"%@ never completed", tool);
    return result;
}

static void TestUnscopedRequestHasNoFriendsTools(void) {
    FakeServices* services = [FakeServices new];
    SPDFMacFriendsChatScopeGate* gate = [[SPDFMacFriendsChatScopeGate alloc] initWithServices:^{ return services; }];
    [gate beginRequestWithScope:nil];
    Expect(!gate.toolDefinitionsForCurrentRequest.count, @"an unscoped request was offered Friends tools");
    NSDictionary* result = Run(gate, SPDFMacFriendsSearchToolName, @{@"query" : @"delivery"});
    // Refused as "not part of this request", telling the model how a person brings chats in, not as a failure.
    Expect([result[@"error"] containsString:@"type @"] && services.opens == 0 && services.scope.searches == 0,
           @"an unscoped call reached the helper or was refused for the wrong reason: %@", result);
}

static void TestScopedCallsStayInScope(void) {
    FakeServices* services = [FakeServices new];
    SPDFMacFriendsChatScopeGate* gate = [[SPDFMacFriendsChatScopeGate alloc] initWithServices:^{ return services; }];
    [gate beginRequestWithScope:[SPDFMacFriendsScopeRequest conversationIDs:@[@"c_mei"] labels:@[@"Mei"]]];
    Expect(services.opens == 1 && [services.openedIDs isEqual:@[@"c_mei"]], @"scope opened for %@", services.openedIDs);
    Expect([ToolNames(gate.toolDefinitionsForCurrentRequest) containsObject:SPDFMacFriendsSearchToolName],
           @"a scoped request must offer the Friends tools");
    // The helper limits the scope; a result from another conversation (a helper bug) must still never be shown.
    services.scope.searchResults = @[FakeResult(@"c_mei", @"m_1", @"Delivery moves to the 20th"),
                                     FakeResult(@"c_kenji", @"m_9", @"Kenji's private note")];
    NSDictionary* result = Run(gate, SPDFMacFriendsSearchToolName, @{@"query" : @"delivery"});
    NSArray* results = result[@"results"];
    Expect(results.count == 1 && [results[0][@"message_id"] isEqual:@"m_1"] && gate.requestReadChats,
           @"search crossed the scope: %@", result);
    Expect([results[0][@"citation"] hasPrefix:@"shenzhenpdf-friends://message?"], @"citation %@",
           results[0][@"citation"]);
    services.scope.readExcerpt = @{@"conversation_id" : @"c_kenji", @"conversation_title" : @"Kenji",
                                   @"messages" : @[@{@"message_id" : @"m_9", @"text" : @"private"}],
                                   @"truncated" : @NO};
    result = Run(gate, SPDFMacFriendsReadToolName, @{@"message_id" : @"m_9"});
    Expect(result[@"error"] && !result[@"messages"], @"a read outside the scope returned messages: %@", result);
    result = Run(gate, SPDFMacFriendsReadToolName, @{@"message_id" : @"../../etc"});
    Expect(result[@"error"] && services.scope.reads == 1, @"a malformed message id reached the helper");

    [gate endRequest];
    Expect(services.scope.closes == 1, @"ending the request must close the helper scope");
    NSInteger searches = services.scope.searches;
    result = Run(gate, SPDFMacFriendsSearchToolName, @{@"query" : @"delivery"});
    Expect(result[@"error"] && services.scope.searches == searches && !gate.toolDefinitionsForCurrentRequest.count,
           @"the scope outlived its request");
}

static void TestSlowAndLateScopes(void) {
    FakeServices* services = [FakeServices new];
    services.delay = 0.1;
    services.scope.searchResults = @[FakeResult(@"c_mei", @"m_1", @"hello")];
    SPDFMacFriendsChatScopeGate* gate = [[SPDFMacFriendsChatScopeGate alloc] initWithServices:^{ return services; }];
    [gate beginRequestWithScope:SPDFMacFriendsScopeRequest.allChats];
    Expect(services.opens == 1 && services.openedIDs == nil, @"All Friends chats must open with no conversation list");
    NSDictionary* result = Run(gate, SPDFMacFriendsSearchToolName, @{@"query" : @"hello"});
    Expect([result[@"results"] count] == 1, @"a call made before the scope opened must wait for it: %@", result);

    // A scope that opens after its request ended is closed at once, not left open on the helper.
    FakeServices* late = [FakeServices new];
    late.delay = 0.1;
    SPDFMacFriendsChatScopeGate* lateGate = [[SPDFMacFriendsChatScopeGate alloc] initWithServices:^{ return late; }];
    [lateGate beginRequestWithScope:SPDFMacFriendsScopeRequest.allChats];
    [lateGate endRequest];
    SPDFMacFriendsTestRunUntil(2, ^BOOL { return late.scope.closes == 1; });
    Expect(late.scope.closes == 1, @"a late scope stayed open");

    // A helper that never answers costs at most the timeout, then refuses.
    FakeServices* silent = [FakeServices new];
    silent.never = YES;
    SPDFMacFriendsChatScopeGate* silentGate =
        [[SPDFMacFriendsChatScopeGate alloc] initWithServices:^{ return silent; }];
    silentGate.openTimeout = 0.3;
    [silentGate beginRequestWithScope:SPDFMacFriendsScopeRequest.allChats];
    NSDate* start = NSDate.date;
    result = Run(silentGate, SPDFMacFriendsSearchToolName, @{@"query" : @"x"});
    Expect(result[@"error"] && -start.timeIntervalSinceNow < 2, @"a silent helper held the tool call");

    SPDFMacFriendsChatScopeGate* off = [[SPDFMacFriendsChatScopeGate alloc] initWithServices:^id { return nil; }];
    [off beginRequestWithScope:SPDFMacFriendsScopeRequest.allChats];
    Expect(Run(off, SPDFMacFriendsSearchToolName, @{@"query" : @"x"})[@"error"], @"Friends off must refuse");
}

#import "SPDFMacFriendsScopeSessionChecks.h"
#import "SPDFMacFriendsScopeHistoryChecks.h"
#import "SPDFMacFriendsScopeStorageChecks.h"
#import "SPDFMacFriendsComposerChecks.h"
#import "SPDFMacFriendsComposerUIChecks.h"

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        TestUnscopedRequestHasNoFriendsTools();
        TestScopedCallsStayInScope();
        TestSlowAndLateScopes();
        CheckSessionEnforcement();
        CheckHistoryRedaction();
        CheckStoredHistory();
        CheckSessionStorage();
        CheckListChatsContract();
        CheckComposerText();
        CheckComposerUI();
    }
    puts("SPDFMacFriendsScopeTests passed");
    return 0;
}
