// Small pieces the attempts use (SZFriendsOnlineDriverInternal.h): requests, relay credentials, URIs, the host sid as
// a signal channel, and the tracked stream.

#import "service/online/driver/SZFriendsOnlineDriverPrivate.h"

#include <netdb.h>

#import "service/host/SZFriendsHostRendezvous.h"
#import "service/online/nat/SZFriendsNAT.h"
#import "service/online/nat/SZFriendsNATRoute.h"

const NSTimeInterval SZFriendsOnlineAnswerTimeout = 15;
const NSTimeInterval SZFriendsOnlineBackoffFirst = 30;
const NSTimeInterval SZFriendsOnlineBackoffMax = 900;
const NSUInteger SZFriendsOnlineConnectionsMax = 250;

@implementation SZFriendsOnlineFriend
@end

@implementation SZFriendsOnlineRequest
@end

@implementation SZFriendsOnlineRelayCredentialsValue
@end

#pragma mark - URIs

NSString *SZFriendsOnlineFirstTURNOverUDP(NSArray<NSString *> *uris) {
    for (NSString *uri in uris) {
        if (![uri isKindOfClass:[NSString class]] || ![uri hasPrefix:@"turn:"]) continue;
        NSRange query = [uri rangeOfString:@"?"];
        if (query.location == NSNotFound) return uri;
        if ([[uri substringFromIndex:query.location] isEqualToString:@"?transport=udp"]) return uri;
    }
    return nil;
}

BOOL SZFriendsOnlineSplitSTUNURI(NSString *uri, NSString **host, uint16_t *port) {
    if (![uri isKindOfClass:[NSString class]] || ![uri hasPrefix:@"stun:"] || [uri containsString:@"?"]) return NO;
    NSString *rest = [uri substringFromIndex:5];
    NSString *name = rest, *number = nil;
    if ([rest hasPrefix:@"["]) {
        NSRange close = [rest rangeOfString:@"]"];
        if (close.location == NSNotFound) return NO;
        name = [rest substringWithRange:NSMakeRange(1, close.location - 1)];
        NSString *tail = [rest substringFromIndex:close.location + 1];
        if (tail.length > 0) {
            if (![tail hasPrefix:@":"]) return NO;
            number = [tail substringFromIndex:1];
        }
    } else {
        NSArray<NSString *> *parts = [rest componentsSeparatedByString:@":"];
        if (parts.count > 2) return NO;
        name = parts[0];
        if (parts.count == 2) number = parts[1];
    }
    NSInteger value = number ? number.integerValue : 3478;
    BOOL canonical = number == nil || [number isEqualToString:[NSString stringWithFormat:@"%ld", (long)value]];
    if (name.length == 0 || name.length > 253 || !canonical || value <= 0 || value > 65535) return NO;
    *host = name;
    *port = (uint16_t)value;
    return YES;
}

NSArray<SZFriendsNATEndpoint *> *SZFriendsOnlineResolveSTUNURIs(NSArray<NSString *> *uris) {
    NSMutableArray<SZFriendsNATEndpoint *> *endpoints = [NSMutableArray array];
    for (NSString *uri in uris) {
        NSString *host = nil;
        uint16_t port = 0;
        if (!SZFriendsOnlineSplitSTUNURI(uri, &host, &port)) continue;
        SZFriendsNATEndpoint *endpoint = [SZFriendsNATEndpoint endpointWithHost:host port:port];
        if (endpoint == nil) {
            // UDP, first answer: the host's names have A and AAAA records, and the system orders them.
            struct addrinfo hints = {.ai_family = AF_UNSPEC, .ai_socktype = SOCK_DGRAM, .ai_flags = AI_ADDRCONFIG};
            struct addrinfo *found = NULL;
            if (getaddrinfo(host.UTF8String, NULL, &hints, &found) == 0 && found != NULL) {
                endpoint = [[SZFriendsNATEndpoint endpointWithSockaddr:found->ai_addr length:found->ai_addrlen]
                    endpointWithPort:port];
            }
            if (found != NULL) freeaddrinfo(found);
        }
        if (endpoint != nil) [endpoints addObject:endpoint];
    }
    return endpoints;
}

NSString *SZFriendsOnlineNetworkSignature(void) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSNumber *family in @[ @(AF_INET), @(AF_INET6) ]) {
        SZFriendsNATRoute *route = [SZFriendsNATRoute defaultRouteForFamily:(sa_family_t)family.intValue];
        [parts addObject:route ? [NSString stringWithFormat:@"%@|%@|%@", route.interfaceName,
                                                            route.gateway.host ?: @"-", route.localAddress.host ?: @"-"]
                               : @"none"];
    }
    return [parts componentsJoinedByString:@" "];
}

NSString *SZFriendsOnlineNumericSTUNURI(SZFriendsNATEndpoint *endpoint) {
    NSString *host = endpoint.family == AF_INET6 ? [NSString stringWithFormat:@"[%@]", endpoint.host] : endpoint.host;
    return [NSString stringWithFormat:@"stun:%@:%u", host, endpoint.port];
}

#pragma mark - The host sid

@interface SZFriendsOnlineHostChannel : NSObject <SZFriendsOnlineSignalChannel>
@property(nonatomic, strong) SZFriendsHostSignal *signal;
@end

@implementation SZFriendsOnlineHostChannel

@synthesize onPayload = _onPayload;
@synthesize onEnd = _onEnd;

- (BOOL)ended {
    return self.signal.ended;
}

- (BOOL)sendPayload:(NSData *)payload {
    return [self.signal sendPayload:payload];
}

- (void)close {
    [self.signal close];
}

- (void)requestRelayCredentials:(void (^)(id<SZFriendsOnlineRelayCredentials>, NSError *))completion {
    [self.signal requestRelayCredentials:^(SZFriendsHostRelayCredentials *credentials, NSError *error) {
        NSString *uri = credentials ? SZFriendsOnlineFirstTURNOverUDP(credentials.turnURIs) : nil;
        if (uri == nil) {
            completion(nil, error ?: [NSError errorWithDomain:SZFriendsOnlineErrorDomain
                                                         code:SZFriendsOnlineErrorRelayRefused
                                                     userInfo:nil]);
            return;
        }
        SZFriendsOnlineRelayCredentialsValue *value = [SZFriendsOnlineRelayCredentialsValue new];
        value.turnURI = uri;
        value.username = credentials.username;
        value.credential = credentials.credential;
        value.expires = credentials.expires;
        completion(value, nil);
    }];
}

@end

id<SZFriendsOnlineSignalChannel> SZFriendsOnlineChannelForSignal(SZFriendsHostSignal *signal) {
    SZFriendsOnlineHostChannel *channel = [SZFriendsOnlineHostChannel new];
    channel.signal = signal;
    __weak SZFriendsOnlineHostChannel *weakChannel = channel;
    signal.onPayload = ^(NSData *payload) {
        SZFriendsOnlineHostChannel *strong = weakChannel;
        if (strong.onPayload) strong.onPayload(payload);
    };
    signal.onEnd = ^(SZFriendsHostSignalEnd reason) {
        (void)reason; // why matters to nobody here: an ended sid is a sid that carries nothing more
        SZFriendsOnlineHostChannel *strong = weakChannel;
        if (strong.onEnd) strong.onEnd();
    };
    return channel;
}

#pragma mark - The tracked stream

@interface SZFriendsOnlineTrackedStream : NSObject <SZFriendsByteStream>
@property(nonatomic, strong) id<SZFriendsByteStream> inner;
@property(nonatomic, copy, nullable) void (^closed)(void);
@end

@implementation SZFriendsOnlineTrackedStream

@synthesize onData = _onData;
@synthesize onClose = _onClose;

- (NSUInteger)preferredWriteSize {
    return self.inner.preferredWriteSize;
}

- (void)noteClosed {
    void (^closed)(void) = self.closed;
    self.closed = nil;
    if (closed) closed();
}

- (void)startWithQueue:(dispatch_queue_t)queue {
    __weak SZFriendsOnlineTrackedStream *weakSelf = self;
    self.inner.onData = ^(NSData *data) {
        SZFriendsOnlineTrackedStream *strong = weakSelf;
        if (strong.onData) strong.onData(data);
    };
    self.inner.onClose = ^(NSError *error) {
        SZFriendsOnlineTrackedStream *strong = weakSelf;
        void (^onClose)(NSError *) = strong.onClose;
        [strong noteClosed];
        if (onClose) onClose(error);
    };
    [self.inner startWithQueue:queue];
}

- (void)writeData:(NSData *)data completion:(void (^)(NSError *))completion {
    [self.inner writeData:data completion:completion];
}

- (void)close {
    [self.inner close];
    [self noteClosed];
}

@end

id<SZFriendsByteStream> SZFriendsOnlineTrackStream(id<SZFriendsByteStream> stream, void (^onClose)(void)) {
    SZFriendsOnlineTrackedStream *tracked = [SZFriendsOnlineTrackedStream new];
    tracked.inner = stream;
    tracked.closed = onClose;
    return tracked;
}

BOOL SZFriendsOnlineKeySortsFirst(NSData *key, NSData *other) {
    NSUInteger length = MIN(key.length, other.length);
    int order = memcmp(key.bytes, other.bytes, length);
    return order < 0 || (order == 0 && key.length < other.length);
}
