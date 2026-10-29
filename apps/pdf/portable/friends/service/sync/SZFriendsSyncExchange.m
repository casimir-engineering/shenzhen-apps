// Anti-entropy on one session between two of our devices (SZFriendsSync.h). Messages, each one SYNC frame's payload:
//   1 HELLO   version u8 (1) | vector                       what this side holds
//   2 EVENTS  count u16 | (header length u16 | header | has body u8 | [body length u32 | body])*
//   3 ACK     vector                                         what this side holds after applying an EVENTS
//   4 WANT    id length u8 | id | offset u64 | parts u16     send these parts of a file's bytes
//   5 PART    id length u8 | id | offset u64 | last u8 | bytes
//   6 NONE    id length u8 | id                              this side does not have that file's bytes
//   7 WANT BLOCKS    id length u8 | id | shift u8 | ranges   these blocks (ADR 0018 § 4; fast-transfer sessions only)
//   8 BLOCKS FOLLOW  id length u8 | id | root (32) | shift u8; HASHES and PARTs follow on the session
// Each side sends the events the other's vector lacks, each author's in order, with at most SZFriendsSyncWindow
// EVENTS unacknowledged, then whatever new it captures or hears from a third device. A file copies one at a time,
// SZFriendsSyncCopyAhead parts requested ahead, into received/.partial/ where a later session resumes it, and is
// published only once its whole digest matches the record.

#import "service/sync/SZFriendsSyncExchangeInternal.h"

NS_ASSUME_NONNULL_BEGIN

const NSUInteger SZFriendsSyncWindow = 4;
@implementation SZFriendsSyncCopy
@end

NSData *_Nullable SZFriendsCopyRangesDecode(const uint8_t *bytes, NSUInteger length) {
    if (length == 0 || length % 8 != 0 || length > 8 * 8000) return nil;
    NSMutableData *pairs = [NSMutableData dataWithLength:length];
    uint32_t *out = pairs.mutableBytes;
    for (NSUInteger i = 0; i < length / 4; i++) {
        const uint8_t *b = bytes + 4 * i;
        out[i] = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
        if (i % 2 == 1 && out[i] == 0) return nil;
    }
    return pairs;
}

@implementation SZFriendsSyncExchange

- (instancetype)initWithEngine:(SZFriendsSyncEngine *)engine
                       peerKey:(NSData *)peerDeviceKey
                          send:(void (^)(NSData *message))send {
    if ((self = [super init])) {
        _engine = engine;
        _peerKey = [peerDeviceKey copy];
        _send = [send copy];
        _sent = [NSMutableDictionary dictionary];
        _unavailable = [NSMutableSet set];
    }
    return self;
}

- (void)start {
    NSMutableData *hello = [NSMutableData dataWithBytes:(uint8_t[]){SZFriendsSyncMessageHello, 1} length:2];
    [hello appendData:SZFriendsSyncEncodeVector([_engine vector])];
    _send(hello);
}

- (BOOL)peerCaughtUp {
    if (_peerVector == nil) return NO;
    SZFriendsSyncVector *ours = [_engine offeredVector];
    for (NSData *author in ours) {
        if (!SZFriendsSyncVectorCovers(_peerVector, author, [ours[author] unsignedLongLongValue])) return NO;
    }
    return YES;
}

- (NSUInteger)filesInFlight {
    return _copy != nil ? 1 : 0;
}

- (nullable NSString *)copyingTransferID {
    return _copy.file.transferID;
}

- (double)copyingFraction {
    uint64_t received = _copy.blocks ? _copy.blocks.receivedBytes : _copy.received;
    return _copy.file.size > 0 ? (double)received / (double)_copy.file.size : 0;
}

- (nullable NSString *)copyingByBlocks {
    return _copy.blocks ? _copy.file.transferID : nil;
}

// Ends the current copy, keeping what arrived for a later one.
- (void)endCopy {
    [_copy.handle closeFile];
    [_copy.blocks pause];
    _copy = nil;
}

- (void)stop {
    _stopped = YES;
    [self endCopy];
}

#pragma mark - Receiving

- (BOOL)receiveMessage:(NSData *)message error:(NSError **)error {
    if (_stopped) return YES;
    if (message.length == 0 || message.length > SZFriendsSyncMessageMax) {
        return SZFriendsSyncFail(error, SZFriendsSyncErrorMalformed, @"a sync message of the wrong size");
    }
    const uint8_t *p = message.bytes;
    switch (p[0]) {
    case SZFriendsSyncMessageHello: return [self receiveHello:message error:error];
    case SZFriendsSyncMessageEvents: return [self receiveEvents:message error:error];
    case SZFriendsSyncMessageAck: return [self receiveAck:message error:error];
    case SZFriendsSyncMessageWant: return [self receiveWant:message error:error];
    case SZFriendsSyncMessagePart: return [self receivePart:message error:error];
    case SZFriendsSyncMessageNone: return [self receiveNone:message error:error];
    case SZFriendsSyncMessageWantBlocks: return [self receiveWantBlocks:message error:error];
    case SZFriendsSyncMessageBlocksFollow: return [self receiveBlocksFollow:message error:error];
    default: return SZFriendsSyncFail(error, SZFriendsSyncErrorMalformed, @"an unknown sync message");
    }
}

- (nullable SZFriendsSyncVector *)vectorIn:(NSData *)message from:(NSUInteger)offset {
    NSUInteger consumed = 0;
    NSData *rest = [message subdataWithRange:NSMakeRange(offset, message.length - offset)];
    SZFriendsSyncVector *vector = SZFriendsSyncDecodeVector(rest, &consumed);
    return vector != nil && consumed == rest.length ? vector : nil;
}

- (void)learnPeerHolds:(SZFriendsSyncVector *)vector {
    for (NSData *author in vector) {
        if ([vector[author] unsignedLongLongValue] > [_sent[author] unsignedLongLongValue]) {
            _sent[author] = vector[author];
        }
    }
}

- (BOOL)receiveHello:(NSData *)message error:(NSError **)error {
    const uint8_t *p = message.bytes;
    SZFriendsSyncVector *vector = message.length >= 2 && p[1] == 1 ? [self vectorIn:message from:2] : nil;
    if (vector == nil) return SZFriendsSyncFail(error, SZFriendsSyncErrorMalformed, @"a HELLO that does not decode");
    _peerVector = vector;
    _helloReceived = YES;
    [_engine noteDevice:_peerKey holds:vector]; // what reached it, kept for You's "On all your computers"
    [_sent removeAllObjects];
    [self learnPeerHolds:vector];
    _outstanding = 0;
    [self pump];
    return YES;
}

- (BOOL)receiveEvents:(NSData *)message error:(NSError **)error {
    const uint8_t *p = message.bytes;
    NSData *root = _engine.rootKey;
    // Removed from the profile meanwhile (the chain that says so may have arrived just before): nothing to sync with.
    if (root == nil) return SZFriendsSyncFail(error, SZFriendsSyncErrorInactive, @"this device left the profile");
    if (message.length < 3) return SZFriendsSyncFail(error, SZFriendsSyncErrorMalformed, @"EVENTS");
    NSUInteger count = ((NSUInteger)p[1] << 8) | p[2], offset = 3;
    NSMutableArray<SZFriendsSyncEvent *> *events = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        if (offset + 2 > message.length) return SZFriendsSyncFail(error, SZFriendsSyncErrorMalformed, @"EVENTS");
        NSUInteger headerLength = ((NSUInteger)p[offset] << 8) | p[offset + 1];
        if (offset + 2 + headerLength + 1 > message.length) {
            return SZFriendsSyncFail(error, SZFriendsSyncErrorMalformed, @"EVENTS");
        }
        NSData *header = [message subdataWithRange:NSMakeRange(offset + 2, headerLength)];
        offset += 2 + headerLength;
        uint8_t hasBody = p[offset++];
        NSData *body = nil;
        if (hasBody > 1) return SZFriendsSyncFail(error, SZFriendsSyncErrorMalformed, @"EVENTS");
        if (hasBody == 1) {
            if (offset + 4 > message.length) return SZFriendsSyncFail(error, SZFriendsSyncErrorMalformed, @"EVENTS");
            NSUInteger length = ((NSUInteger)p[offset] << 24) | ((NSUInteger)p[offset + 1] << 16) |
                                ((NSUInteger)p[offset + 2] << 8) | p[offset + 3];
            if (length > SZFriendsSyncBodyMax || offset + 4 + length > message.length) {
                return SZFriendsSyncFail(error, SZFriendsSyncErrorMalformed, @"EVENTS");
            }
            body = [message subdataWithRange:NSMakeRange(offset + 4, length)];
            offset += 4 + length;
        }
        SZFriendsSyncEvent *event = [SZFriendsSyncEvent eventWithHeader:header body:body rootKey:root error:error];
        if (event == nil) return NO;
        [events addObject:event];
    }
    if (offset != message.length) return SZFriendsSyncFail(error, SZFriendsSyncErrorMalformed, @"EVENTS");
    for (SZFriendsSyncEvent *event in events) {
        if (event.seq > [_sent[event.author] unsignedLongLongValue]) _sent[event.author] = @(event.seq);
    }
    if (![_engine receiveEvents:events error:error]) return NO;
    NSMutableData *ack = [NSMutableData dataWithBytes:(uint8_t[]){SZFriendsSyncMessageAck} length:1];
    [ack appendData:SZFriendsSyncEncodeVector([_engine vector])];
    _send(ack);
    [self pump];
    return YES;
}

- (BOOL)receiveAck:(NSData *)message error:(NSError **)error {
    SZFriendsSyncVector *vector = [self vectorIn:message from:1];
    if (vector == nil) return SZFriendsSyncFail(error, SZFriendsSyncErrorMalformed, @"an ACK that does not decode");
    _peerVector = vector;
    [self learnPeerHolds:vector];
    [_engine noteDevice:_peerKey holds:vector];
    if (_outstanding > 0) _outstanding--;
    [self pump];
    return YES;
}

#pragma mark - Sending events

- (void)pump {
    if (_stopped || !_helloReceived) return;
    while (_outstanding < SZFriendsSyncWindow) {
        NSArray<SZFriendsSyncEvent *> *events = [_engine eventsMissingFrom:_sent limit:SZFriendsSyncEventsPerMessage];
        if (events.count == 0) break;
        NSMutableData *message = [NSMutableData dataWithBytes:(uint8_t[]){SZFriendsSyncMessageEvents, 0, 0} length:3];
        uint16_t count = 0;
        for (SZFriendsSyncEvent *event in events) {
            NSUInteger size = 2 + event.header.length + 1 + (event.body ? 4 + event.body.length : 0);
            if (count > 0 && message.length + size > SZFriendsSyncMessageMax) break;
            uint8_t headerLength[2] = {(uint8_t)(event.header.length >> 8), (uint8_t)event.header.length};
            [message appendBytes:headerLength length:2];
            [message appendData:event.header];
            uint8_t hasBody = event.body != nil;
            [message appendBytes:&hasBody length:1];
            if (event.body != nil) {
                uint32_t length = (uint32_t)event.body.length;
                uint8_t lengthBytes[4] = {(uint8_t)(length >> 24), (uint8_t)(length >> 16), (uint8_t)(length >> 8),
                                          (uint8_t)length};
                [message appendBytes:lengthBytes length:4];
                [message appendData:event.body];
            }
            _sent[event.author] = @(event.seq);
            count++;
        }
        ((uint8_t *)message.mutableBytes)[1] = (uint8_t)(count >> 8);
        ((uint8_t *)message.mutableBytes)[2] = (uint8_t)count;
        _outstanding++;
        _send(message);
    }
    // A copy nobody wants any more (Cancel after Get) stops; what arrived waits for another Get.
    if (_copy != nil && ![[[_engine filesWanted] valueForKey:@"transferID"] containsObject:_copy.file.transferID]) {
        [self endCopy];
    }
    [self startNextCopy];
}

- (BOOL)receiveHashes:(NSData *)hashes index:(uint32_t)index forTransfer:(NSString *)transferID {
    if (_copy.blocks == nil || ![_copy.file.transferID isEqualToString:transferID]) return NO;
    BOOL done = NO;
    if (![_copy.blocks acceptHashes:hashes index:index done:&done]) {
        [self stopBlocksCopy];
        return YES;
    }
    [self sendHave];
    if (done && _copy.blocks.complete) [self finishBlocksCopy];
    return YES;
}

- (BOOL)receivePart:(NSData *)data offset:(uint64_t)offset forTransfer:(NSString *)transferID {
    if (_copy.blocks == nil || ![_copy.file.transferID isEqualToString:transferID]) return NO;
    uint32_t block = 0;
    switch ([_copy.blocks acceptPart:data offset:offset block:&block]) {
    case SZFriendsCopyPartPending:
    case SZFriendsCopyPartLate: break;
    case SZFriendsCopyPartWritten: [self sendHave]; break;
    case SZFriendsCopyPartCorrupt: {
        uint32_t pair[2] = {block, 1};
        NSData *want = SZFriendsSyncWantBlocks(transferID, _copy.blocks.shift,
                                               [NSData dataWithBytes:pair length:sizeof pair]);
        if (want) _send(want);
        break;
    }
    case SZFriendsCopyPartRefused: [self stopBlocksCopy]; break;
    case SZFriendsCopyPartComplete:
        [self sendHave];
        [self finishBlocksCopy];
        break;
    }
    return YES;
}

- (void)sendNone:(NSString *)transferID {
    NSMutableData *none = [NSMutableData dataWithBytes:(uint8_t[]){SZFriendsSyncMessageNone} length:1];
    SZFriendsSyncPutID(none, transferID);
    _send(none);
    if ([_servingTransferID isEqualToString:transferID]) _servingTransferID = nil;
}

- (void)sendServing:(NSString *)transferID message:(NSData *)message {
    _send(message);
    _servingTransferID = transferID;
    _servingFraction = 0;
}

@end

NS_ASSUME_NONNULL_END
