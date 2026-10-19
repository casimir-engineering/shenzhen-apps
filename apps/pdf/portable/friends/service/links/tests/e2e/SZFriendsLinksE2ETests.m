// friends-links-check, end to end (SZFriendsLinksE2E.h).
//
// Usage: SZFriendsLinksE2ETests <links e2e helper> <animal manifest>

#import "SZFriendsLinksE2E.h"

#import <sodium.h>

static const NSTimeInterval kScenarioBudget = 60;

// The host's guest URL and STUN URI, from the signed list a helper of this world checks in with.
static BOOL HostAddresses(NSDictionary<NSString *, NSString *> *env, NSURL **guestURL, NSString **stun) {
    NSData *envelope = [NSData dataWithContentsOfFile:env[@"SZFRIENDS_TEST_HOST_LIST"]];
    NSDictionary *outer = envelope ? [NSJSONSerialization JSONObjectWithData:envelope options:0 error:NULL] : nil;
    NSData *payload = SZFriendsLinkBase64URLDecode(outer[@"payload"]);
    NSDictionary *list = payload ? [NSJSONSerialization JSONObjectWithData:payload options:0 error:NULL] : nil;
    NSDictionary *host = [list[@"hosts"] firstObject];
    NSString *url = [host[@"urls"] firstObject];
    *guestURL = url ? [NSURL URLWithString:[url stringByAppendingString:@"?guest=1"]] : nil;
    *stun = [host[@"turn_uris"] firstObject];
    return *guestURL != nil;
}

// "https://host/d#<fragment>" -> "d.<fragment>": what the page's buttons hand an app.
static NSString *AppPayload(NSString *url) {
    NSRange hash = [url rangeOfString:@"#"];
    if (hash.location == NSNotFound || hash.location < 2) return nil;
    NSString *kind = [url substringWithRange:NSMakeRange(hash.location - 1, 1)];
    return [NSString stringWithFormat:@"%@.%@", kind, [url substringFromIndex:hash.location + 1]];
}

static NSDictionary *MakeLink(SZFE2EClient *client, NSString *path, NSInteger days) {
    NSDictionary *reply = [client intent:@"make_download_link"
                                  fields:@{@"file" : @{@"path" : path}, @"expires_days" : @(days)}];
    return [reply[@"ok"] isEqual:@YES] ? reply[@"result"] : nil;
}

// Opens a link as a guest until the sender's helper has it registered (the first open can come before the host
// does), or 3 tries.
static SZFriendsLinkOutcome Guest(NSURL *url, NSString *stun, NSString *payload, BOOL block, SZFLGuestSink *sink,
                                  uint8_t *attempt) {
    SZFriendsLinkOutcome outcome = SZFriendsLinkOutcomeUnavailable;
    for (int i = 0; i < 3 && outcome == SZFriendsLinkOutcomeUnavailable; i++) {
        if (i > 0) SZFE2EPump(1);
        outcome = SZFLGuestOpen(url, stun, payload, block, sink, attempt);
    }
    return outcome;
}

static NSDictionary *Data(SZFE2EClient *client, NSString *subscription) {
    return [client dataFor:subscription] ?: @{};
}

BOOL SZFLScenarioGuests(SZFE2EWorld *world) {
    NSString *why = nil;
    SZFE2EOnlineHost *host = [SZFE2EOnlineHost startInWorld:world relay:YES skip:&why];
    BOOL relay = host != nil;
    if (host == nil && [why containsString:@"FRIENDS_TEST_COTURN"]) {
        printf("skip the relayed download: %s\n", why.UTF8String);
        host = [SZFE2EOnlineHost startInWorld:world relay:NO skip:&why];
    }
    if (host == nil) {
        if (why != nil) printf("skip links guests: %s\n", why.UTF8String);
        return why != nil;
    }
    SZFE2EHelper *sender = [world helperNamed:@"s"];
    NSMutableDictionary *env = [[host environmentForHelper:@"s"] mutableCopy];
    env[@"SZFRIENDS_TEST_LINK_NO_CLONE"] = @"1"; // the original is served: its changes must be caught
    sender.extraEnvironment = env;
    CHECK([sender start], "the sender starts");
    SZFE2EClient *client = [SZFE2EClient clientForHelper:sender];
    CHECK(client != nil && [client.welcome[@"capabilities"] containsObject:@"links"], "%@", client.welcome);
    NSURL *guestURL = nil;
    NSString *stun = nil;
    CHECK(HostAddresses(env, &guestURL, &stun), "the host's addresses");
    NSString *path = [world fileOfSize:3 * 1024 * 1024 + 17 named:@"Site photos.pdf"];
    NSData *bytes = [NSData dataWithContentsOfFile:path];
    NSDictionary *bad = [client intent:@"open_link" fields:@{@"payload" : @"d.AB"}];
    CHECK([bad[@"error"][@"code"] isEqual:@"invalid_field"] &&
              [bad[@"error"][@"message"] hasPrefix:@"This link isn’t complete."],
          "%@", bad);
    NSDictionary *days = [client intent:@"make_download_link"
                                 fields:@{@"file" : @{@"path" : path}, @"expires_days" : @3}];
    CHECK([days[@"error"][@"code"] isEqual:@"invalid_field"], "1, 7 or 30 days only: %@", days);
    NSDictionary *made = MakeLink(client, path, 7);
    CHECK([made[@"url"] hasPrefix:@"http://127.0.0.1:"] && [made[@"message"] hasPrefix:@"Download link copied."],
          "%@", made);
    NSString *payload = AppPayload(made[@"url"]);
    SZFLGuestSink *sink = [SZFLGuestSink new];
    uint8_t attempt = 0;
    SZFriendsLinkOutcome outcome = Guest(guestURL, stun, payload, NO, sink, &attempt);
    CHECK(outcome == SZFriendsLinkOutcomeDone && attempt == 1 && [sink.bytes isEqualToData:bytes],
          "direct: outcome %ld attempt %d, %lu bytes", (long)outcome, attempt, (unsigned long)sink.bytes.length);
    CHECK([sink.metadata.name isEqualToString:@"Site photos.pdf"], "%@", sink.metadata.name);
    NSUInteger downloads = 1;
    if (relay) {
        NSString *block = SZFE2EOnlineBlockPath(sender);
        [[NSData data] writeToFile:block atomically:YES];
        SZFLGuestSink *relayed = [SZFLGuestSink new];
        outcome = SZFLGuestOpen(guestURL, stun, payload, YES, relayed, &attempt);
        [[NSFileManager defaultManager] removeItemAtPath:block error:NULL];
        CHECK(outcome == SZFriendsLinkOutcomeDone && attempt == 2 && [relayed.bytes isEqualToData:bytes],
              "relayed: outcome %ld attempt %d", (long)outcome, attempt);
        downloads = 2;
    }
    NSString *profile = [client subscribe:@"profile" params:nil];
    NSString *expected = downloads == 1 ? @"1 download" : @"2 downloads";
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              NSDictionary *row = [Data(client, profile)[@"links"][@"downloads"] firstObject];
              return [row[@"downloads_label"] isEqual:expected];
          }),
          "Your links counts %@: %@", expected, Data(client, profile)[@"links"]);
    // The original changed after the link was made: refused before any byte.
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    [handle seekToEndOfFile];
    [handle writeData:[@"edited" dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
    SZFLGuestSink *changed = [SZFLGuestSink new];
    outcome = SZFLGuestOpen(guestURL, stun, payload, NO, changed, NULL);
    CHECK(outcome == SZFriendsLinkOutcomeChanged && changed.bytes.length == 0 && changed.metadata == nil,
          "changed: outcome %ld", (long)outcome);
    // Revoked, then expired: nothing at all, and the opener is told why at once (the helper's tombstone).
    NSString *other = [world fileOfSize:20000 named:@"Contract.pdf"];
    NSDictionary *revoked = MakeLink(client, other, 7);
    NSDictionary *reply = [client intent:@"revoke_link" fields:@{@"link_id" : revoked[@"link_id"] ?: @""}];
    CHECK([reply[@"ok"] isEqual:@YES], "%@", reply);
    SZFLGuestSink *late = [SZFLGuestSink new];
    outcome = SZFLGuestOpen(guestURL, stun, AppPayload(revoked[@"url"]), NO, late, NULL);
    CHECK(outcome == SZFriendsLinkOutcomeEnded && late.metadata == nil, "revoked: outcome %ld", (long)outcome);
    NSDictionary *daily = MakeLink(client, other, 1);
    NSString *offset = [sender.stateDirectory stringByAppendingPathComponent:@"links-clock-offset"];
    [@"172800" writeToFile:offset atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    SZFLGuestSink *expired = [SZFLGuestSink new];
    outcome = SZFLGuestOpen(guestURL, stun, AppPayload(daily[@"url"]), NO, expired, NULL);
    CHECK(outcome == SZFriendsLinkOutcomeEnded && expired.metadata == nil, "expired: outcome %ld", (long)outcome);
    [client close];
    [host stop];
    return YES;
}

static NSDictionary *RowWhere(SZFE2EClient *client, NSString *list, BOOL (^match)(NSDictionary *row)) {
    for (NSDictionary *row in Data(client, list)[@"rows"]) {
        if (match(row)) return row;
    }
    return nil;
}

BOOL SZFLScenarioApps(SZFE2EWorld *world) {
    NSString *why = nil;
    SZFE2EOnlineHost *host = [SZFE2EOnlineHost startInWorld:world relay:NO skip:&why];
    if (host == nil) {
        if (why != nil) printf("skip links apps: %s\n", why.UTF8String);
        return why != nil;
    }
    SZFE2EHelper *sender = [world helperNamed:@"s"], *opener = [world helperNamed:@"o"];
    NSDictionary *senderEnv = [host environmentForHelper:@"s"];
    NSMutableDictionary *openerEnv = [[host environmentForHelper:@"o"] mutableCopy];
    // Nearby on loopback, as the friend link's request travels between Macs that are nearby.
    openerEnv[@"SZFRIENDS_TEST_SERVICE_TYPE"] = senderEnv[@"SZFRIENDS_TEST_SERVICE_TYPE"];
    sender.extraEnvironment = senderEnv;
    opener.extraEnvironment = openerEnv;
    CHECK([sender start] && [opener start], "both start");
    SZFE2EClient *mei = [SZFE2EClient clientForHelper:sender], *app = [SZFE2EClient clientForHelper:opener];
    CHECK(mei != nil && app != nil, "both clients");
    // Both people opened Friends: Nearby runs, which carries the friend link's request.
    CHECK([[mei intent:@"activate" fields:nil][@"ok"] isEqual:@YES] &&
              [[app intent:@"activate" fields:nil][@"ok"] isEqual:@YES],
          "activated");
    CHECK([[mei intent:@"set_name" fields:@{@"name" : @"Mei Wong"}][@"ok"] isEqual:@YES], "name");
    NSString *path = [world fileOfSize:600000 named:@"Site photos.pdf"];
    NSString *payload = AppPayload(MakeLink(mei, path, 7)[@"url"]);
    NSDictionary *card = [app intent:@"open_link" fields:@{@"payload" : payload ?: @""}][@"result"][@"card"];
    CHECK([card[@"kind"] isEqual:@"download"] && [[card[@"actions"] firstObject][@"payload"] isEqual:payload],
          "%@", card);
    NSDictionary *reply = nil;
    for (int i = 0; i < 5 && ![reply[@"ok"] isEqual:@YES]; i++) {
        if (i > 0) SZFE2EPump(1); // the sender's link reaches the host once it checked in
        reply = [app intent:@"receive_link" fields:@{@"payload" : payload}];
    }
    CHECK([reply[@"result"][@"message"] hasPrefix:@"Receiving Site photos.pdf from Mei Wong."], "%@", reply);
    NSString *conversation = reply[@"result"][@"conversation_id"];
    NSString *received = [opener.stateDirectory stringByAppendingPathComponent:@"received/Site photos.pdf"];
    NSData *bytes = [NSData dataWithContentsOfFile:path];
    CHECK(SZFE2EWaitUntil(15, ^BOOL { return [[NSData dataWithContentsOfFile:received] isEqualToData:bytes]; }),
          "the file arrives in the received folder");
    NSString *list = [app subscribe:@"list" params:nil];
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              return RowWhere(app, list, ^BOOL(NSDictionary *row) {
                         return [row[@"conversation_id"] isEqual:conversation] &&
                                [row[@"subtitle"] isEqual:@"Sent you Site photos.pdf through a link"];
                     }) != nil;
          }),
          "the sender's row: %@", Data(app, list)[@"rows"]);
    // The friend link: Mei's Mac accepts the request at once, and both say how they met.
    NSString *profile = [mei subscribe:@"profile" params:nil];
    CHECK(SZFE2EWaitUntil(10, ^BOOL { return Data(mei, profile)[@"links"][@"friend"][@"url"] != nil; }), "a link");
    NSString *friendPayload = AppPayload(Data(mei, profile)[@"links"][@"friend"][@"url"]);
    card = [app intent:@"open_link" fields:@{@"payload" : friendPayload ?: @""}][@"result"][@"card"];
    CHECK([card[@"title"] isEqual:@"Add Mei Wong?"], "%@", card);
    reply = [app intent:@"add_from_link" fields:@{@"payload" : friendPayload}];
    CHECK([reply[@"ok"] isEqual:@YES], "%@", reply);
    NSString *meiList = [mei subscribe:@"list" params:nil];
    CHECK(SZFE2EWaitUntil(45, ^BOOL {
              return RowWhere(mei, meiList, ^BOOL(NSDictionary *row) {
                         return [row[@"subtitle"] isEqual:@"Added through your link"];
                     }) != nil;
          }),
          "accepted at once on Mei's Mac: %@", Data(mei, meiList)[@"rows"]);
    CHECK(SZFE2EWaitUntil(30, ^BOOL {
              return RowWhere(app, list, ^BOOL(NSDictionary *row) {
                         return [row[@"conversation_id"] isEqual:conversation] &&
                                ([row[@"subtitle"] isEqual:@"Added through Mei’s link"] ||
                                 [row[@"subtitle"] isEqual:@"You are now friends"]);
                     }) != nil;
          }),
          "friends on the other Mac too: %@", Data(app, list)[@"rows"]);
    [mei close];
    [app close];
    [host stop];
    return YES;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3 || sodium_init() < 0) {
            fprintf(stderr, "usage: SZFriendsLinksE2ETests <links e2e helper> <animal manifest>\n");
            return 2;
        }
        SZFriendsOnlineTestLinksUseLocalAddresses = YES; // the browser stand-in runs here, on loopback
        char template[1024];
        NSString *pattern = [NSTemporaryDirectory() stringByAppendingPathComponent:@"szfl.XXXXXX"];
        strlcpy(template, pattern.fileSystemRepresentation, sizeof(template));
        NSString *root = mkdtemp(template) ? @(template) : nil;
        if (root == nil) return 2;
        SZFE2EWorld *world = [[SZFE2EWorld alloc] initWithExecutable:@(argv[1]) manifest:@(argv[2]) root:root];
        struct {
            const char *name;
            BOOL (*run)(SZFE2EWorld *);
        } scenarios[] = {
            {"links: a guest downloads directly and relayed; changed, revoked and expired refused", SZFLScenarioGuests},
            {"links: an app receives a download link; a friend link is accepted at once", SZFLScenarioApps},
        };
        int failed = 0;
        for (size_t i = 0; i < sizeof scenarios / sizeof scenarios[0]; i++) {
            int before = SZFE2EFailures;
            [world beginScenario:[NSString stringWithFormat:@"l%02zu", i + 1]];
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
        }
        if (failed > 0 || SZFE2EFailures > 0) {
            fprintf(stderr, "SZFriendsLinksE2ETests: %d scenario(s) failed\n", failed);
            return 1;
        }
        printf("SZFriendsLinksE2ETests passed\n");
        return 0;
    }
}
