// Process tests of intents about people, against a store seeded the way an earlier helper run would have left it.

#import <Foundation/Foundation.h>

#import <signal.h>
#import <sodium.h>

#import "SZFriendsHelperProcessHarness.h"
#import "service/store/SZFriendsOutbox.h"
#import "service/store/SZFriendsStore.h"
#import "service/store/SZFriendsTransfers.h"

static NSData *SZFHRandom(NSUInteger count) {
    NSMutableData *data = [NSMutableData dataWithLength:count];
    randombytes_buf(data.mutableBytes, count);
    return data;
}

// Review (key change handling): add_by_id used to turn an existing row that named the Friends ID into the new
// request, keeping that row's identity key. Someone we removed whose ID later went to someone else then had their
// IK accepted again, and our request went to their public entry. A row holding a key is never reused now: the
// request gets a fresh row without one, and the removed person's row stays as it was.
BOOL SZFHTestAddByIDKeepsKeyedRows(SZFHHarness *harness) {
    if (sodium_init() < 0) return NO;
    NSString *state = [harness makeDirectory];
    SZFriendsStore *store = [SZFriendsStore storeInDirectory:state error:NULL];
    CHECK(store != nil, "a store to seed");
    SZFriendsPersonRecord *removed = [[SZFriendsPersonRecord alloc] init];
    removed.conversationID = @"c_old";
    removed.identityKey = SZFHRandom(32);
    removed.staticKey = SZFHRandom(32);
    removed.friendsID = @"tulip-canyon";
    removed.name = @"Bob";
    removed.picture = [SZFriendsPicture placeholder];
    removed.relation = SZFriendsRelationRemoved;
    removed.lastInteractionAt = [NSDate dateWithTimeIntervalSinceNow:-86400];
    CHECK([store savePerson:removed error:NULL]);
    [store close];

    pid_t pid = [harness spawnHelperWithStateDirectory:state timeScale:1];
    SZFHClient *client = [SZFHClient connectToSocket:[harness socketPathForStateDirectory:state] timeout:5];
    CHECK([[client helloWithEmbeddedBuild:0][@"type"] isEqual:@"welcome"]);
    NSDictionary *reply = [client intent:@"add_by_id" fields:@{@"friends_id" : @"tulip-canyon"}];
    NSString *conversation = reply[@"result"][@"conversation_id"];
    CHECK([reply[@"ok"] boolValue] && conversation.length > 0 && ![conversation isEqual:@"c_old"],
          "a new row for the request: %@", reply);
    reply = [client intent:@"add_by_id" fields:@{@"friends_id" : @"tulip-canyon"}];
    CHECK([reply[@"result"][@"conversation_id"] isEqual:conversation], "asking again finds that row: %@", reply);
    kill(pid, SIGTERM);
    CHECK([harness waitForExit:pid timeout:3 status:NULL]);

    store = [SZFriendsStore storeInDirectory:state error:NULL];
    CHECK(store != nil);
    SZFriendsPersonRecord *old = [store personWithConversationID:@"c_old"];
    SZFriendsPersonRecord *request = [store personWithConversationID:conversation];
    [store close];
    CHECK(old.relation == SZFriendsRelationRemoved && [old.identityKey isEqualToData:removed.identityKey],
          "the removed person's row is untouched (relation %ld)", (long)old.relation);
    CHECK(request.relation == SZFriendsRelationOutgoingRequest && request.identityKey == nil &&
              [request.friendsID isEqual:@"tulip-canyon"],
          "the request's row holds no key until someone answers");
    return YES;
}

static SZFriendsPersonRecord *SZFHSeed(SZFriendsStore *store, NSString *conversationID, NSString *friendsID,
                                       SZFriendsRelation relation, BOOL keyed) {
    SZFriendsPersonRecord *person = [[SZFriendsPersonRecord alloc] init];
    person.conversationID = conversationID;
    if (keyed) {
        person.identityKey = SZFHRandom(32);
        person.staticKey = SZFHRandom(32);
    }
    person.friendsID = friendsID;
    person.picture = [SZFriendsPicture placeholder];
    person.relation = relation;
    person.lastInteractionAt = [NSDate dateWithTimeIntervalSinceNow:-86400];
    [store savePerson:person error:NULL];
    return person;
}

// Wave-4 re-check: add_by_id stopped at any row whose PROFILE claimed the ID, so a stranger who once sent a nearby
// request saying "tulip-canyon" got Bob's Add by ID instead of the holder, "Request sent" was shown with nothing
// sent, and a "Request sent" row whose request had expired stayed waiting for ever. Now only a host-confirmed friend
// or block, or our own request still out, stops a new request; everything else is broadcast.
BOOL SZFHTestAddByIDBroadcastsPastClaims(SZFHHarness *harness) {
    if (sodium_init() < 0) return NO;
    NSString *state = [harness makeDirectory];
    SZFriendsStore *store = [SZFriendsStore storeInDirectory:state error:NULL];
    CHECK(store != nil, "a store to seed");
    SZFHSeed(store, @"c_claim", @"tulip-canyon", SZFriendsRelationIncomingRequest, YES);
    SZFHSeed(store, @"c_stale", @"willow-breeze", SZFriendsRelationOutgoingRequest, NO); // its request expired
    SZFHSeed(store, @"c_friend", @"amber-falcon", SZFriendsRelationFriend, YES);         // a friend who said so
    SZFHSeed(store, @"c_held", @"cedar-lantern", SZFriendsRelationFriend, YES);
    CHECK([store confirmFriendsID:@"cedar-lantern" attestation:SZFHRandom(100) day:@"2026-10-12"
                  forConversation:@"c_held" error:NULL], "a friend the host confirmed");
    [store close];

    pid_t pid = [harness spawnHelperWithStateDirectory:state timeScale:1];
    SZFHClient *client = [SZFHClient connectToSocket:[harness socketPathForStateDirectory:state] timeout:5];
    CHECK([[client helloWithEmbeddedBuild:0][@"type"] isEqual:@"welcome"]);
    NSMutableDictionary<NSString *, NSString *> *rows = [NSMutableDictionary dictionary];
    for (NSString *friendsID in @[ @"tulip-canyon", @"willow-breeze", @"amber-falcon" ]) {
        NSDictionary *reply = [client intent:@"add_by_id" fields:@{@"friends_id" : friendsID}];
        CHECK([reply[@"ok"] boolValue], "%@ is asked for: %@", friendsID, reply);
        rows[friendsID] = reply[@"result"][@"conversation_id"];
    }
    CHECK(![rows[@"tulip-canyon"] isEqual:@"c_claim"], "never the stranger who claimed it: %@", rows);
    CHECK(rows[@"willow-breeze"] != nil && ![rows[@"willow-breeze"] isEqual:@"c_stale"],
          "the expired request's row lapsed when the helper started; a new request goes out: %@", rows);
    NSDictionary *again = [client intent:@"add_by_id" fields:@{@"friends_id" : @"tulip-canyon"}];
    CHECK([again[@"result"][@"conversation_id"] isEqual:rows[@"tulip-canyon"]], "our request still out: %@", again);
    NSDictionary *held = [client intent:@"add_by_id" fields:@{@"friends_id" : @"cedar-lantern"}];
    CHECK([held[@"error"][@"code"] isEqual:@"already_friends"], "the confirmed friend: %@", held);
    kill(pid, SIGTERM);
    CHECK([harness waitForExit:pid timeout:3 status:NULL]);

    store = [SZFriendsStore storeInDirectory:state error:NULL];
    CHECK(store != nil);
    NSMutableArray<NSString *> *asked = [NSMutableArray array];
    for (SZFriendsIDRequestRecord *request in [store pendingIDRequestsAtDate:[NSDate date]])
        [asked addObject:request.targetFriendsID];
    SZFriendsPersonRecord *claim = [store personWithConversationID:@"c_claim"];
    BOOL staleGone = [store personWithConversationID:@"c_stale"] == nil;
    [store close];
    CHECK(staleGone, "a Request sent row nobody can answer any more does not wait for ever");
    [asked sortUsingSelector:@selector(compare:)];
    CHECK([asked isEqual:(@[ @"amber-falcon", @"tulip-canyon", @"willow-breeze" ])],
          "one request each goes out to everyone nearby: %@", asked);
    CHECK(claim.relation == SZFriendsRelationIncomingRequest, "the claimant's own request is left as it was");
    return YES;
}

static SZFriendsItemRecord *SZFHMessage(NSString *conversationID, NSString *itemID, SZFriendsDirection direction) {
    SZFriendsItemRecord *item = [[SZFriendsItemRecord alloc] init];
    item.itemID = itemID;
    item.conversationID = conversationID;
    item.kind = SZFriendsItemKindMessage;
    item.direction = direction;
    item.sentAt = [NSDate date];
    item.receivedAt = item.sentAt;
    item.text = @"Pages 3–5?";
    return item;
}

// The row of the latest list snapshot `client` received.
static NSDictionary *SZFHRowFor(SZFHClient *client, NSString *conversationID) {
    for (NSDictionary *snapshot in client.snapshots.reverseObjectEnumerator) {
        if (![snapshot[@"view"] isEqual:@"list"]) continue;
        for (NSDictionary *row in snapshot[@"data"][@"rows"])
            if ([row[@"conversation_id"] isEqual:conversationID]) return row;
        return nil;
    }
    return nil;
}

// message_status (PROTOCOL.md § Views): AI chat follows a message the person sent from it without opening the
// conversation, so nothing is read: Mei's unread question stays unread, and only this person's outgoing messages get
// a row, even when a friend's message carries the same id.
BOOL SZFHTestMessageStatus(SZFHHarness *harness) {
    if (sodium_init() < 0) return NO;
    NSString *state = [harness makeDirectory];
    SZFriendsStore *store = [SZFriendsStore storeInDirectory:state error:NULL];
    CHECK(store != nil, "a store to seed");
    SZFriendsPersonRecord *mei = SZFHSeed(store, @"c_mei", @"jasmine-street", SZFriendsRelationFriend, YES);
    mei.name = @"Mei Lin";
    CHECK([store savePerson:mei error:NULL]);
    SZFHSeed(store, @"c_kenji", @"amber-falcon", SZFriendsRelationFriend, YES);
    CHECK([store insertItem:SZFHMessage(@"c_mei", @"m_question", SZFriendsDirectionIncoming) error:NULL]);
    CHECK([store insertItem:SZFHMessage(@"c_kenji", @"m_reply", SZFriendsDirectionIncoming) error:NULL],
          "Kenji's message reuses the id of ours");
    SZFriendsOutboxEntry *entry = [[SZFriendsOutboxEntry alloc] init];
    entry.entryID = @"0123456789abcdef0123456789abcdef";
    entry.conversationID = @"c_mei";
    entry.kind = SZFriendsOutboxKindMessage;
    entry.createdAt = [NSDate date];
    entry.itemID = @"m_reply";
    CHECK([[[SZFriendsOutbox alloc] initWithStore:store] enqueue:entry
                                                            item:SZFHMessage(@"c_mei", @"m_reply",
                                                                             SZFriendsDirectionOutgoing)
                                                           error:NULL],
          "our reply waits for Mei");
    [store close];

    pid_t pid = [harness spawnHelperWithStateDirectory:state timeScale:1];
    SZFHClient *client = [SZFHClient connectToSocket:[harness socketPathForStateDirectory:state] timeout:5];
    NSDictionary *welcome = [client helloWithEmbeddedBuild:0];
    CHECK([welcome[@"capabilities"] containsObject:@"messages.status"], "announced: %@", welcome[@"capabilities"]);
    NSDictionary *params = @{@"message_ids" : @[ @"m_nothing", @"m_question", @"m_reply" ]};
    NSDictionary *reply = [client intent:@"subscribe" fields:@{@"view" : @"message_status", @"params" : params}];
    NSDictionary *snapshot = client.snapshots.lastObject;
    CHECK([reply[@"ok"] boolValue] && [snapshot[@"view"] isEqual:@"message_status"], "%@ / %@", reply, snapshot);
    NSArray *expected = @[ @{@"message_id" : @"m_reply",
                             @"status" : @{@"state" : @"queued", @"label" : @"Sends when Mei is nearby"}} ];
    CHECK([snapshot[@"data"][@"messages"] isEqual:expected], "only our message, with its status: %@", snapshot);
    NSMutableArray *seventeen = [NSMutableArray array];
    for (int i = 0; i < 17; i++) [seventeen addObject:[NSString stringWithFormat:@"m_%d", i]];
    for (id ids in @[ @[], seventeen, @[ @42 ], @[ @"" ], @"m_reply" ]) {
        reply = [client intent:@"subscribe" fields:@{@"view" : @"message_status", @"params" : @{@"message_ids" : ids}}];
        CHECK([reply[@"error"][@"code"] isEqual:@"invalid_field"] &&
                  [reply[@"error"][@"details"][@"field"] isEqual:@"params.message_ids"],
              "%@ refused: %@", ids, reply);
    }
    [client intent:@"subscribe" fields:@{@"view" : @"list"}];
    CHECK([SZFHRowFor(client, @"c_mei")[@"unread"] isEqual:@YES], "Mei's question is still unread: %@",
          SZFHRowFor(client, @"c_mei"));
    kill(pid, SIGTERM);
    CHECK([harness waitForExit:pid timeout:3 status:NULL]);
    store = [SZFriendsStore storeInDirectory:state error:NULL];
    NSInteger unread = [store personWithConversationID:@"c_mei"].unreadCount;
    [store close];
    CHECK(unread == 1, "and stays unread in the store: %ld", (long)unread);
    return YES;
}

static BOOL SZFHIncoming(SZFriendsStore *store, NSString *conversationID, NSString *text, NSTimeInterval ago) {
    SZFriendsItemRecord *item = [[SZFriendsItemRecord alloc] init];
    item.itemID = SZFriendsNewIdentifier();
    item.conversationID = conversationID;
    item.kind = SZFriendsItemKindMessage;
    item.direction = SZFriendsDirectionIncoming;
    item.sentAt = [NSDate dateWithTimeIntervalSinceNow:-ago];
    item.receivedAt = item.sentAt;
    item.text = text;
    return [store insertItem:item error:NULL];
}

// Integration review, wave 6b: the helper keyed each row's newest item by conversation id while the builder looks it
// up by item id, so in a real helper every row's subtitle was "" in both apps. The presentation tests key their world
// by item id and missed it. Rows built from a real store describe each conversation's newest item: a message's text,
// and a waiting offer's file.
BOOL SZFHTestListRowsDescribeNewestItem(SZFHHarness *harness) {
    if (sodium_init() < 0) return NO;
    NSString *state = [harness makeDirectory];
    SZFriendsStore *store = [SZFriendsStore storeInDirectory:state error:NULL];
    CHECK(store != nil, "a store to seed");
    SZFHSeed(store, @"c_mei", @"jasmine-street", SZFriendsRelationFriend, YES);
    SZFHSeed(store, @"c_kenji", @"amber-falcon", SZFriendsRelationFriend, YES);
    CHECK(SZFHIncoming(store, @"c_mei", @"Did the scan arrive?", 600) &&
              SZFHIncoming(store, @"c_mei", @"Can you check pages 3–5 before Friday?", 60),
          "two messages from Mei");
    SZFriendsTransfers *transfers = [[SZFriendsTransfers alloc] initWithStore:store stateDirectory:state];
    CHECK([transfers recordIncomingOfferWithID:SZFriendsNewIdentifier() conversationID:@"c_kenji"
                                      fileName:@"Site photos.pdf" uniformType:@"com.adobe.pdf" size:1000
                                 contentDigest:SZFHRandom(32) sentAt:[NSDate date] error:NULL],
          "an offer from Kenji");
    [store close];

    pid_t pid = [harness spawnHelperWithStateDirectory:state timeScale:1];
    SZFHClient *client = [SZFHClient connectToSocket:[harness socketPathForStateDirectory:state] timeout:5];
    CHECK([[client helloWithEmbeddedBuild:0][@"type"] isEqual:@"welcome"]);
    CHECK([[client intent:@"subscribe" fields:@{@"view" : @"list"}][@"ok"] boolValue]);
    NSDictionary *mei = SZFHRowFor(client, @"c_mei"), *kenji = SZFHRowFor(client, @"c_kenji");
    kill(pid, SIGTERM);
    CHECK([harness waitForExit:pid timeout:3 status:NULL]);
    CHECK([mei[@"subtitle"] isEqual:@"Can you check pages 3–5 before Friday?"], "Mei's newest message: %@", mei);
    CHECK([kenji[@"subtitle"] isEqual:@"Sent you Site photos.pdf"], "Kenji's offer: %@", kenji);
    return YES;
}
