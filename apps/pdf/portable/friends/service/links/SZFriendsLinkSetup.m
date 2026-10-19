// One opening of a download link, either end (SZFriendsLinksInternal.h): the setup messages of the link pages
// (portable/server/friends/src/pages/script/receiver.js) and the peer connections they make. The opener's attempt 1 is
// direct (STUN); when no channel opens within the direct timeout, attempt 2 goes through the relay. The sender makes a
// connection only for an offer that arrives after the opener's proof, and answers each attempt it is offered.

#import "service/links/SZFriendsLinksInternal.h"

#import <sodium.h>

#import "service/online/transport/SZFriendsOnlineTransportInternal.h"

NSString *const SZFriendsLinkEndRevoked = @"revoked";
NSString *const SZFriendsLinkEndExpired = @"expired";
NSString *const SZFriendsLinkEndChanged = @"changed";

// Candidates per setup payload are batched under this many bytes of JSON, as the page batches its own.
static const NSUInteger SZFriendsLinkCandidateJSONMax = 3000;
// The sender's end message goes out before its sid is closed.
static const NSTimeInterval SZFriendsLinkEndLinger = 1;

@implementation SZFriendsLinkSetup {
    SZFriendsLinkEnvironment *_environment;
    id<SZFriendsOnlineSignalChannel> _channel;
    NSData *_openerNonce;
    NSMutableDictionary<NSNumber *, SZFriendsLinkAttempt *> *_attempts;
    SZFriendsLinkAttempt *_current; // the opener's attempt now
    NSUInteger _timer;              // bumped to cancel the running timer
    BOOL _proven, _refused, _ended, _streamOpened, _flushScheduled;
}

- (instancetype)initOpenerWithKeys:(SZFriendsLinkKeys *)keys environment:(SZFriendsLinkEnvironment *)environment {
    if ((self = [super init])) {
        _keys = keys;
        _environment = environment;
        _attempts = [NSMutableDictionary dictionary];
    }
    return self;
}

- (instancetype)initSenderWithKeys:(SZFriendsLinkKeys *)keys
                           channel:(id<SZFriendsOnlineSignalChannel>)channel
                       environment:(SZFriendsLinkEnvironment *)environment {
    if ((self = [self initOpenerWithKeys:keys environment:environment])) {
        _isSender = YES;
        _channel = channel;
    }
    return self;
}

- (BOOL)directBlocked {
    return _environment.directPathsBlocked != nil && _environment.directPathsBlocked();
}

#pragma mark - Timers

- (void)armTimer:(NSTimeInterval)delay then:(void (^)(SZFriendsLinkSetup *setup))fire {
    NSUInteger timer = ++_timer;
    __weak SZFriendsLinkSetup *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _environment.queue, ^{
        SZFriendsLinkSetup *setup = weakSelf;
        if (setup != nil && !setup->_ended && setup->_timer == timer) fire(setup);
    });
}

#pragma mark - The sid

- (void)watchChannel {
    __weak SZFriendsLinkSetup *weakSelf = self;
    _channel.onPayload = ^(NSData *payload) { [weakSelf receivePayload:payload]; };
    _channel.onEnd = ^{
        SZFriendsLinkSetup *setup = weakSelf;
        // Once a channel is open the host is no longer needed (the page closes the sid itself then).
        if (setup != nil && !setup->_streamOpened) [setup fail:SZFriendsLinkOutcomeUnavailable];
    };
}

- (BOOL)sendMessage:(NSDictionary<NSString *, id> *)message {
    NSData *sealed = [_keys sealMessage:message from:_isSender ? SZFriendsLinkSideSender : SZFriendsLinkSideOpener];
    return sealed != nil && sealed.length <= SZFriendsOnlineSignalPayloadMax && [_channel sendPayload:sealed];
}

- (void)startWithOpen:(void (^)(NSData *, void (^)(id<SZFriendsOnlineSignalChannel>, BOOL)))open {
    _openerNonce = SZFriendsLinkRandomNonce();
    NSData *hello = [_keys sealMessage:@{@"t" : @"hello", @"v" : @1, @"n" : SZFriendsLinkBase64URLEncode(_openerNonce)}
                                  from:SZFriendsLinkSideOpener];
    [self armTimer:_environment.answerTimeout then:^(SZFriendsLinkSetup *setup) {
        [setup fail:SZFriendsLinkOutcomeUnavailable];
    }];
    __weak SZFriendsLinkSetup *weakSelf = self;
    open(hello, ^(id<SZFriendsOnlineSignalChannel> channel, BOOL ownerOnline) {
        SZFriendsLinkSetup *setup = weakSelf;
        if (setup == nil || setup->_ended || channel == nil || !ownerOnline) {
            [channel close];
            [setup fail:SZFriendsLinkOutcomeUnavailable];
            return;
        }
        setup->_channel = channel;
        [setup watchChannel];
    });
}

- (BOOL)receiveHello:(NSData *)payload {
    return [self receiveHello:payload refusing:nil];
}

- (BOOL)receiveHello:(NSData *)payload refusing:(NSString *)reason {
    NSDictionary *hello = [_keys openPayload:payload from:SZFriendsLinkSideOpener];
    id n = hello[@"n"];
    NSData *openerNonce = [n isKindOfClass:[NSString class]] ? SZFriendsLinkBase64URLDecode(n) : nil;
    if (![hello[@"t"] isEqual:@"hello"] || ![hello[@"v"] isEqual:@1] ||
        openerNonce.length != SZFriendsLinkNonceLength) {
        return NO;
    }
    if (reason != nil) {
        // A link this helper still remembers but no longer serves: the opener hears why rather than waiting out the
        // host's sid. It holds the secret (the hello opened), and nothing about the file goes with the reason.
        _refused = YES;
        [self watchChannel];
        NSData *end = [_keys sealMessage:@{@"t" : @"end", @"reason" : reason} from:SZFriendsLinkSideSender];
        if (![_channel sendPayload:end]) return NO;
        [self armTimer:SZFriendsLinkEndLinger then:^(SZFriendsLinkSetup *setup) {
            [setup fail:SZFriendsLinkOutcomeEnded];
        }];
        return YES;
    }
    NSData *senderNonce = SZFriendsLinkRandomNonce();
    NSData *challenge = [_keys sealMessage:@{@"t" : @"challenge", @"o" : n,
                                             @"n" : SZFriendsLinkBase64URLEncode(senderNonce)}
                                      from:SZFriendsLinkSideSender];
    [_keys setOpenerNonce:openerNonce senderNonce:senderNonce];
    [self watchChannel];
    if (![_channel sendPayload:challenge]) return NO;
    [self armTimer:_environment.setupTimeout then:^(SZFriendsLinkSetup *setup) {
        [setup fail:SZFriendsLinkOutcomeFailed];
    }];
    return YES;
}

- (void)receivePayload:(NSData *)payload {
    if (_ended || (_isSender && _refused)) return;
    if (!_isSender && !_keys.hasSession) {
        NSDictionary *message = [_keys openPayload:payload from:SZFriendsLinkSideSender];
        if ([message[@"t"] isEqual:@"end"]) {
            [self fail:SZFriendsLinkOutcomeForReason(message[@"reason"])];
            return;
        }
        id n = message[@"n"];
        NSData *senderNonce = [n isKindOfClass:[NSString class]] ? SZFriendsLinkBase64URLDecode(n) : nil;
        if (![message[@"t"] isEqual:@"challenge"] || senderNonce.length != SZFriendsLinkNonceLength ||
            ![message[@"o"] isEqual:SZFriendsLinkBase64URLEncode(_openerNonce)]) {
            return;
        }
        [_keys setOpenerNonce:_openerNonce senderNonce:senderNonce];
        [self sendMessage:@{@"t" : @"proof", @"mac" : SZFriendsLinkBase64URLEncode([_keys proof])}];
        [self startAttempt:1 relay:nil];
        return;
    }
    NSDictionary *message = [_keys openPayload:payload from:_isSender ? SZFriendsLinkSideOpener
                                                                      : SZFriendsLinkSideSender];
    if (message == nil) return;
    if (_isSender) [self senderMessage:message];
    else [self openerMessage:message];
}

#pragma mark - Sender

- (void)senderMessage:(NSDictionary *)message {
    NSString *type = message[@"t"];
    if (!_proven) {
        id mac = message[@"mac"];
        NSData *proof = [mac isKindOfClass:[NSString class]] ? SZFriendsLinkBase64URLDecode(mac) : nil;
        if (![type isEqualToString:@"proof"] || ![_keys verifyProof:proof]) {
            // Whoever this is did not prove the secret: no answer, no connection.
            [self fail:SZFriendsLinkOutcomeFailed];
            return;
        }
        _proven = YES;
        id<SZFriendsLinkSetupDelegate> delegate = self.delegate;
        NSString *refusal = [delegate respondsToSelector:@selector(linkSetupOpenerProved:)]
                                ? [delegate linkSetupOpenerProved:self]
                                : nil;
        if (refusal != nil) {
            _refused = YES; // nothing it sends from now on is answered
            [self sendMessage:@{@"t" : @"end", @"reason" : refusal}];
            [self armTimer:SZFriendsLinkEndLinger then:^(SZFriendsLinkSetup *setup) {
                [setup fail:SZFriendsLinkOutcomeEnded];
            }];
        }
        return;
    }
    NSInteger number = SZFriendsLinkAttemptNumber(message[@"a"]);
    if (number == 0 || _refused) return;
    if ([type isEqualToString:@"offer"] && [message[@"sdp"] isKindOfClass:[NSString class]] &&
        _attempts[@(number)] == nil) {
        [self answerOffer:message[@"sdp"] number:(uint8_t)number relay:[message[@"relay"] isEqual:@YES]];
    } else if ([type isEqualToString:@"cand"]) {
        [self remoteCandidates:message attempt:_attempts[@(number)]];
    }
}

- (void)answerOffer:(NSString *)sdp number:(uint8_t)number relay:(BOOL)relay {
    // A new attempt replaces the earlier one, as the page drops its own.
    for (SZFriendsLinkAttempt *older in _attempts.allValues) [older.connection close];
    [_attempts removeAllObjects];
    if (!relay) {
        [self openAttempt:number relay:nil offer:sdp];
        return;
    }
    SZFriendsLinkAttempt *placeholder = [SZFriendsLinkAttempt new]; // holds candidates until the relay is asked
    placeholder.number = number;
    placeholder.relay = YES;
    _attempts[@(number)] = placeholder;
    __weak SZFriendsLinkSetup *weakSelf = self;
    [_channel requestRelayCredentials:^(id<SZFriendsOnlineRelayCredentials> credentials, NSError *error) {
        (void)error;
        SZFriendsLinkSetup *setup = weakSelf;
        if (setup == nil || setup->_ended || credentials == nil) return; // the opener's own timer decides
        NSArray *held = [placeholder.held copy];
        [setup->_attempts removeObjectForKey:@(number)];
        SZFriendsLinkAttempt *attempt = [setup openAttempt:number relay:credentials offer:sdp];
        for (id candidate in held) [setup applyRemoteCandidate:candidate toAttempt:attempt];
    }];
}

#pragma mark - Opener

- (void)openerMessage:(NSDictionary *)message {
    NSString *type = message[@"t"];
    if ([type isEqualToString:@"end"]) {
        [self fail:SZFriendsLinkOutcomeForReason(message[@"reason"])];
        return;
    }
    SZFriendsLinkAttempt *attempt = _current;
    if (attempt == nil || SZFriendsLinkAttemptNumber(message[@"a"]) != attempt.number) return;
    if ([type isEqualToString:@"answer"] && [message[@"sdp"] isKindOfClass:[NSString class]] && !attempt.remoteReady) {
        SZFriendsOnlineDescription *answer = [SZFriendsOnlineDescription descriptionWithSDP:message[@"sdp"] error:NULL];
        if (answer == nil || ![attempt.connection applyRemoteAnswerSDP:message[@"sdp"]
                                                     remoteFingerprint:answer.fingerprint
                                                                 error:NULL]) {
            return; // the connection reports its own failure
        }
        attempt.remoteReady = YES;
        NSArray *held = [attempt.held copy];
        [attempt.held removeAllObjects];
        for (id candidate in held) [self applyRemoteCandidate:candidate toAttempt:attempt];
    } else if ([type isEqualToString:@"cand"]) {
        [self remoteCandidates:message attempt:attempt];
    }
}

- (void)startAttempt:(uint8_t)number relay:(id<SZFriendsOnlineRelayCredentials>)relay {
    for (SZFriendsLinkAttempt *old in _attempts.allValues) [old.connection close];
    [_attempts removeAllObjects];
    _current = [self openAttempt:number relay:relay offer:nil];
    if (_current == nil) {
        [self fail:SZFriendsLinkOutcomeFailed];
        return;
    }
    [self armTimer:relay ? _environment.relayTimeout : _environment.directTimeout then:^(SZFriendsLinkSetup *setup) {
        [setup attemptTimedOut:number];
    }];
}

- (void)attemptTimedOut:(uint8_t)number {
    if (_ended || _streamOpened || _current.number != number) return;
    if (number > 1) {
        [self fail:SZFriendsLinkOutcomeFailed];
        return;
    }
    ++_timer; // the relay's request answers within the host's own timeout
    __weak SZFriendsLinkSetup *weakSelf = self;
    [_channel requestRelayCredentials:^(id<SZFriendsOnlineRelayCredentials> credentials, NSError *error) {
        (void)error;
        SZFriendsLinkSetup *setup = weakSelf;
        if (setup == nil || setup->_ended || setup->_streamOpened) return;
        if (credentials == nil) [setup fail:SZFriendsLinkOutcomeFailed];
        else [setup startAttempt:2 relay:credentials];
    }];
}

#pragma mark - Connections

- (SZFriendsLinkAttempt *)openAttempt:(uint8_t)number
                                relay:(id<SZFriendsOnlineRelayCredentials>)relay
                                offer:(NSString *)offer {
    SZFriendsOnlineRequest *request = [SZFriendsOnlineRequest new];
    request.purpose = SZFriendsOnlinePurposeLink;
    request.role = _isSender ? SZFriendsOnlineRoleAnswerer : SZFriendsOnlineRoleOfferer;
    request.kind = relay ? SZFriendsOnlineConnectionRelay : SZFriendsOnlineConnectionDirect;
    request.peer = _keys.linkID;
    request.relay = relay;
    request.stunURI = relay || [self directBlocked] ? nil : _environment.stunURI;
    if (offer != nil) {
        SZFriendsOnlineDescription *description = [SZFriendsOnlineDescription descriptionWithSDP:offer error:NULL];
        if (description == nil) return nil;
        request.remoteOfferSDP = offer;
        request.remoteFingerprint = description.fingerprint;
    }
    SZFriendsLinkAttempt *attempt = [SZFriendsLinkAttempt new];
    attempt.number = number;
    attempt.relay = relay != nil;
    attempt.remoteReady = _isSender;
    _attempts[@(number)] = attempt; // before the transport can call back
    attempt.connection = [_environment.transport openConnection:request delegate:self queue:_environment.queue
                                                          error:NULL];
    if (attempt.connection == nil) {
        [_attempts removeObjectForKey:@(number)];
        return nil;
    }
    return attempt;
}

- (SZFriendsLinkAttempt *)attemptForConnection:(id<SZFriendsOnlineConnection>)connection {
    for (SZFriendsLinkAttempt *attempt in _attempts.allValues) {
        if (attempt.connection == connection) return attempt;
    }
    return nil;
}

- (void)remoteCandidates:(NSDictionary *)message attempt:(SZFriendsLinkAttempt *)attempt {
    if (attempt == nil) return;
    if ([message[@"end"] isEqual:@YES]) {
        [self applyRemoteCandidate:[NSNull null] toAttempt:attempt];
        return;
    }
    NSArray *candidates = [message[@"c"] isKindOfClass:[NSArray class]] ? message[@"c"] : @[];
    for (id candidate in [candidates subarrayWithRange:NSMakeRange(0, MIN(candidates.count, 64))]) {
        if ([candidate isKindOfClass:[NSArray class]] && [candidate count] >= 1 &&
            [candidate[0] isKindOfClass:[NSString class]]) {
            [self applyRemoteCandidate:candidate[0] toAttempt:attempt];
        }
    }
}

// A candidate line, or NSNull for the end of the other side's candidates.
- (void)applyRemoteCandidate:(id)candidate toAttempt:(SZFriendsLinkAttempt *)attempt {
    if (attempt.connection == nil || !attempt.remoteReady) {
        [attempt.held addObject:candidate];
        return;
    }
    if (candidate == [NSNull null]) {
        [attempt.connection remoteCandidatesDidEnd];
        return;
    }
    SZFriendsOnlineTechnique technique = SZFriendsLinkRemoteTechnique(candidate);
    // A scripted direct failure (tests): only relay candidates reach the stack.
    if ([self directBlocked] && technique != SZFriendsOnlineTechniqueRelay) return;
    [attempt.connection addRemoteCandidate:candidate technique:technique error:NULL];
}

- (void)scheduleFlush {
    if (_flushScheduled) return;
    _flushScheduled = YES;
    __weak SZFriendsLinkSetup *weakSelf = self;
    dispatch_async(_environment.queue, ^{
        SZFriendsLinkSetup *setup = weakSelf;
        if (setup == nil) return;
        setup->_flushScheduled = NO;
        [setup flush];
    });
}

// Local candidates go in batches, each attempt's after its description, and its end after its last batch.
- (void)flush {
    if (_ended || _channel == nil) return;
    for (SZFriendsLinkAttempt *attempt in _attempts.allValues) {
        if (!attempt.described || attempt.streamOpen) continue;
        NSMutableArray *batch = [NSMutableArray array];
        NSUInteger size = 0;
        for (NSArray<NSString *> *candidate in attempt.outgoing) {
            NSUInteger cost = candidate[0].length + candidate[1].length + 8;
            if (batch.count > 0 && size + cost > SZFriendsLinkCandidateJSONMax) {
                [self sendMessage:@{@"t" : @"cand", @"a" : @(attempt.number), @"c" : batch}];
                batch = [NSMutableArray array];
                size = 0;
            }
            [batch addObject:candidate];
            size += cost;
        }
        [attempt.outgoing removeAllObjects];
        if (batch.count > 0) [self sendMessage:@{@"t" : @"cand", @"a" : @(attempt.number), @"c" : batch}];
        if (attempt.localEnded && !attempt.endSent) {
            attempt.endSent = YES;
            [self sendMessage:@{@"t" : @"cand", @"a" : @(attempt.number), @"end" : @YES}];
        }
    }
}

- (void)onlineConnection:(id<SZFriendsOnlineConnection>)connection
    didCreateLocalDescription:(NSString *)sdp
                  fingerprint:(NSData *)fingerprint {
    (void)fingerprint; // it is in the SDP, which travels sealed; the other side hands it to its transport too
    SZFriendsLinkAttempt *attempt = [self attemptForConnection:connection];
    if (attempt == nil || _ended) return;
    attempt.mid = [SZFriendsOnlineDescription descriptionWithSDP:sdp error:NULL].mid ?: @"0";
    if (_isSender) {
        [self sendMessage:@{@"t" : @"answer", @"a" : @(attempt.number), @"sdp" : sdp}];
    } else {
        [self sendMessage:@{@"t" : @"offer", @"a" : @(attempt.number), @"relay" : @(attempt.relay), @"sdp" : sdp}];
    }
    attempt.described = YES;
    [self scheduleFlush];
}

- (void)onlineConnection:(id<SZFriendsOnlineConnection>)connection
    didGatherLocalCandidate:(NSString *)candidate
                  technique:(SZFriendsOnlineTechnique)technique {
    SZFriendsLinkAttempt *attempt = [self attemptForConnection:connection];
    if (attempt == nil || _ended || ([self directBlocked] && technique != SZFriendsOnlineTechniqueRelay)) return;
    [attempt.outgoing addObject:@[ candidate, attempt.mid ]];
    [self scheduleFlush];
}

- (void)onlineConnectionDidFinishGathering:(id<SZFriendsOnlineConnection>)connection {
    SZFriendsLinkAttempt *attempt = [self attemptForConnection:connection];
    attempt.localEnded = YES;
    if (attempt != nil) [self scheduleFlush];
}

- (void)onlineConnection:(id<SZFriendsOnlineConnection>)connection
           didOpenStream:(id<SZFriendsByteStream>)stream
                   route:(SZFriendsOnlineRoute)route {
    (void)route;
    SZFriendsLinkAttempt *attempt = [self attemptForConnection:connection];
    if (attempt == nil || _ended || _streamOpened) {
        [stream close];
        return;
    }
    _streamOpened = YES;
    attempt.streamOpen = YES;
    ++_timer;
    // The host is no longer needed: the sid ends, and so does every other attempt.
    for (SZFriendsLinkAttempt *other in _attempts.allValues) {
        if (other != attempt) [other.connection close];
    }
    _channel.onEnd = nil;
    _channel.onPayload = nil;
    if (!_isSender) [_channel close];
    [self.delegate linkSetup:self didOpenStream:stream attempt:attempt.number];
}

- (void)onlineConnection:(id<SZFriendsOnlineConnection>)connection
                  stream:(id<SZFriendsByteStream>)stream
          didChangeRoute:(SZFriendsOnlineRoute)route {
    (void)connection, (void)stream, (void)route;
}

- (void)onlineConnection:(id<SZFriendsOnlineConnection>)connection didFailWithError:(NSError *)error {
    (void)error;
    SZFriendsLinkAttempt *attempt = [self attemptForConnection:connection];
    if (attempt == nil || _ended || _streamOpened || _isSender || attempt != _current) return;
    // The opener moves on at once rather than waiting out its timer.
    if (attempt.number == 1) [self attemptTimedOut:1];
    else [self fail:SZFriendsLinkOutcomeFailed];
}

#pragma mark - Ending

- (void)fail:(SZFriendsLinkOutcome)outcome {
    if (_ended) return;
    [self close];
    [self.delegate linkSetup:self didFail:outcome];
}

- (void)close {
    if (_ended && _attempts.count == 0) return;
    _ended = YES;
    ++_timer;
    _channel.onPayload = nil;
    _channel.onEnd = nil;
    [_channel close];
    for (SZFriendsLinkAttempt *attempt in _attempts.allValues) [attempt.connection close];
    [_attempts removeAllObjects];
    _current = nil;
}

@end
