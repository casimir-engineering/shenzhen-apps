// Request context, chips, budgets, cancellation and settings snapshots. Included by SPDFMacAIToolSeamTests.mm.
#pragma once

static void CheckRequestContext(void) {
    NSMutableArray* chips = [@[[SPDFMacAIRequestChip friendsChipWithConversationIDs:@[@"c_mei"] displayName:@"Mei"]]
        mutableCopy];
    SPDFMacAIChatActivity* activity = [SPDFMacAIChatActivity new];
    SPDFMacAIRequestChip* friendChip = [SPDFMacAIRequestChip friendsChipWithConversationIDs:@[@"c_kenji"]
                                                                                displayName:@"Kenji"];
    SPDFMacAIRequestContext* context = [[SPDFMacAIRequestContext alloc] initWithText:@"What did @Mei say?" chips:chips
        origin:SPDFMacAIRequestOriginChat friendConversation:friendChip settings:nil budget:nil activity:activity];
    [chips addObject:[SPDFMacAIRequestChip friendsChipWithConversationIDs:nil displayName:@"All Friends chats"]];
    CHECK(context.chips.count == 1 && [[context chipsOfKind:SPDFMacAIChipKindFriends].firstObject.scopeIDs
                                      isEqual:@[@"c_mei"]],
          "a context keeps the chips the person sent; changing the caller's array later adds none");
    CHECK(!context.friendConversation, "only a friend's `/` names the conversation's friend");
    CHECK(context.budget.remainingSteps == 12 && context.budget.remainingToolCalls == NSUIntegerMax &&
          context.depth == 0 && context.activity == activity && context.requestID.length,
          "a context has the default budget, depth 0 and the session's activity");
    SPDFMacAIRequestContext* slash = [[SPDFMacAIRequestContext alloc] initWithText:@"send a summary" chips:nil
        origin:SPDFMacAIRequestOriginFriendComposer friendConversation:friendChip settings:nil budget:nil activity:nil];
    CHECK([slash.friendConversation.scopeIDs isEqual:@[@"c_kenji"]], "`/` carries the friend of its conversation");
    SPDFMacAIRequestContext* plain = [[SPDFMacAIRequestContext alloc] initWithText:@"Summarize" chips:nil
        origin:SPDFMacAIRequestOriginChat friendConversation:friendChip settings:nil budget:nil activity:nil];
    CHECK(context.includesFriendsChats && slash.includesFriendsChats && !plain.includesFriendsChats,
          "a Friends chip or `/` makes a request one that includes Friends chats; a stray friend chip alone doesn't");
    NSURL* file = [NSURL fileURLWithPath:@"/tmp/contract.pdf"];
    SPDFMacAIRequestChip* document = [SPDFMacAIRequestChip documentChipWithFileURL:file identifier:@"doc:abc"
        revision:@{@"revision_id" : @"r1", @"sha256" : @"00"} displayName:@"contract.pdf"];
    CHECK([document.kind isEqual:SPDFMacAIChipKindDocument] && [document.revision[@"revision_id"] isEqual:@"r1"] &&
          [document.fileURL isEqual:file], "a document chip keeps its exact revision");

    SPDFMacAIRequestBudget* tasks = [context.budget childBudgetWithSteps:4 tokens:1000 toolCalls:12];
    NSError* error = nil;
    SPDFMacAIRequestContext* child = [context childContextWithText:@"Find the delivery date" budget:tasks error:&error];
    CHECK(child && child.depth == 1 && child.chips.count == 1 && child.activity == activity &&
          child.budget == tasks && ![child.requestID isEqual:context.requestID],
          "a subagent's context keeps the person's chips and activity with its own budget");
    CHECK(child.includesFriendsChats, "so a helper's request includes Friends chats when its parent's does");
    error = nil;
    CHECK(![child childContextWithText:@"deeper" budget:tasks error:&error] && error.localizedDescription.length,
          "nesting stops at one level");
    __block NSUInteger stops = 0;
    [child.cancellation onCancel:^{ stops++; }];
    [context.cancellation cancel];
    CHECK(child.cancellation.cancelled && stops == 1, "Stop on the request stops its subagents");
    [context.cancellation cancel];
    __block BOOL late = NO;
    [context.cancellation onCancel:^{ late = YES; }];
    CHECK(stops == 1 && late, "cancellation runs each handler once, and at once after the fact");
    SPDFMacAICancellationToken* parent = [SPDFMacAICancellationToken new];
    SPDFMacAICancellationToken* only = [parent childToken];
    [only cancel];
    CHECK(only.cancelled && !parent.cancelled, "a subagent stopping does not stop its request");
}

static void CheckRequestBudget(void) {
    SPDFMacAIRequestBudget* budget = [SPDFMacAIRequestBudget defaultRequestBudget];
    NSUInteger steps = 0;
    while ([budget consumeStep]) steps++;
    CHECK(steps == 12 && !budget.remainingSteps && budget.usedSteps == 12, "the default request has 12 steps");
    [budget returnStep];
    CHECK(budget.usedSteps == 11 && budget.remainingSteps == 1 && [budget consumeStep] && !budget.remainingSteps,
          "a step given back can be taken again");
    SPDFMacAIRequestBudget* request = [[SPDFMacAIRequestBudget alloc] initWithSteps:10 tokens:1000 toolCalls:12];
    SPDFMacAIRequestBudget* a = [request childBudgetWithSteps:50 tokens:600 toolCalls:50];
    SPDFMacAIRequestBudget* b = [request childBudgetWithSteps:5 tokens:600 toolCalls:5];
    CHECK(a.remainingSteps == 10 && a.remainingToolCalls == 12 && b.remainingTokens == 600,
          "a child budget is capped at what its parent has left");
    [a consumeTokens:600];
    CHECK(request.usedTokens == 600 && b.remainingTokens == 400, "a child's spending is charged to its parent");
    [b consumeStep];
    [b returnStep];
    [a returnStep];
    CHECK(!b.usedSteps && !a.usedSteps && !request.usedSteps, "a step given back returns to the parent, never below 0");
    for (NSUInteger i = 0; i < 5; i++) [b consumeToolCall];
    for (NSUInteger i = 0; i < 7; i++) [a consumeToolCall];
    CHECK(![b consumeToolCall] && a.usedToolCalls == 7 && ![a consumeToolCall] && request.usedToolCalls == 12,
          "subagents share their request's tool calls and cannot outspend it");
    [b consumeTokens:NSUIntegerMax];
    CHECK(!request.remainingTokens && !a.remainingTokens && ![request childBudgetWithSteps:1 tokens:1 toolCalls:1],
          "token charges saturate, and an exhausted request gives no child budget");
}

static void CheckSettingsSnapshot(void) {
    NSString* root = SeamTemporaryDirectory(@"settings");
    NSURL* URL = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"ai-settings.yaml"]];
    SPDFMacAISettings* settings = [[SPDFMacAISettings alloc] initWithURL:URL];
    CHECK(settings.aiWebSearchEnabled && settings.aiPythonEnabled && settings.aiSubagentsEnabled,
          "web search, Python and subagents are on unless the person turns them off");
    CHECK([settings load:nil] && settings.aiWebSearchEnabled, "a missing file reads as every capability on");
    [@"schema_version: 1\nmodel: fake/model\nenabled: true\n" writeToURL:URL atomically:YES encoding:4 error:nil];
    SPDFMacAISettings* older = [[SPDFMacAISettings alloc] initWithURL:URL];
    CHECK([older load:nil] && older.aiWebSearchEnabled && older.aiPythonEnabled && older.aiSubagentsEnabled,
          "a settings file from before these switches keeps them on");
    older.aiWebSearchEnabled = NO;
    CHECK([older save:nil], "the switches save");
    NSString* YAML = [NSString stringWithContentsOfURL:URL encoding:NSUTF8StringEncoding error:nil];
    CHECK([YAML containsString:@"web_search_enabled: false"] && [YAML containsString:@"python_enabled: true"] &&
          [YAML containsString:@"subagents_enabled: true"], "each switch has its own line in ai-settings.yaml");
    SPDFMacAISettings* otherWindow = [[SPDFMacAISettings alloc] initWithURL:URL];
    [otherWindow load:nil];
    SPDFMacAISettings* thisWindow = [[SPDFMacAISettings alloc] initWithURL:URL];
    [thisWindow load:nil];
    otherWindow.aiSubagentsEnabled = NO;
    [otherWindow save:nil];
    thisWindow.aiPythonEnabled = NO;
    [thisWindow save:nil];
    SPDFMacAISettings* reread = [[SPDFMacAISettings alloc] initWithURL:URL];
    [reread load:nil];
    CHECK(!reread.aiWebSearchEnabled && !reread.aiPythonEnabled && !reread.aiSubagentsEnabled,
          "two windows changing different switches keep both changes");
    SPDFMacAISettingsSnapshot* snapshot = reread.snapshot;
    reread.aiWebSearchEnabled = YES;
    CHECK(!snapshot.aiWebSearchEnabled && [snapshot.model isEqual:@"fake/model"],
          "a request keeps the switches it started with");
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
}
