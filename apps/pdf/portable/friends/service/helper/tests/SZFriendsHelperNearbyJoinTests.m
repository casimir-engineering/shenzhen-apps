// friends-helper-check: joining a profile in the helper (SZFriendsNearbyService+Join.m, +JoinOnline.m). Two helpers'
// services, the new computer and one already holding the profile, exchange JOIN frames over fake NN links (each side
// told its own handshake hash) and join payloads over in-memory sids: a request becomes a row only, answered alike by
// every device; Approve shows a code; the code joins; a device in the middle, a wrong code, three of them and Deny do
// not; and the same run works through the host.

#import "SZFriendsHelperNearbyTests.h"

#import "service/online/SZFriendsOnlineTransport.h"
#import "service/sync/SZFriendsSync.h"
#import "service/helper/SZFriendsHostCheckIn.h"

#import "service/helper/nearby/SZFriendsNearbyJoin.h"
#import "service/identity/SZFriendsDeviceChain.h"
#import "service/store/SZFriendsStoreDevices.h"

static NSData *Hash(uint8_t fill) {
    NSMutableData *hash = [NSMutableData dataWithLength:64];
    memset(hash.mutableBytes, fill, 64);
    return hash;
}

static SZFriendsPeerLink *NNLink(BOOL initiator, NSData *hash, NSString *_Nullable attemptKey) {
    SZFNFakeChannel *channel = [[SZFNFakeChannel alloc] init];
    channel.pattern = SZFriendsHandshakeNN;
    channel.isInitiator = initiator;
    channel.handshakeHash = hash;
    SZFriendsPeerLink *link = SZFNLink(channel);
    link.attemptKey = attemptKey;
    return link;
}

static NSMutableArray<SZFriendsFrame *> *Sent(SZFriendsPeerLink *link) {
    return ((SZFNFakeChannel *)(id)link.channel).sent;
}

// Moves frames both ways until neither side sends anything new; returns how many crossed.
static NSUInteger Shuttle(SZFriendsNearbyService *a, SZFriendsPeerLink *la, SZFriendsNearbyService *b,
                          SZFriendsPeerLink *lb) {
    NSUInteger fromA = 0, fromB = 0, moved = 0;
    while (fromA < Sent(la).count || fromB < Sent(lb).count) {
        while (fromA < Sent(la).count) [b link:lb receivedFrame:Sent(la)[fromA++]], moved++;
        while (fromB < Sent(lb).count) [a link:la receivedFrame:Sent(lb)[fromB++]], moved++;
    }
    return moved;
}

static NSString *RequestKey(SZFriendsNearbyService *joining) {
    return [NSString stringWithFormat:@"join|%@|ep|1", SZFriendsLinkHex(joining.joinState.joiner.requestID)];
}

static NSString *CodeKey(SZFriendsNearbyService *joining) {
    return [NSString stringWithFormat:@"joincode|%lu|ep", (unsigned long)joining.joinState.generation];
}

// The new computer's request over one NN session to `device`: what `device` answered.
static NSArray<SZFriendsFrame *> *SendRequest(SZFriendsNearbyService *joining, SZFriendsNearbyService *device) {
    SZFriendsPeerLink *la = NNLink(YES, Hash(1), RequestKey(joining)), *lb = NNLink(NO, Hash(1), nil);
    [joining joinLinkWentLive:la];
    Shuttle(joining, la, device, lb);
    return Sent(lb);
}

// One run of the code typed on the new computer, nearby; each side sees its own hash.
static void RunCode(SZFriendsNearbyService *joining, NSString *code, SZFriendsNearbyService *device, uint8_t hashA,
                    uint8_t hashB) {
    EXPECT([joining tryJoinCode:code] == nil, "the code is tried");
    SZFriendsPeerLink *la = NNLink(YES, Hash(hashA), CodeKey(joining)), *lb = NNLink(NO, Hash(hashB), nil);
    [joining joinLinkWentLive:la];
    Shuttle(joining, la, device, lb);
    [joining joinLinkEnded:la];
    [device joinLinkEnded:lb];
}

static SZFriendsNearbyService *Device(NSString *scratch, NSString *name, NSString *friendsID) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, name);
    if (services == nil) return nil;
    services.store.friendsID = friendsID;
    services.store.profileName = friendsID ? @"Mei Lin" : nil;
    return SZFNNearbyWith(services, @[]);
}

static void TestJoinNearby(NSString *scratch) {
    SZFriendsNearbyService *laptop = Device(scratch, @"join-laptop", @"walnut-garden");
    SZFriendsNearbyService *desktop = Device(scratch, @"join-desktop", @"tulip-canyon");
    SZFriendsNearbyService *stranger = Device(scratch, @"join-stranger", @"amber-otter");
    if (laptop == nil || desktop == nil || stranger == nil) return;
    EXPECT([laptop joiningFacts].state == SZFriendsJoiningIdle, "offered on a computer with nobody in Friends");
    EXPECT([[laptop startJoiningFriendsID:@"not an id"] isEqual:@"id_invalid"], "a malformed ID");
    EXPECT([[laptop startJoiningFriendsID:@"walnut-garden"] isEqual:@"id_is_yours"], "its own ID");
    EXPECT([laptop startJoiningFriendsID:@"Tulip Canyon"] == nil, "the ID as typed");
    EXPECT([laptop joiningFacts].state == SZFriendsJoiningWaiting &&
               [[laptop joiningFacts].friendsID isEqual:@"tulip-canyon"], "waiting for an approval");

    // Every device answers the request alike; only the profile's own shows a row, and approves nothing by itself.
    NSArray<SZFriendsFrame *> *fromDesktop = SendRequest(laptop, desktop);
    NSArray<SZFriendsFrame *> *fromStranger = SendRequest(laptop, stranger);
    EXPECT(fromDesktop.count == 1 && fromDesktop[0].type == SZFriendsFrameTypeReceived, "RECEIVED");
    EXPECT([SZFriendsEncodeFrame(fromDesktop[0], NULL) isEqualToData:SZFriendsEncodeFrame(fromStranger[0], NULL)],
           "the same bytes from a device that holds the ID and one that does not");
    EXPECT([stranger joinRequestFacts].count == 0, "no row elsewhere");
    NSArray<SZFriendsJoinRequestFacts *> *rows = [desktop joinRequestFacts];
    EXPECT(rows.count == 1 && !rows[0].approved && [rows[0].deviceName isEqual:SZFriendsLocalDeviceName()] &&
               [rows[0].system isEqual:SZFriendsLocalDeviceSystem()], "a waiting row naming the computer");
    SendRequest(laptop, desktop);
    EXPECT([desktop joinRequestFacts].count == 1, "a repeat refreshes the same row");
    EXPECT([[desktop approveJoinID:@"00112233445566778899aabbccddeeff"] isEqual:@"not_found"], "an unknown request");
    EXPECT([desktop approveJoinID:rows[0].joinID] == nil, "approved");
    NSString *code = [desktop joinRequestFacts][0].code;
    EXPECT(code.length == 8 && [desktop joinRequestFacts][0].approved, "the code shows");
    EXPECT([desktop.services.store.ownDeviceChain.rootKey isEqualToData:desktop.services.identity.publicKey],
           "the existing profile got its genesis on Approve");

    // A device in the middle holds a different session with each side: the run fails and joins nobody.
    RunCode(laptop, code, desktop, 2, 3);
    EXPECT([laptop joiningFacts].state == SZFriendsJoiningWrongCode, "the laptop says the code did not match");
    EXPECT(laptop.services.store.ownDeviceChain == nil, "nothing adopted");
    EXPECT([desktop.services.store.ownDeviceChain devices].count == 1, "nobody added");
    // A wrong code: the same.
    NSString *wrong = [code isEqualToString:@"12345678"] ? @"87654321" : @"12345678";
    RunCode(laptop, wrong, desktop, 4, 4);
    EXPECT([laptop joiningFacts].state == SZFriendsJoiningWrongCode, "wrong code");
    EXPECT([desktop joinRequestFacts].count == 1, "two failures leave the approval");

    // The right code, on one session: the laptop joins the desktop's profile.
    RunCode(laptop, [NSString stringWithFormat:@"%@-%@", [code substringToIndex:4], [code substringFromIndex:4]],
            desktop, 5, 5);
    SZFriendsStore *joined = laptop.services.store;
    EXPECT([laptop joiningFacts].state == SZFriendsJoiningJoined, "joined: %ld", (long)[laptop joiningFacts].state);
    EXPECT([joined.ownDeviceChain.rootKey isEqualToData:desktop.services.identity.publicKey] &&
               [joined.ownDeviceChain authorizesDeviceKey:laptop.services.identity.publicKey],
           "the laptop holds the profile's chain, with itself in it");
    EXPECT([desktop.services.store.ownDeviceChain authorizesDeviceKey:laptop.services.identity.publicKey],
           "the desktop stored the add link first");
    EXPECT([joined.friendsID isEqual:@"tulip-canyon"] && [joined.profileName isEqual:@"Mei Lin"],
           "the profile's ID and name: %@ %@", joined.friendsID, joined.profileName);
    EXPECT([desktop joinRequestFacts].count == 0, "the row is gone");
    EXPECT([[joined syncStateForKey:SZFriendsCheckInPreJoinReleaseKey] boolValue],
           "the ID this computer held on its own is released before it checks in for the profile");
    EXPECT([[laptop startJoiningFriendsID:@"amber-otter"] isEqual:@"not_allowed"] &&
               [laptop joiningFacts].state == SZFriendsJoiningJoined, "a computer in a shared profile joins no other");
}

static void TestDenyAndAttempts(NSString *scratch) {
    SZFriendsNearbyService *laptop = Device(scratch, @"deny-laptop", @"walnut-garden");
    SZFriendsNearbyService *desktop = Device(scratch, @"deny-desktop", @"tulip-canyon");
    SZFriendsNearbyService *busy = Device(scratch, @"deny-busy", @"amber-otter");
    if (laptop == nil || desktop == nil || busy == nil) return;
    SZFNSavePerson(busy.services.store, SZFriendsRelationFriend);
    EXPECT([busy joiningFacts].state == SZFriendsJoiningUnavailable &&
               [[busy startJoiningFriendsID:@"tulip-canyon"] isEqual:@"not_allowed"],
           "a computer with friends cannot join another profile");

    [laptop startJoiningFriendsID:@"tulip-canyon"];
    SendRequest(laptop, desktop);
    NSString *joinID = [desktop joinRequestFacts][0].joinID;
    NSString *code = [desktop approveJoinID:joinID] ? nil : [desktop joinRequestFacts][0].code;
    NSString *wrong = [code isEqualToString:@"12345678"] ? @"87654321" : @"12345678";
    for (int i = 0; i < 3; i++) RunCode(laptop, wrong, desktop, (uint8_t)(10 + i), (uint8_t)(10 + i));
    EXPECT([desktop joinRequestFacts].count == 0, "three wrong codes cancel the approval");
    RunCode(laptop, code, desktop, 20, 20);
    EXPECT([laptop joiningFacts].state == SZFriendsJoiningTooManyAttempts, "the laptop hears why: %ld",
           (long)[laptop joiningFacts].state);
    EXPECT(laptop.services.store.ownDeviceChain == nil, "and joined nothing");

    // Start again, and the person denies: the next copy of the request hears it.
    EXPECT([laptop startJoiningFriendsID:@"tulip-canyon"] == nil, "started again");
    SendRequest(laptop, desktop);
    EXPECT([desktop denyJoinID:[desktop joinRequestFacts][0].joinID] == nil, "denied");
    NSArray<SZFriendsFrame *> *answer = SendRequest(laptop, desktop);
    EXPECT(answer.count == 1 && answer[0].type == SZFriendsFrameTypeJoin, "an Ended message, not RECEIVED");
    EXPECT([laptop joiningFacts].state == SZFriendsJoiningDenied, "the laptop shows it was not approved");
    EXPECT([desktop joinRequestFacts].count == 0 && [[desktop denyJoinID:joinID] isEqual:@"not_found"],
           "no row comes back");

    // Reset Friends forgets requests and approvals.
    [laptop cancelJoining];
    EXPECT([laptop joiningFacts].state == SZFriendsJoiningIdle, "cancelled");
    [laptop startJoiningFriendsID:@"tulip-canyon"];
    [desktop forgetJoins];
    SendRequest(laptop, desktop);
    EXPECT([desktop joinRequestFacts].count == 1, "a fresh row after forgetting the denial");
    [desktop forgetJoins];
    EXPECT([desktop joinRequestFacts].count == 0, "Reset Friends: nothing waits");
}

#pragma mark - Online

// One end of an in-memory sid, as the host forwards it: the caller's payloads reach every waiting target until one
// answers, which then is the only far end; a target that closes before answering is nobody to the caller.
@interface SZFNJoinSid : NSObject <SZFriendsOnlineJoinChannel>
@property(nonatomic, strong, nullable) SZFNJoinSid *peer;
@property(nonatomic, strong) NSMutableArray<SZFNJoinSid *> *waiting; // the caller's, until a target answers
@property(nonatomic, weak, nullable) SZFNJoinSid *caller;            // a target's
@property(nonatomic) NSUInteger sent;
@property(nonatomic) BOOL closed;
@end

@implementation SZFNJoinSid
@synthesize onPayload = _onPayload;
@synthesize onEnd = _onEnd;

- (instancetype)init {
    if ((self = [super init])) _waiting = [NSMutableArray array];
    return self;
}

static void Deliver(SZFNJoinSid *to, NSData *payload) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!to.closed && to.onPayload) to.onPayload(payload);
    });
}

- (BOOL)sendPayload:(NSData *)payload {
    if (self.closed || payload.length > 4096) return NO;
    self.sent++;
    SZFNJoinSid *caller = self.caller;
    if (caller != nil && caller.peer == nil) {
        caller.peer = self;
        self.peer = caller;
        for (SZFNJoinSid *other in caller.waiting) if (other != self) [other close];
    }
    if (self.peer != nil) Deliver(self.peer, payload);
    else for (SZFNJoinSid *target in self.waiting) Deliver(target, payload);
    return YES;
}

- (void)close {
    if (self.closed) return;
    self.closed = YES;
    SZFNJoinSid *peer = self.peer;
    if (peer == nil) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!peer.closed && peer.onEnd) peer.onEnd();
    });
}
@end

static void TestJoinOnline(NSString *scratch) {
    SZFriendsNearbyService *laptop = Device(scratch, @"online-laptop", @"walnut-garden");
    SZFriendsNearbyService *desktop = Device(scratch, @"online-desktop", @"tulip-canyon");
    SZFriendsNearbyService *other = Device(scratch, @"online-other", @"tulip-canyon"); // the profile, no approval
    if (laptop == nil || desktop == nil || other == nil) return;
    NSMutableArray<SZFNJoinSid *> *sids = [NSMutableArray array];
    // The host: every open by ID reaches both of the profile's computers; whoever answers first keeps it.
    laptop.joinState.testOpener = ^(NSString *friendsID, NSData *payload,
                                    void (^completion)(id<SZFriendsOnlineJoinChannel>)) {
        EXPECT([friendsID isEqual:@"tulip-canyon"], "opened to the ID typed");
        SZFNJoinSid *caller = [SZFNJoinSid new];
        [sids addObject:caller];
        for (SZFriendsNearbyService *target in @[ other, desktop ]) {
            SZFNJoinSid *end = [SZFNJoinSid new];
            end.caller = caller;
            [caller.waiting addObject:end];
            [sids addObject:end];
            dispatch_async(dispatch_get_main_queue(), ^{ [target receiveJoinOpenPayload:payload channel:end]; });
        }
        completion(caller);
    };
    EXPECT([laptop startJoiningFriendsID:@"tulip-canyon"] == nil, "started");
    SZFNSpin(0.3);
    EXPECT([desktop joinRequestFacts].count == 1 && [other joinRequestFacts].count == 1, "both computers show it");
    NSUInteger answered = 0;
    for (SZFNJoinSid *sid in sids) answered += sid.sent;
    EXPECT(answered == 0, "nobody answers a request");
    [desktop approveJoinID:[desktop joinRequestFacts][0].joinID];
    NSString *code = [desktop joinRequestFacts][0].code;
    EXPECT([laptop tryJoinCode:code] == nil, "the code goes out through the host");
    BOOL done = NO;
    for (int i = 0; i < 40 && !done; i++) {
        SZFNSpin(0.1);
        done = [laptop joiningFacts].state == SZFriendsJoiningJoined;
    }
    EXPECT(done, "joined online: %ld", (long)[laptop joiningFacts].state);
    EXPECT([laptop.services.store.ownDeviceChain authorizesDeviceKey:laptop.services.identity.publicKey] &&
               [desktop.services.store.ownDeviceChain authorizesDeviceKey:laptop.services.identity.publicKey],
           "both hold the add link");
    EXPECT([other.services.store.ownDeviceChain devices].count == 0, "the computer without an approval stayed out");
    // Joined through the host alone, with no nearby route ever: it holds what reaching friends and our own devices
    // online takes, so it syncs online without first meeting one of them nearby.
    SZFriendsStore *joined = laptop.services.store, *profile = desktop.services.store;
    EXPECT(joined.ownPresenceSecret.length == 32 && [joined.ownPresenceSecret isEqual:profile.ownPresenceSecret],
           "the person's presence secret came with the welcome");
    NSData *devicesSecret = [SZFriendsSyncEngine ownDevicesSecretInStore:joined creating:NO];
    EXPECT(devicesSecret != nil &&
               [devicesSecret isEqual:[SZFriendsSyncEngine ownDevicesSecretInStore:profile creating:NO]],
           "and the secret our devices find each other by");
    NSData *desktopKey = desktop.services.identity.publicKey, *laptopKey = laptop.services.identity.publicKey;
    SZFriendsOnlineFriend *sibling = [laptop onlineOwnDeviceWithKey:desktopKey];
    EXPECT(sibling != nil && [sibling.presenceSecret isEqual:profile.ownPresenceSecret] &&
               [sibling.staticKey isEqual:desktop.services.identity.staticPublicKey],
           "the laptop can reach the desktop online");
    EXPECT([[desktop onlineOwnDeviceWithKey:laptopKey].presenceSecret isEqual:joined.ownPresenceSecret] &&
               [[desktop onlineOwnDeviceWithKey:laptopKey].rootKey isEqual:desktopKey],
           "and the desktop the laptop, through the records filed under the person");
    SZFNSpin(2.2);
    NSUInteger open = 0;
    for (SZFNJoinSid *sid in sids) open += sid.closed ? 0 : 1;
    EXPECT(open == 0, "every sid let go: %lu open", (unsigned long)open);
}

// The profile that answers must be the one whose ID was typed: a profile whose ID changed meanwhile joins nobody.
static void TestJoinOnlyTheTypedID(NSString *scratch) {
    SZFriendsNearbyService *laptop = Device(scratch, @"typed-laptop", @"walnut-garden");
    SZFriendsNearbyService *desktop = Device(scratch, @"typed-desktop", @"tulip-canyon");
    if (laptop == nil || desktop == nil) return;
    EXPECT([laptop startJoiningFriendsID:@"tulip-canyon"] == nil, "asked");
    SendRequest(laptop, desktop);
    [desktop approveJoinID:[desktop joinRequestFacts][0].joinID];
    NSString *code = [desktop joinRequestFacts][0].code;
    desktop.services.store.friendsID = @"amber-otter";
    RunCode(laptop, code, desktop, 6, 6);
    EXPECT([laptop joiningFacts].state != SZFriendsJoiningJoined && laptop.services.store.ownDeviceChain == nil,
           "not joined: %ld", (long)[laptop joiningFacts].state);
    EXPECT([laptop.services.store.friendsID isEqual:@"walnut-garden"], "its own ID stays");
}

void SZFNTestJoin(NSString *scratch) {
    TestJoinNearby(scratch);
    TestJoinOnlyTheTypedID(scratch);
    TestDenyAndAttempts(scratch);
    TestJoinOnline(scratch);
}
