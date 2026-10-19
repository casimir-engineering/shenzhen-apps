// friends-e2e-check, online Friends (SZFriendsE2EOnline.h): friends who are never nearby reach each other through the
// local host, directly, then through the relay when every direct path fails, and back off the relay once a direct
// path opens.
//
// Usage: SZFriendsE2EOnlineTests <online e2e helper> <animal manifest> [scenario numbers, e.g. 2]

#import "SZFriendsE2EOnline.h"

#import <signal.h>
#import <sodium.h>

// The brief's budget for one whole scenario.
static const NSTimeInterval kScenarioBudget = 60;
static const NSUInteger kFileBytes = 50 * 1024 * 1024;
// The relay's cap (ADR 0010: max-bps=625000, 5 Mbit/s), with room for coturn's bursts across second boundaries.
static const double kRelayCapBytesPerSecond = 625000 * 1.1;

typedef BOOL (*SZFE2EOnlineScenario)(SZFE2EWorld *world);

// A started pair of friends: helpers, clients, and the conversation each has with the other.
@interface SZFE2EOnlinePair : NSObject
@property(nonatomic) SZFE2EHelper *helperA, *helperB;
@property(nonatomic) SZFE2EClient *a, *b;
@property(nonatomic, copy) NSString *bAtA, *aAtB;
@end

@implementation SZFE2EOnlinePair
@end

static NSString *Token(void) {
    return [[NSUUID UUID].UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""].lowercaseString;
}

static BOOL StartPair(SZFE2EWorld *world, SZFE2EOnlineHost *host, SZFE2EOnlinePair *pair, BOOL blockDirect) {
    pair.helperA = [world helperNamed:@"a"];
    pair.helperB = [world helperNamed:@"b"];
    NSString *bAtA = nil, *aAtB = nil;
    if (!SZFE2EOnlineSeedFriends(pair.helperA, pair.helperB, &bAtA, &aAtB)) return NO;
    pair.bAtA = bAtA;
    pair.aAtB = aAtB;
    for (SZFE2EHelper *helper in @[ pair.helperA, pair.helperB ]) {
        if (blockDirect) [[NSData data] writeToFile:SZFE2EOnlineBlockPath(helper) atomically:YES];
        helper.extraEnvironment = [host environmentForHelper:helper.name];
        CHECK([helper start], "%@ starts", helper.name);
    }
    pair.a = [SZFE2EClient clientForHelper:pair.helperA];
    pair.b = [SZFE2EClient clientForHelper:pair.helperB];
    CHECK(pair.a != nil && pair.b != nil, "both clients reach READY");
    CHECK([pair.a.welcome[@"capabilities"] containsObject:@"host.checkin"], "%@", pair.a.welcome);
    return YES;
}

static NSDictionary *TransferItem(SZFE2EClient *client, NSString *subscription, NSString *transferID) {
    for (NSDictionary *item in [client dataFor:subscription][@"items"]) {
        if ([item[@"kind"] isEqual:@"transfer"] && [item[@"transfer_id"] isEqual:transferID]) return item;
    }
    return nil;
}

// How much of the file B has: the progress while it moves, all of it once received, none before.
static double Fraction(NSDictionary *item) {
    if ([item[@"state"] isEqual:@"received"]) return 1;
    id progress = item[@"progress"];
    return [progress isKindOfClass:[NSDictionary class]] ? [progress[@"fraction"] doubleValue] : 0;
}

static NSString *RouteMethod(SZFE2EClient *client, NSString *subscription) {
    id method = [client dataFor:subscription][@"header"][@"route"][@"method"];
    return [method isKindOfClass:[NSString class]] ? method : @"";
}

static NSDictionary *HeaderRoute(SZFE2EClient *client, NSString *subscription) {
    id route = [client dataFor:subscription][@"header"][@"route"];
    return [route isKindOfClass:[NSDictionary class]] ? route : @{};
}

static NSDictionary *ListRoute(SZFE2EClient *client, NSString *list, NSString *conversationID) {
    for (NSDictionary *row in [client dataFor:list][@"rows"]) {
        if ([row[@"conversation_id"] isEqual:conversationID]) {
            return [row[@"route"] isKindOfClass:[NSDictionary class]] ? row[@"route"] : @{};
        }
    }
    return @{};
}

static BOOL RouteReads(NSDictionary *route, NSString *method, NSString *label) {
    return [route[@"kind"] isEqual:@"online"] && [route[@"method"] isEqual:method] &&
           [route[@"label"] isKindOfClass:[NSString class]] && [route[@"label"] hasPrefix:label];
}

// The person sees how the friend is connected in both places: the conversation header and their row in the list.
static BOOL ShowsOnline(SZFE2EClient *client, NSString *conversation, NSString *list, NSString *conversationID,
                        NSString *method, NSString *label) {
    CHECK(SZFE2EWaitUntil(5, ^BOOL {
              return RouteReads(HeaderRoute(client, conversation), method, label) &&
                     RouteReads(ListRoute(client, list, conversationID), method, label);
          }),
          "header %@, list row %@", HeaderRoute(client, conversation), ListRoute(client, list, conversationID));
    return YES;
}

// A sends a 50 MiB file; B sees the offer arrive over the Internet and accepts it. The transfer id comes back. With
// `atA`, A's conversation is watched meanwhile: `sawConnecting` says whether it showed Connecting while the file
// waited.
static NSString *OfferAndAccept(SZFE2EWorld *world, SZFE2EOnlinePair *pair, NSString *atB, NSString **source,
                                NSString *atA, BOOL *sawConnecting) {
    *source = [world fileOfSize:kFileBytes named:@"Site survey.pdf"];
    NSDictionary *reply = [pair.a intent:@"send_files" fields:@{@"conversation_id" : pair.bAtA,
                                                                @"files" : @[ @{@"path" : *source} ],
                                                                @"client_token" : Token()}];
    NSString *transferID = [reply[@"result"][@"transfer_ids"] firstObject];
    if (transferID == nil) {
        SZFE2EFail(__FILE__, __LINE__, "send_files", reply.description);
        return nil;
    }
    __block BOOL connecting = NO;
    if (!SZFE2EWaitUntil(25, ^BOOL {
            connecting = connecting || (atA != nil && [HeaderRoute(pair.a, atA)[@"kind"] isEqual:@"connecting"]);
            return TransferItem(pair.b, atB, transferID) != nil;
        })) {
        SZFE2EFail(__FILE__, __LINE__, "the offer reaches B online", [[pair.b dataFor:atB] description]);
        return nil;
    }
    if (![[pair.b intent:@"accept_offer" fields:@{@"transfer_id" : transferID}][@"ok"] boolValue]) {
        SZFE2EFail(__FILE__, __LINE__, "accept_offer", transferID);
        return nil;
    }
    if (sawConnecting) *sawConnecting = connecting;
    return transferID;
}

static BOOL ReceivedIntact(SZFE2EOnlinePair *pair, NSString *atB, NSString *transferID, NSString *source,
                           NSTimeInterval timeout) {
    __block NSDictionary *item = nil;
    CHECK(SZFE2EWaitUntil(timeout, ^BOOL {
              item = TransferItem(pair.b, atB, transferID);
              return [item[@"state"] isEqual:@"received"];
          }),
          "the file arrives: %@", item);
    CHECK([[NSData dataWithContentsOfFile:item[@"file"][@"path"]] isEqual:[NSData dataWithContentsOfFile:source]],
          "byte for byte");
    return YES;
}

BOOL SZFE2EOnlineScenarioDirect(SZFE2EWorld *world) {
    NSString *why = nil;
    SZFE2EOnlineHost *host = [SZFE2EOnlineHost startInWorld:world relay:NO skip:&why];
    if (host == nil) {
        if (why != nil) printf("skip online direct: %s\n", why.UTF8String);
        return why != nil;
    }
    BOOL ok = NO;
    @try {
        SZFE2EOnlinePair *pair = [SZFE2EOnlinePair new];
        if (!StartPair(world, host, pair, NO)) return NO;
        NSString *atB = [pair.b openConversation:pair.aAtB], *source = nil;
        NSString *listB = [pair.b subscribe:@"list" params:nil];
        NSString *transferID = OfferAndAccept(world, pair, atB, &source, nil, NULL);
        CHECK(transferID != nil);
        CHECK([RouteMethod(pair.b, atB) isEqualToString:@"internet"], "a direct Internet session: %@",
              [pair.b dataFor:atB][@"header"]);
        CHECK(ShowsOnline(pair.b, atB, listB, pair.aAtB, @"internet", @"Online, direct"));
        ok = ReceivedIntact(pair, atB, transferID, source, 30);
        CHECK([RouteMethod(pair.b, atB) isEqualToString:@"internet"], "never the relay");
        // An app that connects once the host offers online is told so in its welcome.
        SZFE2EClient *late = [SZFE2EClient clientForHelper:pair.helperB];
        CHECK([late.welcome[@"capabilities"] containsObject:@"online"], "%@", late.welcome);
        [late close];
    } @finally {
        [host stop];
    }
    return ok;
}

BOOL SZFE2EOnlineScenarioRelayThenDirect(SZFE2EWorld *world) {
    NSString *why = nil;
    SZFE2EOnlineHost *host = [SZFE2EOnlineHost startInWorld:world relay:YES skip:&why];
    if (host == nil) {
        if (why != nil) printf("skip online relay: %s\n", why.UTF8String);
        return why != nil;
    }
    BOOL ok = NO;
    @try {
        SZFE2EOnlinePair *pair = [SZFE2EOnlinePair new];
        if (!StartPair(world, host, pair, YES)) return NO;
        NSString *atB = [pair.b openConversation:pair.aAtB], *source = nil;
        NSString *atA = [pair.a openConversation:pair.bAtA], *listB = [pair.b subscribe:@"list" params:nil];
        BOOL sawConnecting = NO;
        NSString *transferID = OfferAndAccept(world, pair, atB, &source, atA, &sawConnecting);
        CHECK(transferID != nil);
        CHECK(sawConnecting, "A showed Connecting while the file waited for a path");
        CHECK(SZFE2EWaitUntil(5, ^BOOL { return [RouteMethod(pair.b, atB) isEqualToString:@"relay"]; }),
              "with every direct path blocked, the relay: %@", [pair.b dataFor:atB][@"header"]);
        CHECK(ShowsOnline(pair.b, atB, listB, pair.aAtB, @"relay", @"Online, through"));
        // At the cap: what arrives over 4 s, once the download is under way.
        __block double first = 0;
        CHECK(SZFE2EWaitUntil(10, ^BOOL {
                  first = Fraction(TransferItem(pair.b, atB, transferID));
                  return first > 0;
              }),
              "the download starts over the relay");
        NSDate *start = [NSDate date];
        SZFE2EPump(4);
        double fraction = Fraction(TransferItem(pair.b, atB, transferID));
        double rate = (fraction - first) * kFileBytes / -start.timeIntervalSinceNow;
        printf("  relayed at %.0f B/s\n", rate);
        CHECK(rate > 50000 && rate <= kRelayCapBytesPerSecond, "5 Mbit/s at most, and moving: %.0f B/s", rate);
        CHECK([RouteMethod(pair.b, atB) isEqualToString:@"relay"] && fraction < 0.5, "still relayed: %.2f", fraction);
        // A direct path opens, and the network change makes the offerer try it at once.
        for (SZFE2EHelper *helper in @[ pair.helperA, pair.helperB ]) {
            [[NSFileManager defaultManager] removeItemAtPath:SZFE2EOnlineBlockPath(helper) error:NULL];
        }
        kill(pair.helperA.pid, SIGUSR1);
        CHECK(SZFE2EWaitUntil(15, ^BOOL { return [RouteMethod(pair.b, atB) isEqualToString:@"internet"]; }),
              "the transfer moves off the relay: %@", [pair.b dataFor:atB][@"header"]);
        CHECK(ShowsOnline(pair.b, atB, listB, pair.aAtB, @"internet", @"Online, direct"));
        ok = ReceivedIntact(pair, atB, transferID, source, 20);
        CHECK([pair.helperA.log rangeOfString:@" resumes at byte "].location != NSNotFound,
              "resumed mid-file on the direct session: %@", pair.helperA.log);
    } @finally {
        [host stop];
    }
    return ok;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3 || sodium_init() < 0) {
            fprintf(stderr, "usage: SZFriendsE2EOnlineTests <online e2e helper> <animal manifest>\n");
            return 2;
        }
        NSString *executable = @(argv[1]), *manifest = @(argv[2]);
        char template[1024];
        NSString *pattern = [NSTemporaryDirectory() stringByAppendingPathComponent:@"szfo.XXXXXX"];
        strlcpy(template, pattern.fileSystemRepresentation, sizeof(template));
        NSString *root = mkdtemp(template) ? @(template) : nil;
        if (root == nil || ![[NSFileManager defaultManager] isExecutableFileAtPath:executable]) {
            fprintf(stderr, "SZFriendsE2EOnlineTests: no scratch directory or no helper at %s\n", argv[1]);
            return 2;
        }
        SZFE2EWorld *world = [[SZFE2EWorld alloc] initWithExecutable:executable manifest:manifest root:root];
        struct {
            const char *name;
            SZFE2EOnlineScenario run;
        } scenarios[] = {
            {"online: friends never nearby connect directly and move 50 MiB", SZFE2EOnlineScenarioDirect},
            {"online: direct blocked, the relay at the cap, then a direct path takes over",
             SZFE2EOnlineScenarioRelayThenDirect},
            {"online: Add by ID never nearby, a request then Accept", SZFE2EOnlineScenarioAddByID},
            {"online: a friend link is accepted remotely", SZFE2EOnlineScenarioFriendLink},
            {"online: a friend link with another key never completes", SZFE2EOnlineScenarioLinkKeyMismatch},
            {"online: past 20 a day, a link's request waits for the person", SZFE2EOnlineScenarioLinkCap},
        };
        NSArray<NSString *> *only = argc > 3 ? [@(argv[3]) componentsSeparatedByString:@","] : nil;
        int failed = 0;
        for (size_t i = 0; i < sizeof(scenarios) / sizeof(scenarios[0]); i++) {
            if (only != nil && ![only containsObject:[NSString stringWithFormat:@"%zu", i + 1]]) continue;
            int before = SZFE2EFailures;
            [world beginScenario:[NSString stringWithFormat:@"o%02zu", i + 1]];
            NSDate *start = [NSDate date];
            BOOL ok = scenarios[i].run(world) && SZFE2EFailures == before;
            NSTimeInterval took = -start.timeIntervalSinceNow;
            if (ok && took > kScenarioBudget) {
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
        if (getenv("SZFRIENDS_E2E_KEEP_LOGS") == NULL) {
            [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
        } else fprintf(stderr, "SZFriendsE2EOnlineTests: helper logs kept under %s\n", root.UTF8String);
        if (failed > 0 || SZFE2EFailures > 0) {
            fprintf(stderr, "SZFriendsE2EOnlineTests: %d scenario(s) failed\n", failed);
            return 1;
        }
        printf("SZFriendsE2EOnlineTests passed\n");
        return 0;
    }
}
