// friends-driver-check: the pre-authentication rule end to end (SZFriendsOnlineTransport.h, lead decision 6), the
// small helpers, and that the driver makes nothing before it is used. Transports here are fakes that record what
// they were asked: a refusal must reach no transport at all.

#import "SZFODriverTestSupport.h"

// IK message 1 from `from` to `to`, carrying `items`, as an offerer's attempt would send it.
static NSData *MessageOne(SZFriendsIdentity *from, SZFriendsIdentity *to, NSArray<SZFriendsSignalItem *> *items) {
    SZFriendsSignalingSession *session =
        [[SZFriendsSignalingSession alloc] initIKInitiatorWithIdentity:from
                                                       remoteStaticKey:to.staticPublicKey
                                                   expectedIdentityKey:to.publicKey
                                                          requestToken:nil];
    return [session openingMessageWithItems:items now:[NSDate date] error:NULL];
}

static SZFriendsSignalItem *NATItem(void) {
    return [SZFriendsSignalItem natWithClass:SZFriendsSignalNATUnknown step:0];
}

static SZFODWorld *FakeWorld(void) {
    return [[SZFODWorld alloc] initWithTransportFactory:^id<SZFriendsOnlineTransport> {
        return [SZFODFakeTransport new];
    }];
}

void SZFODTestHelpers(void) {
    NSArray *uris = @[ @"stun:h.example:3478", @"turn:h.example:3478?transport=tcp", @"turn:h.example?transport=udp" ];
    EXPECT([SZFriendsOnlineFirstTURNOverUDP(uris) isEqualToString:@"turn:h.example?transport=udp"],
           "the first TURN over UDP, past a TCP one");
    EXPECT([SZFriendsOnlineFirstTURNOverUDP(@[ @"turn:h.example:3478" ]) isEqualToString:@"turn:h.example:3478"]);
    EXPECT(SZFriendsOnlineFirstTURNOverUDP(@[ @"stun:h.example", @"turns:h.example:5349" ]) == nil);
    NSString *host = nil;
    uint16_t port = 0;
    EXPECT(SZFriendsOnlineSplitSTUNURI(@"stun:[::1]:3479", &host, &port) && [host isEqualToString:@"::1"] &&
           port == 3479);
    EXPECT(SZFriendsOnlineSplitSTUNURI(@"stun:h.example", &host, &port) && port == 3478, "3478 when absent");
    EXPECT(!SZFriendsOnlineSplitSTUNURI(@"stun:h.example:03478", &host, &port), "one spelling per port");
    EXPECT(!SZFriendsOnlineSplitSTUNURI(@"stun:h.example:0", &host, &port));
    EXPECT(!SZFriendsOnlineSplitSTUNURI(@"turn:h.example:3478", &host, &port));
    NSArray<SZFriendsNATEndpoint *> *servers =
        SZFriendsOnlineResolveSTUNURIs(@[ @"stun:127.0.0.1:3478", @"turn:127.0.0.1", @"stun:[::1]:3479" ]);
    EXPECT(servers.count == 2 && [servers[0].host isEqualToString:@"127.0.0.1"] && servers[1].port == 3479,
           "numeric STUN servers in list order: %@", servers);
    EXPECT([SZFriendsOnlineNumericSTUNURI(servers[1]) isEqualToString:@"stun:[::1]:3479"]);
    uint8_t low[32] = {1}, high[32] = {2};
    NSData *a = [NSData dataWithBytes:low length:32], *b = [NSData dataWithBytes:high length:32];
    EXPECT(SZFriendsOnlineKeySortsFirst(a, b) && !SZFriendsOnlineKeySortsFirst(b, a), "one answer on both Macs");

    // Nothing is made before the host says it takes online messages: no context, so no transport and no stack.
    SZFriendsOnlineDriver *driver = [[SZFriendsOnlineDriver alloc] initWithIdentity:SZFODNewIdentity()
                                                                              queue:dispatch_get_main_queue()];
    [driver reachFriend:SZFODRandom(32)];
    [driver nearbyRoutesChanged];
    [driver networkChanged];
    EXPECT(!driver.available && [driver valueForKey:@"_context"] == nil, "a driver costs nothing until used");
}

void SZFODTestGating(void) {
    // 1. A friend dials someone who does not hold them as a friend: silence, and nothing reaches B's transport.
    SZFODWorld *world = FakeWorld();
    world.delegateA.friends[world.identityB.publicKey] = SZFODFriendFor(world.identityB, SZFODRandom(32));
    SZFODFakeTransport *fakeA = (SZFODFakeTransport *)world.a.onlineContext.transport;
    SZFODFakeTransport *fakeB = (SZFODFakeTransport *)world.b.onlineContext.transport;
    [world.a reachFriend:world.identityB.publicKey];
    EXPECT(SZFODWaitUntil(2, ^BOOL { return world.sids.count == 1 && world.sids[0][1].closed; }),
           "B closes the open: %@", world.sids);
    EXPECT(world.sids[0][1].sent.count == 0, "a refusal says nothing");
    EXPECT(world.b.attempts.count == 0 && fakeB.requests.count == 0, "nothing reaches B's stack");
    EXPECT(fakeA.requests.count == 1 && fakeA.connections[0].answersApplied == 0);
    // The offerer gives up after the answer timeout, closing its connection, and backs off.
    SZFriendsOnlineContext *contextA = world.a.onlineContext;
    NSTimeInterval later = contextA.clock() + SZFriendsOnlineAnswerTimeout + 1;
    contextA.clock = ^NSTimeInterval { return later; };
    [world.a.attempts.firstObject fireTimers];
    EXPECT(world.a.attempts.count == 0 && fakeA.connections[0].closed, "unanswered: the attempt ends");
    [world.a reachFriend:world.identityB.publicKey];
    EXPECT(world.a.attempts.count == 0 && fakeA.requests.count == 1, "and the next waits for the backoff");
    [world stop];

    // 2. Only IK opens by rendezvous key reach the responder: Friends ID and link opens are closed unanswered.
    world = FakeWorld();
    [world befriend];
    fakeB = (SZFODFakeTransport *)world.b.onlineContext.transport;
    NSData *one = MessageOne(world.identityA, world.identityB, @[ NATItem() ]);
    for (NSNumber *via in @[ @(SZFriendsHostSignalViaFriendsID), @(SZFriendsHostSignalViaLink) ]) {
        NSArray<SZFODChannel *> *pair = [SZFODChannel pair];
        [world.b receiveOpenVia:(SZFriendsHostSignalVia)via.integerValue channel:pair[1] payload:one];
        EXPECT(pair[1].closed && pair[1].sent.count == 0 && world.b.attempts.count == 0, "via %@ refused", via);
    }

    // 3. A friend presenting another static key than the one we hold waits for the person's review: refused.
    SZFriendsOnlineFriend *changed = SZFODFriendFor(world.identityA, SZFODRandom(32));
    changed.staticKey = SZFODRandom(32);
    world.delegateB.friends[world.identityA.publicKey] = changed;
    NSArray<SZFODChannel *> *pair = [SZFODChannel pair];
    [world.b receiveOpenVia:SZFriendsHostSignalViaRendezvous channel:pair[1] payload:one];
    EXPECT(pair[1].closed && world.b.attempts.count == 0, "another static key is refused");
    [world befriend];

    // 4. Garbage, and message 1 sealed to someone else, open nothing.
    SZFriendsIdentity *stranger = SZFODNewIdentity();
    for (NSData *payload in @[ SZFODRandom(300), MessageOne(world.identityA, stranger, @[ NATItem() ]) ]) {
        pair = [SZFODChannel pair];
        [world.b receiveOpenVia:SZFriendsHostSignalViaRendezvous channel:pair[1] payload:payload];
        EXPECT(pair[1].closed && world.b.attempts.count == 0 && fakeB.requests.count == 0);
    }

    // 5. A friend's message 1 starts an answerer whose only connection is bound to that authenticated peer, with
    // the offer and fingerprint from the message; the same message again (a replay) opens nothing more.
    NSData *fingerprint = SZFODRandom(32);
    SZFriendsSignalItem *offer = [SZFriendsSignalItem descriptionWithConnection:0
                                                                           kind:SZFriendsOnlineConnectionDirect
                                                                            sdp:@"v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\n"
                                                                    fingerprint:fingerprint];
    NSData *withOffer = MessageOne(world.identityA, world.identityB, @[ offer, NATItem() ]);
    pair = [SZFODChannel pair];
    [world.b receiveOpenVia:SZFriendsHostSignalViaRendezvous channel:pair[1] payload:withOffer];
    EXPECT(world.b.attempts.count == 1 && fakeB.requests.count == 1, "a friend's offer opens one connection");
    id<SZFriendsOnlineConnectionRequest> request = fakeB.requests.firstObject;
    EXPECT([request.peer isEqualToData:world.identityA.publicKey] && request.role == SZFriendsOnlineRoleAnswerer &&
           request.purpose == SZFriendsOnlinePurposeFriend && [request.remoteFingerprint isEqualToData:fingerprint],
           "bound to the peer and fingerprint the signalling authenticated");
    EXPECT(SZFODWaitUntil(2, ^BOOL { return pair[1].sent.count >= 1; }), "B answers with IK message 2");
    NSArray<SZFODChannel *> *replay = [SZFODChannel pair];
    [world.b receiveOpenVia:SZFriendsHostSignalViaRendezvous channel:replay[1] payload:withOffer];
    SZFODSpin(0.1);
    EXPECT(replay[1].closed && replay[1].sent.count == 0 && fakeB.requests.count == 1, "a replay opens nothing");
    [world stop];

    // 6. The offerer applies nothing remote before IK message 2 authenticates the friend: a forged reply ends it.
    world = FakeWorld();
    [world befriend];
    fakeA = (SZFODFakeTransport *)world.a.onlineContext.transport;
    world.a.testOpener = ^(NSData *rdvKey, NSData *payload, void (^completion)(id<SZFriendsOnlineSignalChannel>)) {
        (void)rdvKey;
        (void)payload;
        NSArray<SZFODChannel *> *forged = [SZFODChannel pair];
        completion(forged[0]);
        [forged[1] sendPayload:SZFODRandom(200)];
    };
    [world.a reachFriend:world.identityB.publicKey];
    EXPECT(SZFODWaitUntil(2, ^BOOL { return world.a.attempts.count == 0; }), "a forged reply ends the attempt");
    EXPECT(fakeA.connections.count == 1 && fakeA.connections[0].answersApplied == 0 &&
           fakeA.connections[0].candidatesAdded == 0 && fakeA.connections[0].closed, "and nothing in it was applied");
    [world stop];
}

// An offerer nobody answered backs off; while it waits, the friend's record appearing at a lookup ends the wait, the
// host's filler does not, and a friend is looked up at most once per host period however often the helper asks.
static void FailOnce(SZFODWorld *world, NSTimeInterval *clock) {
    [world.b stop]; // nobody answers
    [world.a reachFriend:world.identityB.publicKey];
    SZFODSpin(0.1);
    *clock += SZFriendsOnlineAnswerTimeout + 1;
    [world.a.attempts.firstObject fireTimers];
}

void SZFODTestBackoffLookups(void) {
    for (NSNumber *online in @[ @NO, @YES ]) {
        SZFODWorld *world = FakeWorld();
        [world befriend];
        __block NSTimeInterval clock = 1000;
        world.a.onlineContext.clock = ^NSTimeInterval { return clock; };
        SZFODFakeTransport *fakeA = (SZFODFakeTransport *)world.a.onlineContext.transport;
        FailOnce(world, &clock);
        EXPECT(world.a.attempts.count == 0 && fakeA.requests.count == 1, "the unanswered attempt ended");
        NSData *secret = world.delegateA.friends[world.identityB.publicKey].presenceSecret;
        NSData *record = SZFriendsSealRendezvousRecord(world.identityB, world.identityB.publicKey, secret,
                                                       SZFriendsPresenceWindowIndex([NSDate date]),
                                                       @[ NATItem() ], NULL);
        __block NSUInteger lookups = 0;
        world.a.testLookup = ^(NSArray<NSData *> *keys, void (^completion)(NSArray<NSData *> *, NSError *)) {
            lookups++;
            EXPECT(keys.count == 1 && [keys[0] isEqualToData:SZFriendsHostRendezvousKey(world.identityB.publicKey)]);
            completion(@[ online.boolValue ? record : SZFODRandom(SZFriendsRendezvousSealedLength) ], nil);
        };
        clock += 1;
        [world.a reachFriend:world.identityB.publicKey];
        EXPECT(lookups == 1, "a backed-off friend is looked up");
        if (online.boolValue) {
            EXPECT(fakeA.requests.count == 2 && world.a.attempts.count == 1, "their record ends the wait");
        } else {
            EXPECT(fakeA.requests.count == 1 && world.a.attempts.count == 0, "filler changes nothing");
            clock += 1;
            [world.a reachFriend:world.identityB.publicKey];
            EXPECT(lookups == 1, "once per host period");
        }
        [world stop];
    }
}

// Another computer of the friend's (or of ours) files its records under the person's root key, not its own key: a
// lookup under the device key only ever finds filler, so the wait would never end early.
void SZFODTestBackoffLookupsUnderTheRoot(void) {
    SZFODWorld *world = FakeWorld();
    [world befriend];
    SZFriendsIdentity *root = SZFODNewIdentity();
    world.delegateA.friends[world.identityB.publicKey].rootKey = root.publicKey;
    __block NSTimeInterval clock = 1000;
    world.a.onlineContext.clock = ^NSTimeInterval { return clock; };
    SZFODFakeTransport *fakeA = (SZFODFakeTransport *)world.a.onlineContext.transport;
    FailOnce(world, &clock);
    NSData *secret = world.delegateA.friends[world.identityB.publicKey].presenceSecret;
    NSData *record = SZFriendsSealRendezvousRecord(world.identityB, world.identityB.publicKey, secret,
                                                   SZFriendsPresenceWindowIndex([NSDate date]), @[ NATItem() ], NULL);
    __block NSArray<NSData *> *asked = nil;
    world.a.testLookup = ^(NSArray<NSData *> *keys, void (^completion)(NSArray<NSData *> *, NSError *)) {
        asked = keys;
        completion(@[ record ], nil);
    };
    clock += 1;
    [world.a reachFriend:world.identityB.publicKey];
    EXPECT(asked.count == 1 && [asked[0] isEqualToData:SZFriendsHostRendezvousKey(root.publicKey)],
           "the device is looked up under its person's root key");
    EXPECT(fakeA.requests.count == 2 && world.a.attempts.count == 1, "its record there ends the wait");
    [world stop];
}
