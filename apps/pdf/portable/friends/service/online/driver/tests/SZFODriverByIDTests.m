// friends-driver-check: Add by ID online (SZFriendsOnlineDriver+ByID.m). NN through a sid opened to a Friends ID
// carries REQUEST_BY_ID and RECEIVED and nothing else: no attempt and no peer connection on either side. The holder's
// IK callback presents the request's token, and the requester admits it only as its delegate says.

#import "SZFODriverTestSupport.h"

@interface SZFODByIDDelegate : SZFODDelegate
@property(nonatomic, readonly) NSMutableArray<SZFriendsFrame *> *frames;
@property(nonatomic, readonly) NSMutableArray<NSData *> *hashes;
// Token -> who may answer with it; every token asked about, in order.
@property(nonatomic, readonly) NSMutableDictionary<NSData *, SZFriendsOnlineFriend *> *answering;
@property(nonatomic, readonly) NSMutableArray<NSData *> *tokensAsked;
@end

@implementation SZFODByIDDelegate

- (instancetype)init {
    if ((self = [super init])) {
        _frames = [NSMutableArray array];
        _hashes = [NSMutableArray array];
        _answering = [NSMutableDictionary dictionary];
        _tokensAsked = [NSMutableArray array];
    }
    return self;
}

- (void)onlineDriver:(SZFriendsOnlineDriver *)driver
    receivedRequestByID:(SZFriendsFrame *)frame
          handshakeHash:(NSData *)handshakeHash {
    (void)driver;
    [_frames addObject:frame];
    [_hashes addObject:handshakeHash];
}

- (SZFriendsOnlineFriend *)onlineDriver:(SZFriendsOnlineDriver *)driver
         friendAnsweringWithIdentityKey:(NSData *)identityKey
                           requestToken:(NSData *)token {
    (void)driver;
    [_tokensAsked addObject:token];
    SZFriendsOnlineFriend *friend = _answering[token];
    if (![friend.identityKey isEqualToData:identityKey]) return nil;
    SZFriendsOnlineFriend *copy = [SZFriendsOnlineFriend new];
    copy.identityKey = friend.identityKey; // no static key: the session's certificate supplies it
    return copy;
}

@end

// A's opens by ID reach B's driver as the host would deliver them; every sid is kept in `sids`.
static void ConnectByID(SZFriendsOnlineDriver *from, SZFriendsOnlineDriver *to, NSMutableArray *sids,
                        NSMutableArray<NSString *> *names) {
    __weak SZFriendsOnlineDriver *weakTo = to;
    from.testIDOpener = ^(NSString *friendsID, NSData *payload, void (^completion)(id<SZFriendsOnlineSignalChannel>)) {
        [names addObject:friendsID];
        NSArray<SZFODChannel *> *pair = [SZFODChannel pair];
        [sids addObject:pair];
        completion(pair[0]);
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakTo receiveOpenVia:SZFriendsHostSignalViaFriendsID channel:pair[1] payload:payload];
        });
    };
}

static NSData *RequestFrame(SZFriendsIdentity *identity, NSData *token, NSData *hash) {
    SZFriendsFrame *frame = SZFriendsMakeRequestByIDFrame(identity, @"brave-otter", token, SZFODRandom(32), hash);
    return frame ? SZFriendsEncodeFrame(frame, NULL) : nil;
}

static void TestRequestReachesHolder(void) {
    SZFODWorld *world = [[SZFODWorld alloc] initWithTransportFactory:^id<SZFriendsOnlineTransport> {
        return [SZFODFakeTransport new];
    }];
    SZFODByIDDelegate *holder = [SZFODByIDDelegate new];
    world.b.delegate = holder;
    NSMutableArray<NSArray<SZFODChannel *> *> *sids = [NSMutableArray array];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    ConnectByID(world.a, world.b, sids, names);
    NSData *token = SZFODRandom(16);
    __block NSData *signedHash = nil;
    __block NSNumber *outcome = nil;
    [world.a sendRequestByIDToFriendsID:@"brave-otter"
                                  frame:^NSData *(NSData *hash) {
                                      signedHash = hash;
                                      return RequestFrame(world.identityA, token, hash);
                                  }
                             completion:^(BOOL received) { outcome = @(received); }];
    EXPECT(SZFODWaitUntil(5, ^BOOL { return outcome != nil && holder.frames.count == 1; }), "RECEIVED came back");
    EXPECT(outcome.boolValue && [names isEqual:@[ @"brave-otter" ]], "opened to the ID: %@", names);
    EXPECT([holder.hashes.firstObject isEqualToData:signedHash], "one handshake hash on both sides");
    NSData *key = holder.frames.count ? SZFriendsVerifyRequestByIDFrame(holder.frames[0], holder.hashes[0]) : nil;
    EXPECT([key isEqualToData:world.identityA.publicKey], "the request verifies as A's, bound to this session");
    EXPECT([[holder.frames.firstObject dataForTag:SZFriendsFieldToken] isEqualToData:token]);
    // NN message 1 (in the open) and the request one way, message 2 and RECEIVED the other: nothing else.
    EXPECT(sids.count == 1 && sids[0][0].sent.count == 1 && sids[0][1].sent.count == 2, "%lu %lu",
           (unsigned long)sids[0][0].sent.count, (unsigned long)sids[0][1].sent.count);
    SZFODFakeTransport *fakeA = (SZFODFakeTransport *)world.a.onlineContext.transport;
    SZFODFakeTransport *fakeB = (SZFODFakeTransport *)world.b.onlineContext.transport;
    EXPECT(world.a.attempts.count == 0 && world.b.attempts.count == 0, "no attempt either side");
    EXPECT(fakeA.requests.count == 0 && fakeB.requests.count == 0, "no peer connection either side");
    EXPECT(SZFODWaitUntil(4, ^BOOL { return sids[0][1].closed && sids[0][0].closed; }), "both let the sid go");

    // Something other than REQUEST_BY_ID after the handshake: the holder hands nothing on and lets the sid go.
    outcome = nil;
    [world.a sendRequestByIDToFriendsID:@"brave-otter"
                                  frame:^NSData *(NSData *hash) {
                                      (void)hash;
                                      return SZFriendsEncodeFrame(
                                          [SZFriendsFrame frameWithType:SZFriendsFrameTypeReceived fields:@{}], NULL);
                                  }
                             completion:^(BOOL received) { outcome = @(received); }];
    EXPECT(SZFODWaitUntil(5, ^BOOL { return outcome != nil; }), "the exchange ends");
    EXPECT(!outcome.boolValue && holder.frames.count == 1 && sids.lastObject[1].closed, "nothing reached B");

    // A holder that takes no requests (no delegate method) answers nothing at all.
    world.b.delegate = world.delegateB;
    SZFriendsSignalingSession *nn = [[SZFriendsSignalingSession alloc] initNNInitiator];
    NSArray<SZFODChannel *> *pair = [SZFODChannel pair];
    [world.b receiveOpenVia:SZFriendsHostSignalViaFriendsID channel:pair[1]
                    payload:[nn openingMessageWithItems:@[] now:[NSDate date] error:NULL]];
    EXPECT(pair[1].closed && pair[1].sent.count == 0, "silence");
    world.b.delegate = holder;

    // The host's 5 opens an hour: the sixth is not even tried.
    for (int i = 0; i < 6; i++) {
        [world.a sendRequestByIDToFriendsID:@"brave-otter"
                                      frame:^NSData *(NSData *hash) {
                                          return RequestFrame(world.identityA, token, hash);
                                      }
                                 completion:^(BOOL received) { (void)received; }];
    }
    EXPECT(names.count == 5, "five opens by ID in the hour: %lu", (unsigned long)names.count);
    [world stop];
}

static void TestHolderCallback(void) {
    SZFODWorld *world = [[SZFODWorld alloc] initWithTransportFactory:^id<SZFriendsOnlineTransport> {
        return [SZFODFakeTransport new];
    }];
    SZFODByIDDelegate *requester = [SZFODByIDDelegate new];
    world.a.delegate = requester;
    NSData *token = SZFODRandom(16);
    // B accepted A's request: B dials A, presenting A's token; A does not hold B as a friend.
    SZFriendsOnlineFriend *asker = SZFODFriendFor(world.identityA, SZFODRandom(32));
    asker.requestToken = token;
    world.delegateB.friends[world.identityA.publicKey] = asker;
    SZFODFakeTransport *fakeA = (SZFODFakeTransport *)world.a.onlineContext.transport;

    // A's delegate does not admit B's key for that token (a request bound to another key): silence, nothing made.
    [world.b reachFriend:world.identityA.publicKey];
    EXPECT(SZFODWaitUntil(2, ^BOOL { return world.sids.count == 1 && world.sids[0][1].closed; }), "%@", world.sids);
    EXPECT([requester.tokensAsked isEqual:@[ token ]], "asked about the token B presented: %@", requester.tokensAsked);
    EXPECT(world.sids[0][1].sent.count == 0 && world.a.attempts.count == 0 && fakeA.requests.count == 0,
           "refused before any peer connection");
    [world stop];

    // Admitted: A answers as for a friend, with the static key B's certificate bound.
    world = [[SZFODWorld alloc] initWithTransportFactory:^id<SZFriendsOnlineTransport> {
        return [SZFODFakeTransport new];
    }];
    requester = [SZFODByIDDelegate new];
    world.a.delegate = requester;
    asker = SZFODFriendFor(world.identityA, SZFODRandom(32));
    asker.requestToken = token;
    world.delegateB.friends[world.identityA.publicKey] = asker;
    requester.answering[token] = SZFODFriendFor(world.identityB, SZFODRandom(32));
    fakeA = (SZFODFakeTransport *)world.a.onlineContext.transport;
    [world.b reachFriend:world.identityB.publicKey]; // B does not dial itself
    [world.b reachFriend:world.identityA.publicKey];
    EXPECT(SZFODWaitUntil(3, ^BOOL { return world.a.attempts.count == 1 && fakeA.requests.count == 1; }),
           "A answers B's callback: %lu", (unsigned long)world.a.attempts.count);
    EXPECT([world.a.attempts.firstObject.peer isEqualToData:world.identityB.publicKey]);
    EXPECT([fakeA.requests.firstObject.peer isEqualToData:world.identityB.publicKey], "bound to B");
    [world stop];

    // The driver's host connection is the one it was given.
    SZFriendsOnlineDriver *driver = [[SZFriendsOnlineDriver alloc] initWithIdentity:SZFODNewIdentity()
                                                                              queue:dispatch_get_main_queue()];
    NSObject *marker = [NSObject new];
    [driver setValue:marker forKey:@"_online"];
    EXPECT((id)driver.online == marker, "online reads the driver's own connection");
}

void SZFODTestByID(void) {
    TestRequestReachesHolder();
    TestHolderCallback();
}
