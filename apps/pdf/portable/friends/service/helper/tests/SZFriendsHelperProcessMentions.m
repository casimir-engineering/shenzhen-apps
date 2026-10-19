// Process tests of mentions (PROTOCOL.md § Mentions, ADR 0007): the helper writes the mentions send_message names, and
// add_from_mention refuses or starts a request bound to the mentioned key, against a store seeded as a run would leave.

#import <Foundation/Foundation.h>

#import <signal.h>
#import <sodium.h>

#import "SZFriendsHelperProcessHarness.h"
#import "service/presentation/SZFriendsMentions.h"
#import "service/store/SZFriendsStore.h"

static NSData *SZFHMentionRandom(NSUInteger count) {
    NSMutableData *data = [NSMutableData dataWithLength:count];
    randombytes_buf(data.mutableBytes, count);
    return data;
}

static SZFriendsPersonRecord *SZFHMentionSeed(SZFriendsStore *store, NSString *conversationID, NSString *name,
                                              NSString *friendsID, SZFriendsRelation relation, BOOL confirmed) {
    SZFriendsPersonRecord *person = [[SZFriendsPersonRecord alloc] init];
    person.conversationID = conversationID;
    person.identityKey = SZFHMentionRandom(32);
    person.staticKey = SZFHMentionRandom(32);
    person.name = name;
    person.friendsID = friendsID;
    person.picture = [SZFriendsPicture placeholder];
    person.relation = relation;
    person.lastInteractionAt = [NSDate dateWithTimeIntervalSinceNow:-86400];
    [store savePerson:person error:NULL];
    if (confirmed) {
        [store confirmFriendsID:friendsID attestation:SZFHMentionRandom(64) day:@"2026-10-12"
                forConversation:conversationID
                          error:NULL];
    }
    return person;
}

// ADR 0007's binding: the token is BLAKE2b-128 of the domain and the key, keyed by the request's callback secret.
static NSData *SZFHMentionToken(NSData *secret, NSData *key) {
    NSMutableData *message = [[@"SZFriends mention request v1" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [message appendData:key];
    uint8_t token[16];
    crypto_generichash(token, sizeof token, message.bytes, message.length, secret.bytes, secret.length);
    return [NSData dataWithBytes:token length:sizeof token];
}

// send_message: the helper writes each friend's mention where its U+FFFC was, from its own store, and turns what the
// person typed into plain text however much it looks like a mention.
BOOL SZFHTestMentionsWritten(SZFHHarness *harness) {
    if (sodium_init() < 0) return NO;
    NSString *state = [harness makeDirectory];
    SZFriendsStore *store = [SZFriendsStore storeInDirectory:state error:NULL];
    CHECK(store != nil, "a store to seed");
    SZFriendsPersonRecord *mei = SZFHMentionSeed(store, @"c_mei", @"Mei Lin", @"jasmine-street",
                                                 SZFriendsRelationFriend, NO);
    SZFHMentionSeed(store, @"c_bob", @"Bob", @"cedar-lantern", SZFriendsRelationFriend, NO);
    SZFHMentionSeed(store, @"c_gone", @"Gone", @"amber-falcon", SZFriendsRelationRemoved, NO);
    [store close];
    pid_t pid = [harness spawnHelperWithStateDirectory:state timeScale:1];
    SZFHClient *client = [SZFHClient connectToSocket:[harness socketPathForStateDirectory:state] timeout:5];
    CHECK([[client helloWithEmbeddedBuild:0][@"capabilities"] containsObject:@"mentions"], "the helper says so");
    NSDictionary *(^send)(NSString *, id) = ^NSDictionary *(NSString *text, id mentions) {
      NSMutableDictionary *fields = [@{@"conversation_id" : @"c_bob", @"text" : text,
                                       @"client_token" : [NSUUID UUID].UUIDString} mutableCopy];
      if (mentions) fields[@"mentions"] = mentions;
      return [client intent:@"send_message" fields:fields];
    };
    NSDictionary *reply = send(@"Ask ￼", @[]);
    CHECK([reply[@"error"][@"code"] isEqual:@"invalid_field"] && [reply[@"error"][@"details"][@"field"]
                                                                     isEqual:@"mentions"],
          "one U+FFFC, no mention: %@", reply);
    reply = send(@"Ask ￼", @[ @{@"conversation_id" : @"c_gone"} ]);
    CHECK([reply[@"error"][@"code"] isEqual:@"not_allowed"] &&
              [reply[@"error"][@"details"][@"field"] isEqual:@"mentions[0]"],
          "only friends can be named: %@", reply);
    reply = send(@"Ask ￼", @[ @{@"conversation_id" : @"c_nobody"} ]);
    CHECK([reply[@"error"][@"code"] isEqual:@"not_found"], "%@", reply);
    NSString *typed = SZFriendsMentionLink(@"Kenji", @"cedar-lantern", SZFHMentionRandom(32));
    reply = send([NSString stringWithFormat:@"Ask ￼, not %@", typed], @[ @{@"conversation_id" : @"c_mei"} ]);
    CHECK([reply[@"ok"] boolValue], "sent: %@", reply);
    NSString *messageID = reply[@"result"][@"message_id"];
    kill(pid, SIGTERM);
    CHECK([harness waitForExit:pid timeout:3 status:NULL]);
    store = [SZFriendsStore storeInDirectory:state error:NULL];
    SZFriendsItemRecord *stored = [store itemWithID:messageID inConversation:@"c_bob"];
    [store close];
    NSString *link = SZFriendsMentionLink(@"Mei Lin", @"jasmine-street", mei.identityKey);
    NSString *expected = [NSString stringWithFormat:@"Ask %@, not @Kenji", link];
    CHECK([stored.text isEqualToString:expected], "the text that goes: %@", stored.text);
    return YES;
}

// add_from_mention: refusals that keep the person from reaching someone else, then a request bound to the key.
BOOL SZFHTestAddFromMention(SZFHHarness *harness) {
    if (sodium_init() < 0) return NO;
    NSString *state = [harness makeDirectory];
    SZFriendsStore *store = [SZFriendsStore storeInDirectory:state error:NULL];
    CHECK(store != nil, "a store to seed");
    SZFriendsPersonRecord *friend = SZFHMentionSeed(store, @"c_mei", @"Mei", @"jasmine-street",
                                                    SZFriendsRelationFriend, NO);
    SZFriendsPersonRecord *blocked = SZFHMentionSeed(store, @"c_jo", @"Jo", @"copper-pebble",
                                                     SZFriendsRelationBlocked, NO);
    SZFriendsPersonRecord *asking = SZFHMentionSeed(store, @"c_lena", @"Lena", @"amber-falcon",
                                                    SZFriendsRelationIncomingRequest, NO);
    SZFHMentionSeed(store, @"c_holder", @"Holder", @"silver-ocean", SZFriendsRelationRemoved, YES);
    [store close];
    pid_t pid = [harness spawnHelperWithStateDirectory:state timeScale:1];
    SZFHClient *client = [SZFHClient connectToSocket:[harness socketPathForStateDirectory:state] timeout:5];
    CHECK([[client helloWithEmbeddedBuild:0][@"type"] isEqual:@"welcome"]);
    NSDictionary *(^add)(NSString *, NSData *) = ^NSDictionary *(NSString *friendsID, NSData *key) {
      return [client intent:@"add_from_mention" fields:@{@"friends_id" : friendsID,
                                                         @"identity_key" : SZFriendsMentionKeyString(key),
                                                         @"name" : @"Leo Park"}];
    };
    CHECK([add(@"jasmine-street", friend.identityKey)[@"error"][@"code"] isEqual:@"already_friends"]);
    CHECK([add(@"copper-pebble", blocked.identityKey)[@"error"][@"code"] isEqual:@"blocked"]);
    CHECK([add(@"amber-falcon", asking.identityKey)[@"error"][@"code"] isEqual:@"stale"], "they asked first");
    NSData *leo = SZFHMentionRandom(32);
    // A friend's ID, or one the host vouched for, under another key: Add would reach someone else.
    NSDictionary *reply = add(@"jasmine-street", leo);
    CHECK([reply[@"error"][@"code"] isEqual:@"mention_mismatch"] &&
              [reply[@"error"][@"message"] isEqual:@"This link no longer matches Leo Park, so no request was sent."],
          "a friend's ID: %@", reply);
    CHECK([add(@"silver-ocean", leo)[@"error"][@"code"] isEqual:@"mention_mismatch"], "a vouched-for ID");
    CHECK([add(@"not-words", leo)[@"error"][@"code"] isEqual:@"id_invalid"]);
    reply = [client intent:@"add_from_mention" fields:@{@"friends_id" : @"bonfire-otter", @"identity_key" : @"short",
                                                        @"name" : @"Leo"}];
    CHECK([reply[@"error"][@"details"][@"field"] isEqual:@"identity_key"], "%@", reply);
    reply = add(@"bonfire-otter", leo);
    NSString *conversation = reply[@"result"][@"conversation_id"];
    CHECK([reply[@"ok"] boolValue] && [reply[@"result"][@"message"] hasPrefix:@"Request sent to Leo Park."], "%@",
          reply);
    CHECK([add(@"bonfire-otter", leo)[@"result"][@"conversation_id"] isEqual:conversation], "asking again is one ask");
    kill(pid, SIGTERM);
    CHECK([harness waitForExit:pid timeout:3 status:NULL]);
    store = [SZFriendsStore storeInDirectory:state error:NULL];
    SZFriendsPersonRecord *row = [store personWithConversationID:conversation];
    SZFriendsIDRequestRecord *request = nil;
    for (SZFriendsIDRequestRecord *pending in [store pendingIDRequestsAtDate:[NSDate date]])
        if ([pending.conversationID isEqualToString:conversation]) request = pending;
    [store close];
    CHECK(row.relation == SZFriendsRelationOutgoingRequest && [row.identityKey isEqualToData:leo] &&
              [row.name isEqual:@"Leo Park"] && [row.friendsID isEqual:@"bonfire-otter"],
          "the row holds the mentioned key and name");
    CHECK(request != nil && [request.targetFriendsID isEqual:@"bonfire-otter"] &&
              [request.requestToken isEqualToData:SZFHMentionToken(request.callbackSecret, leo)],
          "its token binds the request to that key");
    return YES;
}
