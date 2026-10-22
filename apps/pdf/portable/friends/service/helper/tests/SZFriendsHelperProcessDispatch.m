// Process tests of the dispatch layer: snapshots every window agrees on, and intents routed to the store.
//
// The store is seeded through its own header before the helper starts, the way a previous helper run would have
// left it, so these tests exercise whichever store implementation the helper links.

#import <Foundation/Foundation.h>

#import <signal.h>
#import <sodium.h>
#import <unistd.h>

#import "SZFriendsHelperProcessHarness.h"
#import "service/store/SZFriendsStore.h"

// Two incoming requests waiting for an answer: the badge counts 2.
static BOOL SZFHSeedRequests(NSString *state) {
    if (sodium_init() < 0) return NO;
    NSError *error = nil;
    SZFriendsStore *store = [SZFriendsStore storeInDirectory:state error:&error];
    if (store == nil) {
        fprintf(stderr, "store: %s\n", error.localizedDescription.UTF8String);
        return NO;
    }
    NSDate *now = [NSDate date];
    for (NSString *name in @[ @"Lena", @"Kenji" ]) {
        SZFriendsPersonRecord *person = [[SZFriendsPersonRecord alloc] init];
        person.conversationID = [@"c_" stringByAppendingString:name.lowercaseString];
        NSMutableData *key = [NSMutableData dataWithLength:32];
        randombytes_buf(key.mutableBytes, key.length);
        person.identityKey = key;
        person.name = name;
        person.friendsID = [name isEqual:@"Lena"] ? @"orchid-summit" : @"maple-river";
        person.picture = [SZFriendsPicture placeholder];
        person.relation = SZFriendsRelationIncomingRequest;
        person.requestAt = now;
        person.requestFoundNearby = YES;
        person.lastInteractionAt = now;
        if (![store savePerson:person error:&error]) {
            fprintf(stderr, "seed: %s\n", error.localizedDescription.UTF8String);
            return NO;
        }
    }
    [store close];
    return YES;
}

static NSDictionary *SZFHSnapshotFor(SZFHClient *client, NSString *subscription, NSTimeInterval timeout) {
    for (NSDictionary *snapshot in client.snapshots) {
        if ([snapshot[@"subscription"] isEqual:subscription]) return snapshot;
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (deadline.timeIntervalSinceNow > 0) {
        NSDictionary *frame = [client nextFrameOfType:@"snapshot" timeout:deadline.timeIntervalSinceNow];
        if (frame == nil) return nil;
        if ([frame[@"subscription"] isEqual:subscription]) return frame;
    }
    return nil;
}

// The badge belongs to the helper: two windows subscribed to it receive the same snapshot, and an answer given in
// one window updates both, before the reply reaches the window that answered.
BOOL SZFHTestSameBadge(SZFHHarness *harness) {
    NSString *state = [harness makeDirectory];
    CHECK(SZFHSeedRequests(state), "seeded the store");
    pid_t pid = [harness spawnHelperWithStateDirectory:state timeScale:1];
    NSString *socket = [harness socketPathForStateDirectory:state];
    SZFHClient *a = [SZFHClient connectToSocket:socket timeout:5];
    SZFHClient *b = [SZFHClient connectToSocket:socket timeout:5];
    CHECK([[a helloWithEmbeddedBuild:0][@"type"] isEqual:@"welcome"]);
    CHECK([[b helloWithEmbeddedBuild:0][@"type"] isEqual:@"welcome"]);
    NSDictionary *replyA = [a intent:@"subscribe" fields:@{@"view" : @"badge"}];
    NSDictionary *replyB = [b intent:@"subscribe" fields:@{@"view" : @"badge"}];
    NSString *subA = replyA[@"result"][@"subscription"], *subB = replyB[@"result"][@"subscription"];
    CHECK(subA != nil && subB != nil, "%@ %@", replyA, replyB);
    NSDictionary *firstA = SZFHSnapshotFor(a, subA, 0), *firstB = SZFHSnapshotFor(b, subB, 0);
    CHECK(firstA != nil && firstB != nil, "the first snapshot arrives before the subscribe reply");
    CHECK([firstA[@"view"] isEqual:@"badge"] && [firstA[@"rev"] intValue] == 1);
    CHECK([firstA[@"data"][@"count"] intValue] == 2, "two requests wait: %@", firstA[@"data"]);
    CHECK([firstA[@"data"] isEqual:firstB[@"data"]], "both windows show the same badge");

    [a.snapshots removeAllObjects];
    [b.snapshots removeAllObjects];
    NSDictionary *declined = [a intent:@"decline_request" fields:@{@"conversation_id" : @"c_lena"}];
    CHECK([declined[@"ok"] boolValue], "%@", declined);
    NSDictionary *nextA = SZFHSnapshotFor(a, subA, 0);
    CHECK(nextA != nil, "the snapshot reflecting the answer comes before its reply");
    NSDictionary *nextB = SZFHSnapshotFor(b, subB, 3);
    CHECK(nextB != nil, "the other window is told too");
    CHECK([nextA[@"rev"] intValue] == 2 && [nextB[@"rev"] intValue] == 2, "%@ / %@", nextA, nextB);
    CHECK([nextA[@"data"][@"count"] intValue] == 1 && [nextA[@"data"] isEqual:nextB[@"data"]], "%@ / %@",
          nextA[@"data"], nextB[@"data"]);
    kill(pid, SIGTERM);
    CHECK([harness waitForExit:pid timeout:3 status:NULL]);
    return YES;
}

// A conversation whose newest 200 messages would not fit one 8 MiB frame still opens: the helper sends fewer
// items with has_earlier rather than dropping the snapshot.
BOOL SZFHTestLongConversation(SZFHHarness *harness) {
    NSString *state = [harness makeDirectory];
    CHECK(sodium_init() >= 0);
    NSError *error = nil;
    SZFriendsStore *store = [SZFriendsStore storeInDirectory:state error:&error];
    CHECK(store != nil, "%@", error);
    SZFriendsPersonRecord *person = [[SZFriendsPersonRecord alloc] init];
    person.conversationID = @"c_long";
    NSMutableData *key = [NSMutableData dataWithLength:32];
    randombytes_buf(key.mutableBytes, key.length);
    person.identityKey = key;
    person.name = @"Ana";
    person.picture = [SZFriendsPicture placeholder];
    person.relation = SZFriendsRelationFriend;
    person.lastInteractionAt = [NSDate date];
    CHECK([store savePerson:person error:&error], "%@", error);
    NSString *text = [@"" stringByPaddingToLength:32000 withString:@"long message " startingAtIndex:0];
    NSDate *start = [NSDate dateWithTimeIntervalSinceNow:-3600];
    for (NSUInteger i = 0; i < 140; i++) {
        SZFriendsItemRecord *item = [[SZFriendsItemRecord alloc] init];
        item.itemID = [NSString stringWithFormat:@"%032lx", (unsigned long)i + 1];
        item.conversationID = @"c_long";
        item.kind = SZFriendsItemKindMessage;
        item.direction = SZFriendsDirectionIncoming;
        item.sentAt = [start dateByAddingTimeInterval:i];
        item.receivedAt = item.sentAt;
        item.text = text;
        CHECK([store insertItem:item error:&error], "%@", error);
    }
    [store close];
    pid_t pid = [harness spawnHelperWithStateDirectory:state timeScale:1];
    SZFHClient *c = [SZFHClient connectToSocket:[harness socketPathForStateDirectory:state] timeout:5];
    CHECK([[c helloWithEmbeddedBuild:0][@"type"] isEqual:@"welcome"]);
    NSDictionary *reply = [c intent:@"open_conversation" fields:@{@"conversation_id" : @"c_long"}];
    NSDictionary *snapshot = SZFHSnapshotFor(c, reply[@"result"][@"subscription"], 0);
    NSArray *items = snapshot[@"data"][@"items"];
    CHECK(snapshot != nil && items.count > 0, "a snapshot, not a dropped frame: %@", reply);
    CHECK([snapshot[@"data"][@"has_earlier"] boolValue], "the rest stays reachable with load_earlier");
    kill(pid, SIGTERM);
    CHECK([harness waitForExit:pid timeout:3 status:NULL]);
    return YES;
}

// Paths in the fixtures name the owner's files; the test never lets the helper read them.
static id SZFHWithoutRealPaths(id value, NSString *missing) {
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *copy = [NSMutableDictionary dictionary];
        for (NSString *key in value) {
            id item = value[key];
            BOOL path = [key isEqual:@"path"] && [item isKindOfClass:[NSString class]];
            copy[key] = path ? [missing stringByAppendingPathComponent:[item lastPathComponent]]
                             : SZFHWithoutRealPaths(item, missing);
        }
        return copy;
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *copy = [NSMutableArray array];
        for (id item in value) [copy addObject:SZFHWithoutRealPaths(item, missing)];
        return copy;
    }
    return value;
}

// One example of every intent (fixtures/intents.jsonl) gets exactly one reply, never `internal`; Reset Friends
// then says goodbye to every client so they subscribe again.
BOOL SZFHTestEveryIntent(SZFHHarness *harness, NSString *fixtures) {
    NSString *state = [harness makeDirectory];
    CHECK(SZFHSeedRequests(state));
    NSString *lines = [NSString stringWithContentsOfFile:[fixtures stringByAppendingPathComponent:@"intents.jsonl"]
                                                encoding:NSUTF8StringEncoding error:NULL];
    CHECK(lines.length > 0, "fixtures at %@", fixtures);
    pid_t pid = [harness spawnHelperWithStateDirectory:state timeScale:1];
    NSString *socket = [harness socketPathForStateDirectory:state];
    SZFHClient *c = [SZFHClient connectToSocket:socket timeout:5];
    SZFHClient *other = [SZFHClient connectToSocket:socket timeout:5];
    CHECK([[c helloWithEmbeddedBuild:0][@"type"] isEqual:@"welcome"]);
    CHECK([[other helloWithEmbeddedBuild:0][@"type"] isEqual:@"welcome"]);
    NSString *missing = [state stringByAppendingPathComponent:@"not-there"];
    NSDictionary *reset = nil, *disable = nil;
    NSUInteger count = 0;
    for (NSString *line in [lines componentsSeparatedByString:@"\n"]) {
        if (line.length == 0) continue;
        NSDictionary *frame = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding]
                                                              options:0 error:NULL];
        CHECK([frame isKindOfClass:[NSDictionary class]], "%@", line);
        if ([frame[@"type"] isEqual:@"reset_friends"]) reset = frame;
        if ([frame[@"type"] isEqual:@"disable"]) disable = frame;
        if (reset == frame || disable == frame) continue;
        NSMutableDictionary *fields = [SZFHWithoutRealPaths(frame, missing) mutableCopy];
        [fields removeObjectsForKeys:@[ @"type", @"id" ]];
        NSDictionary *reply = [c intent:frame[@"type"] fields:fields];
        CHECK([reply[@"type"] isEqual:@"reply"], "a reply to %@", frame[@"type"]);
        CHECK(![reply[@"error"][@"code"] isEqual:@"internal"], "%@ → %@", frame[@"type"], reply);
        count++;
    }
    CHECK(count > 40 && reset != nil && disable != nil, "%lu intents", (unsigned long)count);
    NSDictionary *reply = [c intent:@"reset_friends" fields:@{@"confirm" : @"reset"}];
    CHECK([reply[@"ok"] boolValue], "%@", reply);
    for (SZFHClient *client in @[ c, other ]) {
        NSDictionary *goodbye = [client nextFrameOfType:@"goodbye" timeout:3];
        CHECK([goodbye[@"reason"] isEqual:@"reset"], "%@", goodbye);
    }
    SZFHClient *after = [SZFHClient connectToSocket:socket timeout:5];
    CHECK([[after helloWithEmbeddedBuild:0][@"type"] isEqual:@"welcome"], "clients come back after a reset");
    reply = [after intent:@"subscribe" fields:@{@"view" : @"list"}];
    NSDictionary *list = SZFHSnapshotFor(after, reply[@"result"][@"subscription"], 0);
    CHECK([list[@"data"][@"rows"] count] == 0, "nobody left after Reset Friends: %@", list[@"data"][@"rows"]);
    CHECK([[after intent:@"disable" fields:nil][@"ok"] boolValue]);
    int status = 0;
    CHECK([harness waitForExit:pid timeout:3 status:&status], "the last client turned Friends off");
    return YES;
}

// Intents reach the store through the dispatch layer and come back as replies and snapshots.
BOOL SZFHTestDispatch(SZFHHarness *harness) {
    NSString *state = [harness makeDirectory];
    CHECK(SZFHSeedRequests(state));
    pid_t pid = [harness spawnHelperWithStateDirectory:state timeScale:1];
    SZFHClient *c = [SZFHClient connectToSocket:[harness socketPathForStateDirectory:state] timeout:5];
    CHECK([[c helloWithEmbeddedBuild:0][@"type"] isEqual:@"welcome"]);

    NSDictionary *reply = [c intent:@"subscribe" fields:@{@"view" : @"list"}];
    NSDictionary *list = SZFHSnapshotFor(c, reply[@"result"][@"subscription"], 0);
    CHECK([list[@"data"][@"rows"] count] == 2, "two rows: %@", list);

    CHECK([[c intent:@"set_name" fields:@{@"name" : @"  Mei  "}][@"ok"] boolValue]);
    reply = [c intent:@"subscribe" fields:@{@"view" : @"profile"}];
    NSDictionary *profile = SZFHSnapshotFor(c, reply[@"result"][@"subscription"], 0);
    CHECK([profile[@"data"][@"name"][@"value"] isEqual:@"Mei"], "trimmed name: %@", profile[@"data"][@"name"]);
    reply = [c intent:@"set_name" fields:@{@"name" : [NSString stringWithFormat:@"Mei%C", (unichar)7]}];
    CHECK([reply[@"error"][@"code"] isEqual:@"name_invalid"], "%@", reply);
    NSString *tooLong = [@"" stringByPaddingToLength:41 withString:@"x" startingAtIndex:0];
    reply = [c intent:@"set_name" fields:@{@"name" : tooLong}];
    CHECK([reply[@"error"][@"code"] isEqual:@"name_invalid"], "41 characters: %@", reply);

    reply = [c intent:@"add_by_id" fields:@{@"friends_id" : @"not-a-real-id"}];
    CHECK([reply[@"error"][@"code"] isEqual:@"id_invalid"], "%@", reply);
    reply = [c intent:@"open_conversation" fields:@{@"conversation_id" : @"c_nobody"}];
    CHECK([reply[@"error"][@"code"] isEqual:@"not_found"], "%@", reply);
    reply = [c intent:@"send_message" fields:@{@"conversation_id" : @"c_kenji", @"text" : @"hi",
                                               @"client_token" : @"token-0123456789abcdef"}];
    CHECK([reply[@"error"][@"code"] isEqual:@"not_friends"], "a request is not a friend yet: %@", reply);

    [c.snapshots removeAllObjects];
    reply = [c intent:@"open_conversation" fields:@{@"conversation_id" : @"c_kenji"}];
    CHECK([reply[@"result"][@"conversation_id"] isEqual:@"c_kenji"], "%@", reply);
    NSString *conversationSubscription = reply[@"result"][@"subscription"];
    NSDictionary *conversation = SZFHSnapshotFor(c, conversationSubscription, 0);
    CHECK([conversation[@"view"] isEqual:@"conversation"], "snapshot before reply: %@", conversation);

    CHECK([[c intent:@"accept_request" fields:@{@"conversation_id" : @"c_kenji"}][@"ok"] boolValue]);
    NSDictionary *fields = @{@"conversation_id" : @"c_kenji", @"text" : @"合同 attached tomorrow",
                             @"client_token" : @"token-0123456789abcdef"};
    reply = [c intent:@"send_message" fields:fields];
    NSString *messageID = reply[@"result"][@"message_id"];
    CHECK(messageID.length > 0, "%@", reply);
    reply = [c intent:@"send_message" fields:fields];
    CHECK([reply[@"result"][@"message_id"] isEqual:messageID], "the same client token sends once: %@", reply);
    // Files attached with nothing typed are only the files: no empty message goes out above them.
    NSString *attached = [[harness makeDirectory] stringByAppendingPathComponent:@"Site plan.pdf"];
    CHECK([[NSData dataWithBytes:"%PDF-1.4\n" length:9] writeToFile:attached atomically:YES]);
    NSDictionary *attachOnly = @{@"conversation_id" : @"c_kenji", @"text" : @"",
                                 @"attachments" : @[ @{@"path" : attached} ],
                                 @"client_token" : @"token-attachonly-0123456789"};
    reply = [c intent:@"send_message" fields:attachOnly];
    CHECK([reply[@"result"][@"message_id"] isEqual:@""] && [reply[@"result"][@"transfer_ids"] count] == 1,
          "an attachment alone is one offer and no message: %@", reply);
    NSString *transferID = reply[@"result"][@"transfer_ids"][0];
    reply = [c intent:@"send_message" fields:attachOnly];
    CHECK([reply[@"result"][@"message_id"] isEqual:@""] && [reply[@"result"][@"transfer_ids"] isEqual:@[ transferID ]],
          "the same client token offers it once: %@", reply);
    // The newest conversation snapshot, from those that came with the replies or from the ones that follow.
    NSArray *items = nil;
    for (NSDictionary *frame in c.snapshots) {
        if ([frame[@"subscription"] isEqual:conversationSubscription]) items = frame[@"data"][@"items"];
    }
    for (NSDate *until = [NSDate dateWithTimeIntervalSinceNow:5];
         ![[items valueForKey:@"item_id"] containsObject:transferID] && until.timeIntervalSinceNow > 0;) {
        NSDictionary *frame = [c nextFrameOfType:@"snapshot" timeout:until.timeIntervalSinceNow];
        if (frame == nil) break;
        if ([frame[@"subscription"] isEqual:conversationSubscription]) items = frame[@"data"][@"items"];
    }
    CHECK([[items valueForKey:@"item_id"] containsObject:transferID], "the offer is in the conversation: %@", items);
    for (NSDictionary *item in items) {
        CHECK(![item[@"kind"] isEqual:@"message"] || [item[@"text"] length] > 0, "an empty message: %@", item);
    }
    reply = [c intent:@"send_message" fields:@{@"conversation_id" : @"c_kenji", @"text" : @"",
                                               @"client_token" : @"token-nothing-0123456789"}];
    CHECK([reply[@"error"][@"code"] isEqual:@"invalid_field"], "nothing typed or attached: %@", reply);
    reply = [c intent:@"search_messages" fields:@{@"query" : @"合同"}];
    CHECK([reply[@"ok"] boolValue] && [reply[@"result"][@"results"] isKindOfClass:[NSArray class]], "%@", reply);

    reply = [c intent:@"start_visibility" fields:nil];
    NSString *deadline = reply[@"result"][@"deadline"];
    CHECK([deadline hasSuffix:@"Z"], "%@", reply);
    usleep(1100000);
    reply = [c intent:@"start_visibility" fields:nil];
    CHECK([reply[@"result"][@"deadline"] isEqual:deadline], "repeating never extends: %@", reply);
    CHECK([[c intent:@"stop_visibility" fields:nil][@"ok"] boolValue]);

    reply = [c intent:@"retry_item" fields:@{@"item_id" : @"nothing-like-this"}];
    CHECK([reply[@"error"][@"code"] isEqual:@"not_found"], "%@", reply);
    CHECK([[c intent:@"block" fields:@{@"conversation_id" : @"c_kenji"}][@"ok"] boolValue]);
    reply = [c intent:@"send_message" fields:@{@"conversation_id" : @"c_kenji", @"text" : @"hello?",
                                               @"client_token" : @"token-fedcba9876543210"}];
    CHECK([reply[@"error"][@"code"] isEqual:@"blocked"], "%@", reply);
    reply = [c intent:@"reset_friends" fields:@{@"confirm" : @"nope"}];
    CHECK([reply[@"error"][@"code"] isEqual:@"invalid_field"], "reset needs its confirmation: %@", reply);
    kill(pid, SIGTERM);
    CHECK([harness waitForExit:pid timeout:3 status:NULL]);
    return YES;
}
