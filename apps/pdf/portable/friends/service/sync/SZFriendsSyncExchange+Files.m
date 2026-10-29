// Files copied between a person's own computers inside the sync exchange (SZFriendsSyncExchange.h), as the Rust core's
// sync/exchange_copies.rs: which file is copied next, its WANTs, PARTs and NONEs, and the same file by blocks when both
// ends have fast transfers.

#import "service/sync/SZFriendsSyncExchangeInternal.h"

NS_ASSUME_NONNULL_BEGIN

@implementation SZFriendsSyncExchange (Files)

#pragma mark - Files

- (void)startNextCopy {
    if (_copy != nil || _stopped || self.pulls) return;
    for (SZFriendsSyncFileRecord *file in [_engine filesWanted]) {
        if (![file.holders containsObject:_peerKey] || [_unavailable containsObject:file.transferID]) continue;
        NSString *partial = [_engine.receivedDirectory stringByAppendingPathComponent:@".partial"];
        [NSFileManager.defaultManager createDirectoryAtPath:partial withIntermediateDirectories:YES
                                                 attributes:@{NSFilePosixPermissions : @0700} error:NULL];
        NSString *path = [partial stringByAppendingPathComponent:[@"sync-" stringByAppendingString:file.transferID]];
        if (self.fast) {
            // By blocks, from what the map beside the copy says is here (ADR 0018 § 4).
            SZFriendsBlockCopy *blocks = [SZFriendsBlockCopy openWithSize:file.size digest:file.contentDigest
                                                                  partial:path];
            NSData *want = blocks ? SZFriendsSyncWantBlocks(file.transferID, blocks.shift, blocks.missing) : nil;
            if (want == nil) continue;
            SZFriendsSyncCopy *copy = [[SZFriendsSyncCopy alloc] init];
            copy.file = file;
            copy.path = path;
            copy.blocks = blocks;
            _copy = copy;
            _send(want);
            return;
        }
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
        // Listed as holding it and it is gone (moved or deleted here): every device hears so now (ADR 0016).
        if (path == nil) [_engine captureLocalChanges];
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
- (BOOL)receiveWantBlocks:(NSData *)message error:(NSError **)error {
    NSUInteger offset = 1;
    NSString *transferID = SZFriendsSyncGetID(message, &offset);
    const uint8_t *p = message.bytes;
    NSData *ranges = transferID != nil && offset < message.length
                         ? SZFriendsCopyRangesDecode(p + offset + 1, message.length - offset - 1)
                         : nil;
    if (ranges == nil) return SZFriendsSyncFail(error, SZFriendsSyncErrorMalformed, @"a WANT BLOCKS that does not decode");
    NSString *path = [_engine localPathOfFile:transferID];
    SZFriendsTransferRecord *transfer = path ? [_engine.store transferRecordWithID:transferID] : nil;
    if (transfer == nil || self.wantBlocks == nil) {
        [self sendNone:transferID];
        if (path == nil) [_engine captureLocalChanges]; // listed as holding it and it is gone: every device hears so
        return YES;
    }
    self.wantBlocks(transferID, path, transfer.size, p[offset], ranges);
    return YES;
}
#pragma mark - Requester by blocks

- (BOOL)receiveBlocksFollow:(NSData *)message error:(NSError **)error {
    NSUInteger offset = 1;
    NSString *transferID = SZFriendsSyncGetID(message, &offset);
    if (transferID == nil || offset + 33 != message.length) {
        return SZFriendsSyncFail(error, SZFriendsSyncErrorMalformed, @"a BLOCKS FOLLOW that does not decode");
    }
    const uint8_t *p = message.bytes;
    if (self.pullAnswer && self.pullAnswer(transferID, [message subdataWithRange:NSMakeRange(offset, 32)],
                                           p[offset + 32], NO)) {
        return YES;
    }
    if (_copy.blocks == nil || ![_copy.file.transferID isEqualToString:transferID]) return YES; // late
    if (![_copy.blocks followRoot:[message subdataWithRange:NSMakeRange(offset, 32)] shift:p[offset + 32]]) {
        [self stopBlocksCopy]; // a tree that cannot be this file's: tried again on the next session
    }
    return YES;
}
- (void)sendHave {
    NSData *have = [_copy.blocks takeHave];
    NSData *wire = SZFriendsSyncHexBytes(_copy.file.transferID);
    if (have.length == 0 || wire == nil || self.sendFrame == nil) return;
    for (SZFriendsFrame *frame in SZFriendsHaveFrames(wire, have, [NSData data])) self.sendFrame(frame);
}
- (void)stopBlocksCopy {
    NSString *transferID = _copy.file.transferID;
    [self endCopy];
    if (transferID) [_unavailable addObject:transferID];
    [self startNextCopy];
}
- (void)finishBlocksCopy {
    SZFriendsSyncCopy *copy = _copy;
    _copy = nil;
    NSString *path = [copy.blocks finish];
    if (path != nil) [_engine adoptCopiedFile:copy.file.transferID atPath:path error:NULL];
    else [_unavailable addObject:copy.file.transferID];
    [self startNextCopy];
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
    if (copy == nil || copy.blocks != nil || ![copy.file.transferID isEqualToString:transferID] ||
        at != copy.received) {
        return YES;
    }
    if (copy.received + bytes.length > copy.file.size || (last && copy.received + bytes.length != copy.file.size)) {
        [self abandonCopy:YES];
        return YES;
    }
    if (![copy.handle writeData:bytes error:NULL]) {
        // No room left here: what arrived goes, and so does the Get; the item offers Get, which then says so.
        [self abandonCopy:YES];
        [_engine cancelFileRequest:transferID error:NULL];
        return YES;
    }
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
        SZFriendsRemoveCopy(copy.path);
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
    if (self.pullAnswer && self.pullAnswer(transferID, nil, 0, YES)) return YES;
    [_unavailable addObject:transferID];
    if ([_copy.file.transferID isEqualToString:transferID]) [self abandonCopy:NO];
    [self startNextCopy];
    return YES;
}
- (void)abandonCopy:(BOOL)discard {
    SZFriendsSyncCopy *copy = _copy;
    [self endCopy];
    if (discard) SZFriendsRemoveCopy(copy.path);
    if (copy) [_unavailable addObject:copy.file.transferID];
}

@end

NS_ASSUME_NONNULL_END
