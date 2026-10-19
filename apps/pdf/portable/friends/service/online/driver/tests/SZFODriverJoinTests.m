// friends-driver-check: joining a profile through the host (SZFriendsOnlineDriver+Join.m). An open by Friends ID whose
// payload starts with 'J' goes to the delegate untouched and never to Add by ID's NN responder; one that does not stays
// Add by ID's. Opens for joining go out through the same sid machinery, under a budget of their own: the host's 40
// an hour for to.join, apart from Add by ID's 5.

#import "SZFODriverTestSupport.h"

@interface SZFODJoinDelegate : SZFODDelegate
@property(nonatomic, readonly) NSMutableArray<NSData *> *payloads;
@property(nonatomic, readonly) NSMutableArray<id<SZFriendsOnlineJoinChannel>> *channels;
@property(nonatomic) NSUInteger requestsByID;
@end

@implementation SZFODJoinDelegate

- (instancetype)init {
    if ((self = [super init])) {
        _payloads = [NSMutableArray array];
        _channels = [NSMutableArray array];
    }
    return self;
}

- (void)onlineDriver:(SZFriendsOnlineDriver *)driver
    receivedJoinPayload:(NSData *)payload
                channel:(id<SZFriendsOnlineJoinChannel>)channel {
    (void)driver;
    [_payloads addObject:payload];
    [_channels addObject:channel];
}

- (void)onlineDriver:(SZFriendsOnlineDriver *)driver
    receivedRequestByID:(SZFriendsFrame *)frame
          handshakeHash:(NSData *)handshakeHash {
    (void)driver, (void)frame, (void)handshakeHash;
    _requestsByID++;
}

@end

static NSData *JoinPayload(uint8_t kind, NSUInteger extra) {
    NSMutableData *payload = [NSMutableData dataWithBytes:(uint8_t[]){'J', kind} length:2];
    [payload appendData:SZFODRandom(extra)];
    return payload;
}

static void TestJoinOpensReachTheDelegate(void) {
    SZFODWorld *world = [[SZFODWorld alloc] initWithTransportFactory:nil];
    SZFODJoinDelegate *holder = [SZFODJoinDelegate new];
    world.b.delegate = holder;
    NSArray<SZFODChannel *> *pair = [SZFODChannel pair];
    NSData *payload = JoinPayload(1, 300);
    [world.b receiveOpenVia:SZFriendsHostSignalViaFriendsID channel:pair[1] payload:payload];
    EXPECT(holder.payloads.count == 1 && [holder.payloads[0] isEqualToData:payload], "handed over as it came");
    EXPECT(pair[1].sent.count == 0 && !pair[1].closed, "the driver answers nothing itself");
    // The channel the helper gets carries payloads both ways and closes the sid.
    __block NSData *heard = nil;
    holder.channels[0].onPayload = ^(NSData *data) { heard = data; };
    [pair[0] sendPayload:SZFODRandom(10)];
    EXPECT(SZFODWaitUntil(2, ^BOOL { return heard.length == 10; }), "payloads arrive");
    EXPECT([holder.channels[0] sendPayload:SZFODRandom(20)] && pair[1].sent.count == 1, "and go back");
    [holder.channels[0] close];
    EXPECT(pair[1].closed, "close ends the sid");

    // An NN message 1 by ID is still Add by ID's, and a join payload never reaches Add by ID.
    SZFriendsSignalingSession *nn = [[SZFriendsSignalingSession alloc] initNNInitiator];
    NSArray<SZFODChannel *> *byID = [SZFODChannel pair];
    [world.b receiveOpenVia:SZFriendsHostSignalViaFriendsID channel:byID[1]
                    payload:[nn openingMessageWithItems:@[] now:[NSDate date] error:NULL]];
    EXPECT(holder.payloads.count == 1 && byID[1].sent.count == 1, "NN answered as Add by ID: %lu",
           (unsigned long)byID[1].sent.count);
    // Nor through a friend's key: joining is by Friends ID only.
    NSArray<SZFODChannel *> *byKey = [SZFODChannel pair];
    [world.b receiveOpenVia:SZFriendsHostSignalViaRendezvous channel:byKey[1] payload:JoinPayload(2, 40)];
    EXPECT(holder.payloads.count == 1 && byKey[1].closed && byKey[1].sent.count == 0, "closed unanswered");

    // Through to.join (protocol 3): a join payload reaches the helper; anything else, even Add by ID's NN, is silence.
    NSArray<SZFODChannel *> *viaJoin = [SZFODChannel pair];
    [world.b receiveOpenVia:SZFriendsHostSignalViaJoin channel:viaJoin[1] payload:JoinPayload(1, 30)];
    EXPECT(holder.payloads.count == 2 && !viaJoin[1].closed, "a join request through to.join reaches the helper");
    NSArray<SZFODChannel *> *notJoin = [SZFODChannel pair];
    SZFriendsSignalingSession *other = [[SZFriendsSignalingSession alloc] initNNInitiator];
    [world.b receiveOpenVia:SZFriendsHostSignalViaJoin channel:notJoin[1]
                    payload:[other openingMessageWithItems:@[] now:[NSDate date] error:NULL]];
    EXPECT(holder.payloads.count == 2 && notJoin[1].closed && notJoin[1].sent.count == 0, "not Add by ID's");

    // A delegate that does not join closes such opens and says nothing.
    world.b.delegate = world.delegateB;
    NSArray<SZFODChannel *> *silent = [SZFODChannel pair];
    [world.b receiveOpenVia:SZFriendsHostSignalViaFriendsID channel:silent[1] payload:JoinPayload(1, 30)];
    EXPECT(silent[1].closed && silent[1].sent.count == 0, "silence");
    [world stop];
}

static void TestJoinOpensGoOut(void) {
    SZFODWorld *world = [[SZFODWorld alloc] initWithTransportFactory:nil];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSMutableArray<NSData *> *sent = [NSMutableArray array];
    world.a.testIDOpener = ^(NSString *friendsID, NSData *payload,
                             void (^completion)(id<SZFriendsOnlineSignalChannel>)) {
        [names addObject:friendsID];
        [sent addObject:payload];
        completion([SZFODChannel pair][0]);
    };
    __block NSUInteger opened = 0, refused = 0;
    void (^count)(id<SZFriendsOnlineJoinChannel>) = ^(id<SZFriendsOnlineJoinChannel> channel) {
        if (channel) opened++;
        else refused++;
    };
    [world.a openJoinToFriendsID:@"brave-otter" payload:SZFODRandom(20) completion:count];
    EXPECT(refused == 1 && names.count == 0, "only join payloads go out this way");
    NSMutableData *huge = [JoinPayload(1, 4095) mutableCopy];
    [world.a openJoinToFriendsID:@"brave-otter" payload:huge completion:count];
    EXPECT(refused == 2 && names.count == 0, "nor over the host's 4,096 bytes");
    for (NSUInteger i = 0; i < SZFriendsOnlineJoinOpensPerHour + 1; i++) {
        [world.a openJoinToFriendsID:@"brave-otter" payload:JoinPayload(1, 100) completion:count];
    }
    EXPECT(SZFriendsOnlineJoinOpensPerHour == 40, "the host's to.join budget");
    EXPECT(opened == 40 && refused == 3 && [names.lastObject isEqual:@"brave-otter"],
           "forty join opens an hour, the host's for to.join: %lu", (unsigned long)opened);
    // Joining spends nothing of Add by ID's 5, and Add by ID nothing of joining's.
    for (int i = 0; i < 5; i++) {
        [world.a sendRequestByIDToFriendsID:@"brave-otter"
                                      frame:^NSData *(NSData *hash) { return hash; }
                                 completion:^(BOOL received) { (void)received; }];
    }
    EXPECT(names.count == 45, "Add by ID still has its five: %lu", (unsigned long)names.count);
    [world stop];
}

// A device of a person other than their first: the open goes to the person's root, under which every device of theirs
// files its record (HOST-PROTOCOL-ONLINE.md § Several devices); IK message 1 is sealed to that device alone.
static void TestOpensReachThePersonsRoot(void) {
    SZFODWorld *world = [[SZFODWorld alloc] initWithTransportFactory:^id<SZFriendsOnlineTransport> {
        return [SZFODFakeTransport new];
    }];
    [world befriend];
    NSData *root = SZFODRandom(32);
    world.delegateA.friends[world.identityB.publicKey].rootKey = root;
    __block NSData *opened = nil;
    world.a.testOpener = ^(NSData *rdvKey, NSData *payload, void (^completion)(id<SZFriendsOnlineSignalChannel>)) {
        (void)payload;
        opened = rdvKey;
        completion(nil);
    };
    [world.a reachFriend:world.identityB.publicKey];
    EXPECT(SZFODWaitUntil(2, ^BOOL { return opened != nil; }), "an open went out");
    EXPECT([opened isEqual:SZFriendsHostRendezvousKey(root)], "to the person's records, not the device's own");
    [world stop];
}

void SZFODTestJoin(void) {
    TestOpensReachThePersonsRoot();
    TestJoinOpensReachTheDelegate();
    TestJoinOpensGoOut();
}
