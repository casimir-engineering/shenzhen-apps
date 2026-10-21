// Process test of remove_friend for everyone in the list: a friend, an incoming and an outgoing request, a former
// friend, a link contact and a blocked person all leave the list, each the way the intent says, with or without their
// history; You and unknown conversations are refused; someone already off the list is a quiet success.

#import <Foundation/Foundation.h>

#import <signal.h>
#import <sodium.h>

#import "SZFriendsHelperProcessHarness.h"
#import "service/store/SZFriendsOutbox.h"
#import "service/store/SZFriendsStore.h"
#import "service/store/SZFriendsStoreLinks.h"
#import "service/store/SZFriendsStoreSync.h"

static NSData *SZFHRemoveRandom(NSUInteger count) {
    NSMutableData *data = [NSMutableData dataWithLength:count];
    randombytes_buf(data.mutableBytes, count);
    return data;
}

static BOOL SZFHRemoveSeed(SZFriendsStore *store, NSString *conversationID, SZFriendsRelation relation) {
    SZFriendsPersonRecord *person = [[SZFriendsPersonRecord alloc] init];
    person.conversationID = conversationID;
    person.identityKey = SZFHRemoveRandom(32);
    person.staticKey = SZFHRemoveRandom(32);
    person.name = [conversationID substringFromIndex:2].capitalizedString;
    person.picture = [SZFriendsPicture placeholder];
    person.relation = relation;
    person.autoAccept = relation == SZFriendsRelationFriend;
    person.requestAt = [NSDate date];
    person.requestFoundNearby = YES; // a request by ID with no id_requests row would lapse at start
    person.lastInteractionAt = [NSDate dateWithTimeIntervalSinceNow:-60];
    NSError *error = nil;
    if (![store savePerson:person error:&error]) {
        fprintf(stderr, "seed %s: %s\n", conversationID.UTF8String, error.localizedDescription.UTF8String);
        return NO;
    }
    SZFriendsItemRecord *item = [[SZFriendsItemRecord alloc] init];
    item.itemID = [@"m_" stringByAppendingString:conversationID];
    item.conversationID = conversationID;
    item.kind = SZFriendsItemKindMessage;
    item.direction = SZFriendsDirectionIncoming;
    item.sentAt = item.receivedAt = [NSDate dateWithTimeIntervalSinceNow:-120];
    item.text = @"hello";
    return [store insertItem:item error:NULL];
}

static NSArray<NSString *> *SZFHRemoveRows(SZFHClient *client) {
    NSDictionary *reply = [client intent:@"subscribe" fields:@{@"view" : @"list"}];
    NSString *subscription = reply[@"result"][@"subscription"];
    NSDictionary *snapshot = nil;
    for (NSDictionary *frame in client.snapshots)
        if ([frame[@"subscription"] isEqual:subscription]) snapshot = frame;
    [client intent:@"unsubscribe" fields:@{@"subscription" : subscription ?: @""}];
    NSMutableArray *ids = [NSMutableArray array];
    for (NSDictionary *row in snapshot[@"data"][@"rows"]) [ids addObject:row[@"conversation_id"]];
    return snapshot ? ids : nil;
}

static NSString *SZFHRemoveAnswerFrame(SZFriendsOutbox *outbox, NSString *conversationID) {
    for (SZFriendsOutboxEntry *entry in [outbox pendingEntriesForConversation:conversationID]) {
        if (entry.kind != SZFriendsOutboxKindAnswer || entry.payload == nil) continue;
        NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:entry.payload options:0 error:NULL];
        return payload[@"frame"];
    }
    return nil;
}

BOOL SZFHTestRemoveFromList(SZFHHarness *harness) {
    if (sodium_init() < 0) return NO;
    NSString *state = [harness makeDirectory];
    SZFriendsStore *store = [SZFriendsStore storeInDirectory:state error:NULL];
    CHECK(store != nil, "a store to seed");
    NSDictionary<NSString *, NSNumber *> *people = @{
        @"c_mei" : @(SZFriendsRelationFriend), @"c_lena" : @(SZFriendsRelationIncomingRequest),
        @"c_priya" : @(SZFriendsRelationOutgoingRequest), @"c_tulip" : @(SZFriendsRelationRemoved),
        @"c_sam" : @(SZFriendsRelationRemoved), @"c_jonas" : @(SZFriendsRelationBlocked),
        @"c_kept" : @(SZFriendsRelationFriend)
    };
    for (NSString *conversationID in people) {
        CHECK(SZFHRemoveSeed(store, conversationID, (SZFriendsRelation)people[conversationID].integerValue),
              "seeded %@", conversationID);
    }
    CHECK([store markLinkContact:@"c_sam" error:NULL], "Sam is a link contact");
    CHECK([store ensureYouConversation:NULL], "the You conversation");
    // Priya's request still waits in the outbox; cancelling must keep it from going out.
    SZFriendsOutbox *outbox = [[SZFriendsOutbox alloc] initWithStore:store];
    SZFriendsOutboxEntry *request = [[SZFriendsOutboxEntry alloc] init];
    request.entryID = @"0123456789abcdef0123456789abcdef";
    request.conversationID = @"c_priya";
    request.state = SZFriendsOutboxStateQueued;
    request.createdAt = [NSDate date];
    request.kind = SZFriendsOutboxKindRequest;
    CHECK([outbox enqueue:request error:NULL], "Priya's queued request");
    [store close];

    pid_t pid = [harness spawnHelperWithStateDirectory:state timeScale:1];
    SZFHClient *c = [SZFHClient connectToSocket:[harness socketPathForStateDirectory:state] timeout:5];
    CHECK([[c helloWithEmbeddedBuild:0][@"type"] isEqual:@"welcome"]);
    NSArray *before = SZFHRemoveRows(c);
    CHECK(before.count == 7, "everyone is listed: %@", before);

    NSDictionary *reply = [c intent:@"remove_friend" fields:@{@"conversation_id" : @"c_mei", @"delete_history" : @"yes"}];
    CHECK([reply[@"error"][@"code"] isEqual:@"invalid_field"] &&
              [reply[@"error"][@"details"][@"field"] isEqual:@"delete_history"],
          "delete_history is a bool: %@", reply);
    reply = [c intent:@"remove_friend" fields:@{@"conversation_id" : @"c_nobody"}];
    CHECK([reply[@"error"][@"code"] isEqual:@"not_found"], "%@", reply);
    reply = [c intent:@"remove_friend" fields:@{@"conversation_id" : @"you"}];
    CHECK([reply[@"error"][@"code"] isEqual:@"not_allowed"], "You cannot be removed: %@", reply);

    for (NSString *conversationID in @[ @"c_mei", @"c_lena", @"c_priya", @"c_tulip", @"c_jonas" ]) {
        reply = [c intent:@"remove_friend" fields:@{@"conversation_id" : conversationID}];
        CHECK([reply[@"ok"] boolValue], "remove %@: %@", conversationID, reply);
    }
    reply = [c intent:@"remove_friend" fields:@{@"conversation_id" : @"c_sam", @"delete_history" : @YES}];
    CHECK([reply[@"ok"] boolValue], "remove Sam and his history: %@", reply);
    reply = [c intent:@"remove_friend" fields:@{@"conversation_id" : @"c_mei", @"delete_history" : [NSNull null]}];
    CHECK([reply[@"ok"] boolValue], "already off the list: %@", reply);
    NSArray *after = SZFHRemoveRows(c);
    CHECK([after isEqual:@[ @"c_kept" ]], "only the friend kept is listed: %@", after);
    reply = [c intent:@"open_conversation" fields:@{@"conversation_id" : @"c_mei"}];
    CHECK([reply[@"ok"] boolValue], "Mei's conversation still opens: %@", reply);
    [c close];
    kill(pid, SIGTERM);
    CHECK([harness waitForExit:pid timeout:3 status:NULL]);

    store = [SZFriendsStore storeInDirectory:state error:NULL];
    CHECK(store != nil);
    outbox = [[SZFriendsOutbox alloc] initWithStore:store];
    NSMutableDictionary<NSString *, SZFriendsPersonRecord *> *records = [NSMutableDictionary dictionary];
    for (NSString *conversationID in people) records[conversationID] = [store personWithConversationID:conversationID];
    NSString *lenaAnswer = SZFHRemoveAnswerFrame(outbox, @"c_lena");
    NSString *priyaAnswer = SZFHRemoveAnswerFrame(outbox, @"c_priya");
    BOOL priyaRequestQueued = NO;
    for (SZFriendsOutboxEntry *entry in [outbox pendingEntriesForConversation:@"c_priya"])
        if (entry.kind == SZFriendsOutboxKindRequest) priyaRequestQueued = YES;
    BOOL meiRemovedEvent = NO;
    for (SZFriendsItemRecord *item in [store itemsInConversation:@"c_mei" beforeItemID:nil limit:10 hasEarlier:NULL])
        if ([item.eventKind isEqual:@"removed"]) meiRemovedEvent = YES;
    BOOL meiHistory = [store itemWithID:@"m_c_mei" inConversation:@"c_mei"] != nil;
    BOOL samHistory = [store itemWithID:@"m_c_sam" inConversation:@"c_sam"] != nil;
    BOOL keptListed = records[@"c_kept"].leftListAt == nil && records[@"c_kept"].relation == SZFriendsRelationFriend;
    [store close];

    for (NSString *conversationID in @[ @"c_mei", @"c_lena", @"c_priya", @"c_tulip", @"c_sam", @"c_jonas" ]) {
        CHECK(records[conversationID].leftListAt != nil, "%@ is off the list", conversationID);
    }
    CHECK(keptListed, "the other friend stays");
    CHECK(records[@"c_mei"].relation == SZFriendsRelationRemoved && !records[@"c_mei"].autoAccept && meiRemovedEvent,
          "Mei is removed as a friend is, with the event in her history");
    CHECK(meiHistory, "and her history stays without delete_history");
    CHECK(!samHistory && records[@"c_sam"] != nil, "Sam's history went with delete_history; his row stays");
    CHECK(records[@"c_lena"].relation == SZFriendsRelationRemoved && [lenaAnswer isEqual:@"decline"],
          "Lena's request is declined (answer %@)", lenaAnswer);
    CHECK(records[@"c_priya"].relation == SZFriendsRelationRemoved && [priyaAnswer isEqual:@"cancel"] &&
              !priyaRequestQueued,
          "Priya's request is withdrawn (answer %@, request still queued %d)", priyaAnswer, priyaRequestQueued);
    CHECK(records[@"c_tulip"].relation == SZFriendsRelationRemoved, "a former friend stays one");
    CHECK(records[@"c_jonas"].relation == SZFriendsRelationBlocked, "removing never unblocks");
    return YES;
}

// A client that declared list.menu gets each row's menu; the helper's welcome is unchanged.
BOOL SZFHTestRemoveMenu(SZFHHarness *harness) {
    if (sodium_init() < 0) return NO;
    NSString *state = [harness makeDirectory];
    SZFriendsStore *store = [SZFriendsStore storeInDirectory:state error:NULL];
    CHECK(store != nil && SZFHRemoveSeed(store, @"c_mei", SZFriendsRelationFriend), "Mei");
    [store close];
    pid_t pid = [harness spawnHelperWithStateDirectory:state timeScale:1];
    SZFHClient *c = [SZFHClient connectToSocket:[harness socketPathForStateDirectory:state] timeout:5];
    NSDictionary *hello = @{
        @"type" : @"hello", @"id" : @"1", @"protocol" : @{@"major" : @1, @"minor" : @0, @"min_major" : @1},
        @"client" : @{@"app_id" : @"com.example.friends-test", @"app_name" : @"Friends Test", @"app_version" : @"1",
                      @"toolkit" : @"appkit", @"reveal_in" : @"Finder", @"pid" : @(getpid())},
        @"embedded_helper" : [NSNull null], @"capabilities" : @[ @"list.menu" ], @"open_formats" : @[ @"pdf" ],
        @"locale" : @"en-GB",
    };
    CHECK([c sendFrame:hello] && [[c nextFrameWithTimeout:5][@"type"] isEqual:@"welcome"]);
    NSDictionary *reply = [c intent:@"subscribe" fields:@{@"view" : @"list"}];
    NSDictionary *row = nil;
    for (NSDictionary *frame in c.snapshots)
        if ([frame[@"subscription"] isEqual:reply[@"result"][@"subscription"]]) row = [frame[@"data"][@"rows"] firstObject];
    NSDictionary *remove = [row[@"menu"] firstObject];
    CHECK([remove[@"action"] isEqual:@"remove_friend"] && [remove[@"label"] isEqual:@"Remove"] &&
              [remove[@"confirm"][@"option"][@"field"] isEqual:@"delete_history"],
          "Mei's row offers Remove, with her history as an option: %@", row);
    [c close];
    kill(pid, SIGTERM);
    CHECK([harness waitForExit:pid timeout:3 status:NULL]);
    return YES;
}

// A You conversation left on a computer with no other computers and nothing in it is nobody's row: not in the list
// (never as a person, never "Someone"), not on the badge, not mentionable. With a message to yourself in it, the You
// row shows it (SZFHTestYouIntents); with another computer, the You row is there as always (devices facts).
BOOL SZFHTestLeftoverYouIsNoRow(SZFHHarness *harness) {
    if (sodium_init() < 0) return NO;
    NSString *state = [harness makeDirectory];
    SZFriendsStore *store = [SZFriendsStore storeInDirectory:state error:NULL];
    CHECK(store != nil && [store ensureYouConversation:NULL] && SZFHRemoveSeed(store, @"c_mei", SZFriendsRelationFriend),
          "a leftover You conversation and a friend");
    store.profileName = @"Raph";
    [store close];
    pid_t pid = [harness spawnHelperWithStateDirectory:state timeScale:1];
    SZFHClient *c = [SZFHClient connectToSocket:[harness socketPathForStateDirectory:state] timeout:5];
    NSDictionary *hello = @{
        @"type" : @"hello", @"id" : @"1", @"protocol" : @{@"major" : @1, @"minor" : @0, @"min_major" : @1},
        @"client" : @{@"app_id" : @"com.example.friends-test", @"app_name" : @"Friends Test", @"app_version" : @"1",
                      @"toolkit" : @"appkit", @"reveal_in" : @"Finder", @"pid" : @(getpid())},
        @"embedded_helper" : [NSNull null], @"capabilities" : @[ @"mentions" ], @"open_formats" : @[ @"pdf" ],
        @"locale" : @"en-GB",
    };
    CHECK([c sendFrame:hello] && [[c nextFrameWithTimeout:5][@"type"] isEqual:@"welcome"]);
    NSDictionary *reply = [c intent:@"subscribe" fields:@{@"view" : @"list"}];
    NSDictionary *list = nil;
    for (NSDictionary *frame in c.snapshots)
        if ([frame[@"subscription"] isEqual:reply[@"result"][@"subscription"]]) list = frame[@"data"];
    NSArray *rows = list[@"rows"];
    CHECK(rows.count == 1 && [rows[0][@"conversation_id"] isEqual:@"c_mei"], "only Mei is listed: %@", rows);
    for (NSDictionary *row in rows) CHECK(![row[@"title"] isEqual:@"Someone"], "nobody unnamed: %@", row);
    reply = [c intent:@"subscribe" fields:@{@"view" : @"badge"}];
    NSDictionary *badge = nil;
    for (NSDictionary *frame in c.snapshots)
        if ([frame[@"subscription"] isEqual:reply[@"result"][@"subscription"]]) badge = frame[@"data"];
    CHECK([badge[@"count"] integerValue] == 0, "nothing waits: %@", badge);
    [c close];
    kill(pid, SIGTERM);
    CHECK([harness waitForExit:pid timeout:3 status:NULL]);
    return YES;
}
