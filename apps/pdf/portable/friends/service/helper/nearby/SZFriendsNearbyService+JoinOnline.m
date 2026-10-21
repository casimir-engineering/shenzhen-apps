// Joining a profile through the Friends host (SZFriendsNearbyJoin.h, SZFriendsOnlineDriver (Join)).
//
// The new computer's request is the payload of an open to the Friends ID it typed: the host hands it to every device of
// that profile that is connected, nobody answers, and the host keeps nothing. Its code is an open too, carrying Noise
// NN message 1 (the signalling session Add by ID online uses); only a device holding an approval answers, so the run
// happens with it alone, and every JOIN frame after message 2 travels sealed in that session, at most three to a
// payload. Messages, approvals and attempts are the same objects as nearby (+Join), through a pipe.

#import "service/helper/nearby/SZFriendsNearbyJoin.h"

#import "service/session/SZFriendsSignaling.h"
#import "service/store/SZFriendsStoreDevices.h"

static const NSUInteger kFramesPerPayload = 3; // 3 x (1,000 + headers) stays under a sid's 4,096-byte payload
static const NSTimeInterval kOnlineLinger = 2; // the last payloads leave the host before the sid closes
static const NSUInteger kReplayCapacity = 64;

// One sid carrying a run, either side.
@interface SZFriendsJoinSidPipe : NSObject <SZFriendsJoinPipe>
@property(nonatomic, weak) SZFriendsNearbyService *service;
@property(nonatomic, strong) SZFriendsSignalingSession *session;
@property(nonatomic, strong, nullable) id<SZFriendsOnlineJoinChannel> channel;
@property(nonatomic) BOOL initiator;
@end

@implementation SZFriendsJoinSidPipe

- (NSData *)handshakeHash {
    return self.session.handshakeHash;
}

- (BOOL)sendJoinMessages:(NSArray<NSData *> *)messages {
    for (NSUInteger start = 0; start < messages.count; start += kFramesPerPayload) {
        NSMutableArray<SZFriendsSignalItem *> *items = [NSMutableArray array];
        for (NSUInteger i = start; i < MIN(messages.count, start + kFramesPerPayload); i++) {
            SZFriendsFrame *frame = [SZFriendsFrame frameWithType:SZFriendsFrameTypeJoin
                                                           fields:@{@(SZFriendsFieldJoin) : messages[i]}];
            NSData *encoded = SZFriendsEncodeFrame(frame, NULL);
            if (encoded == nil) return NO;
            [items addObject:[SZFriendsSignalItem frameItemWithData:encoded]];
        }
        NSData *sealed = [self.session sealItems:items error:NULL];
        if (sealed == nil || ![self.channel sendPayload:sealed]) return NO;
    }
    return YES;
}

- (void)sendReceived {
    // Online, the answer every device gives is silence.
}

- (void)finish {
    id<SZFriendsOnlineJoinChannel> channel = self.channel;
    self.channel = nil;
    if (channel == nil) return;
    channel.onPayload = nil;
    channel.onEnd = nil;
    SZFriendsNearbyService *service = self.service;
    [service pipeEnded:self];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kOnlineLinger * NSEC_PER_SEC)),
                   service ? service.queue : dispatch_get_main_queue(), ^{ [channel close]; });
}

// Every JOIN frame of one sealed payload, in order; nil for a payload that does not open.
- (nullable NSArray<NSData *> *)messagesInPayload:(NSData *)payload {
    NSArray<SZFriendsSignalItem *> *items = [self.session openPayload:payload error:NULL];
    if (items == nil) return nil;
    NSMutableArray<NSData *> *messages = [NSMutableArray array];
    for (SZFriendsSignalItem *item in items) {
        NSData *bytes = item.type == SZFriendsSignalItemFrame ? [item dataForTag:SZFriendsSignalTagFrame] : nil;
        SZFriendsFrame *frame = bytes ? SZFriendsDecodeFrame(bytes, NULL) : nil;
        NSData *message = frame.type == SZFriendsFrameTypeJoin ? [frame dataForTag:SZFriendsFieldJoin] : nil;
        if (message == nil) return nil;
        [messages addObject:message];
    }
    return messages;
}

@end

static NSData *SZFriendsJoinOpenPayload(uint8_t kind, NSData *body) {
    NSMutableData *payload = [NSMutableData dataWithBytes:(uint8_t[]){SZFriendsJoinOpenPrefix, kind} length:2];
    [payload appendData:body];
    return payload;
}

@implementation SZFriendsNearbyService (JoinOnline)

- (void)openJoinPayload:(NSData *)payload
             completion:(void (^)(id<SZFriendsOnlineJoinChannel> _Nullable channel))completion {
    SZFriendsJoinState *state = self.joinState;
    NSString *friendsID = state.joiner.friendsID;
    if (friendsID == nil) {
        completion(nil);
    } else if (state.testOpener != nil) {
        state.testOpener(friendsID, payload, completion);
    } else if (self.onlineDriver.available) {
        [self.onlineDriver openJoinToFriendsID:friendsID payload:payload completion:completion];
    } else {
        completion(nil);
    }
}

- (BOOL)joinCanGoOnline {
    return self.joinState.testOpener != nil || self.onlineDriver.available;
}

#pragma mark - The new computer

- (void)offerJoinOnline {
    SZFriendsJoinState *state = self.joinState;
    SZFriendsJoiningState phase = state.phase;
    BOOL waiting = phase == SZFriendsJoiningWaiting || phase == SZFriendsJoiningWrongCode ||
                   phase == SZFriendsJoiningNotReached;
    NSDate *last = state.requestSentOnlineAt;
    if (state.joiner == nil || !waiting || self.shutDown || self.resetting || ![self joinCanGoOnline] ||
        (last != nil && -last.timeIntervalSinceNow < SZFriendsJoinOnlineRepeat)) {
        return;
    }
    NSData *request = [state.joiner requestMessageAtDate:[NSDate date]];
    if (request == nil) return;
    state.requestSentOnlineAt = [NSDate date];
    NSUInteger generation = state.generation;
    __weak SZFriendsNearbyService *weakSelf = self;
    [self openJoinPayload:SZFriendsJoinOpenPayload(SZFriendsJoinOpenRequest, request)
               completion:^(id<SZFriendsOnlineJoinChannel> channel) {
                   // Nobody answers a request: the open itself was the message.
                   [channel close];
                   SZFriendsJoinState *current = weakSelf.joinState;
                   // Not sent (the hour's opens are spent, or the host refused): tried again in a minute.
                   if (channel == nil && current.generation == generation) {
                       current.requestSentOnlineAt =
                           [NSDate dateWithTimeIntervalSinceNow:60 - SZFriendsJoinOnlineRepeat];
                   }
               }];
}

- (void)sendJoinCodeOnline {
    SZFriendsJoinState *state = self.joinState;
    if (state.joiner == nil || state.phase != SZFriendsJoiningChecking || ![self joinCanGoOnline]) return;
    SZFriendsJoinSidPipe *pipe = [SZFriendsJoinSidPipe new];
    pipe.service = self;
    pipe.initiator = YES;
    pipe.session = [[SZFriendsSignalingSession alloc] initNNInitiator];
    NSData *opening = [pipe.session openingMessageWithItems:@[] now:[NSDate date] error:NULL];
    if (opening == nil) return;
    NSUInteger generation = state.generation;
    __weak SZFriendsNearbyService *weakSelf = self;
    [self openJoinPayload:SZFriendsJoinOpenPayload(SZFriendsJoinOpenCode, opening)
               completion:^(id<SZFriendsOnlineJoinChannel> channel) {
                   SZFriendsNearbyService *strongSelf = weakSelf;
                   if (strongSelf == nil || channel == nil || strongSelf.joinState.generation != generation) {
                       [channel close];
                       return;
                   }
                   [strongSelf adoptJoinChannel:channel pipe:pipe];
               }];
}

#pragma mark - Every computer of the person

- (void)receiveJoinOpenPayload:(NSData *)payload channel:(id<SZFriendsOnlineJoinChannel>)channel {
    const uint8_t *bytes = payload.bytes;
    NSData *body = payload.length > 2 ? [payload subdataWithRange:NSMakeRange(2, payload.length - 2)] : nil;
    if (body == nil || bytes[0] != SZFriendsJoinOpenPrefix || self.shutDown || self.resetting ||
        self.services.store == nil || self.services.identity == nil) {
        [channel close];
        return;
    }
    if (bytes[1] == SZFriendsJoinOpenRequest) {
        [channel close];
        if (SZFriendsJoinMessageKindOf(body) != SZFriendsJoinMessageRequest) return;
        SZFriendsStore *store = self.services.store;
        SZFriendsJoinApprover *approver = self.joinState.approver;
        if (approver == nil) {
            approver = [[SZFriendsJoinApprover alloc] initWithIdentity:self.services.identity];
            self.joinState.approver = approver;
        }
        SZFriendsJoinReceipt receipt = [approver receiveRequestMessage:body ownFriendsID:store.friendsID
                                                                 chain:store.ownDeviceChain now:[NSDate date]
                                                           endedReason:NULL];
        if (receipt == SZFriendsJoinReceiptAdded) [self notifyJoinRequests];
        if (receipt == SZFriendsJoinReceiptAdded || receipt == SZFriendsJoinReceiptRefreshed) [self changed];
        return;
    }
    if (bytes[1] != SZFriendsJoinOpenCode || ![self holdsJoinApproval]) {
        [channel close]; // silence: to the caller, a device without an approval is nobody
        return;
    }
    SZFriendsJoinState *state = self.joinState;
    if (state.replayCache == nil) {
        state.replayCache = [[SZFriendsReplayCache alloc] initWithCapacity:kReplayCapacity clock:nil];
    }
    NSArray<SZFriendsSignalItem *> *items = nil;
    SZFriendsSignalingSession *session =
        [SZFriendsSignalingSession responderForMessage:body
                                              identity:self.services.identity
                                               allowed:@[ @(SZFriendsHandshakeNN) ]
                                           replayCache:state.replayCache
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
    if (reply == nil || ![channel sendPayload:reply]) {
        [channel close];
        return;
    }
    SZFriendsJoinSidPipe *pipe = [SZFriendsJoinSidPipe new];
    pipe.service = self;
    pipe.session = session;
    pipe.initiator = NO;
    [self adoptJoinChannel:channel pipe:pipe];
}

- (BOOL)holdsJoinApproval {
    SZFriendsJoinApprover *approver = self.joinState.approver;
    for (SZFriendsJoinRequest *request in [approver openRequestsWithChain:self.services.store.ownDeviceChain
                                                                      now:[NSDate date]]) {
        if (request.state == SZFriendsJoinRequestApproved) return YES;
    }
    return NO;
}

- (void)adoptJoinChannel:(id<SZFriendsOnlineJoinChannel>)channel pipe:(SZFriendsJoinSidPipe *)pipe {
    pipe.channel = channel;
    __weak SZFriendsNearbyService *weakSelf = self;
    __weak SZFriendsJoinSidPipe *weakPipe = pipe;
    __block SZFriendsJoinSidPipe *held = pipe; // the channel's blocks keep the pipe until it ends
    channel.onPayload = ^(NSData *payload) {
        SZFriendsNearbyService *strongSelf = weakSelf;
        SZFriendsJoinSidPipe *strongPipe = weakPipe;
        if (strongSelf == nil || strongPipe == nil || strongPipe.channel == nil) return;
        [strongSelf joinPipe:strongPipe receivedPayload:payload];
    };
    channel.onEnd = ^{
        SZFriendsJoinSidPipe *strongPipe = held;
        held = nil;
        if (strongPipe.channel != nil) {
            strongPipe.channel = nil;
            [weakSelf pipeEnded:strongPipe];
        }
    };
}

- (void)joinPipe:(SZFriendsJoinSidPipe *)pipe receivedPayload:(NSData *)payload {
    SZFriendsSignalingSession *session = pipe.session;
    if (pipe.initiator && !session.established) {
        // The approving device's message 2: the hash both now share is what the code's run is bound to.
        if ([session readReply:payload error:NULL] == nil) [pipe finish];
        else [self beginCodeLegOnPipe:pipe];
        return;
    }
    NSArray<NSData *> *messages = [pipe messagesInPayload:payload];
    if (messages == nil) {
        [pipe finish];
        return;
    }
    for (NSData *message in messages) {
        if (pipe.channel == nil) return;
        [self pipe:pipe receivedJoinMessage:message initiator:pipe.initiator];
    }
}

#pragma mark - The driver's delegate

- (void)onlineDriver:(SZFriendsOnlineDriver *)driver
    receivedJoinPayload:(NSData *)payload
                channel:(id<SZFriendsOnlineJoinChannel>)channel {
    (void)driver;
    [self receiveJoinOpenPayload:payload channel:channel];
}

@end
