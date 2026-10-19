// One secure channel as the nearby orchestration tracks it (SZFriendsPeerLink.h).

#import "service/helper/nearby/SZFriendsPeerLink.h"

NSString *SZFriendsLinkHex(NSData *data) {
    static const char digits[] = "0123456789abcdef";
    const uint8_t *bytes = data.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) {
        [hex appendFormat:@"%c%c", digits[bytes[i] >> 4], digits[bytes[i] & 0x0f]];
    }
    return hex;
}

NSData *SZFriendsLinkBytesFromHex(NSString *hex) {
    // Ids this Mac issues are 32 lowercase hex digits (SZFriendsNewIdentifier); anything else never came from us
    // and never travels as a 16-byte wire ID.
    if (hex.length != 32) return nil;
    uint8_t bytes[16];
    for (NSUInteger i = 0; i < 16; i++) {
        int value = 0;
        for (NSUInteger j = 0; j < 2; j++) {
            unichar c = [hex characterAtIndex:i * 2 + j];
            int nibble = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1;
            if (nibble < 0) return nil;
            value = value * 16 + nibble;
        }
        bytes[i] = (uint8_t)value;
    }
    return [NSData dataWithBytes:bytes length:sizeof bytes];
}

@implementation SZFriendsPeerLink {
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *_acks;
}

- (instancetype)initWithChannel:(SZFriendsSecureChannel *)channel
                        purpose:(SZFriendsLinkPurpose)purpose
                          route:(SZFriendsRouteMethod)route {
    if ((self = [super init])) {
        _channel = channel;
        _purpose = purpose;
        _dialedRoute = route;
        _createdAt = [NSDate date];
        _inFlightEntries = [NSMutableSet set];
        _acks = [NSMutableDictionary dictionary];
        _senders = [NSMutableDictionary dictionary];
        _receivers = [NSMutableDictionary dictionary];
        _endedTransfers = [NSMutableSet set];
        _doneSent = [NSMutableSet set];
        _thumbnailsSent = [NSMutableSet set];
        _rateStart = [NSMutableDictionary dictionary];
        _sources = [NSMutableDictionary dictionary];
    }
    return self;
}

- (SZFriendsRouteMethod)raceRoute {
    SZFriendsRouteMethod route = self.channel.initiatorRoute;
    return route != SZFriendsRouteMethodNone ? route : self.dialedRoute;
}

- (nullable NSData *)initiatorKeyWithLocalKey:(NSData *)localIdentityKey {
    return self.channel.isInitiator ? localIdentityKey : self.channel.remoteIdentityKey;
}

- (void)expectAckForID:(NSString *)wireID token:(NSString *)token {
    NSMutableArray<NSString *> *queue = _acks[wireID];
    if (queue == nil) _acks[wireID] = queue = [NSMutableArray array];
    [queue addObject:token];
}

- (nullable NSString *)takeAckForID:(NSString *)wireID {
    NSMutableArray<NSString *> *queue = _acks[wireID];
    if (queue.count == 0) return nil;
    NSString *token = queue.firstObject;
    [queue removeObjectAtIndex:0];
    if (queue.count == 0) [_acks removeObjectForKey:wireID];
    return token;
}

- (BOOL)expectsAckForID:(NSString *)wireID {
    return _acks[wireID].count > 0;
}

- (void)cancelTimers {
    if (self.progressTimer != nil) dispatch_source_cancel(self.progressTimer);
    self.progressTimer = nil;
    for (NSFileHandle *file in self.sources.allValues) [file closeFile];
    [self.sources removeAllObjects];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<link %p purpose %ld route %ld %@%@>", (void *)self, (long)self.purpose,
                                      (long)self.raceRoute, self.live ? @"live" : @"handshaking",
                                      self.adopted ? @" adopted" : @""];
}

@end
