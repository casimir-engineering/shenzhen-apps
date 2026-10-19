// Joining a profile through the host (SZFriendsOnlineDriver.h, SZFriendsOnlineDriver (Join); PROTOCOL.md § Joining).
//
//   new computer                       host                          the person's computers
//   sig_open to.join, 'J' 1 ---------------------------------> sig_incoming to each connected one; nobody answers
//   sig_open to.join, 'J' 2 + NN message 1 ------------------> the one that approved answers NN message 2; the
//                                                             others stay silent, which is nobody to the caller
//
// The host forwards opens by Friends ID to every device of the identity holding it (HOST-PROTOCOL-ONLINE.md § Several
// devices), keeps nothing, and counts them against the caller's join opens (40 an hour, apart from Add by ID's 5).
// Here nothing is read: join payloads go to the helper, which answers or closes. They never reach Add by ID's NN
// responder, and Add by ID's never reach the helper's join code, because a join payload starts with 'J' where a
// signalling message 1 starts with 'S'.

#import "service/online/driver/SZFriendsOnlineDriverPrivate.h"

#import "service/host/SZFriendsHostRendezvous.h"

static const uint8_t kJoinPrefix = 'J';

// A driver channel as joining sees it: the same sid, without relay credentials, which joining never asks for.
@interface SZFriendsOnlineJoinChannelBox : NSObject <SZFriendsOnlineJoinChannel>
- (instancetype)initWithChannel:(id<SZFriendsOnlineSignalChannel>)channel;
@end

@implementation SZFriendsOnlineJoinChannelBox {
    id<SZFriendsOnlineSignalChannel> _channel;
}

- (instancetype)initWithChannel:(id<SZFriendsOnlineSignalChannel>)channel {
    self = [super init];
    if (self != nil) _channel = channel;
    return self;
}

- (void (^)(NSData *))onPayload {
    return _channel.onPayload;
}

- (void)setOnPayload:(void (^)(NSData *))onPayload {
    _channel.onPayload = onPayload;
}

- (void (^)(void))onEnd {
    return _channel.onEnd;
}

- (void)setOnEnd:(void (^)(void))onEnd {
    _channel.onEnd = onEnd;
}

- (BOOL)sendPayload:(NSData *)payload {
    return [_channel sendPayload:payload];
}

- (void)close {
    _channel.onPayload = nil;
    _channel.onEnd = nil;
    [_channel close];
}

@end

@implementation SZFriendsOnlineDriver (Join)

- (void)routeIDOpenWithChannel:(id<SZFriendsOnlineSignalChannel>)channel payload:(NSData *)payload {
    if (payload.length < 2 || ((const uint8_t *)payload.bytes)[0] != kJoinPrefix) {
        [self answerIDOpenWithChannel:channel payload:payload];
        return;
    }
    id<SZFriendsOnlineDriverDelegate> delegate = self.delegate;
    if (![delegate respondsToSelector:@selector(onlineDriver:receivedJoinPayload:channel:)]) {
        [channel close];
        return;
    }
    [delegate onlineDriver:self
        receivedJoinPayload:payload
                    channel:[[SZFriendsOnlineJoinChannelBox alloc] initWithChannel:channel]];
}

- (void)routeOpenVia:(SZFriendsHostSignalVia)via
             channel:(id<SZFriendsOnlineSignalChannel>)channel
             payload:(NSData *)payload {
    // A to.join open is joining or nothing: anything but a join payload is silence.
    BOOL joinPayload = payload.length >= 2 && ((const uint8_t *)payload.bytes)[0] == kJoinPrefix;
    if (via == SZFriendsHostSignalViaJoin && !joinPayload) {
        [channel close];
        return;
    }
    [self routeIDOpenWithChannel:channel payload:payload];
}

- (void)openJoinToFriendsID:(NSString *)friendsID
                    payload:(NSData *)payload
                 completion:(void (^)(id<SZFriendsOnlineJoinChannel> _Nullable channel))completion {
    void (^done)(id<SZFriendsOnlineJoinChannel>) = [completion copy];
    BOOL wellFormed = payload.length >= 2 && payload.length <= SZFriendsHostSignalPayloadMax &&
                      ((const uint8_t *)payload.bytes)[0] == kJoinPrefix && friendsID.length > 0;
    if (!self.available || !wellFormed || (self.testIDOpener == nil && self.online == nil) || ![self takeJoinOpen]) {
        done(nil);
        return;
    }
    void (^opened)(id<SZFriendsOnlineSignalChannel>) = ^(id<SZFriendsOnlineSignalChannel> channel) {
        done(channel ? [[SZFriendsOnlineJoinChannelBox alloc] initWithChannel:channel] : nil);
    };
    if (self.testIDOpener != nil) {
        self.testIDOpener(friendsID, payload, opened);
        return;
    }
    // to.join (protocol 3): the host hands it to every connected device of the ID's holder, under a budget of its own.
    [self.online openToJoinFriendsID:friendsID
                             payload:payload
                          completion:^(SZFriendsHostSignal *signal, NSError *error) {
                              (void)error;
                              opened(signal ? SZFriendsOnlineChannelForSignal(signal) : nil);
                          }];
}

@end
