// Connection setup over the host (SZFriendsHostRendezvous.h; HOST-PROTOCOL-ONLINE.md § Connection setup, § Relay
// credentials): opens, incoming opens, the payloads that follow, closes, and TURN credentials for a sid. The host
// answers an open at once whatever exists, and a target that does not answer is never reported, so nothing here
// waits for one: the order component's own timers decide when to give up.

#import "service/host/SZFriendsHostRendezvousInternal.h"

#import "service/host/SZFriendsHostInternal.h"

#import <os/log.h>

@interface SZFriendsHostRelayCredentials ()
@property(nonatomic, readwrite) NSArray<NSString *> *turnURIs;
@property(nonatomic, readwrite) NSString *username;
@property(nonatomic, readwrite) NSString *credential;
@property(nonatomic, readwrite) NSDate *expires;
@end

@implementation SZFriendsHostRelayCredentials
@end

@implementation SZFriendsHostSignal {
    __weak SZFriendsHostOnline *_online;
    NSUInteger _sent;
}

- (instancetype)initWithOnline:(SZFriendsHostOnline *)online
                           sid:(NSString *)sid
                           via:(SZFriendsHostSignalVia)via
                      incoming:(BOOL)incoming
                        linkID:(NSData *)linkID
                   ownerOnline:(BOOL)ownerOnline {
    if ((self = [super init])) {
        _online = online;
        _sid = [sid copy];
        _via = via;
        _incoming = incoming;
        _linkID = [linkID copy];
        _ownerOnline = ownerOnline;
    }
    return self;
}

- (BOOL)sendPayload:(NSData *)payload {
    SZFriendsHostOnline *online = _online;
    if (online) dispatch_assert_queue_debug(online->_queue);
    if (_ended || online == nil || payload.length == 0 || payload.length > SZFriendsHostSignalPayloadMax ||
        _sent >= SZFriendsHostSignalMessagesMax) {
        return NO;
    }
    if (![online sendType:@"sig_msg" fields:@{@"sid" : _sid, @"payload" : SZFriendsHostBase64URLEncode(payload)}]) {
        return NO;
    }
    _sent += 1;
    return YES;
}

- (void)close {
    SZFriendsHostOnline *online = _online;
    if (_ended) return;
    _ended = YES;
    _onPayload = nil;
    _onEnd = nil;
    if (online == nil) return;
    [online->_signals removeObjectForKey:_sid];
    [online sendType:@"sig_close" fields:@{@"sid" : _sid}];
}

- (void)endWithReason:(SZFriendsHostSignalEnd)reason {
    if (_ended) return;
    _ended = YES;
    void (^onEnd)(SZFriendsHostSignalEnd) = _onEnd;
    _onPayload = nil;
    _onEnd = nil;
    if (onEnd) onEnd(reason);
}

- (void)deliver:(NSData *)payload {
    if (!_ended && _onPayload) _onPayload(payload);
}

- (void)requestRelayCredentials:(void (^)(SZFriendsHostRelayCredentials *, NSError *))completion {
    SZFriendsHostOnline *online = _online;
    // relay_credentials for a sid the host does not know closes the whole connection, so an ended sid never asks.
    if (_ended || online == nil || !online->_available) {
        completion(nil, SZFriendsHostOnlineMakeError(_ended ? SZFriendsHostOnlineErrorInvalid
                                                            : SZFriendsHostOnlineErrorUnavailable,
                                                     @"Relay credentials need a live sid on an online host."));
        return;
    }
    SZFriendsHostPending *pending = [[SZFriendsHostPending alloc] init];
    pending.kind = @"credentials";
    pending.completion = completion;
    pending.signal = self;
    NSInteger req = [online addPending:pending];
    [online sendType:@"relay_credentials" fields:@{@"req" : @(req), @"sid" : _sid}];
}

@end

static BOOL SZFriendsHostValidSid(id value) {
    return SZFriendsHostBase64URLDecode(value, 16) != nil;
}

@implementation SZFriendsHostOnline (Signaling)

#pragma mark - Opening

- (void)openTo:(NSDictionary<NSString *, id> *)to
           via:(SZFriendsHostSignalVia)via
        linkID:(NSData *)linkID
       payload:(NSData *)payload
    completion:(void (^)(SZFriendsHostSignal *, NSError *))completion {
    dispatch_assert_queue_debug(_queue);
    if (to == nil || payload.length == 0 || payload.length > SZFriendsHostSignalPayloadMax || !_available) {
        completion(nil, SZFriendsHostOnlineMakeError(to && payload.length > 0 &&
                                                             payload.length <= SZFriendsHostSignalPayloadMax
                                                         ? SZFriendsHostOnlineErrorUnavailable
                                                         : SZFriendsHostOnlineErrorInvalid,
                                                     @"An open needs a target, a payload and an online host."));
        return;
    }
    SZFriendsHostPending *pending = [[SZFriendsHostPending alloc] init];
    pending.kind = @"open";
    pending.completion = completion;
    pending.via = via;
    pending.linkID = linkID;
    NSInteger req = [self addPending:pending];
    [self sendType:@"sig_open"
            fields:@{@"req" : @(req), @"to" : to, @"payload" : SZFriendsHostBase64URLEncode(payload)}];
}

- (void)openToRendezvousKey:(NSData *)rdvKey
                    payload:(NSData *)payload
                 completion:(void (^)(SZFriendsHostSignal *, NSError *))completion {
    NSDictionary *to = rdvKey.length == 32 ? @{@"rdv_key" : SZFriendsHostBase64URLEncode(rdvKey)} : nil;
    [self openTo:to via:SZFriendsHostSignalViaRendezvous linkID:nil payload:payload completion:completion];
}

- (void)openToFriendsID:(NSString *)friendsID
                payload:(NSData *)payload
             completion:(void (^)(SZFriendsHostSignal *, NSError *))completion {
    NSDictionary *to = friendsID.length > 0 && friendsID.length <= 64 ? @{@"friends_id" : friendsID} : nil;
    [self openTo:to via:SZFriendsHostSignalViaFriendsID linkID:nil payload:payload completion:completion];
}

- (void)openToJoinFriendsID:(NSString *)friendsID
                    payload:(NSData *)payload
                 completion:(void (^)(SZFriendsHostSignal *, NSError *))completion {
    NSDictionary *to = friendsID.length > 0 && friendsID.length <= 64 ? @{@"join" : friendsID} : nil;
    [self openTo:to via:SZFriendsHostSignalViaJoin linkID:nil payload:payload completion:completion];
}

- (void)openToLinkID:(NSData *)linkID
             payload:(NSData *)payload
          completion:(void (^)(SZFriendsHostSignal *, NSError *))completion {
    NSDictionary *to = linkID.length == 16 ? @{@"link_id" : SZFriendsHostBase64URLEncode(linkID)} : nil;
    [self openTo:to via:SZFriendsHostSignalViaLink linkID:linkID payload:payload completion:completion];
}

@end

@implementation SZFriendsHostOnline (SignalingInternal)

#pragma mark - Messages from the host

- (BOOL)receiveSignalingMessage:(NSDictionary<NSString *, id> *)message type:(NSString *)type {
    static NSSet<NSString *> *types;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        types = [NSSet setWithArray:@[ @"sig_opened", @"sig_refused", @"sig_incoming", @"sig_msg", @"sig_closed",
                                       @"relay_credentials_result", @"relay_refused" ]];
    });
    if (![types containsObject:type]) return NO;
    if (!_available) return YES;
    if ([type isEqualToString:@"sig_opened"] || [type isEqualToString:@"sig_refused"]) {
        [self receiveOpened:message refused:[type isEqualToString:@"sig_refused"]];
    } else if ([type isEqualToString:@"sig_incoming"]) {
        [self receiveIncoming:message];
    } else if ([type isEqualToString:@"sig_msg"]) {
        NSData *payload = SZFriendsHostBase64URLDecode(message[@"payload"], 0);
        NSString *sid = [message[@"sid"] isKindOfClass:[NSString class]] ? message[@"sid"] : nil;
        SZFriendsHostSignal *signal = sid ? _signals[sid] : nil;
        if (signal && payload.length > 0 && payload.length <= SZFriendsHostSignalPayloadMax) [signal deliver:payload];
    } else if ([type isEqualToString:@"sig_closed"]) {
        [self receiveClosed:message];
    } else {
        [self receiveCredentials:message refused:[type isEqualToString:@"relay_refused"]];
    }
    return YES;
}

- (void)receiveOpened:(NSDictionary<NSString *, id> *)message refused:(BOOL)refused {
    SZFriendsHostPending *pending = [self takePending:message[@"req"] kind:@"open"];
    void (^completion)(SZFriendsHostSignal *, NSError *) = pending.completion;
    NSString *sid = message[@"sid"];
    BOOL valid = !refused && SZFriendsHostValidSid(sid) && _signals[sid] == nil;
    id ended = refused ? nil : message[@"link_ended"];
    if (completion != nil && ([ended isEqual:@"revoked"] || [ended isEqual:@"expired"])) {
        // The host made no sid: the link ended, and its sender left word why.
        completion(nil, [NSError errorWithDomain:SZFriendsHostOnlineErrorDomain code:SZFriendsHostOnlineErrorLinkEnded
                                        userInfo:@{SZFriendsHostLinkEndedKey : ended}]);
        return;
    }
    if (completion == nil) {
        // An answer to an open this side gave up on (it timed out): let the host forget the sid now.
        if (valid) [self sendType:@"sig_close" fields:@{@"sid" : sid}];
        return;
    }
    if (!valid) {
        completion(nil, SZFriendsHostOnlineMakeError(refused ? SZFriendsHostOnlineErrorRateLimited
                                                             : SZFriendsHostOnlineErrorUnavailable,
                                                     @"The Friends host did not open a sid."));
        return;
    }
    SZFriendsHostSignal *signal = [[SZFriendsHostSignal alloc] initWithOnline:self
                                                                          sid:sid
                                                                          via:pending.via
                                                                     incoming:NO
                                                                       linkID:pending.linkID
                                                                  ownerOnline:[message[@"owner_online"] isEqual:@YES]];
    _signals[sid] = signal;
    completion(signal, nil);
}

- (void)receiveIncoming:(NSDictionary<NSString *, id> *)message {
    NSDictionary *vias = @{@"rdv" : @(SZFriendsHostSignalViaRendezvous), @"id" : @(SZFriendsHostSignalViaFriendsID),
                           @"link" : @(SZFriendsHostSignalViaLink), @"join" : @(SZFriendsHostSignalViaJoin)};
    NSString *sid = message[@"sid"];
    NSNumber *via = [message[@"via"] isKindOfClass:[NSString class]] ? vias[message[@"via"]] : nil;
    NSData *payload = SZFriendsHostBase64URLDecode(message[@"payload"], 0);
    NSData *linkID = via.integerValue == SZFriendsHostSignalViaLink ? SZFriendsHostBase64URLDecode(message[@"link_id"],
                                                                                                   16)
                                                                    : nil;
    id<SZFriendsHostOnlineDelegate> delegate = self.delegate;
    if (!SZFriendsHostValidSid(sid) || via == nil || payload.length == 0 ||
        payload.length > SZFriendsHostSignalPayloadMax || (via.integerValue == SZFriendsHostSignalViaLink && !linkID) ||
        _signals[sid] != nil || delegate == nil) {
        return; // silence: to the caller, exactly as if nobody were here
    }
    SZFriendsHostSignal *signal = [[SZFriendsHostSignal alloc] initWithOnline:self
                                                                          sid:sid
                                                                          via:via.integerValue
                                                                     incoming:YES
                                                                       linkID:linkID
                                                                  ownerOnline:NO];
    _signals[sid] = signal;
    [delegate hostOnline:self didReceiveSignal:signal payload:payload];
}

- (void)receiveClosed:(NSDictionary<NSString *, id> *)message {
    NSDictionary *reasons = @{
        @"closed" : @(SZFriendsHostSignalEndClosed), @"gone" : @(SZFriendsHostSignalEndGone),
        @"expired" : @(SZFriendsHostSignalEndExpired), @"limit" : @(SZFriendsHostSignalEndLimit),
        @"unknown" : @(SZFriendsHostSignalEndUnknown),
        @"answered_elsewhere" : @(SZFriendsHostSignalEndAnsweredElsewhere)
    };
    NSString *sid = [message[@"sid"] isKindOfClass:[NSString class]] ? message[@"sid"] : nil;
    SZFriendsHostSignal *signal = sid ? _signals[sid] : nil;
    if (signal == nil) return;
    [_signals removeObjectForKey:sid];
    NSNumber *reason = [message[@"reason"] isKindOfClass:[NSString class]] ? reasons[message[@"reason"]] : nil;
    [signal endWithReason:reason ? reason.integerValue : SZFriendsHostSignalEndUnknown];
}

- (void)receiveCredentials:(NSDictionary<NSString *, id> *)message refused:(BOOL)refused {
    SZFriendsHostPending *pending = [self takePending:message[@"req"] kind:@"credentials"];
    void (^completion)(SZFriendsHostRelayCredentials *, NSError *) = pending.completion;
    if (completion == nil) return;
    long long expires = 0;
    NSString *username = message[@"username"], *credential = message[@"credential"];
    if (!refused && [username isKindOfClass:[NSString class]] && [credential isKindOfClass:[NSString class]] &&
        username.length > 0 && credential.length > 0 && SZFriendsHostJSONInteger(message[@"expires"], 0,
                                                                                  INT64_MAX >> 11, &expires)) {
        if (_relayURIs.count == 0) {
            completion(nil, SZFriendsHostOnlineMakeError(SZFriendsHostOnlineErrorNoRelay,
                                                         @"The signed host list names no relay."));
            return;
        }
        SZFriendsHostRelayCredentials *credentials = [[SZFriendsHostRelayCredentials alloc] init];
        credentials.turnURIs = _relayURIs;
        credentials.username = username;
        credentials.credential = credential;
        credentials.expires = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)expires - _skew];
        completion(credentials, nil);
        return;
    }
    NSDictionary *codes = @{@"not_answered" : @(SZFriendsHostOnlineErrorNotAnswered),
                            @"rate_limited" : @(SZFriendsHostOnlineErrorRateLimited),
                            @"no_relay" : @(SZFriendsHostOnlineErrorNoRelay)};
    NSNumber *code = refused && [message[@"reason"] isKindOfClass:[NSString class]] ? codes[message[@"reason"]] : nil;
    completion(nil, SZFriendsHostOnlineMakeError(code ? code.integerValue : SZFriendsHostOnlineErrorUnavailable,
                                                 @"The Friends host gave no relay credentials."));
}

- (void)endAllSignals {
    NSArray<SZFriendsHostSignal *> *signals = [_signals.allValues copy];
    [_signals removeAllObjects];
    for (SZFriendsHostSignal *signal in signals) [signal endWithReason:SZFriendsHostSignalEndConnectionLost];
}

@end
