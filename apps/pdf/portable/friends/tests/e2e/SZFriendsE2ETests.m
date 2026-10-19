// friends-e2e-check: the runner and the steps every scenario shares (SZFriendsE2EScenarios.h).
//
// Usage: SZFriendsE2ETests <e2e helper executable> <animal manifest> [scenario numbers, e.g. 1,5]

#import "SZFriendsE2EScenarios.h"

#import <unistd.h>

// The brief's budget for one whole scenario.
static const NSTimeInterval SZFE2EScenarioBudget = 60;

@implementation SZFE2EPair
@end

NSString *SZFE2EToken(void) {
    return [[NSUUID UUID].UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""].lowercaseString;
}

NSDictionary *SZFE2ERowTitled(NSDictionary *list, NSString *title) {
    for (NSDictionary *row in list[@"rows"]) {
        if ([row[@"title"] isEqual:title]) return row;
    }
    return nil;
}

NSDictionary *SZFE2ERowWithID(NSDictionary *list, NSString *conversationID) {
    for (NSDictionary *row in list[@"rows"]) {
        if ([row[@"conversation_id"] isEqual:conversationID]) return row;
    }
    return nil;
}

NSArray<NSDictionary *> *SZFE2EItems(NSDictionary *conversation, NSString *kind) {
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *item in conversation[@"items"]) {
        if ([item[@"kind"] isEqual:kind]) [items addObject:item];
    }
    return items;
}

static BOOL SZFE2EOpen(SZFE2EClient *client, NSString *name, NSString **list) {
    CHECK([[client intent:@"activate" fields:nil][@"ok"] boolValue], "activate");
    CHECK([[client intent:@"set_name" fields:@{@"name" : name}][@"ok"] boolValue], "set_name %@", name);
    *list = [client subscribe:@"list" params:nil];
    CHECK(*list != nil, "list subscription");
    return YES;
}

BOOL SZFE2EStartPair(SZFE2EWorld *world, SZFE2EPair *pair, NSDictionary *envA, NSDictionary *envB) {
    pair.helperA = [world helperNamed:@"a"];
    pair.helperB = [world helperNamed:@"b"];
    pair.helperA.extraEnvironment = envA ?: @{};
    pair.helperB.extraEnvironment = envB ?: @{};
    CHECK([pair.helperA start] && [pair.helperB start], "both helpers start");
    pair.a = [SZFE2EClient clientForHelper:pair.helperA];
    pair.b = [SZFE2EClient clientForHelper:pair.helperB];
    CHECK(pair.a != nil && pair.b != nil, "both clients reach READY");
    NSArray *capabilities = pair.a.welcome[@"capabilities"];
    BOOL hosted = envA[@"SZFRIENDS_TEST_HOST_LIST"] != nil;
    CHECK([capabilities containsObject:@"nearby.network"] && [capabilities containsObject:@"host.checkin"] == hosted,
          "a test helper finds people on loopback and checks in only with the local host: %@", capabilities);
    NSString *listA = nil, *listB = nil;
    if (!SZFE2EOpen(pair.a, @"Ana", &listA) || !SZFE2EOpen(pair.b, @"Ben", &listB)) return NO;
    pair.listA = listA;
    pair.listB = listB;
    return YES;
}

BOOL SZFE2EStartSingle(SZFE2EWorld *world, NSString *name, NSString *displayName, NSDictionary *env,
                       SZFE2EHelper **helper, SZFE2EClient **client, NSString **list) {
    *helper = [world helperNamed:name];
    (*helper).extraEnvironment = env ?: @{};
    CHECK([*helper start], "%@ starts", name);
    *client = [SZFE2EClient clientForHelper:*helper];
    CHECK(*client != nil, "%@'s client reaches READY", name);
    return SZFE2EOpen(*client, displayName, list);
}

BOOL SZFE2EReconnect(SZFE2EClient *client, NSString **list) {
    CHECK([client waitReady], "the client reconnects by itself");
    *list = [client subscribe:@"list" params:nil];
    CHECK(*list != nil, "list subscription after reconnecting");
    return YES;
}

BOOL SZFE2ERequestFromNearby(SZFE2EPair *pair) {
    SZFE2EClient *a = pair.a, *b = pair.b;
    CHECK([[b intent:@"start_visibility" fields:nil][@"result"][@"deadline"] length] > 0, "B is visible");
    NSString *nearby = [a subscribe:@"nearby" params:nil];
    __block NSString *nearbyID = nil;
    CHECK(SZFE2EWaitUntil(20, ^BOOL {
              for (NSDictionary *person in [a dataFor:nearby][@"people"]) {
                  if ([person[@"title"] isEqual:@"Ben"] && [person[@"nearby_id"] isKindOfClass:[NSString class]]) {
                      nearbyID = person[@"nearby_id"];
                  }
              }
              return nearbyID != nil;
          }),
          "A sees Ben in Nearby, from his public entry: %@", [a dataFor:nearby]);
    NSDictionary *reply = [a intent:@"send_request" fields:@{@"nearby_id" : nearbyID}];
    CHECK([reply[@"ok"] boolValue], "send_request: %@", reply);
    [a intent:@"unsubscribe" fields:@{@"subscription" : nearby}];
    CHECK(SZFE2EWaitUntil(20, ^BOOL {
              NSDictionary *row = SZFE2ERowTitled([b dataFor:pair.listB], @"Ana");
              return [row[@"waiting"] isKindOfClass:[NSDictionary class]] &&
                     [row[@"waiting"][@"kind"] isEqual:@"request"];
          }),
          "B's list shows Ana's request: %@", [b dataFor:pair.listB]);
    pair.aAtB = SZFE2ERowTitled([b dataFor:pair.listB], @"Ana")[@"conversation_id"];
    pair.bAtA = SZFE2ERowTitled([a dataFor:pair.listA], @"Ben")[@"conversation_id"];
    CHECK(pair.aAtB != nil && pair.bAtA != nil, "both sides have a row: %@", [a dataFor:pair.listA]);
    return YES;
}

BOOL SZFE2EBefriend(SZFE2EPair *pair) {
    if (!SZFE2ERequestFromNearby(pair)) return NO;
    SZFE2EClient *a = pair.a, *b = pair.b;
    NSDictionary *reply = nil;
    // The comparison code: the same six digits on both screens before anyone accepts (ADR 0001).
    NSString *atA = [a openConversation:pair.bAtA], *atB = [b openConversation:pair.aAtB];
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              id codeA = [a dataFor:atA][@"request"][@"comparison_code"];
              id codeB = [b dataFor:atB][@"request"][@"comparison_code"];
              return [codeA isKindOfClass:[NSString class]] && [codeB isKindOfClass:[NSString class]];
          }),
          "both request cards show a code: %@ / %@", [a dataFor:atA][@"request"], [b dataFor:atB][@"request"]);
    pair.codeA = [a dataFor:atA][@"request"][@"comparison_code"];
    pair.codeB = [b dataFor:atB][@"request"][@"comparison_code"];
    CHECK([pair.codeA isEqual:pair.codeB], "the codes match: %@ vs %@", pair.codeA, pair.codeB);
    CHECK([[a dataFor:atA][@"request"][@"direction"] isEqual:@"outgoing"] &&
          [[b dataFor:atB][@"request"][@"direction"] isEqual:@"incoming"], "directions");
    reply = [b intent:@"accept_request" fields:@{@"conversation_id" : pair.aAtB}];
    CHECK([reply[@"ok"] boolValue], "accept_request: %@", reply);
    // Friends accept drops: the row's drop label appears once the friendship holds on that side.
    CHECK(SZFE2EWaitUntil(15, ^BOOL {
              id dropA = SZFE2ERowWithID([a dataFor:pair.listA], pair.bAtA)[@"drop_label"];
              id dropB = SZFE2ERowWithID([b dataFor:pair.listB], pair.aAtB)[@"drop_label"];
              return [dropA isKindOfClass:[NSString class]] && [dropB isKindOfClass:[NSString class]];
          }),
          "both are friends: %@ / %@", [a dataFor:pair.listA], [b dataFor:pair.listB]);
    [a intent:@"unsubscribe" fields:@{@"subscription" : atA}];
    [b intent:@"unsubscribe" fields:@{@"subscription" : atB}];
    CHECK([[b intent:@"stop_visibility" fields:nil][@"ok"] boolValue], "B hides again");
    return YES;
}

typedef BOOL (*SZFE2EScenario)(SZFE2EWorld *world);

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: SZFriendsE2ETests <e2e helper> <animal manifest>\n");
            return 2;
        }
        NSString *executable = @(argv[1]), *manifest = @(argv[2]);
        // Private and per run in the per-user temp directory, and short enough for the scripted Bluetooth sockets
        // (sun_path holds 104 bytes); nothing is shared with another run or another agent.
        char template[1024];
        NSString *pattern = [NSTemporaryDirectory() stringByAppendingPathComponent:@"szfe.XXXXXX"];
        strlcpy(template, pattern.fileSystemRepresentation, sizeof(template));
        NSString *root = mkdtemp(template) ? @(template) : nil;
        if (root == nil || ![[NSFileManager defaultManager] isExecutableFileAtPath:executable]) {
            fprintf(stderr, "SZFriendsE2ETests: no scratch directory or no helper at %s\n", argv[1]);
            return 2;
        }
        SZFE2EWorld *world = [[SZFE2EWorld alloc] initWithExecutable:executable manifest:manifest root:root];
        struct {
            const char *name;
            SZFE2EScenario run;
        } scenarios[] = {
            {"public visibility, request, matching codes", SZFE2EScenarioRequest},
            {"messages and duplicate suppression", SZFE2EScenarioMessages},
            {"offer, accept, transfer, digest", SZFE2EScenarioTransfer},
            {"automatic acceptance", SZFE2EScenarioAutoAccept},
            {"kill -9 mid-transfer and resume", SZFE2EScenarioKillResume},
            {"Add by ID nearby", SZFE2EScenarioAddByID},
            {"block stops reconnection and requests", SZFE2EScenarioBlock},
            {"outbox expiry with an injected clock", SZFE2EScenarioExpiry},
            {"two clients agree on the badge", SZFE2EScenarioSameBadge},
            {"Bluetooth then the network mid-file", SZFE2EScenarioBluetoothToNetwork},
            {"codes only after a recorded request, never replaced", SZFE2EScenarioCodeAfterRequest},
            {"Add by ID answers: two unattested keys, each a request to accept", SZFE2EScenarioAnswersByID},
            {"Add by ID: a second holder still answers", SZFE2EScenarioTwoHolders},
            {"accept, remove before delivery: nothing goes out", SZFE2EScenarioRemoveBeforeDelivery},
            {"XX admissions per address", SZFE2EScenarioAdmission},
            {"stranger sessions end: NN after RECEIVED, idle", SZFE2EScenarioStrangerLifetimes},
            {"host check-in: reservation, collision rename, release", SZFE2EScenarioHostCheckIn},
            {"Add by ID again after a decline: one row, a fresh code", SZFE2EScenarioAskAgainByID},
            {"Add by ID with the host: the holder confirmed, a second holder apart", SZFE2EScenarioAttestedHolder},
            {"Add by ID with the host: another key's attestation refused", SZFE2EScenarioCopiedAttestation},
            {"via the assistant, on both sides", SZFE2EScenarioViaAssistant},
            {"message status: queued, then delivered, nothing read", SZFE2EScenarioMessageStatus},
            {"cancel: withdrawn while away never arrives, too late once delivered", SZFE2EScenarioCancelMessage},
            {"file previews: before acceptance, replaced after the digest, gone on decline and cancel",
             SZFE2EScenarioThumbnails},
            {"file previews: unsolicited, oversized, malformed and second ones refused",
             SZFE2EScenarioThumbnailRefusals},
            {"cancel: written, then the session lost, refused (it may have arrived)", SZFE2EScenarioCancelAfterLostAck},
            {"mentions: a stranger added from a mention, bound to its key", SZFE2EScenarioMentionAddBound},
            {"mentions: forged and malformed mentions show as text", SZFE2EScenarioMentionForged},
            {"two apps, one helper: the same chats, messages and read state", SZFE2EScenarioTwoAppsShareHelper},
            {"two apps: equal builds keep the helper, the higher build takes over", SZFE2EScenarioTwoAppsHandover},
            {"delete history: one chat only (store, row, search), then all", SZFE2EScenarioDeleteHistory},
        };
        // While working on one scenario, only it runs; make always runs them all.
        NSArray<NSString *> *only = argc > 3 ? [@(argv[3]) componentsSeparatedByString:@","] : nil;
        int failed = 0;
        for (size_t i = 0; i < sizeof(scenarios) / sizeof(scenarios[0]); i++) {
            if (only != nil && ![only containsObject:[NSString stringWithFormat:@"%zu", i + 1]]) continue;
            int before = SZFE2EFailures;
            [world beginScenario:[NSString stringWithFormat:@"s%02zu", i + 1]];
            NSDate *start = [NSDate date];
            BOOL ok = scenarios[i].run(world) && SZFE2EFailures == before;
            NSTimeInterval took = -start.timeIntervalSinceNow;
            if (ok && took > SZFE2EScenarioBudget) {
                SZFE2EFail(__FILE__, __LINE__, "took <= 60 s", [NSString stringWithFormat:@"%.1f s", took]);
                ok = NO;
            }
            printf("%s %s (%.1f s)\n", ok ? "ok  " : "FAIL", scenarios[i].name, took);
            fflush(stdout);
            if (!ok) {
                failed++;
                [world printLogs];
            }
            [world endScenario];
        }
        // Every run removes what it made, a failing one too (its logs went to stderr above).
        // SZFRIENDS_E2E_KEEP_LOGS keeps the whole directory, for whoever is investigating a run.
        if (getenv("SZFRIENDS_E2E_KEEP_LOGS") == NULL) {
            [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
        }
        else fprintf(stderr, "SZFriendsE2ETests: helper logs kept under %s\n", root.UTF8String);
        if (failed > 0 || SZFE2EFailures > 0) {
            fprintf(stderr, "SZFriendsE2ETests: %d scenario(s) failed\n", failed);
            return 1;
        }
        printf("SZFriendsE2ETests passed\n");
        return 0;
    }
}
