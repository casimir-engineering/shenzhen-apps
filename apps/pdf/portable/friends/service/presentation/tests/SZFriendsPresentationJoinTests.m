// Joining a profile as the views show it (PROTOCOL.md § Joining; SZFriendsPresentationJoin.h). The fixtures
// fixtures/snapshots/list-join-requests.json, badge-join-requests.json and join-*.json rebuilt from their facts at the
// fixture clock: the list with a waiting and an approved join row, the badge counting them, and the new computer's
// `join` view in four states, each validated against PROTOCOL.md's schema blocks, with the join intents' examples in
// fixtures/intents.jsonl.

#import "SZFriendsPresentationWorld.h"

#import "service/presentation/SZFriendsPresentationJoin.h"

static id Serialized(id object) {
    NSData *data = [NSJSONSerialization isValidJSONObject:object]
                       ? [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL]
                       : nil;
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
}

static void ExpectData(NSDictionary *built, NSString *fixture) {
    NSString *relative = [@"snapshots/" stringByAppendingString:fixture];
    NSString *difference = SZPDifference(Serialized(built), SZPFixture(relative)[@"data"], @"data");
    if (difference) SZPFail(@"%@ differs at %@", fixture, difference);
}

static NSArray<SZFriendsJoinRequestFacts *> *JoinRequests(void) {
    SZFriendsJoinRequestFacts *waiting = [SZFriendsJoinRequestFacts new];
    waiting.joinID = @"5f2d0c4be1a94a7b8d3e6f1a2b3c4d5e";
    waiting.deviceName = @"Raph’s MacBook Air";
    waiting.system = @"macOS 26.1";
    waiting.receivedAt = SZPHongKong(@"2026-10-12 14:46");
    SZFriendsJoinRequestFacts *approved = [SZFriendsJoinRequestFacts new];
    approved.joinID = @"0a1b2c3d4e5f60718293a4b5c6d7e8f9";
    approved.deviceName = @"Raph’s Mac mini";
    approved.system = @"macOS 15.7";
    approved.receivedAt = SZPHongKong(@"2026-10-12 14:45");
    approved.approved = YES;
    approved.code = @"48312207";
    approved.codeExpiresAt = SZPHongKong(@"2026-10-12 14:51");
    return @[ approved, waiting ];
}

static SZFriendsJoiningFacts *Joining(SZFriendsJoiningState state, NSString *_Nullable friendsID) {
    SZFriendsJoiningFacts *facts = [SZFriendsJoiningFacts new];
    facts.state = state;
    facts.friendsID = friendsID;
    return facts;
}

static void TestFixtures(void) {
    SZFriendsSnapshotBuilder *builder = SZPBuilder(SZPAudience());
    NSArray<SZFriendsPersonFacts *> *people = SZPPeople().allValues;
    NSMutableDictionary *list = [[builder listWithPeople:people previewItems:SZPPreviewItems()
                                                 profile:SZPProfileRaph() query:@"" now:SZPNow()] mutableCopy];
    SZPValidateSnapshot(list, @"list", @"list-join-requests.json without its join rows");
    list[@"join_requests"] = [builder joinRequestRowsWithFacts:JoinRequests() now:SZPNow()];
    ExpectData(list, @"list-join-requests.json");
    SZPValidateSnapshot(list, @"list", @"list-join-requests.json");

    NSDictionary *badge = [builder badgeWithPeople:people joinRequests:JoinRequests()];
    ExpectData(badge, @"badge-join-requests.json");
    SZPValidateSnapshot(badge, @"badge", @"badge-join-requests.json");

    NSDictionary<NSString *, SZFriendsJoiningFacts *> *views = @{
        @"join-idle.json" : Joining(SZFriendsJoiningIdle, nil),
        @"join-wrong-code.json" : Joining(SZFriendsJoiningWrongCode, @"cottage-violet"),
        @"join-denied.json" : Joining(SZFriendsJoiningDenied, @"cottage-violet"),
        @"join-joined.json" : Joining(SZFriendsJoiningJoined, @"cottage-violet"),
    };
    for (NSString *name in views) {
        NSDictionary *data = [builder joinWithFacts:views[name]];
        ExpectData(data, name);
        SZPValidateSnapshot(data, @"join", name);
    }
}

// Every state builds a valid view; the code field shows exactly while a code can be typed.
static void TestStates(void) {
    SZFriendsSnapshotBuilder *builder = SZPBuilder(SZPAudience());
    for (NSInteger state = SZFriendsJoiningIdle; state <= SZFriendsJoiningUnavailable; state++) {
        NSDictionary *data = [builder joinWithFacts:Joining((SZFriendsJoiningState)state, @"cottage-violet")];
        NSString *label = [NSString stringWithFormat:@"join state %ld", (long)state];
        SZPValidateSnapshot(data, @"join", label);
        BOOL typing = state >= SZFriendsJoiningWaiting && state <= SZFriendsJoiningNotReached;
        SZPExpect((data[@"code_field"] != NSNull.null) == typing, @"%@: code field %@", label, data[@"code_field"]);
        SZPExpect((data[@"id_field"] != NSNull.null) == (state == SZFriendsJoiningIdle), @"%@: ID field", label);
        SZPExpect([data[@"code_field"] isKindOfClass:NSDictionary.class] == typing &&
                      (!typing || [data[@"code_field"][@"enabled"] isEqual:@(state != SZFriendsJoiningChecking)]),
                  @"%@: the field waits while a code is checked", label);
    }
    SZFriendsStrings *strings = [[SZFriendsStrings alloc] initWithAudience:SZPAudience()];
    SZPExpect([[strings joinMessageForErrorCode:@"invalid_field" field:@"code"] containsString:@"8 digits"],
              @"a code that is not 8 digits says so");
    SZPExpect([strings joinMessageForErrorCode:@"not_allowed" field:nil].length > 0 &&
                  [strings joinMessageForErrorCode:@"not_found" field:nil].length > 0, @"join errors have words");
    SZPExpect([strings joinMessageForErrorCode:@"rate_limited" field:nil] == nil, @"the rest keep the general ones");
    // An approval past its time shows nothing to type any more: the row offers Approve again.
    SZFriendsJoinRequestFacts *stale = JoinRequests().firstObject;
    stale.codeExpiresAt = [SZPNow() dateByAddingTimeInterval:-1];
    NSDictionary *row = [builder joinRequestRowsWithFacts:@[ stale ] now:SZPNow()].firstObject;
    SZPExpect([row[@"state"] isEqual:@"waiting"] && row[@"code"] == NSNull.null, @"no expired code: %@", row);
}

// fixtures/intents.jsonl holds one example of every join intent (friends-protocol-check validates each line).
static void TestIntents(void) {
    NSString *path = [SZPFriendsDirectory stringByAppendingPathComponent:@"fixtures/intents.jsonl"];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    NSSet *expected = [NSSet setWithArray:@[ @"join_profile", @"enter_join_code", @"cancel_join", @"approve_join",
                                             @"deny_join" ]];
    NSMutableSet<NSString *> *types = [NSMutableSet set];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (line.length == 0) continue;
        NSDictionary *intent = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding]
                                                               options:0 error:NULL];
        if ([expected containsObject:intent[@"type"]]) [types addObject:intent[@"type"]];
    }
    SZPExpect([types isEqualToSet:expected], @"one example of every join intent: %@", types);
}

void SZPRunJoinTests(void) {
    TestFixtures();
    TestStates();
    TestIntents();
}
