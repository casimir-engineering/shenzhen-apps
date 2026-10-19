// friends-helper-check: Add by ID online on the helper's side (SZFriendsNearbyService+ByIDOnline.m). The requester
// admits a holder's IK callback only as its hidden listener would (a request from a mention or a friend link only for
// the key it carries), and the holder files a request that arrived online as one heard nearby, accepting it at once
// through a live friend link only up to the link's 20 a day.

#import "SZFriendsHelperNearbyTests.h"

#import "service/identity/SZFriendsIdentity.h"
#import "service/presentation/SZFriendsPresentation.h"
#import "service/store/SZFriendsStoreLinks.h"

static SZFriendsIdentity *NewIdentity(void) {
    return [SZFriendsIdentity identityWithSigningSeed:SZFNBytes(32) staticPrivateKey:SZFNBytes(32)];
}

// Our own Add by ID: a "Request sent" row (holding `key` when the request is bound to it) and its request.
static NSData *SaveRequest(SZFriendsStore *store, NSData *_Nullable key) {
    SZFriendsPersonRecord *row = [[SZFriendsPersonRecord alloc] init];
    row.conversationID = SZFriendsNewIdentifier();
    row.identityKey = key;
    row.friendsID = @"orchid-summit";
    row.picture = [SZFriendsPicture placeholder];
    row.relation = SZFriendsRelationOutgoingRequest;
    row.lastInteractionAt = [NSDate date];
    EXPECT([store savePerson:row error:NULL]);
    SZFriendsIDRequestRecord *request = [[SZFriendsIDRequestRecord alloc] init];
    request.conversationID = row.conversationID;
    request.targetFriendsID = row.friendsID;
    request.callbackSecret = SZFNBytes(32);
    request.requestToken = key ? SZFriendsMentionRequestToken(request.callbackSecret, key) : SZFNBytes(16);
    request.createdAt = [NSDate date];
    request.expiresAt = [request.createdAt dateByAddingTimeInterval:86400];
    EXPECT([store saveIDRequest:request error:NULL]);
    return request.requestToken;
}

static void TestRequesterAdmitsTheCallback(NSString *scratch) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"byid-online-requester");
    if (services == nil) return;
    SZFriendsStore *store = services.store;
    SZFriendsNearbyService *nearby = SZFNNearbyWith(services, @[]);
    SZFriendsOnlineDriver *driver = [[SZFriendsOnlineDriver alloc] initWithIdentity:services.identity
                                                                              queue:dispatch_get_main_queue()];
    NSData *(^ask)(NSData *, NSData *) = ^NSData *(NSData *key, NSData *token) {
        return [nearby onlineDriver:driver friendAnsweringWithIdentityKey:key requestToken:token].identityKey;
    };
    // From a mention or a friend link: exactly the key it carried, whoever holds the ID now.
    SZFriendsIdentity *carried = NewIdentity(), *holder = NewIdentity();
    NSData *bound = SaveRequest(store, carried.publicKey);
    EXPECT([ask(carried.publicKey, bound) isEqualToData:carried.publicKey], "the key the link carried");
    EXPECT(ask(holder.publicKey, bound) == nil, "another key holding the ID is refused before any connection");
    // A plain Add by ID: whoever holds the ID, with our token only.
    NSData *plain = SaveRequest(store, nil);
    EXPECT([ask(holder.publicKey, plain) isEqualToData:holder.publicKey], "the holder answering add_by_id");
    EXPECT(ask(holder.publicKey, SZFNBytes(16)) == nil, "a token we never issued");
    SZFriendsPersonRecord *blocked = SZFNSavePerson(store, SZFriendsRelationBlocked);
    EXPECT(ask(blocked.identityKey, plain) == nil, "blocked people never");
    EXPECT(ask(services.identity.publicKey, plain) == nil, "never ourselves");
    // A friend presenting a token must still present the static key we hold.
    SZFriendsPersonRecord *friend = SZFNSavePerson(store, SZFriendsRelationFriend);
    SZFriendsOnlineFriend *known = [nearby onlineDriver:driver friendAnsweringWithIdentityKey:friend.identityKey
                                           requestToken:plain];
    EXPECT([known.staticKey isEqualToData:friend.staticKey], "%@", known.staticKey);
    EXPECT([nearby onlineDriver:driver friendAnsweringWithIdentityKey:holder.publicKey requestToken:plain].staticKey ==
               nil,
           "a new holder's static key comes from its certificate");
    [driver stop];
}

static NSString *EventIn(SZFriendsStore *store, NSString *conversationID) {
    return [store itemsInConversation:conversationID beforeItemID:nil limit:10 hasEarlier:NULL].lastObject.eventKind;
}

static void TestHolderFilesRequestsArrivedOnline(NSString *scratch) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"byid-online-holder");
    if (services == nil) return;
    SZFriendsStore *store = services.store;
    store.friendsID = @"amber-otter";
    SZFriendsNearbyService *nearby = SZFNNearbyWith(services, @[]);
    SZFriendsOnlineDriver *driver = [[SZFriendsOnlineDriver alloc] initWithIdentity:services.identity
                                                                              queue:dispatch_get_main_queue()];
    NSData *invite = [store standingInviteCreatingIfNeeded:YES error:NULL].token;
    // One request from `asker`, as the driver hands it over: through our link when `proved`.
    SZFriendsPersonRecord *(^arrive)(SZFriendsIdentity *, BOOL) = ^(SZFriendsIdentity *asker, BOOL proved) {
        NSData *hash = SZFNBytes(64);
        SZFriendsFrame *frame = SZFriendsMakeRequestByIDFrame(asker, store.friendsID, SZFNBytes(16), SZFNBytes(32),
                                                              hash);
        if (proved) {
            NSMutableDictionary *fields = [frame.fields mutableCopy];
            fields[@(SZFriendsFieldInviteProof)] = SZFriendsInviteProof(invite, hash);
            frame = [SZFriendsFrame frameWithType:frame.type fields:fields];
        }
        [nearby onlineDriver:driver receivedRequestByID:frame handshakeHash:hash];
        return [store personWithIdentityKey:asker.publicKey];
    };
    SZFriendsPersonRecord *asked = arrive(NewIdentity(), NO);
    EXPECT(asked != nil && asked.relation == SZFriendsRelationIncomingRequest && !asked.requestFoundNearby,
           "a request by ID waits for the person: %ld", (long)asked.relation);
    SZFriendsIdentity *other = NewIdentity();
    SZFriendsFrame *wrong = SZFriendsMakeRequestByIDFrame(other, store.friendsID, SZFNBytes(16), SZFNBytes(32),
                                                          SZFNBytes(64));
    [nearby onlineDriver:driver receivedRequestByID:wrong handshakeHash:SZFNBytes(64)];
    EXPECT([store personWithIdentityKey:other.publicKey] == nil, "signed over another session: nothing kept");
    // Through our link: accepted at once, with "Added through your link" each time...
    NSUInteger accepted = 0;
    for (NSUInteger i = 0; i < SZFriendsInviteAcceptsPerDay; i++) {
        SZFriendsPersonRecord *linked = arrive(NewIdentity(), YES);
        BOOL ok = linked.relation == SZFriendsRelationFriend &&
                  [EventIn(store, linked.conversationID) isEqual:SZFriendsEventAddedThroughOurLink];
        accepted += ok ? 1 : 0;
    }
    EXPECT(accepted == 20, "twenty accepted through the link, each saying so: %lu", (unsigned long)accepted);
    // ...and past twenty in a day the request waits for the person, as any other.
    SZFriendsPersonRecord *late = arrive(NewIdentity(), YES);
    EXPECT(late != nil && late.relation == SZFriendsRelationIncomingRequest, "the 21st waits: %ld",
           (long)late.relation);
    EXPECT(late == nil || EventIn(store, late.conversationID) == nil, "and says nothing about the link");
    [driver stop];
}

void SZFNTestByIDOnline(NSString *scratch) {
    TestRequesterAdmitsTheCallback(scratch);
    TestHolderFilesRequestsArrivedOnline(scratch);
}
