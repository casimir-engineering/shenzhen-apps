// friends-helper-check: what a session with someone who is not a friend may do and how long it lasts, and the order
// of Reset Friends. Links here carry fake channels; nothing is dialed or listened on.

#import "SZFriendsHelperNearbyTests.h"

#import <objc/runtime.h>
#import <sodium.h>
#import <sys/stat.h>

#import "service/helper/SZFriendsHelperTesting.h"
#import "service/identity/SZFriendsIdentity.h"

@implementation SZFNFakeChannel (Session)
static char SZFNHashKey, SZFNSentKey, SZFNAttestationKey;
- (void)setLivenessKeepalive:(BOOL)keepalive watch:(BOOL)watch {
    (void)keepalive, (void)watch;
}
- (BOOL)fastTransfers {
    return NO;
}
- (NSData *)remoteAttestation {
    return objc_getAssociatedObject(self, &SZFNAttestationKey);
}
- (void)setRemoteAttestation:(NSData *)attestation {
    objc_setAssociatedObject(self, &SZFNAttestationKey, attestation, OBJC_ASSOCIATION_COPY);
}
- (NSData *)handshakeHash {
    return objc_getAssociatedObject(self, &SZFNHashKey);
}
- (void)setHandshakeHash:(NSData *)hash {
    objc_setAssociatedObject(self, &SZFNHashKey, hash, OBJC_ASSOCIATION_COPY);
}
- (NSMutableArray<SZFriendsFrame *> *)sent {
    NSMutableArray *sent = objc_getAssociatedObject(self, &SZFNSentKey);
    if (sent == nil) {
        sent = [NSMutableArray array];
        objc_setAssociatedObject(self, &SZFNSentKey, sent, OBJC_ASSOCIATION_RETAIN);
    }
    return sent;
}
- (BOOL)sendFrame:(SZFriendsFrame *)frame {
    [self.sent addObject:frame];
    return YES;
}
- (NSData *)remoteIdentityKey {
    return nil;
}
- (NSData *)remoteStaticKey {
    return nil;
}
@end

SZFriendsPeerLink *SZFNLink(SZFNFakeChannel *channel) {
    return [[SZFriendsPeerLink alloc] initWithChannel:channel.asChannel purpose:SZFriendsLinkPurposeIncoming
                                                route:SZFriendsRouteMethodLAN];
}

SZFriendsNearbyService *SZFNNearbyWith(SZFriendsHelperServices *services, NSArray *adapters) {
    SZFriendsNearbyService *nearby = [[SZFriendsNearbyService alloc] initWithServices:services adapters:adapters
                                                                                queue:dispatch_get_main_queue()];
    services.nearby = nearby;
    return nearby;
}

NSData *SZFNBytes(NSUInteger count) {
    NSMutableData *data = [NSMutableData dataWithLength:count];
    randombytes_buf(data.mutableBytes, count);
    return data;
}

// Review (work before authentication; Add by ID): the key policy runs on IK message 1, which can be replayed, so it
// must not write anything; a token admits at most three distinct keys; and sessions with people who are not friends
// are capped at 64 at once (SZFNTestStrangerCap).
void SZFNTestKeyPolicy(NSString *scratch) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"policy");
    if (services == nil) return;
    SZFriendsStore *store = services.store;
    SZFriendsNearbyService *nearby = SZFNNearbyWith(services, @[]);
    SZFriendsPeerLink *link = SZFNLink([[SZFNFakeChannel alloc] init]);
    EXPECT([nearby allowRemoteKey:nil pattern:SZFriendsHandshakeNN token:nil link:link publicEntry:NO] && link.stranger,
           "anyone may ask by ID, as a stranger");
    NSData *unknown = SZFNBytes(32);
    EXPECT(![nearby allowRemoteKey:unknown pattern:SZFriendsHandshakeXX token:nil link:nil publicEntry:NO],
           "XX only on the public entry");
    EXPECT([nearby allowRemoteKey:unknown pattern:SZFriendsHandshakeXX token:nil link:nil publicEntry:YES]);
    SZFriendsPersonRecord *blocked = SZFNSavePerson(store, SZFriendsRelationBlocked);
    EXPECT(![nearby allowRemoteKey:blocked.identityKey pattern:SZFriendsHandshakeXX token:nil link:nil
                       publicEntry:YES]);
    SZFriendsPersonRecord *removed = SZFNSavePerson(store, SZFriendsRelationRemoved);
    EXPECT(![nearby allowRemoteKey:removed.identityKey pattern:SZFriendsHandshakeIK token:nil link:nil publicEntry:NO]);
    SZFriendsPersonRecord *friend = SZFNSavePerson(store, SZFriendsRelationFriend);
    SZFriendsPeerLink *friendLink = SZFNLink([[SZFNFakeChannel alloc] init]);
    EXPECT([nearby allowRemoteKey:friend.identityKey pattern:SZFriendsHandshakeIK token:nil link:friendLink
                      publicEntry:NO] && !friendLink.stranger, "a friend is not a stranger");

    // An Add by ID of ours: unknown keys with its token, up to three, and nothing written by asking.
    SZFriendsPersonRecord *row = [[SZFriendsPersonRecord alloc] init];
    row.conversationID = SZFriendsNewIdentifier();
    row.friendsID = @"orchid-summit";
    row.picture = [SZFriendsPicture placeholder];
    row.relation = SZFriendsRelationOutgoingRequest;
    row.lastInteractionAt = [NSDate date];
    EXPECT([store savePerson:row error:NULL]);
    SZFriendsIDRequestRecord *request = [[SZFriendsIDRequestRecord alloc] init];
    request.conversationID = row.conversationID;
    request.targetFriendsID = row.friendsID;
    request.requestToken = SZFNBytes(16);
    request.callbackSecret = SZFNBytes(32);
    request.createdAt = [NSDate date];
    request.expiresAt = [request.createdAt dateByAddingTimeInterval:86400];
    EXPECT([store saveIDRequest:request error:NULL]);
    NSData *token = request.requestToken;
    EXPECT(![nearby allowRemoteKey:unknown pattern:SZFriendsHandshakeIK token:nil link:nil publicEntry:NO]);
    EXPECT(![nearby allowRemoteKey:unknown pattern:SZFriendsHandshakeIK token:SZFNBytes(16) link:nil publicEntry:NO]);
    for (int replay = 0; replay < 3; replay++) {
        EXPECT([nearby allowRemoteKey:unknown pattern:SZFriendsHandshakeIK token:token link:nil publicEntry:NO]);
    }
    EXPECT([store personWithIdentityKey:unknown] == nil && [store idRequestWithToken:token].answeringKeyCount == 0 &&
           [store pendingIDRequestsAtDate:[NSDate date]].count == 1,
           "a replayed message 1 changes nothing: no person, no answer, the token unspent");
    NSMutableArray<NSData *> *answered = [NSMutableArray array];
    for (int i = 0; i < 3; i++) {
        NSData *key = SZFNBytes(32);
        [answered addObject:key];
        EXPECT([store conversationForIDRequestAnswerWithToken:token identityKey:key staticKey:SZFNBytes(32)
                                                       atDate:[NSDate date] error:NULL] != nil);
    }
    EXPECT(![nearby allowRemoteKey:unknown pattern:SZFriendsHandshakeIK token:token link:nil publicEntry:NO],
           "a fourth key is refused before any reply");
    EXPECT([nearby allowRemoteKey:answered[1] pattern:SZFriendsHandshakeIK token:token link:nil publicEntry:NO],
           "one of the three may come back");

    // The cap on strangers' sessions: SZFNTestStrangerCap.
    [services close];
}

// Review (NN and stranger sessions held open): a session with someone who is not a friend ends after a quiet spell
// (60 s; shortened here), and an NN session 2 s after RECEIVED whether this device holds the ID or not.
void SZFNTestIdleClose(NSString *scratch) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"idle");
    if (services == nil) return;
    SZFriendsNearbyService *nearby = SZFNNearbyWith(services, @[]);
    SZFriendsHelperTestHooks.strangerIdleTimeout = 0.4;
    SZFNFakeChannel *quietChannel = [[SZFNFakeChannel alloc] init], *talkerChannel = [[SZFNFakeChannel alloc] init];
    SZFNFakeChannel *friendChannel = [[SZFNFakeChannel alloc] init];
    quietChannel.pattern = talkerChannel.pattern = SZFriendsHandshakeXX;
    friendChannel.pattern = SZFriendsHandshakeIK;
    SZFriendsPeerLink *quiet = SZFNLink(quietChannel), *talker = SZFNLink(talkerChannel);
    SZFriendsPeerLink *friendLink = SZFNLink(friendChannel);
    friendLink.conversationID = SZFNSavePerson(services.store, SZFriendsRelationFriend).conversationID;
    for (SZFriendsPeerLink *link in @[ quiet, talker, friendLink ]) {
        link.live = YES;
        link.liveAt = [NSDate date];
        [nearby armIdleCheckForLink:link];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [nearby noteApplicationFrameOnLink:talker];
    });
    SZFNSpin(0.55);
    EXPECT(quietChannel.closed, "a quiet stranger's session ends");
    EXPECT(!talkerChannel.closed && !friendChannel.closed, "one that spoke lately stays, and so does a friend's");
    SZFNSpin(0.4);
    EXPECT(talkerChannel.closed && !friendChannel.closed, "until it too is quiet; a friend's never is");
    SZFriendsHelperTestHooks.strangerIdleTimeout = 0;

    // NN: RECEIVED at once, then the close 2 s later, for the holder and for anyone else.
    SZFriendsIdentity *asker = [SZFriendsIdentity identityWithSigningSeed:SZFNBytes(32) staticPrivateKey:SZFNBytes(32)];
    NSMutableArray<SZFNFakeChannel *> *channels = [NSMutableArray array];
    for (NSString *target in @[ services.store.friendsID, @"not-mine" ]) {
        SZFNFakeChannel *channel = [[SZFNFakeChannel alloc] init];
        channel.pattern = SZFriendsHandshakeNN;
        channel.handshakeHash = SZFNBytes(64);
        SZFriendsFrame *frame = SZFriendsMakeRequestByIDFrame(asker, target, SZFNBytes(16), SZFNBytes(32),
                                                              channel.handshakeHash);
        EXPECT(frame != nil, "a signed request for %@", target);
        if (frame == nil) continue;
        // Held by the service like every link, so the delayed close finds it.
        SZFriendsPeerLink *link = SZFNLink(channel);
        [nearby.links addObject:link];
        [nearby link:link receivedRequestByID:frame];
        EXPECT(channel.sent.firstObject.type == SZFriendsFrameTypeReceived && !channel.closed, "RECEIVED first");
        [channels addObject:channel];
    }
    EXPECT([services.store personWithIdentityKey:asker.publicKey].relation == SZFriendsRelationIncomingRequest,
           "the holder kept the request");
    SZFNSpin(1.7);
    EXPECT(!channels.firstObject.closed && !channels.lastObject.closed, "still open 1.7 s after RECEIVED");
    SZFNSpin(0.6);
    EXPECT(channels.firstObject.closed && channels.lastObject.closed, "both closed by 2.3 s, not after 10 s");
    [services close];
}

// The keychain identity is removed first, so a keychain that refuses (locked) costs the person nothing: the friends,
// the ID and the identity stay and the person is told. The key store of these tests is the file store, whose delete
// fails when its directory cannot be written, as the keychain's does when it is locked.
void SZFNTestResetOrder(NSString *scratch) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"reset");
    if (services == nil) return;
    SZFNRecordingAdapter *adapter = [[SZFNRecordingAdapter alloc] init];
    SZFriendsNearbyService *nearby = SZFNNearbyWith(services, @[ adapter ]);
    [nearby refreshAdvertisement];
    NSData *firstTag = adapter.lastTag;
    EXPECT(firstTag != nil, "advertising before the reset");
    SZFNSavePerson(services.store, SZFriendsRelationFriend);
    NSData *identity = services.identity.publicKey;
    NSData *presenceSecret = services.store.ownPresenceSecret;
    NSString *friendsID = services.store.friendsID;
    NSString *keys = [[scratch stringByAppendingPathComponent:@"reset"] stringByAppendingPathComponent:@"keys"];
    EXPECT(chmod(keys.fileSystemRepresentation, 0500) == 0, "the key directory is read-only");
    NSError *error = nil;
    EXPECT(![services resetFriendsWithError:&error] && error != nil, "the reset fails when the identity stays");
    EXPECT(services.store.peopleByLatestInteraction.count == 1 && [services.store.friendsID isEqual:friendsID] &&
               [services.store.ownPresenceSecret isEqualToData:presenceSecret],
           "friends, ID and presence secret untouched");
    EXPECT([services.identity.publicKey isEqualToData:identity], "the identity stays");
    EXPECT(chmod(keys.fileSystemRepresentation, 0700) == 0);
    SZFriendsHelperServices *reopened = SZFNOpenServices(scratch, @"reset");
    if (reopened == nil) return;
    EXPECT([reopened.identity.publicKey isEqualToData:identity] && reopened.store.peopleByLatestInteraction.count == 1,
           "a restart finds the same identity and friends");
    [reopened close];

    // The wipe fails (a store that is closed here; a full disk or a damaged file in life) after the identity went.
    // Nothing is advertised, and nothing of the old data stays on the air under a new key.
    [services.store close];
    EXPECT(![services resetFriendsWithError:NULL], "the reset fails");
    EXPECT(adapter.lastTag == nil && !adapter.lastPublicEntry, "nothing on the air: %@", adapter.lastTag);
    [nearby refreshAdvertisement];
    EXPECT(adapter.lastTag == nil, "and nothing until a reset completes");

    // The same state again, now with a store that works.
    SZFriendsHelperServices *again = SZFNOpenServices(scratch, @"reset");
    if (again == nil) return;
    SZFNRecordingAdapter *second = [[SZFNRecordingAdapter alloc] init];
    SZFriendsNearbyService *resumed = SZFNNearbyWith(again, @[ second ]);
    [resumed refreshAdvertisement];
    EXPECT(second.lastTag != nil, "on the air");
    NSData *secret = again.store.ownPresenceSecret;
    EXPECT([again resetFriendsWithError:NULL], "a reset that can wipe succeeds");
    EXPECT(![again.identity.publicKey isEqualToData:identity] && again.store.peopleByLatestInteraction.count == 0,
           "a new identity with nobody");
    EXPECT(again.store.ownPresenceSecret != nil && ![again.store.ownPresenceSecret isEqualToData:secret],
           "and a presence secret no old friend knows");
    EXPECT(second.lastTag == nil, "off the air from the start of the reset until the router says it is done");
    [resumed identityDidReset];
    EXPECT(second.lastTag != nil && ![second.lastTag isEqualToData:firstTag], "on the air again, as someone new");
    [again close];
}
