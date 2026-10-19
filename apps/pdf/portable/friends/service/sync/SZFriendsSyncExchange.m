// Anti-entropy on one session between two of our devices (SZFriendsSync.h). Messages, each one SYNC frame's payload:
//   1 HELLO   version u8 (1) | vector                       what this side holds
//   2 EVENTS  count u16 | (header length u16 | header | has body u8 | [body length u32 | body])*
//   3 ACK     vector                                         what this side holds after applying an EVENTS
//   4 WANT    id length u8 | id | offset u64 | parts u16     send these parts of a file's bytes
//   5 PART    id length u8 | id | offset u64 | last u8 | bytes
//   6 NONE    id length u8 | id                              this side does not have that file's bytes
// Each side sends the events the other's vector lacks, each author's in order, with at most SZFriendsSyncWindow
// EVENTS unacknowledged, then whatever new it captures or hears from a third device. A file copies one at a time,
// SZFriendsSyncCopyAhead parts requested ahead, into received/.partial/ where a later session resumes it, and is
// published only once its whole digest matches the record.

#import <sodium.h>

#import "service/sync/SZFriendsSyncInternal.h"

NS_ASSUME_NONNULL_BEGIN

const NSUInteger SZFriendsSyncWindow = 4;
static const uint16_t SZFriendsSyncCopyParts = 8;  // parts per WANT
static const uint16_t SZFriendsSyncCopyAhead = 16; // parts requested and not yet arrived, at most
static const NSUInteger SZFriendsSyncEventsPerMessage = 200;

typedef NS_ENUM(uint8_t, SZFriendsSyncMessage) {
    SZFriendsSyncMessageHello = 1,
    SZFriendsSyncMessageEvents = 2,
    SZFriendsSyncMessageAck = 3,
    SZFriendsSyncMessageWant = 4,
    SZFriendsSyncMessagePart = 5,
    SZFriendsSyncMessageNone = 6,
};

// One file being copied from the peer.
@interface SZFriendsSyncCopy : NSObject
@property(nonatomic, copy) SZFriendsSyncFileRecord *file;
@property(nonatomic, copy) NSString *path;
@property(nonatomic, strong) NSFileHandle *handle;
@property(nonatomic) uint64_t received;
@property(nonatomic) uint64_t requested;
@end

@implementation SZFriendsSyncCopy
@end

static void SZFriendsSyncPutID(NSMutableData *data, NSString *transferID) {
    NSData *bytes = [transferID dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t length = (uint8_t)bytes.length;
    [data appendBytes:&length length:1];
    [data appendData:bytes];
}

// The transfer id at `*offset`, advancing it; nil when malformed.
static NSString *_Nullable SZFriendsSyncGetID(NSData *data, NSUInteger *offset) {
    const uint8_t *p = data.bytes;
    if (*offset >= data.length) return nil;
    NSUInteger length = p[*offset];
    if (length == 0 || length > 64 || *offset + 1 + length > data.length) return nil;
    NSString *transferID = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(*offset + 1, length)]
                                                 encoding:NSUTF8StringEncoding];
    *offset += 1 + length;
    return SZFriendsSyncLabelIsValid(transferID) && ![transferID containsString:@":"] &&
                   ![transferID containsString:@"/"]
               ? transferID
               : nil;
}

static BOOL SZFriendsSyncFileMatchesDigest(NSString *path, uint64_t size, NSData *digest) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (handle == nil) return NO;
    crypto_generichash_state state;
    crypto_generichash_init(&state, NULL, 0, 32);
    uint64_t total = 0;
    while (YES) {
        @autoreleasepool {
            NSData *chunk = [handle readDataOfLength:1024 * 1024];
            if (chunk.length == 0) break;
            total += chunk.length;
            crypto_generichash_update(&state, chunk.bytes, chunk.length);
        }
    }
    [handle closeFile];
    uint8_t computed[32];
    crypto_generichash_final(&state, computed, sizeof computed);
    return total == size && digest.length == 32 && sodium_memcmp(computed, digest.bytes, 32) == 0;
}

@implementation SZFriendsSyncExchange {
    SZFriendsSyncEngine *_engine;
    void (^_send)(NSData *message);
    NSMutableDictionary<NSData *, NSNumber *> *_sent; // what the peer has, or will once our EVENTS arrive
    SZFriendsSyncVector *_peerVector;                 // what the peer said it holds
    NSUInteger _outstanding;
    BOOL _stopped;
    SZFriendsSyncCopy *_copy;
    NSMutableSet<NSString *> *_unavailable;
}

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
    return _copy.file.size > 0 ? (double)_copy.received / (double)_copy.file.size : 0;
}

- (void)stop {
    _stopped = YES;
    [_copy.handle closeFile];
    _copy = nil;
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
        [_copy.handle closeFile];
        _copy = nil;
    }
    [self startNextCopy];
}

#pragma mark - Files

- (void)startNextCopy {
    if (_copy != nil || _stopped) return;
    for (SZFriendsSyncFileRecord *file in [_engine filesWanted]) {
        if (![file.holders containsObject:_peerKey] || [_unavailable containsObject:file.transferID]) continue;
        NSString *partial = [_engine.receivedDirectory stringByAppendingPathComponent:@".partial"];
        [NSFileManager.defaultManager createDirectoryAtPath:partial withIntermediateDirectories:YES
                                                 attributes:@{NSFilePosixPermissions : @0700} error:NULL];
        NSString *path = [partial stringByAppendingPathComponent:[@"sync-" stringByAppendingString:file.transferID]];
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
            [NSFileManager.defaultManager createFileAtPath:path contents:nil
                                                attributes:@{NSFilePosixPermissions : @0600}];
        }
        NSFileHandle *handle = [NSFileHandle fileHandleForUpdatingAtPath:path];
        if (handle == nil) continue;
        uint64_t held = [handle seekToEndOfFile];
        // What arrived on an earlier session counts; anything past the file's size cannot be its bytes.
        if (held > file.size) {
            [handle truncateFileAtOffset:0];
            held = 0;
        }
        SZFriendsSyncCopy *copy = [[SZFriendsSyncCopy alloc] init];
        copy.file = file;
        copy.path = path;
        copy.handle = handle;
        copy.received = held;
        copy.requested = held;
        _copy = copy;
        [self requestMore];
        return;
    }
}

- (void)requestMore {
    SZFriendsSyncCopy *copy = _copy;
    uint64_t size = copy.file.size;
    BOOL first = copy.requested == copy.received;
    while ((copy.requested < size || (size == 0 && first)) &&
           copy.requested - copy.received < (uint64_t)SZFriendsSyncCopyAhead * SZFriendsSyncFilePartMax) {
        NSMutableData *want = [NSMutableData dataWithBytes:(uint8_t[]){SZFriendsSyncMessageWant} length:1];
        SZFriendsSyncPutID(want, copy.file.transferID);
        SZFriendsSyncPutU64(want, copy.requested);
        uint8_t parts[2] = {0, SZFriendsSyncCopyParts};
        [want appendBytes:parts length:2];
        _send(want);
        copy.requested = MIN(size, copy.requested + (uint64_t)SZFriendsSyncCopyParts * SZFriendsSyncFilePartMax);
        if (size == 0) break;
        first = NO;
    }
}

- (BOOL)receiveWant:(NSData *)message error:(NSError **)error {
    NSUInteger offset = 1;
    NSString *transferID = SZFriendsSyncGetID(message, &offset);
    if (transferID == nil || offset + 10 != message.length) {
        return SZFriendsSyncFail(error, SZFriendsSyncErrorMalformed, @"a WANT that does not decode");
    }
    const uint8_t *p = message.bytes;
    uint64_t start = SZFriendsSyncGetU64(p + offset);
    NSUInteger parts = MIN(((NSUInteger)p[offset + 8] << 8) | p[offset + 9], (NSUInteger)SZFriendsSyncCopyAhead);
    NSString *path = [_engine localPathOfFile:transferID];
    SZFriendsTransferRecord *transfer = path ? [_engine.store transferRecordWithID:transferID] : nil;
    NSFileHandle *handle = path ? [NSFileHandle fileHandleForReadingAtPath:path] : nil;
    if (handle == nil || start > transfer.size) {
        NSMutableData *none = [NSMutableData dataWithBytes:(uint8_t[]){SZFriendsSyncMessageNone} length:1];
        SZFriendsSyncPutID(none, transferID);
        _send(none);
        return YES;
    }
    [handle seekToFileOffset:start];
    uint64_t at = start;
    for (NSUInteger i = 0; i < parts; i++) {
        uint64_t length = MIN((uint64_t)SZFriendsSyncFilePartMax, transfer.size - at);
        NSData *bytes = [handle readDataOfLength:(NSUInteger)length];
        BOOL last = at + bytes.length >= transfer.size;
        NSMutableData *part = [NSMutableData dataWithBytes:(uint8_t[]){SZFriendsSyncMessagePart} length:1];
        SZFriendsSyncPutID(part, transferID);
        SZFriendsSyncPutU64(part, at);
        uint8_t flag = last;
        [part appendBytes:&flag length:1];
        [part appendData:bytes];
        _send(part);
        at += bytes.length;
        if (last || bytes.length == 0) break;
    }
    [handle closeFile];
    _servingTransferID = at >= transfer.size ? nil : transferID;
    _servingFraction = transfer.size > 0 ? (double)at / (double)transfer.size : 1;
    return YES;
}

- (BOOL)receivePart:(NSData *)message error:(NSError **)error {
    NSUInteger offset = 1;
    NSString *transferID = SZFriendsSyncGetID(message, &offset);
    if (transferID == nil || offset + 9 > message.length) {
        return SZFriendsSyncFail(error, SZFriendsSyncErrorMalformed, @"a PART that does not decode");
    }
    const uint8_t *p = message.bytes;
    uint64_t at = SZFriendsSyncGetU64(p + offset);
    BOOL last = p[offset + 8] != 0;
    NSData *bytes = [message subdataWithRange:NSMakeRange(offset + 9, message.length - offset - 9)];
    SZFriendsSyncCopy *copy = _copy;
    // A part of a copy this side gave up, or one already written: nothing to do.
    if (copy == nil || ![copy.file.transferID isEqualToString:transferID] || at != copy.received) return YES;
    if (copy.received + bytes.length > copy.file.size || (last && copy.received + bytes.length != copy.file.size)) {
        [self abandonCopy:YES];
        return YES;
    }
    [copy.handle writeData:bytes];
    copy.received += bytes.length;
    if (copy.received < copy.file.size) {
        [self requestMore];
        return YES;
    }
    [copy.handle synchronizeFile];
    [copy.handle closeFile];
    _copy = nil;
    if (SZFriendsSyncFileMatchesDigest(copy.path, copy.file.size, copy.file.contentDigest)) {
        [_engine adoptCopiedFile:transferID atPath:copy.path error:NULL];
    } else {
        [NSFileManager.defaultManager removeItemAtPath:copy.path error:NULL];
        [_unavailable addObject:transferID];
    }
    [self startNextCopy];
    return YES;
}

- (BOOL)receiveNone:(NSData *)message error:(NSError **)error {
    NSUInteger offset = 1;
    NSString *transferID = SZFriendsSyncGetID(message, &offset);
    if (transferID == nil || offset != message.length) {
        return SZFriendsSyncFail(error, SZFriendsSyncErrorMalformed, @"a NONE that does not decode");
    }
    [_unavailable addObject:transferID];
    if ([_copy.file.transferID isEqualToString:transferID]) [self abandonCopy:NO];
    [self startNextCopy];
    return YES;
}

- (void)abandonCopy:(BOOL)discard {
    SZFriendsSyncCopy *copy = _copy;
    _copy = nil;
    [copy.handle closeFile];
    if (discard) [NSFileManager.defaultManager removeItemAtPath:copy.path error:NULL];
    if (copy) [_unavailable addObject:copy.file.transferID];
}

@end

NS_ASSUME_NONNULL_END
