// SZFriendsSecureChannel: lifecycle, stream bytes, length framing and closing (SZFriendsSecureChannelInternal.h).

#import "service/session/SZFriendsSecureChannelInternal.h"

#import <time.h>

#import <sodium.h>

#import "service/identity/SZFriendsIdentity.h"
#import "service/session/SZFriendsFrameSchema.h"

const char SZFriendsPrologueLabel[18] = "SZFriends session"; // the array's 18th byte is the NUL ADR 0001 names

@implementation SZFriendsSecureChannel

- (instancetype)initWithStream:(id<SZFriendsByteStream>)stream
                      identity:(SZFriendsIdentity *)identity
                         queue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _stream = stream;
        _identity = identity;
        _queue = queue;
        _inbound = [NSMutableData data];
        _controlQueue = [NSMutableArray array];
        _bulkQueue = [NSMutableArray array];
        _rekeyAfterBytes = SZFriendsRekeyAfterBytes;
        _rekeyAfterInterval = SZFriendsRekeyAfterInterval;
        _maxAge = SZFriendsSessionMaxAge;
        _handshakeTimeout = SZFriendsHandshakeTimeout;
        _refusalDelay = SZFriendsRefusalDelay;
        _keepaliveInterval = SZFriendsKeepaliveInterval;
        _silenceLimit = SZFriendsSilenceLimit;
        _silenceLimitBluetooth = SZFriendsSilenceLimitBluetooth;
        _localCapabilities = SZFriendsDefaultCapabilities();
        // CLOCK_MONOTONIC keeps counting while the Mac sleeps, so a session that slept through the night is old.
        _clock = ^NSTimeInterval {
            return (NSTimeInterval)clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1e9;
        };
        _scheduler = ^(NSTimeInterval delay, dispatch_block_t block) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), queue, block);
        };
    }
    return self;
}

- (instancetype)initAsInitiatorWithStream:(id<SZFriendsByteStream>)stream
                                 identity:(SZFriendsIdentity *)identity
                                  options:(SZFriendsHandshakeOptions *)options
                                    queue:(dispatch_queue_t)queue {
    if ((self = [self initWithStream:stream identity:identity queue:queue])) {
        _options = [options copy];
        _isInitiator = YES;
        _pattern = options.pattern;
        _initiatorRoute = options.route;
    }
    return self;
}

- (instancetype)initAsResponderWithStream:(id<SZFriendsByteStream>)stream
                                 identity:(SZFriendsIdentity *)identity
                            publicProfile:(NSDictionary<NSNumber *, NSData *> *)publicProfile
                                keyPolicy:(SZFriendsRemoteKeyPolicy)keyPolicy
                                    queue:(dispatch_queue_t)queue {
    if ((self = [self initWithStream:stream identity:identity queue:queue])) {
        _publicProfile = [publicProfile copy];
        _keyPolicy = [keyPolicy copy];
    }
    return self;
}

- (void)dealloc {
    szfriends_handshake_clear(&_handshake);
    szfriends_cipher_clear(&_sendCipher);
    szfriends_cipher_clear(&_receiveCipher);
}

- (NSTimeInterval)now {
    return _clock();
}

- (SZFriendsReplayCache *)replayCache {
    return _replayCache ?: SZFriendsReplayCache.sharedCache;
}

- (void)setReplayCache:(SZFriendsReplayCache *)replayCache {
    _replayCache = replayCache;
}

#pragma mark - Starting

- (void)start {
    if (_state != SZFriendsChannelStateIdle) {
        return;
    }
    _startedAt = [self now];
    _inputArrivedAt = _startedAt;
    __weak typeof(self) weakSelf = self;
    _stream.onData = ^(NSData *data) {
        [weakSelf receiveData:data];
    };
    _stream.onClose = ^(NSError *error) {
        [weakSelf streamClosedWithError:error];
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_handshakeTimeout * NSEC_PER_SEC)), _queue, ^{
        [weakSelf handshakeTimerFired];
    });
    [_stream startWithQueue:_queue];
    if (_isInitiator) {
        _state = SZFriendsChannelStateHandshaking;
        [self startInitiatorHandshake];
    } else {
        _state = SZFriendsChannelStateAwaitingPreamble;
    }
}

- (void)handshakeTimerFired {
    // A quiet refusal already has its own deadline; a timeout refuses nothing the peer sent, so it closes at once.
    if (_state < SZFriendsChannelStateEstablished) {
        [self terminateWithError:SZFriendsSessionMakeError(SZFriendsSessionErrorTimedOut,
                                                           @"handshake did not go live in time")
                     closeReason:-1];
    }
}

#pragma mark - Inbound bytes

// Reassembles u16-length-prefixed Noise messages from whatever slices the stream delivers. A peer can make us hold
// at most one 65,537-byte message plus one delivery, since complete messages are consumed as they arrive.
- (void)receiveData:(NSData *)data {
    if (_state == SZFriendsChannelStateClosed || _state == SZFriendsChannelStateIdle ||
        _state == SZFriendsChannelStateRefusing) {
        return;
    }
    // Before any work on these bytes: a refusal they cause closes a fixed time after this moment.
    _inputArrivedAt = [self now];
    [self noteHeard:_inputArrivedAt];
    [_inbound appendData:data];
    // Held locally: a callback run from a message handler may close the channel, which replaces _inbound, and the
    // handler is still reading the message out of this buffer.
    NSMutableData *buffer = _inbound;
    while (_state != SZFriendsChannelStateClosed && _state != SZFriendsChannelStateRefusing) {
        const uint8_t *bytes = (const uint8_t *)buffer.bytes + _inboundOffset;
        NSUInteger available = buffer.length - _inboundOffset;
        if (_state == SZFriendsChannelStateAwaitingPreamble) {
            if (available < 4) {
                break;
            }
            _inboundOffset += 4;
            if (![self consumePreambleFromBytes:bytes length:4]) {
                return;
            }
            continue;
        }
        if (available < 2) {
            break;
        }
        NSUInteger length = ((NSUInteger)bytes[0] << 8) | bytes[1];
        if (length == 0) {
            [self failWithCode:SZFriendsSessionErrorFrameInvalid reason:@"zero-length Noise message"];
            return;
        }
        // A responder decides on the length alone, ahead of any Diffie-Hellman and before buffering the body
        // (SZFriendsResponderHandshakeMax): the decision then costs every listener the same.
        BOOL responderHandshake = _state == SZFriendsChannelStateHandshaking && !self.isInitiator;
        if (responderHandshake && length > SZFriendsResponderHandshakeMax) {
            [self failWithCode:SZFriendsSessionErrorFrameInvalid reason:@"handshake message longer than an honest one"];
            return;
        }
        if (available < 2 + length) {
            break;
        }
        _inboundOffset += 2 + length;
        if (_state == SZFriendsChannelStateHandshaking) {
            [self handleHandshakeMessage:bytes + 2 length:length];
        } else if (_state == SZFriendsChannelStateClosing) {
            // After -close nothing more reaches the caller; the bytes are only drained.
        } else {
            [self handleTransportMessage:bytes + 2 length:length];
        }
    }
    if (_state == SZFriendsChannelStateClosed || _state == SZFriendsChannelStateRefusing) {
        return;
    }
    if (_inboundOffset == _inbound.length) {
        _inbound.length = 0;
        _inboundOffset = 0;
    } else if (_inboundOffset > 65537) {
        [_inbound replaceBytesInRange:NSMakeRange(0, _inboundOffset) withBytes:NULL length:0];
        _inboundOffset = 0;
    }
}

- (void)streamClosedWithError:(NSError *)error {
    if (_state == SZFriendsChannelStateClosed) {
        return;
    }
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:@"the link closed without CLOSE"
                                                                   forKey:NSDebugDescriptionErrorKey];
    if (error) {
        info[NSUnderlyingErrorKey] = error;
    }
    if (_state == SZFriendsChannelStateRefusing) {
        // The peer gave up first, so nobody is left to time our close: report the refusal now.
        [self terminateWithError:_refusalError closeReason:-1];
        return;
    }
    [self terminateWithError:[NSError errorWithDomain:SZFriendsSessionErrorDomain
                                                 code:SZFriendsSessionErrorStreamClosed
                                             userInfo:info]
                 closeReason:-1];
}

#pragma mark - Public entry points implemented by the categories

- (BOOL)sendFrame:(SZFriendsFrame *)frame {
    BOOL queued = [self queueFrame:frame];
    if (queued && self.onFrameQueued) self.onFrameQueued(frame);
    return queued;
}

- (void)runComparisonCodeExchange:(void (^)(NSString *_Nullable code, NSError *_Nullable error))completion {
    [self startCodeExchange:completion];
}

- (BOOL)pieces {
    return self.fastTransfers && (self.localCapabilities & SZFriendsCapabilityPieces) &&
           (self.remoteCapabilities & SZFriendsCapabilityPieces);
}

- (BOOL)directWiFiBoost {
    return self.fastTransfers && (self.localCapabilities & SZFriendsCapabilityDirectWiFiBoost) &&
           (self.remoteCapabilities & SZFriendsCapabilityDirectWiFiBoost);
}

- (BOOL)fastTransfers {
    return self.negotiatedMinor >= SZFriendsFastTransfersMinor &&
           (self.localCapabilities & SZFriendsCapabilityFastTransfers) &&
           (self.remoteCapabilities & SZFriendsCapabilityFastTransfers);
}

- (void)setLivenessKeepalive:(BOOL)keepalive watch:(BOOL)watch {
    [self applyLivenessKeepalive:keepalive watch:watch];
}

- (BOOL)watchingLiveness {
    return _watchSilence;
}

- (NSUInteger)queuedBulkFrames {
    return _bulkQueue.count;
}

#pragma mark - Closing

- (void)close {
    [self closeWithReason:SZFriendsCloseReasonNormal];
}

- (void)closeWithReason:(SZFriendsCloseReason)reason {
    [self beginClosingWithReason:reason error:nil];
}

- (void)beginClosingWithReason:(SZFriendsCloseReason)reason error:(NSError *)error {
    if (_state == SZFriendsChannelStateClosed || _state == SZFriendsChannelStateClosing) {
        return;
    }
    if (_state != SZFriendsChannelStateEstablished) {
        // No live session to say goodbye in: before HELLO nothing has been revealed beyond the handshake.
        [self terminateWithError:error closeReason:-1];
        return;
    }
    _state = SZFriendsChannelStateClosing;
    _closingError = error;
    // Queued chunks are dropped; queued control frames (ACKs above all) still go out before CLOSE.
    [_bulkQueue removeAllObjects];
    _closeQueued = YES;
    [self enqueueChannelFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypeClose
                                                     fields:@{@(SZFriendsFieldReason) : [SZFriendsFrame
                                                                 fieldWithUInt64:reason
                                                                             tag:SZFriendsFieldReason]}]];
    [self pumpWrites];
}

- (void)failWithCode:(SZFriendsSessionError)code reason:(NSString *)logReason {
    NSError *error = SZFriendsSessionMakeError(code, logReason);
    BOOL beforeReply = _state == SZFriendsChannelStateAwaitingPreamble || _state == SZFriendsChannelStateHandshaking;
    if (!self.isInitiator && !_responderReplied && beforeReply) {
        [self refuseQuietlyWithError:error];
        return;
    }
    [self terminateWithError:error closeReason:-1];
}

// Every refusal before the responder's first reply looks the same from outside: no byte written, nothing more read,
// and the link closed SZFriendsRefusalDelay after the deciding bytes arrived (SZFriendsSession.h).
- (void)refuseQuietlyWithError:(NSError *)error {
    _state = SZFriendsChannelStateRefusing;
    _refusalError = error;
    szfriends_handshake_clear(&_handshake);
    _inbound = [NSMutableData data];
    _inboundOffset = 0;
    NSTimeInterval wait = MAX(0, _inputArrivedAt + _refusalDelay - [self now]);
    // Held strongly until the deadline, so when the link closes never depends on who else keeps the channel.
    _scheduler(wait, ^{
        if (self->_state == SZFriendsChannelStateRefusing) {
            [self terminateWithError:self->_refusalError closeReason:-1];
        }
    });
}

- (void)protocolFailure:(SZFriendsSessionError)code reason:(NSString *)logReason {
    [self terminateWithError:SZFriendsSessionMakeError(code, logReason)
                 closeReason:SZFriendsCloseReasonProtocolError];
}

// One CLOSE is written straight to the stream, bypassing the queues, because the queues are being abandoned.
- (void)writeCloseNow:(NSInteger)closeReason {
    uint8_t plaintext[5] = {SZFriendsFrameTypeClose, SZFriendsFieldReason, 0, 1, (uint8_t)closeReason};
    uint8_t message[2 + sizeof plaintext + SZFRIENDS_NOISE_TAGLEN];
    size_t written = 0;
    if (szfriends_cipher_encrypt(&_sendCipher, NULL, 0, plaintext, sizeof plaintext, message + 2,
                                 sizeof message - 2, &written) != SZFRIENDS_NOISE_OK) {
        return;
    }
    message[0] = (uint8_t)(written >> 8);
    message[1] = (uint8_t)written;
    [_stream writeData:[NSData dataWithBytes:message length:2 + written] completion:nil];
}

- (void)terminateWithError:(NSError *)error closeReason:(NSInteger)closeReason {
    if (_state == SZFriendsChannelStateClosed) {
        return;
    }
    if (closeReason >= 0 && _hasTransportKeys && !_closeWritten) {
        [self writeCloseNow:closeReason];
    }
    _state = SZFriendsChannelStateClosed;
    [_controlQueue removeAllObjects];
    [_bulkQueue removeAllObjects];
    _inbound = [NSMutableData data];
    _inboundOffset = 0;
    szfriends_handshake_clear(&_handshake);
    szfriends_cipher_clear(&_sendCipher);
    szfriends_cipher_clear(&_receiveCipher);
    _hasTransportKeys = NO;

    _stream.onData = nil;
    _stream.onClose = nil;
    [_stream close];

    if (_codeCompletion) {
        [self finishCodeExchangeWithCode:nil
                                   error:error ?: SZFriendsSessionMakeError(SZFriendsSessionErrorProtocol,
                                                                            @"channel closed before the codes")];
    }
    void (^onClose)(NSError *) = self.onClose;
    // Callbacks often capture the object that owns this channel; dropping them breaks the cycle.
    self.onClose = nil;
    self.onFrame = nil;
    self.onFrameQueued = nil;
    self.onEstablished = nil;
    self.onPublicProfile = nil;
    self.onWritten = nil;
    _keyPolicy = nil;
    if (onClose) {
        onClose(error);
    }
}

@end

@implementation SZFriendsSecureChannel (Testing)

- (void)setRekeyAfterBytes:(uint64_t)bytes interval:(NSTimeInterval)interval {
    _rekeyAfterBytes = bytes;
    _rekeyAfterInterval = interval;
}

- (void)setMaxAge:(NSTimeInterval)maxAge {
    _maxAge = maxAge;
}

- (void)setHandshakeTimeout:(NSTimeInterval)timeout {
    _handshakeTimeout = timeout;
}

- (void)setRefusalDelay:(NSTimeInterval)delay {
    _refusalDelay = delay;
}

- (void)setKeepaliveInterval:(NSTimeInterval)keepalive silence:(NSTimeInterval)silence
                   bluetooth:(NSTimeInterval)bluetooth {
    _keepaliveInterval = keepalive;
    _silenceLimit = silence;
    _silenceLimitBluetooth = bluetooth;
}

- (void)setScheduler:(void (^)(NSTimeInterval delay, dispatch_block_t block))scheduler {
    _scheduler = [scheduler copy];
}

- (void)setClock:(NSTimeInterval (^)(void))clock {
    _clock = [clock copy];
}

- (NSUInteger)rekeysSent {
    return _rekeysSent;
}

- (NSUInteger)rekeysReceived {
    return _rekeysReceived;
}

- (NSUInteger)message1ScalarMultiplications {
    return _message1DH + _message1DummyDH;
}

- (NSUInteger)message1CertificateChecks {
    return _message1CertificateChecks + _message1DummyCertificateChecks;
}

- (NSUInteger)message1DummyScalarMultiplications {
    return _message1DummyDH;
}

- (NSUInteger)message1DummyCertificateChecks {
    return _message1DummyCertificateChecks;
}

@end
