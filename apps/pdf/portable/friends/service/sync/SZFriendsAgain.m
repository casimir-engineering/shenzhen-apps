// Getting a file again from the friend who sent it (SZFriendsAgain.h, ADR 0016): the messages, the requester's copy
// and the server's parts. Copies work as ADR 0014's between own devices: parts requested ahead, written in order,
// resumed from the partial file, kept only when the whole digest matches.

#import "service/sync/SZFriendsAgain.h"

#import <sodium.h>

#import "service/sync/SZFriendsSync.h"
#import "service/transfer/SZFriendsBlockCopy.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint8_t, SZFriendsAgainMessage) {
    SZFriendsAgainMessageWant = 1,
    SZFriendsAgainMessagePart = 2,
    SZFriendsAgainMessageNone = 3,
    SZFriendsAgainMessageWantBlocks = 4,
    SZFriendsAgainMessageBlocksFollow = 5,
};

static const uint16_t SZFriendsAgainParts = 8;           // parts per WANT
static const uint16_t SZFriendsAgainAhead = 16;          // parts requested and not yet arrived, at most
static const NSTimeInterval SZFriendsAgainOneAtATime = 60; // another file waits this long after the last WANT

@implementation SZFriendsAgainFile
@end

BOOL SZFriendsFileHasDigest(NSString *path, uint64_t size, NSData *digest) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (handle == nil || digest.length != 32) return NO;
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
    return total == size && sodium_memcmp(computed, digest.bytes, 32) == 0;
}

void SZFriendsRemoveCopy(NSString *path) {
    [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
    [NSFileManager.defaultManager removeItemAtPath:[path stringByAppendingString:@".map"] error:NULL];
}

static NSData *_Nullable SZFriendsAgainID(NSString *transferID) {
    if (transferID.length != 32) return nil;
    NSMutableData *bytes = [NSMutableData dataWithLength:16];
    for (NSUInteger i = 0; i < 16; i++) {
        unsigned value = 0;
        NSString *pair = [transferID substringWithRange:NSMakeRange(i * 2, 2)];
        NSScanner *scanner = [NSScanner scannerWithString:pair];
        if (![scanner scanHexInt:&value] || !scanner.isAtEnd) return nil;
        ((uint8_t *)bytes.mutableBytes)[i] = (uint8_t)value;
    }
    return bytes;
}

static NSString *SZFriendsAgainTransferID(const uint8_t *bytes) {
    NSMutableString *hex = [NSMutableString stringWithCapacity:32];
    for (NSUInteger i = 0; i < 16; i++) [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}

static void SZFriendsAgainPutU64(NSMutableData *data, uint64_t value) {
    uint8_t bytes[8];
    for (int i = 7; i >= 0; i--, value >>= 8) bytes[i] = (uint8_t)value;
    [data appendBytes:bytes length:8];
}

static uint64_t SZFriendsAgainGetU64(const uint8_t *bytes) {
    uint64_t value = 0;
    for (int i = 0; i < 8; i++) value = (value << 8) | bytes[i];
    return value;
}

static NSMutableData *SZFriendsAgainHead(SZFriendsAgainMessage type, NSData *identifier) {
    NSMutableData *message = [NSMutableData dataWithBytes:&type length:1];
    [message appendData:identifier];
    return message;
}

// One file being copied from the friend.
@interface SZFriendsAgainCopy : NSObject
@property(nonatomic, strong) SZFriendsAgainFile *file;
@property(nonatomic, copy) NSData *identifier;
@property(nonatomic, copy) NSString *path;
@property(nonatomic, strong) NSFileHandle *handle;
@property(nonatomic) uint64_t received;
@property(nonatomic) uint64_t requested;
@property(nonatomic, strong, nullable) SZFriendsBlockCopy *blocks; // by blocks: `handle` is then unused
@end

@implementation SZFriendsAgainCopy
@end

@implementation SZFriendsAgainExchange {
    NSString *_directory;
    void (^_send)(NSData *message);
    SZFriendsAgainCopy *_copy;
    NSMutableSet<NSString *> *_unavailable; // NOT NOW this session
    BOOL _stopped;
    NSString *_servingID;
    NSDate *_servingAt;
    BOOL _servingDone;
}

- (instancetype)initWithPartialDirectory:(NSString *)directory send:(void (^)(NSData *message))send {
    if ((self = [super init])) {
        _directory = [directory copy];
        _send = [send copy];
        _unavailable = [NSMutableSet set];
    }
    return self;
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

#pragma mark - Requester

- (void)pump {
    if (_copy != nil || _stopped || self.wanted == nil) return;
    NSFileManager *files = NSFileManager.defaultManager;
    for (SZFriendsAgainFile *file in self.wanted()) {
        NSData *identifier = SZFriendsAgainID(file.transferID);
        if (identifier == nil || [_unavailable containsObject:file.transferID]) continue;
        [files createDirectoryAtPath:_directory withIntermediateDirectories:YES
                          attributes:@{NSFilePosixPermissions : @0700} error:NULL];
        NSString *path = [_directory stringByAppendingPathComponent:[@"again-" stringByAppendingString:file.transferID]];
        if (self.fast) {
            // By blocks, from what the map beside the copy says is here (ADR 0018 § 4).
            SZFriendsBlockCopy *blocks = [SZFriendsBlockCopy openWithSize:file.size digest:file.digest partial:path];
            NSData *want = blocks ? SZFriendsAgainWantBlocks(file.transferID, blocks.shift, blocks.missing) : nil;
            if (want == nil) continue;
            SZFriendsAgainCopy *copy = [[SZFriendsAgainCopy alloc] init];
            copy.file = file;
            copy.identifier = identifier;
            copy.path = path;
            copy.blocks = blocks;
            _copy = copy;
            _send(want);
            return;
        }
        if (![files fileExistsAtPath:path]) {
            [files createFileAtPath:path contents:nil attributes:@{NSFilePosixPermissions : @0600}];
        }
        NSFileHandle *handle = [NSFileHandle fileHandleForUpdatingAtPath:path];
        if (handle == nil) continue;
        uint64_t held = [handle seekToEndOfFile];
        if (held > file.size) { // not this file's bytes
            [handle truncateFileAtOffset:0];
            held = 0;
        }
        SZFriendsAgainCopy *copy = [[SZFriendsAgainCopy alloc] init];
        copy.file = file;
        copy.identifier = identifier;
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
    SZFriendsAgainCopy *copy = _copy;
    uint64_t size = copy.file.size;
    BOOL first = copy.requested == copy.received;
    while ((copy.requested < size || (size == 0 && first)) &&
           copy.requested - copy.received < (uint64_t)SZFriendsAgainAhead * SZFriendsSyncFilePartMax) {
        NSMutableData *want = SZFriendsAgainHead(SZFriendsAgainMessageWant, copy.identifier);
        SZFriendsAgainPutU64(want, copy.requested);
        uint8_t parts[2] = {0, SZFriendsAgainParts};
        [want appendBytes:parts length:2];
        _send(want);
        copy.requested = MIN(size, copy.requested + (uint64_t)SZFriendsAgainParts * SZFriendsSyncFilePartMax);
        if (size == 0) break;
        first = NO;
    }
}

- (void)abandon:(NSString *)transferID {
    if (![_copy.file.transferID isEqualToString:transferID]) return;
    [self endCopy];
    [self pump];
}

#pragma mark - Requester by blocks

- (void)sendHave {
    NSData *have = [_copy.blocks takeHave];
    NSData *wire = SZFriendsAgainID(_copy.file.transferID);
    if (have.length == 0 || wire == nil || self.sendFrame == nil) return;
    for (SZFriendsFrame *frame in SZFriendsHaveFrames(wire, have, [NSData data])) self.sendFrame(frame);
}

// A copy by blocks that cannot go on now (a tree or leaves that cannot be this file's, a PART out of place): kept for
// the next session, and the next wanted file starts.
- (void)stopBlocksCopy {
    NSString *transferID = _copy.file.transferID;
    [self endCopy];
    if (transferID) [_unavailable addObject:transferID];
    [self pump];
}

- (void)finishBlocksCopy {
    SZFriendsAgainCopy *copy = _copy;
    _copy = nil;
    NSString *path = [copy.blocks finish];
    if (path != nil) {
        if (self.arrived) self.arrived(copy.file, path);
    } else if (self.notThere) {
        self.notThere(copy.file.transferID); // not the file it was offered as: gone, as a copy by offset
    }
    [self pump];
}

- (BOOL)receiveHashes:(NSData *)hashes index:(uint32_t)index forTransfer:(NSString *)transferID {
    if (_copy.blocks == nil || ![_copy.file.transferID isEqualToString:transferID]) return NO;
    BOOL done = NO;
    if (![_copy.blocks acceptHashes:hashes index:index done:&done]) {
        [self stopBlocksCopy];
        return YES;
    }
    [self sendHave];
    if (done && _copy.blocks.complete) [self finishBlocksCopy]; // every block was here already
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
        NSData *want = SZFriendsAgainWantBlocks(transferID, _copy.blocks.shift,
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

- (void)finishCopy {
    SZFriendsAgainCopy *copy = _copy;
    _copy = nil;
    [copy.handle synchronizeFile];
    [copy.handle closeFile];
    if (SZFriendsFileHasDigest(copy.path, copy.file.size, copy.file.digest)) {
        if (self.arrived) self.arrived(copy.file, copy.path);
    } else {
        // Not the bytes it was sent as: the friend's file changed while it was read.
        SZFriendsRemoveCopy(copy.path);
        if (self.notThere) self.notThere(copy.file.transferID);
    }
}

- (void)receivePart:(NSString *)transferID offset:(uint64_t)at last:(BOOL)last bytes:(NSData *)bytes {
    SZFriendsAgainCopy *copy = _copy;
    // A part of a copy this side gave up, or one already written: nothing to do.
    if (copy == nil || copy.blocks != nil || ![copy.file.transferID isEqualToString:transferID] ||
        at != copy.received) {
        return;
    }
    if (copy.received + bytes.length > copy.file.size || (last && copy.received + bytes.length != copy.file.size)) {
        _copy = nil;
        [copy.handle closeFile];
        SZFriendsRemoveCopy(copy.path);
        [_unavailable addObject:transferID];
        return;
    }
    if (![copy.handle writeData:bytes error:NULL]) {
        _copy = nil;
        [copy.handle closeFile];
        SZFriendsRemoveCopy(copy.path);
        if (self.noRoom) self.noRoom(transferID);
        [self pump];
        return;
    }
    copy.received += bytes.length;
    if (copy.received < copy.file.size) {
        [self requestMore];
        return;
    }
    [self finishCopy];
    [self pump];
}

- (void)receiveNone:(NSString *)transferID reason:(SZFriendsAgainAnswer)reason {
    BOOL copying = [_copy.file.transferID isEqualToString:transferID];
    if (copying) {
        NSString *path = _copy.path;
        [self endCopy];
        if (reason == SZFriendsAgainAnswerNotHere) SZFriendsRemoveCopy(path);
    }
    [_unavailable addObject:transferID];
    if (reason == SZFriendsAgainAnswerNotHere && self.notThere) self.notThere(transferID);
    [self pump];
}

#pragma mark - Server

- (void)receiveWant:(NSString *)transferID identifier:(NSData *)identifier offset:(uint64_t)start
              parts:(NSUInteger)parts {
    void (^none)(SZFriendsAgainAnswer) = ^(SZFriendsAgainAnswer answer) {
        NSMutableData *message = SZFriendsAgainHead(SZFriendsAgainMessageNone, identifier);
        uint8_t reason = answer;
        [message appendBytes:&reason length:1];
        self->_send(message);
    };
    // One file at a time: another waits until this one is done or has not been asked for in a minute.
    BOOL busy = _servingID != nil && ![_servingID isEqualToString:transferID] && !_servingDone &&
                [[NSDate date] timeIntervalSinceDate:_servingAt] < SZFriendsAgainOneAtATime;
    if (busy) {
        none(SZFriendsAgainAnswerNotNow);
        return;
    }
    uint64_t size = 0;
    SZFriendsAgainAnswer answer = SZFriendsAgainAnswerNotHere;
    NSString *path = self.servePath ? self.servePath(transferID, &size, &answer) : nil;
    NSFileHandle *handle = path ? [NSFileHandle fileHandleForReadingAtPath:path] : nil;
    if (handle == nil || start > size) {
        none(handle == nil ? answer : SZFriendsAgainAnswerNotHere);
        return;
    }
    [handle seekToFileOffset:start];
    uint64_t at = start;
    for (NSUInteger i = 0; i < MIN(parts, (NSUInteger)SZFriendsAgainAhead); i++) {
        uint64_t length = MIN((uint64_t)SZFriendsSyncFilePartMax, size - at);
        NSData *bytes = [handle readDataOfLength:(NSUInteger)length];
        BOOL last = at + bytes.length >= size;
        NSMutableData *part = SZFriendsAgainHead(SZFriendsAgainMessagePart, identifier);
        SZFriendsAgainPutU64(part, at);
        uint8_t flag = last;
        [part appendBytes:&flag length:1];
        [part appendData:bytes];
        _send(part);
        at += bytes.length;
        if (last || bytes.length == 0) break;
    }
    [handle closeFile];
    _servingID = transferID;
    _servingAt = [NSDate date];
    _servingDone = at >= size;
}

- (nullable NSString *)beginServingBlocks:(NSString *)transferID size:(uint64_t *)size {
    BOOL busy = _servingID != nil && ![_servingID isEqualToString:transferID] && !_servingDone &&
                [[NSDate date] timeIntervalSinceDate:_servingAt] < SZFriendsAgainOneAtATime;
    if (busy) {
        [self sendNone:transferID reason:SZFriendsAgainAnswerNotNow];
        return nil;
    }
    SZFriendsAgainAnswer answer = SZFriendsAgainAnswerNotHere;
    NSString *path = self.servePath ? self.servePath(transferID, size, &answer) : nil;
    if (path == nil) {
        [self sendNone:transferID reason:answer];
        return nil;
    }
    _servingID = transferID;
    _servingAt = [NSDate date];
    _servingDone = NO;
    return path;
}

- (void)sendNone:(NSString *)transferID reason:(SZFriendsAgainAnswer)reason {
    NSData *identifier = SZFriendsAgainID(transferID);
    if (identifier == nil) return;
    NSMutableData *message = SZFriendsAgainHead(SZFriendsAgainMessageNone, identifier);
    uint8_t byte = reason;
    [message appendBytes:&byte length:1];
    _send(message);
}

#pragma mark - Messages

- (BOOL)receiveMessage:(NSData *)message {
    const uint8_t *p = message.bytes;
    if (message.length < 17) return NO;
    NSData *identifier = [message subdataWithRange:NSMakeRange(1, 16)];
    NSString *transferID = SZFriendsAgainTransferID(p + 1);
    switch (p[0]) {
    case SZFriendsAgainMessageWant:
        if (message.length != 27) return NO;
        [self receiveWant:transferID identifier:identifier offset:SZFriendsAgainGetU64(p + 17)
                    parts:((NSUInteger)p[25] << 8) | p[26]];
        return YES;
    case SZFriendsAgainMessagePart:
        if (message.length < 26 || message.length - 26 > SZFriendsSyncFilePartMax) return NO;
        [self receivePart:transferID offset:SZFriendsAgainGetU64(p + 17) last:p[25] != 0
                    bytes:[message subdataWithRange:NSMakeRange(26, message.length - 26)]];
        return YES;
    case SZFriendsAgainMessageNone:
        if (message.length != 18) return NO;
        // A reason this side does not know yet reads as "not now": nothing is concluded from it.
        [self receiveNone:transferID reason:p[17] == SZFriendsAgainAnswerNotHere ? SZFriendsAgainAnswerNotHere
                                                                                 : SZFriendsAgainAnswerNotNow];
        return YES;
    case SZFriendsAgainMessageWantBlocks: {
        NSData *ranges = message.length > 18 ? SZFriendsCopyRangesDecode(p + 18, message.length - 18) : nil;
        if (ranges == nil) return NO;
        if (self.wantBlocks) self.wantBlocks(transferID, p[17], ranges);
        else [self sendNone:transferID reason:SZFriendsAgainAnswerNotNow];
        return YES;
    }
    case SZFriendsAgainMessageBlocksFollow: {
        if (message.length != 17 + 33) return NO;
        if (_copy.blocks == nil || ![_copy.file.transferID isEqualToString:transferID]) return YES; // late
        if (![_copy.blocks followRoot:[message subdataWithRange:NSMakeRange(17, 32)] shift:p[49]]) {
            [self stopBlocksCopy]; // a tree that cannot be this file's: tried again on the next session
        }
        return YES;
    }
    default:
        return YES; // a later kind of message this side does not know: nothing to do
    }
}

@end

NS_ASSUME_NONNULL_END
