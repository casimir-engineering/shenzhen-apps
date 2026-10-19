// The time grant for all Friends chats (SPDFMacFriendsChatGrant.h) through the real registry and session: requests
// sent while it runs may read any chat; expiry, Stop now and Friends going away stop reads at the next call, in the
// middle of a request too; a later grant never reopens an earlier request; a subagent never reads past its parent's
// grant; `/` never reads under it. Included by SPDFMacFriendsToolProviderTests.mm after its helpers (Names, Last,
// Sent, Function, Chip). The clock is the test's: nothing waits an hour.

#pragma once
#import "SPDFMacFriendsChatGrant.h"
#import "SPDFMacFriendsGrantBar.h"

static NSDate* gGrantNow;

static SPDFMacFriendsChatGrant* NewGrant(void) {
    NSCalendar* calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = [NSTimeZone timeZoneWithName:@"Asia/Shanghai"];
    SPDFMacFriendsChatGrant* grant = [[SPDFMacFriendsChatGrant alloc] initWithClock:^{ return gGrantNow; }
                                                                          calendar:calendar];
    [grant friendsAvailabilityChanged:YES];
    return grant;
}

static NSDate* At(NSString* iso) { return [[NSISO8601DateFormatter new] dateFromString:iso]; }

// Records what each request looked like to the registry's providers.
@interface ContextProbe : NSObject <SPDFMacAIToolProvider>
@property SPDFMacAIRequestContext* context;
@end
@implementation ContextProbe
- (NSString*)providerIdentifier { return @"probe"; }
- (BOOL)providesTool:(NSString*)name { (void)name; return NO; }
- (NSArray<NSDictionary*>*)toolDefinitionsForContext:(SPDFMacAIRequestContext*)context {
    self.context = context;
    return @[];
}
- (BOOL)isReadOnlyTool:(NSString*)name { (void)name; return YES; }
- (void)performTool:(NSString*)name arguments:(NSDictionary*)arguments context:(SPDFMacAIRequestContext*)context
         completion:(SPDFMacAIToolCompletion)completion {
    (void)name; (void)arguments; (void)context;
    completion(@{@"error" : @"none"});
}
- (void)cancel {}
@end

// At 320 to 400 points the sentence would cut off the time left, so the bar shows the short text there, whole,
// and keeps the sentence for its tooltip and VoiceOver; a wide chat shows the sentence.
static void CheckGrantBarWidths(void) {
    gGrantNow = At(@"2026-10-14T06:30:00Z");
    SPDFMacFriendsChatGrant* grant = [[SPDFMacFriendsChatGrant alloc] initWithClock:^{ return gGrantNow; }
                                                                          calendar:nil];
    [grant friendsAvailabilityChanged:YES];
    [grant grantAllChatsFor:SPDFMacFriendsGrantLengthHour];
    gGrantNow = [gGrantNow dateByAddingTimeInterval:8 * 60];
    Expect([SPDFMacFriendsGrantBarShortText(grant) isEqual:@"All Friends chats · 52 min left"], @"short: %@",
           SPDFMacFriendsGrantBarShortText(grant));
    SPDFMacFriendsGrantBar* bar = [[SPDFMacFriendsGrantBar alloc] initWithGrant:grant
        show:^(SPDFMacFriendsGrantBar* b) { (void)b; }];
    NSString* sentence = @"The assistant can read all your Friends chats · 52 min left";
    for (NSNumber* width in @[ @320, @360, @400, @720 ]) {
        bar.frame = NSMakeRect(0, 0, width.doubleValue, 30);
        [bar layoutSubtreeIfNeeded];
        NSString* shownText = bar.label.stringValue;
        CGFloat needed = [bar.label.cell cellSizeForBounds:NSMakeRect(0, 0, CGFLOAT_MAX, 30)].width;
        BOOL wide = width.doubleValue >= 700;
        Expect([shownText isEqual:wide ? sentence : @"All Friends chats · 52 min left"] &&
                   needed <= NSWidth(bar.label.frame) + 0.5 && NSMaxX(bar.label.frame) <= NSMinX(bar.stopButton.frame),
               @"at %@ pt the bar shows %@ in %.1f of %.1f pt", width, shownText, NSWidth(bar.label.frame), needed);
        Expect([bar.accessibilityLabel isEqual:sentence] && [bar.toolTip hasPrefix:sentence] &&
                   [bar.toolTip containsString:@"OpenRouter"] && !bar.label.isAccessibilityElement,
               @"the sentence stays for VoiceOver and the tooltip at %@ pt: %@", width, bar.toolTip);
    }
    [grant stop];
    [bar uninstall];
}

static void CheckGrantModel(void) {
    gGrantNow = At(@"2026-10-14T06:30:00Z"); // 14:30 in Shanghai
    __block NSInteger changes = 0;
    SPDFMacFriendsChatGrant* grant = [[SPDFMacFriendsChatGrant alloc] initWithClock:^{ return gGrantNow; }
                                                                          calendar:nil];
    id observer = [NSNotificationCenter.defaultCenter addObserverForName:SPDFMacFriendsChatGrantDidChangeNotification
        object:grant queue:nil usingBlock:^(NSNotification* note) { (void)note; changes++; }];
    Expect(![grant grantAllChatsFor:SPDFMacFriendsGrantLengthHour] && !grant.active,
           @"a grant started while Friends chats could not be read");
    [grant friendsAvailabilityChanged:YES];
    Expect(![grant grantAllChatsFor:SPDFMacFriendsGrantLengthRequest] && !grant.active && !changes,
           @"\"This request\" is a chip, never a grant");
    Expect([grant grantAllChatsFor:SPDFMacFriendsGrantLengthHour] && grant.active && changes == 1 &&
           [grant.expiry isEqual:[gGrantNow dateByAddingTimeInterval:3600]], @"1 hour: %@", grant.expiry);
    uint64_t first = grant.activeToken;
    Expect([SPDFMacFriendsGrantBarText(grant) isEqual:@"The assistant can read all your Friends chats · 60 min left"],
           @"bar: %@", SPDFMacFriendsGrantBarText(grant));
    gGrantNow = [gGrantNow dateByAddingTimeInterval:8 * 60];
    Expect([SPDFMacFriendsGrantBarText(grant) hasSuffix:@" · 52 min left"], @"bar: %@",
           SPDFMacFriendsGrantBarText(grant));

    NSCalendar* shanghai = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    shanghai.timeZone = [NSTimeZone timeZoneWithName:@"Asia/Shanghai"];
    Expect([SPDFMacFriendsGrantExpiry(SPDFMacFriendsGrantLengthUntilTomorrow, gGrantNow, shanghai)
               isEqual:At(@"2026-10-14T16:00:00Z")], @"Until tomorrow must end at the next local midnight");
    Expect([grant grantAllChatsFor:SPDFMacFriendsGrantLengthUntilTomorrow] && grant.activeToken != first &&
           ![grant isActiveToken:first] && [SPDFMacFriendsGrantBarText(grant) hasSuffix:@" · until midnight"],
           @"a new grant must replace the old one with a new token");
    [grant stop];
    Expect(!grant.active && !SPDFMacFriendsGrantBarText(grant) && changes == 3, @"Stop now must end the grant");

    [grant grantAllChatsFor:SPDFMacFriendsGrantLengthHour];
    [grant friendsAvailabilityChanged:NO];
    Expect(!grant.active && ![grant grantAllChatsFor:SPDFMacFriendsGrantLengthHour],
           @"Friends off, reset or not running must end the grant, and none may start");
    [grant friendsAvailabilityChanged:YES];

    [grant grantAllChatsFor:SPDFMacFriendsGrantLengthHour];
    NSInteger before = changes;
    gGrantNow = [gGrantNow dateByAddingTimeInterval:3601];
    Expect(!grant.active && !grant.activeToken, @"expiry is read from the clock, not from a timer having fired");
    [grant tick];
    Expect(changes == before + 1 && !grant.expiry, @"the tick after expiry must end the grant and say so");
    Expect(([[SPDFMacFriendsGrantLengthChoices() valueForKey:@"name"]
               isEqual:@[@"This request", @"1 hour", @"Until tomorrow"]]), @"the lengths offered");
    [NSNotificationCenter.defaultCenter removeObserver:observer];
}

static void CheckGrantEnforcement(void) {
    gGrantNow = At(@"2026-10-14T06:30:00Z");
    NSString* root = SPDFMacFriendsTestTemporaryDirectory(@"grant-chats");
    SPDFMacAIChatStore* store = [[SPDFMacAIChatStore alloc] initWithDirectory:[NSURL fileURLWithPath:root]];
    FakeModel* model = [FakeModel new];
    FakeServices* services = [FakeServices new];
    SPDFMacFriendsChatScopeGate* gate = [[SPDFMacFriendsChatScopeGate alloc] initWithServices:^{ return services; }];
    SPDFMacFriendsChatGrant* grant = NewGrant();
    gate.grant = grant;
    SPDFMacAIToolRegistry* registry = [SPDFMacAIToolRegistry new];
    [registry registerProvider:[[SPDFMacAIChatToolsProvider alloc] initWithIdentifier:@"reader"
        tools:[FakeReaderTools new] definitions:@[Function(@"read_pages")]
        readOnlyTools:SPDFMacAIReaderReadOnlyToolNames()] error:nil];
    [registry registerProvider:[[SPDFMacFriendsToolProvider alloc] initWithGate:gate] error:nil];
    ContextProbe* probe = [ContextProbe new];
    [registry registerProvider:probe error:nil];
    SPDFMacAIChatSession* session = [[SPDFMacAIChatSession alloc] initWithTransport:model registry:registry
                                                                              store:store];
    __block NSAttributedString* composer = nil;
    SPDFMacFriendsChatRequestScoper* scoper = [[SPDFMacFriendsChatRequestScoper alloc] initWithGate:gate
        running:^BOOL { return session.running; } composerText:^NSAttributedString* { return composer; }];
    session.changed = ^{ [scoper sessionDidChange]; };
    SPDFMacFriendsSendText send = [scoper sendTextWrapping:^BOOL(NSString* text) {
        NSUInteger before = [session.chat[@"messages"] count];
        SPDFMacAIRequestContext* context = [[SPDFMacAIRequestContext alloc] initWithText:text
            chips:[registry requestChipsInComposerText:composer] origin:SPDFMacAIRequestOriginChat
            friendConversation:nil settings:nil budget:nil activity:session.activity];
        [session sendContext:context model:@"fake/model" apiKey:@"TEST-NOT-A-KEY"];
        return [session.chat[@"messages"] count] > before;
    }];
    void (^ask)(NSString*) = ^(NSString* text) {
        composer = [[NSAttributedString alloc] initWithString:text];
        Expect(send(text), @"\"%@\" was not sent", text);
    };
    void (^call)(NSString*, NSString*, NSDictionary*) = ^(NSString* identifier, NSString* tool, NSDictionary* args) {
        model.reply(@{@"role" : @"assistant", @"content" : @"",
                      @"tool_calls" : @[ToolCall(identifier, tool, args)]}, nil);
    };
    void (^answer)(void) = ^{ model.reply(@{@"role" : @"assistant", @"content" : @"Done."}, nil); };
    NSString* search = SPDFMacFriendsSearchToolName;
    services.scope.searchResults = @[FakeResult(@"c_mei", @"m_1", @"Delivery moves to the 20th"),
                                     FakeResult(@"c_kenji", @"m_9", @"Kenji's invoice is late")];

    ask(@"Any news on delivery?");
    Expect(![Names(model.definitions) containsObject:search] && !probe.context.includesFriendsChats &&
           services.opens == 0, @"no grant, no chip: Friends must stay out");
    answer();

    // A message sent while the grant runs reads any chat, with no chip, and counts as one including Friends chats.
    [grant grantAllChatsFor:SPDFMacFriendsGrantLengthHour];
    ask(@"Any news on delivery?");
    Expect([Names(model.definitions) containsObject:search] && services.opens == 1 && !services.openedIDs &&
           probe.context.includesFriendsChats && [Last(session, @"user")[@"content"] isEqual:@"Any news on delivery?"],
           @"a request under the grant must read all chats: opens %ld", (long)services.opens);
    call(@"g1", search, @{@"query" : @"delivery"});
    Expect([Last(session, @"tool")[@"content"] containsString:@"Kenji's invoice"], @"all chats were not searched");
    // Expiry in the middle of the request: the next read is refused, the helper scope is closed, the tools go, and
    // the excerpts already read are no longer sent.
    gGrantNow = [gGrantNow dateByAddingTimeInterval:3601];
    call(@"g2", SPDFMacFriendsReadToolName, @{@"message_id" : @"m_9"});
    Expect([Last(session, @"tool")[@"content"] containsString:@"has ended"] && services.scope.reads == 0 &&
           services.scope.closes == 1 && ![Names(model.definitions) containsObject:search] &&
           !Sent(model, @"Kenji's invoice") && !Sent(model, @"moves to the 20th"),
           @"a read after expiry went through: %@", Last(session, @"tool"));
    answer();
    NSString* file = [store chatWithID:session.chat[@"id"]].description;
    Expect(file.length && ![file containsString:@"Kenji's invoice"],
           @"the chat file kept an excerpt read under a grant");
    ask(@"And now?");
    Expect(services.opens == 1 && ![Names(model.definitions) containsObject:search] &&
           !probe.context.includesFriendsChats, @"a request after expiry was given Friends chats");
    answer();

    // Stop now closes the scope at once; a grant given again does not reopen the request made under the first.
    [grant grantAllChatsFor:SPDFMacFriendsGrantLengthHour];
    ask(@"Search again");
    Expect(services.opens == 2, @"the second grant's request did not open");
    [grant stop];
    Expect(services.scope.closes == 2 && !gate.requestHasScope, @"Stop now left the helper scope open");
    [grant grantAllChatsFor:SPDFMacFriendsGrantLengthHour];
    NSInteger searches = services.scope.searches;
    call(@"g3", search, @{@"query" : @"delivery"});
    Expect(services.scope.searches == searches && [Last(session, @"tool")[@"content"] containsString:@"has ended"] &&
           services.opens == 2, @"a new grant reopened a request made under a stopped one");
    answer();

    // A chip of the person's own outlives the grant: after expiry the request reads that chat alone.
    NSMutableAttributedString* text = [Chip([SPDFMacFriendsScopeRequest conversationIDs:@[@"c_mei"]
                                                                                labels:@[@"Mei"]]) mutableCopy];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:@" delivery?"]];
    composer = text;
    Expect(send(text.string) && services.opens == 3 && !services.openedIDs, @"chip and grant: all chats first");
    gGrantNow = [gGrantNow dateByAddingTimeInterval:3601];
    call(@"g4", search, @{@"query" : @"delivery"});
    NSString* result = Last(session, @"tool")[@"content"];
    Expect(services.opens == 4 && [services.openedIDs isEqual:@[@"c_mei"]] && [result containsString:@"20th"] &&
           ![result containsString:@"Kenji"], @"after expiry a chip must read its chat alone: %@", result);
    answer();

    // Friends turned off or reset in the middle of a request.
    [grant grantAllChatsFor:SPDFMacFriendsGrantLengthHour];
    ask(@"Once more");
    [grant friendsAvailabilityChanged:NO];
    call(@"g5", search, @{@"query" : @"delivery"});
    Expect([Last(session, @"tool")[@"content"] containsString:@"has ended"] && !grant.active,
           @"turning Friends off left the grant reading");
    answer();
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
}

static NSDictionary* RunProvider(SPDFMacFriendsToolProvider* provider, SPDFMacAIRequestContext* context) {
    __block NSDictionary* result = nil;
    [provider performTool:SPDFMacFriendsSearchToolName arguments:@{@"query" : @"x"} context:context
               completion:^(NSDictionary* r) { result = r; }];
    SPDFMacFriendsTestRunUntil(5, ^BOOL { return result != nil; });
    return result;
}

static void CheckGrantReach(void) {
    gGrantNow = At(@"2026-10-14T06:30:00Z");
    FakeServices* services = [FakeServices new];
    services.scope.searchResults = @[FakeResult(@"c_mei", @"m_1", @"hello")];
    SPDFMacFriendsChatScopeGate* gate = [[SPDFMacFriendsChatScopeGate alloc] initWithServices:^{ return services; }];
    gate.grant = NewGrant();
    SPDFMacFriendsToolProvider* provider = [[SPDFMacFriendsToolProvider alloc] initWithGate:gate];
    [gate.grant grantAllChatsFor:SPDFMacFriendsGrantLengthHour];
    NSArray* chips = [provider requestChipsInComposerText:[[NSAttributedString alloc] initWithString:@"hi"]];
    Expect(chips.count == 1 && [chips[0] isKindOfClass:SPDFMacFriendsGrantChip.class] && ![chips[0] scopeIDs],
           @"a message sent under the grant must carry its chip: %@", chips);
    SPDFMacAIRequestContext* context = [[SPDFMacAIRequestContext alloc] initWithText:@"hi" chips:chips
        origin:SPDFMacAIRequestOriginChat friendConversation:nil settings:nil budget:nil activity:nil];
    Expect(!SPDFMacFriendsScopeForContext(context) && SPDFMacFriendsGrantTokenForContext(context) ==
           gate.grant.activeToken, @"the grant chip must not count as an All Friends chats chip of its own");
    [provider beginRequestWithContext:context];
    SPDFMacAIRequestContext* child = [context childContextWithText:@"task"
        budget:[context.budget childBudgetWithSteps:2 tokens:1000 toolCalls:2] error:nil];
    Expect(child.includesFriendsChats && [RunProvider(provider, child)[@"results"] count] == 1,
           @"a subagent's context works for its parent's request while the grant runs");
    [gate.grant stop];
    [gate.grant grantAllChatsFor:SPDFMacFriendsGrantLengthHour];
    Expect([RunProvider(provider, child)[@"error"] containsString:@"has ended"] &&
           [RunProvider(provider, context)[@"error"] containsString:@"has ended"],
           @"a subagent or its parent read under a grant given after theirs ended");
    [provider endRequestWithContext:context];
    [gate beginRequestWithScope:nil grantToken:SPDFMacFriendsGrantTokenForContext(context)];
    Expect(!gate.requestHasScope, @"a request with an ended grant's token opened a scope");

    // `/` reads its conversation alone, even with a grant running and a grant chip in its context.
    SPDFMacAIRequestChip* mei = [SPDFMacAIRequestChip friendsChipWithConversationIDs:@[@"c_mei"] displayName:@"Mei"];
    SPDFMacAIRequestContext* slash = [[SPDFMacAIRequestContext alloc] initWithText:@"/summarize"
        chips:@[[SPDFMacFriendsGrantChip chipForGrantToken:gate.grant.activeToken]]
        origin:SPDFMacAIRequestOriginFriendComposer friendConversation:mei settings:nil budget:nil activity:nil];
    NSInteger opens = services.opens;
    [provider beginRequestWithContext:slash];
    Expect(services.opens == opens + 1 && [services.openedIDs isEqual:@[@"c_mei"]],
           @"`/` read under the AI chat's grant: %@", services.openedIDs);
    [provider endRequestWithContext:slash];
}
