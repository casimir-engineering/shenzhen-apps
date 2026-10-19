// SZFriendsSecureChannel: send queues, transport encryption, rekey, session age and frame dispatch.

#import "service/session/SZFriendsSecureChannelInternal.h"

#import "service/session/SZFriendsFrameSchema.h"

// Types only the channel sends and handles; callers never send them and onFrame never sees them.
static BOOL SZFriendsIsChannelFrame(SZFriendsFrameType type) {
    switch (type) {
    case SZFriendsFrameTypeHello:
    case SZFriendsFrameTypeCodeCommit:
    case SZFriendsFrameTypeCodeNonce:
    case SZFriendsFrameTypeCodeReveal:
    case SZFriendsFrameTypeRekey:
    case SZFriendsFrameTypePing:
    case SZFriendsFrameTypeClose:
        return YES;
    default:
        return NO;
    }
}

// NN exists only for Add by ID (ADR 0004) and joining a profile: REQUEST_BY_ID one way, RECEIVED the other, and JOIN
// either way, nothing else. They never travel in XX or IK, where the peer's identity is already known.
static BOOL SZFriendsTypeAllowed(SZFriendsFrameType type, SZFriendsHandshakePattern pattern, BOOL fromInitiator) {
    BOOL nn = pattern == SZFriendsHandshakeNN;
    if (type == SZFriendsFrameTypeJoin) {
        return nn;
    }
    if (type == SZFriendsFrameTypeRequestByID) {
        return nn && fromInitiator;
    }
    if (type == SZFriendsFrameTypeReceived) {
        return nn && !fromInitiator;
    }
    return !nn;
}

@implementation SZFriendsSecureChannel (Transport)

#pragma mark - Sending

- (BOOL)queueFrame:(SZFriendsFrame *)frame {
    if (_state == SZFriendsChannelStateClosing || _state == SZFriendsChannelStateClosed ||
        _state == SZFriendsChannelStateRefusing) {
        return NO;
    }
    // A responder learns the pattern from the preamble; before that nobody is there to send to.
    if (!self.isInitiator && _state < SZFriendsChannelStateHandshaking) {
        return NO;
    }
    if (SZFriendsIsChannelFrame(frame.type) || !SZFriendsTypeAllowed(frame.type, self.pattern, self.isInitiator)) {
        return NO;
    }
    NSData *plaintext = SZFriendsEncodeFrame(frame, NULL);
    if (plaintext == nil) {
        return NO;
    }
    // A preview is up to 64 KB, slow over Bluetooth, and never urgent: it waits with the file data, behind messages.
    if (frame.type == SZFriendsFrameTypeChunk || frame.type == SZFriendsFrameTypeDone ||
        frame.type == SZFriendsFrameTypeThumbnail) {
        [_bulkQueue addObject:plaintext];
    } else {
        [_controlQueue addObject:plaintext];
    }
    [self pumpWrites];
    return YES;
}

- (void)enqueueChannelFrame:(SZFriendsFrame *)frame {
    NSData *plaintext = SZFriendsEncodeFrame(frame, NULL);
    if (plaintext != nil) {
        [_controlQueue addObject:plaintext];
    }
}

// Writes go out one encrypted message at a time while the bytes handed to the link stay under a small budget.
// WHY a budget: everything already handed over is beyond reordering, so keeping it small is what lets a message
// queued now overtake the chunks still waiting. At least one message is always in flight, whatever its size.
- (NSUInteger)inFlightBudget {
    NSUInteger preferred = _stream.preferredWriteSize;
    return MAX(preferred, (NSUInteger)1024) * 4;
}

- (void)pumpWrites {
    if (_state != SZFriendsChannelStateEstablished && _state != SZFriendsChannelStateClosing) {
        return;
    }
    while (_state != SZFriendsChannelStateClosed && !_closeWritten &&
           (_controlQueue.count > 0 || _bulkQueue.count > 0)) {
        NSMutableArray<NSData *> *queue = _controlQueue.count > 0 ? _controlQueue : _bulkQueue;
        NSData *plaintext = queue.firstObject;
        if (_inFlightBytes > 0 && _inFlightBytes + plaintext.length > [self inFlightBudget]) {
            return;
        }
        [queue removeObjectAtIndex:0];
        BOOL isClose = ((const uint8_t *)plaintext.bytes)[0] == SZFriendsFrameTypeClose;
        if (![self writeTransportPlaintext:plaintext]) {
            return;
        }
        if (isClose) {
            _closeWritten = YES;
        }
    }
    [self finishClosingIfDrained];
}

- (void)finishClosingIfDrained {
    if (_state == SZFriendsChannelStateClosing && _closeWritten && _inFlightBytes == 0) {
        [self terminateWithError:_closingError closeReason:-1];
    }
}

- (BOOL)rekeyDue {
    return _bytesSinceSendRekey >= _rekeyAfterBytes || [self now] - _lastSendRekeyAt >= _rekeyAfterInterval;
}

- (BOOL)writeTransportPlaintext:(NSData *)plaintext {
    if (![self checkSessionAge]) {
        return NO;
    }
    if ([self rekeyDue]) {
        // ADR 0001 § Rekey: REKEY under the old key, then Rekey() on this direction. The stream is ordered, so the
        // peer switches at exactly this message.
        static const uint8_t kRekey[1] = {SZFriendsFrameTypeRekey};
        if (![self encryptAndWrite:[NSData dataWithBytes:kRekey length:1]]) {
            return NO;
        }
        szfriends_cipher_rekey(&_sendCipher);
        _rekeysSent++;
        _bytesSinceSendRekey = 0;
        _lastSendRekeyAt = [self now];
    }
    if (![self encryptAndWrite:plaintext]) {
        return NO;
    }
    _bytesSinceSendRekey += plaintext.length;
    return YES;
}

- (BOOL)encryptAndWrite:(NSData *)plaintext {
    NSMutableData *message = [NSMutableData dataWithLength:2 + plaintext.length + SZFRIENDS_NOISE_TAGLEN];
    uint8_t *bytes = message.mutableBytes;
    size_t written = 0;
    int result = szfriends_cipher_encrypt(&_sendCipher, NULL, 0, plaintext.bytes, plaintext.length, bytes + 2,
                                          message.length - 2, &written);
    if (result != SZFRIENDS_NOISE_OK) {
        // Only the reserved last nonce can fail here; a fresh Diffie-Hellman is the only way on.
        [self failWithCode:SZFriendsSessionErrorExpired reason:@"send nonces exhausted"];
        return NO;
    }
    bytes[0] = (uint8_t)(written >> 8);
    bytes[1] = (uint8_t)written;
    NSUInteger length = message.length;
    _inFlightBytes += length;
    __weak typeof(self) weakSelf = self;
    [_stream writeData:message
            completion:^(NSError *error) {
                [weakSelf writeCompletedWithLength:length error:error];
            }];
    return YES;
}

- (void)writeCompletedWithLength:(NSUInteger)length error:(NSError *)error {
    if (_state == SZFriendsChannelStateClosed) {
        return;
    }
    _inFlightBytes -= MIN(length, _inFlightBytes);
    if (error) {
        [self streamClosedWithError:error];
        return;
    }
    [self pumpWrites];
}

#pragma mark - Session lifetime

- (void)becomeEstablished {
    _state = SZFriendsChannelStateEstablished;
    _establishedAt = [self now];
    _lastSendRekeyAt = _establishedAt;
    [self scheduleSessionAgeCheckAfter:_maxAge];
    if (self.isInitiator) {
        // HELLO is the first transport frame, ahead of anything queued while the handshake ran.
        NSData *hello = SZFriendsEncodeFrame([SZFriendsFrame frameWithType:SZFriendsFrameTypeHello fields:@{}], NULL);
        [_controlQueue insertObject:hello atIndex:0];
    } else {
        // HELLO arrived. IK and XX told the listener at the key policy already; NN, which names nobody, only now.
        [self reportAuthenticated];
    }
    [self pumpWrites];
    if (_state != SZFriendsChannelStateEstablished) {
        return;
    }
    void (^onEstablished)(void) = self.onEstablished;
    if (onEstablished) {
        onEstablished();
    }
    [self advanceCodeExchange];
}

// Wall time, so hours asleep count toward the age; sends and receives also check, with the channel's clock.
- (void)scheduleSessionAgeCheckAfter:(NSTimeInterval)delay {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_walltime(NULL, (int64_t)(MAX(delay, 0.001) * NSEC_PER_SEC)), _queue, ^{
        [weakSelf sessionAgeTimerFired];
    });
}

- (void)sessionAgeTimerFired {
    if ([self checkSessionAge] && _state == SZFriendsChannelStateEstablished) {
        // Timers and the clock disagree by a little; look again when the clock says the age is reached.
        [self scheduleSessionAgeCheckAfter:_maxAge - ([self now] - _establishedAt)];
    }
}

// NO after closing the channel: past SZFriendsSessionMaxAge both sides redial for a fresh Diffie-Hellman.
- (BOOL)checkSessionAge {
    if (_state != SZFriendsChannelStateEstablished && _state != SZFriendsChannelStateClosing) {
        return _state != SZFriendsChannelStateClosed;
    }
    if ([self now] - _establishedAt < _maxAge) {
        return YES;
    }
    NSError *error = SZFriendsSessionMakeError(SZFriendsSessionErrorExpired, @"session reached its maximum age");
    if (_state == SZFriendsChannelStateEstablished) {
        [self terminateWithError:error closeReason:SZFriendsCloseReasonExpired];
    } else {
        [self terminateWithError:_closingError ?: error closeReason:-1];
    }
    return NO;
}

#pragma mark - Receiving

- (void)handleTransportMessage:(const uint8_t *)message length:(NSUInteger)length {
    if (length < SZFRIENDS_NOISE_TAGLEN) {
        [self failWithCode:SZFriendsSessionErrorDecryptFailed reason:@"transport message shorter than its tag"];
        return;
    }
    NSMutableData *plaintext = [NSMutableData dataWithLength:length - SZFRIENDS_NOISE_TAGLEN];
    size_t plaintextLength = 0;
    int result = szfriends_cipher_decrypt(&_receiveCipher, NULL, 0, message, length, plaintext.mutableBytes,
                                          plaintext.length, &plaintextLength);
    if (result != SZFRIENDS_NOISE_OK) {
        // Tampered, replayed, reordered or truncated: there is no resynchronisation (ADR 0001), and nothing said
        // back would help an attacker or a broken peer.
        [self failWithCode:result == SZFRIENDS_NOISE_ERR_NONCE ? SZFriendsSessionErrorExpired
                                                                : SZFriendsSessionErrorDecryptFailed
                    reason:@"transport message did not authenticate"];
        return;
    }
    if (_state == SZFriendsChannelStateEstablished && ![self checkSessionAge]) {
        return;
    }
    NSError *error = nil;
    SZFriendsFrame *frame = SZFriendsDecodeFrame(plaintext, &error);
    if (frame == nil) {
        [self protocolFailure:SZFriendsSessionErrorFrameInvalid reason:error.userInfo[NSDebugDescriptionErrorKey]
                                                                       ?: @"frame does not decode"];
        return;
    }
    [self dispatchFrame:frame];
}

- (void)dispatchFrame:(SZFriendsFrame *)frame {
    SZFriendsFrameType type = frame.type;
    if (_state == SZFriendsChannelStateAwaitingHello) {
        if (type != SZFriendsFrameTypeHello) {
            [self protocolFailure:SZFriendsSessionErrorProtocol reason:@"frame before HELLO"];
            return;
        }
        [self becomeEstablished];
        return;
    }
    switch (type) {
    case SZFriendsFrameTypeHello:
        [self protocolFailure:SZFriendsSessionErrorProtocol reason:@"unexpected HELLO"];
        return;
    case SZFriendsFrameTypeRekey:
        szfriends_cipher_rekey(&_receiveCipher);
        _rekeysReceived++;
        return;
    case SZFriendsFrameTypePing:
        return;
    case SZFriendsFrameTypeClose: {
        uint64_t reason = SZFriendsCloseReasonNormal;
        [frame getUInt64:&reason forTag:SZFriendsFieldReason];
        NSError *error = [NSError errorWithDomain:SZFriendsSessionErrorDomain
                                             code:SZFriendsSessionErrorPeerClosed
                                         userInfo:@{SZFriendsSessionCloseReasonKey : @(reason)}];
        [self terminateWithError:error closeReason:-1];
        return;
    }
    case SZFriendsFrameTypeCodeCommit:
    case SZFriendsFrameTypeCodeNonce:
    case SZFriendsFrameTypeCodeReveal:
        [self handleCodeFrame:frame];
        return;
    default:
        break;
    }
    if (!SZFriendsTypeAllowed(type, self.pattern, !self.isInitiator)) {
        [self protocolFailure:SZFriendsSessionErrorProtocol reason:@"frame type not allowed in this pattern"];
        return;
    }
    // One Add by ID exchange per NN session; a second would let one session multiply lookups or replies.
    BOOL *seen = type == SZFriendsFrameTypeRequestByID ? &_receivedRequestByID
                 : type == SZFriendsFrameTypeReceived  ? &_receivedReceived
                                                       : NULL;
    if (seen != NULL) {
        if (*seen) {
            [self protocolFailure:SZFriendsSessionErrorProtocol reason:@"second Add by ID frame"];
            return;
        }
        *seen = YES;
    }
    void (^onFrame)(SZFriendsFrame *) = self.onFrame;
    if (onFrame) {
        onFrame(frame);
    }
}

@end
