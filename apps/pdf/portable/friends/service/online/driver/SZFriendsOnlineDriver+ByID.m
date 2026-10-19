// Add by ID online (SZFriendsOnlineDriver.h; ADR 0004 step 1 through the host, ADR 0010 § Connection setup; lead
// decision 6): Noise NN over a sid opened to a Friends ID.
//
//   requester                          host                         holder of the ID
//   NN message 1 (Hello only) ---- sig_open to.friends_id ----> NN message 2 (Hello only)
//   REQUEST_BY_ID (Frame item) -------- sig_msg -------------> RECEIVED (Frame item), then the sid is let go
//
// Nothing else travels and nothing else is read: no description, no candidate, no attempt and no peer connection,
// whoever asks. The request's own signature and any invite proof are bound to this session's handshake hash
// (SZFriendsVerifyRequestByIDFrame, SZFriendsInviteProof), so a host running one NN session with each side cannot
// pass one off as the other. What the person does with the request is the helper's (the delegate's); once they
// accept, the holder dials the requester with IK presenting the request's token, which the requester admits only for
// a request of its own that admits that key (-friendAnsweringWithIdentityKey:token:).

#import "service/online/driver/SZFriendsOnlineDriverPrivate.h"

#import "service/host/SZFriendsHostRendezvous.h"

// The host's budget for opens by Friends ID (HOST-PROTOCOL-ONLINE.md § Limits): 5 an hour per identity. Opening a
// sixth would only be refused, so it is not tried.
static const NSUInteger kIDOpensPerHour = 5;
static const NSTimeInterval kIDOpenWindow = 3600;
const NSUInteger SZFriendsOnlineJoinOpensPerHour = 40;
// The holder lets go of its sid this long after RECEIVED, so the reply is forwarded before the sid ends.
static const NSTimeInterval kReceivedLinger = 2;
// Exchanges held at once, both ways: a flood of NN opens costs a handful of sessions, never more.
static const NSUInteger kIDExchangesMax = 8;
// NN message 1 ephemeral keys remembered; a replay cannot finish the handshake anyway.
static const NSUInteger kIDReplayCapacity = 256;

@interface SZFriendsOnlineIDExchange : NSObject
@property(nonatomic, strong) SZFriendsSignalingSession *session;
@property(nonatomic, strong, nullable) id<SZFriendsOnlineSignalChannel> channel;
@property(nonatomic) BOOL requester;
@property(nonatomic) BOOL requestSent; // requester: REQUEST_BY_ID went out, RECEIVED is awaited
@property(nonatomic, copy, nullable) NSData *_Nullable (^frame)(NSData *handshakeHash);
@property(nonatomic, copy, nullable) void (^completion)(BOOL received);
@property(nonatomic) NSUInteger step; // each step re-arms the timeout; a stale timer sees another step
@end

@implementation SZFriendsOnlineIDExchange
@end

// The one Frame item of a payload, decoded, or nil.
static SZFriendsFrame *SZFriendsOnlineFrameIn(NSArray<SZFriendsSignalItem *> *items) {
    SZFriendsFrame *found = nil;
    for (SZFriendsSignalItem *item in items) {
        if (item.type != SZFriendsSignalItemFrame) continue;
        NSData *bytes = [item dataForTag:SZFriendsSignalTagFrame];
        if (found != nil || bytes == nil) return nil;
        found = SZFriendsDecodeFrame(bytes, NULL);
    }
    return found;
}

static NSData *SZFriendsOnlineSealFrame(SZFriendsSignalingSession *session, NSData *encodedFrame) {
    if (encodedFrame.length == 0 || encodedFrame.length > SZFriendsSignalFrameMax) return nil;
    return [session sealItems:@[ [SZFriendsSignalItem frameItemWithData:encodedFrame] ] error:NULL];
}

@implementation SZFriendsOnlineDriver (ByID)

#pragma mark - Requester

- (void)sendRequestByIDToFriendsID:(NSString *)friendsID
                             frame:(NSData *_Nullable (^)(NSData *handshakeHash))frame
                        completion:(void (^)(BOOL received))completion {
    void (^done)(BOOL) = [completion copy];
    if (!self.available || friendsID.length == 0 || frame == nil || self.idExchanges.count >= kIDExchangesMax ||
        (self.testIDOpener == nil && self.online == nil) || ![self takeIDOpen]) {
        done(NO);
        return;
    }
    SZFriendsOnlineIDExchange *exchange = [SZFriendsOnlineIDExchange new];
    exchange.requester = YES;
    exchange.session = [[SZFriendsSignalingSession alloc] initNNInitiator];
    exchange.frame = frame;
    exchange.completion = done;
    NSData *message = [exchange.session openingMessageWithItems:@[] now:[NSDate date] error:NULL];
    if (message == nil) {
        done(NO);
        return;
    }
    if (self.idExchanges == nil) self.idExchanges = [NSMutableArray array];
    [self.idExchanges addObject:exchange];
    [self armTimeoutForExchange:exchange];
    __weak SZFriendsOnlineDriver *weakSelf = self;
    void (^opened)(id<SZFriendsOnlineSignalChannel>) = ^(id<SZFriendsOnlineSignalChannel> channel) {
        SZFriendsOnlineDriver *strongSelf = weakSelf;
        if (strongSelf == nil || channel == nil || ![strongSelf.idExchanges containsObject:exchange]) {
            [channel close];
            [strongSelf endExchange:exchange received:NO];
            return;
        }
        [strongSelf adoptChannel:channel forExchange:exchange];
    };
    if (self.testIDOpener != nil) {
        self.testIDOpener(friendsID, message, opened);
        return;
    }
    [self.online openToFriendsID:friendsID
                         payload:message
                      completion:^(SZFriendsHostSignal *signal, NSError *error) {
                          (void)error;
                          opened(signal ? SZFriendsOnlineChannelForSignal(signal) : nil);
                      }];
}

// One open from an hourly budget: NO once `perHour` went out within the last hour.
static BOOL SZFriendsOnlineTakeOpen(NSMutableArray<NSNumber *> *times, NSUInteger perHour, NSTimeInterval now) {
    NSIndexSet *old = [times indexesOfObjectsPassingTest:^BOOL(NSNumber *time, NSUInteger i, BOOL *stop) {
        (void)i;
        (void)stop;
        return now - time.doubleValue >= kIDOpenWindow;
    }];
    [times removeObjectsAtIndexes:old];
    if (times.count >= perHour) return NO;
    [times addObject:@(now)];
    return YES;
}

// At most the host's 5 an hour, counted here so a refused open is never sent.
- (BOOL)takeIDOpen {
    if (self.idOpenTimes == nil) self.idOpenTimes = [NSMutableArray array];
    return SZFriendsOnlineTakeOpen(self.idOpenTimes, kIDOpensPerHour, self.onlineContext.clock());
}

// Join opens (to.join) have the host's budget of their own, 40 an hour: joining never spends Add by ID's 5.
- (BOOL)takeJoinOpen {
    if (self.joinOpenTimes == nil) self.joinOpenTimes = [NSMutableArray array];
    return SZFriendsOnlineTakeOpen(self.joinOpenTimes, SZFriendsOnlineJoinOpensPerHour, self.onlineContext.clock());
}

- (void)requesterExchange:(SZFriendsOnlineIDExchange *)exchange receivedPayload:(NSData *)payload {
    SZFriendsSignalingSession *session = exchange.session;
    if (!exchange.requestSent) {
        // The holder's NN message 2: the hash both sides now share is what the request is signed over.
        NSData *hash = [session readReply:payload error:NULL] ? session.handshakeHash : nil;
        NSData *frame = hash ? exchange.frame(hash) : nil;
        NSData *sealed = frame ? SZFriendsOnlineSealFrame(session, frame) : nil;
        if (sealed == nil || ![exchange.channel sendPayload:sealed]) {
            [self endExchange:exchange received:NO];
            return;
        }
        exchange.requestSent = YES;
        [self armTimeoutForExchange:exchange];
        return;
    }
    NSArray<SZFriendsSignalItem *> *items = [session openPayload:payload error:NULL];
    SZFriendsFrame *frame = items ? SZFriendsOnlineFrameIn(items) : nil;
    [self endExchange:exchange received:frame.type == SZFriendsFrameTypeReceived];
}

#pragma mark - Holder

- (void)answerIDOpenWithChannel:(id<SZFriendsOnlineSignalChannel>)channel payload:(NSData *)payload {
    id<SZFriendsOnlineDriverDelegate> delegate = self.delegate;
    if (!self.available || self.idExchanges.count >= kIDExchangesMax ||
        ![delegate respondsToSelector:@selector(onlineDriver:receivedRequestByID:handshakeHash:)]) {
        [channel close];
        return;
    }
    if (self.idReplayCache == nil) {
        self.idReplayCache = [[SZFriendsReplayCache alloc] initWithCapacity:kIDReplayCapacity clock:nil];
    }
    NSArray<SZFriendsSignalItem *> *items = nil;
    // NN only: an IK message 1 sent by ID is refused like any other stranger's (the friend dials by key).
    SZFriendsSignalingSession *session =
        [SZFriendsSignalingSession responderForMessage:payload
                                              identity:self.onlineContext.identity
                                               allowed:@[ @(SZFriendsHandshakeNN) ]
                                           replayCache:self.idReplayCache
                                             keyPolicy:^BOOL(NSData *key, SZFriendsHandshakePattern pattern,
                                                             NSData *token) {
                                                 (void)key;
                                                 (void)token;
                                                 return pattern == SZFriendsHandshakeNN;
                                             }
                                                   now:[NSDate date]
                                                 items:&items
                                                 error:NULL];
    NSData *reply = session ? [session replyWithItems:@[] error:NULL] : nil;
    if (reply == nil) {
        [channel close];
        return;
    }
    SZFriendsOnlineIDExchange *exchange = [SZFriendsOnlineIDExchange new];
    exchange.session = session;
    if (self.idExchanges == nil) self.idExchanges = [NSMutableArray array];
    [self.idExchanges addObject:exchange];
    [self adoptChannel:channel forExchange:exchange];
    if (![channel sendPayload:reply]) {
        [self endExchange:exchange received:NO];
        return;
    }
    [self armTimeoutForExchange:exchange];
}

- (void)holderExchange:(SZFriendsOnlineIDExchange *)exchange receivedPayload:(NSData *)payload {
    SZFriendsSignalingSession *session = exchange.session;
    NSArray<SZFriendsSignalItem *> *items = [session openPayload:payload error:NULL];
    SZFriendsFrame *frame = items ? SZFriendsOnlineFrameIn(items) : nil;
    if (frame.type != SZFriendsFrameTypeRequestByID) {
        [self endExchange:exchange received:NO];
        return;
    }
    // RECEIVED before anything is looked at, the same bytes whatever follows (ADR 0004 step 2).
    NSData *received = SZFriendsEncodeFrame([SZFriendsFrame frameWithType:SZFriendsFrameTypeReceived fields:@{}], NULL);
    NSData *sealed = received ? SZFriendsOnlineSealFrame(session, received) : nil;
    if (sealed != nil) [exchange.channel sendPayload:sealed];
    id<SZFriendsOnlineSignalChannel> channel = exchange.channel;
    exchange.channel = nil;
    [self endExchange:exchange received:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kReceivedLinger * NSEC_PER_SEC)),
                   self.onlineContext.queue, ^{ [channel close]; });
    NSData *hash = session.handshakeHash;
    id<SZFriendsOnlineDriverDelegate> delegate = self.delegate;
    if (hash != nil && [delegate respondsToSelector:@selector(onlineDriver:receivedRequestByID:handshakeHash:)]) {
        [delegate onlineDriver:self receivedRequestByID:frame handshakeHash:hash];
    }
}

#pragma mark - Both

- (void)adoptChannel:(id<SZFriendsOnlineSignalChannel>)channel forExchange:(SZFriendsOnlineIDExchange *)exchange {
    exchange.channel = channel;
    __weak SZFriendsOnlineDriver *weakSelf = self;
    __weak SZFriendsOnlineIDExchange *weakExchange = exchange;
    channel.onPayload = ^(NSData *payload) {
        SZFriendsOnlineDriver *strongSelf = weakSelf;
        SZFriendsOnlineIDExchange *strongExchange = weakExchange;
        if (strongSelf == nil || strongExchange == nil || ![strongSelf.idExchanges containsObject:strongExchange]) {
            return;
        }
        if (strongExchange.requester) [strongSelf requesterExchange:strongExchange receivedPayload:payload];
        else [strongSelf holderExchange:strongExchange receivedPayload:payload];
    };
    channel.onEnd = ^{
        SZFriendsOnlineIDExchange *strongExchange = weakExchange;
        if (strongExchange != nil) [weakSelf endExchange:strongExchange received:NO];
    };
}

// Each step waits as long as an offer waits for its answer; silence past it ends the exchange.
- (void)armTimeoutForExchange:(SZFriendsOnlineIDExchange *)exchange {
    NSUInteger step = ++exchange.step;
    __weak SZFriendsOnlineDriver *weakSelf = self;
    __weak SZFriendsOnlineIDExchange *weakExchange = exchange;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SZFriendsOnlineAnswerTimeout * NSEC_PER_SEC)),
                   self.onlineContext.queue, ^{
                       SZFriendsOnlineIDExchange *strongExchange = weakExchange;
                       if (strongExchange != nil && strongExchange.step == step) {
                           [weakSelf endExchange:strongExchange received:NO];
                       }
                   });
}

- (void)endExchange:(SZFriendsOnlineIDExchange *)exchange received:(BOOL)received {
    if (exchange == nil || ![self.idExchanges containsObject:exchange]) return;
    [self.idExchanges removeObject:exchange];
    exchange.step++;
    id<SZFriendsOnlineSignalChannel> channel = exchange.channel;
    exchange.channel = nil;
    channel.onPayload = nil;
    channel.onEnd = nil;
    [channel close];
    void (^completion)(BOOL) = exchange.completion;
    exchange.completion = nil;
    if (completion) completion(received);
}

- (void)closeIDExchanges {
    for (SZFriendsOnlineIDExchange *exchange in [self.idExchanges copy]) [self endExchange:exchange received:NO];
}

#pragma mark - The holder's callback

- (SZFriendsOnlineFriend *)friendAnsweringWithIdentityKey:(NSData *)identityKey token:(NSData *)token {
    id<SZFriendsOnlineDriverDelegate> delegate = self.delegate;
    if (token.length != 16 || identityKey.length != 32 ||
        ![delegate respondsToSelector:@selector(onlineDriver:friendAnsweringWithIdentityKey:requestToken:)]) {
        return nil;
    }
    SZFriendsOnlineFriend *friend = [delegate onlineDriver:self friendAnsweringWithIdentityKey:identityKey
                                              requestToken:token];
    return [friend.identityKey isEqualToData:identityKey] ? friend : nil;
}

@end
