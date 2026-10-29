// The receiving side of a transfer: chunks into a private staging file, durable progress, digest verification,
// publishing into the folder received files go to, and crash recovery (ADR 0003 § Durable progress, § Crash
// recovery; ADR 0001 § Files).

#import "service/store/SZFriendsTransferReceiverInternal.h"

NS_ASSUME_NONNULL_BEGIN

// ADR 0003: progress becomes durable every 4 MiB or every second, whichever comes first.
@implementation SZFriendsReceiving
- (instancetype)init {
    if ((self = [super init])) fd = -1; // ivars start at 0, which is stdin
    return self;
}
- (void)dealloc {
    if (fd >= 0) close(fd);
}
@end

@implementation SZFriendsTransferReceiver

- (SZFriendsStore *)store {
    return _store;
}

- (NSString *)partialDirectory {
    return _partialDirectory;
}

- (NSMutableDictionary<NSString *, id> *)blockDownloads {
    return _blockDownloads;
}

- (instancetype)initWithStore:(SZFriendsStore *)store stateDirectory:(NSString *)stateDirectory {
    if ((self = [super init])) {
        _store = store;
        _stateDirectory = [stateDirectory copy];
        _receivedDirectory = [stateDirectory stringByAppendingPathComponent:@"received"];
        _partialDirectory = [_receivedDirectory stringByAppendingPathComponent:@".partial"];
        _open = [NSMutableDictionary dictionary];
        _blockDownloads = [NSMutableDictionary dictionary];
        _clock = ^NSDate * { return [NSDate date]; };
    }
    return self;
}

- (void)forgetTransfer:(NSString *)transferID {
    [_store performOnWriter:^(SZFriendsStoreDB *_Nullable db) {
        (void)db;
        [self->_open removeObjectForKey:transferID];
    }];
}

// Reopens a download after a restart or a route change: bytes past the durable count were never confirmed, so they
// are cut off, and the digest is rebuilt from the durable prefix once ("re-hashing the partial file once").
- (nullable SZFriendsReceiving *)openIn:(SZFriendsStoreDB *)db
                                 record:(SZFriendsTransferRecord *)record
                                  error:(NSError **)error {
    SZFriendsReceiving *receiving = _open[record.transferID];
    if (receiving) return receiving;
    NSString *partial = SZFriendsTransferRowPartialPath(db, record.transferID);
    if (!partial) {
        SZFriendsFail(error, SZFriendsReceiveError(SZFriendsStoreErrorInvalid, @"no staging file"));
        return nil;
    }
    int fd = open(partial.fileSystemRepresentation, O_RDWR | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) {
        SZFriendsFail(error, SZFriendsReceiveError(SZFriendsStoreErrorFileMissing, partial));
        return nil;
    }
    receiving = [[SZFriendsReceiving alloc] init];
    receiving->fd = fd;
    receiving.partialPath = partial;
    receiving.lastCommit = self.clock();
    struct stat info;
    uint64_t durable = record.verifiedBytes;
    if (fstat(fd, &info) == 0 && (uint64_t)info.st_size < durable) durable = (uint64_t)info.st_size;
    if (ftruncate(fd, (off_t)durable) != 0 || (durable != record.verifiedBytes &&
        !SZFriendsTransferRowUpdate(db, record.transferID, @{@"verified_bytes" : @(durable)}, error))) {
        SZFriendsFail(error, SZFriendsReceiveError(SZFriendsStoreErrorDatabase, @"cannot reset staging file"));
        return nil;
    }
    crypto_generichash_init(&receiving->hash, NULL, 0, 32);
    if (!SZFriendsHashPrefix(fd, durable, &receiving->hash)) {
        SZFriendsFail(error, SZFriendsReceiveError(SZFriendsStoreErrorFileMissing, @"cannot read staging file"));
        return nil;
    }
    receiving->written = durable;
    receiving->durable = durable;
    _open[record.transferID] = receiving;
    return receiving;
}

// The bytes ordered first, the commit second, and the commit's own F_FULLFSYNC makes both durable: the database never
// claims a byte the disk could still lose (ADR 0003), and a batch costs one full flush of the drive, not two (ADR 0018
// § 4; F_FULLFSYNC flushes the whole drive cache, so flushing the file first and the commit again only repeated it;
// the partial file and the database both live in the state directory, on one volume).
- (BOOL)commit:(SZFriendsReceiving *)receiving transfer:(NSString *)transferID db:(SZFriendsStoreDB *)db
         error:(NSError **)error {
    if (receiving->durable == receiving->written) return YES;
    if (!SZFriendsOrderWrites(receiving->fd)) {
        return SZFriendsFail(error, SZFriendsReceiveError(SZFriendsStoreErrorDatabase, @"fsync failed"));
    }
    uint64_t written = receiving->written;
    BOOL ok = [db transaction:^BOOL(NSError **inner) {
        return SZFriendsTransferRowUpdate(db, transferID, @{@"verified_bytes" : @(written)}, inner);
    } error:error];
    if (!ok) return NO;
    receiving->durable = written;
    receiving.lastCommit = self.clock();
    return YES;
}

// The row must say Receiving, for this sender, on every chunk: a cancel, decline or Delete history in between ends
// the download, and a chunk for anything else is unsolicited (ADR 0001: no CHUNK moves before acceptance). A chunk
// naming no conversation is no friend's, so it is refused too: there is no unchecked form (security review).
- (nullable SZFriendsTransferRecord *)receivingRecord:(SZFriendsStoreDB *)db
                                           transferID:(NSString *)transferID
                                         conversation:(NSString *)conversationID
                                                error:(NSError **)error {
    SZFriendsTransferRecord *record = SZFriendsTransferRowLoad(db, transferID);
    BOOL live = record && !record.outgoing && record.state == SZFriendsTransferStateReceiving;
    BOOL theirs = conversationID.length > 0 && [record.conversationID isEqualToString:conversationID];
    if (!live || !theirs) {
        // Only the owner's own stream may lose its open file: a stranger naming the id must not disturb it.
        if (!live) [_open removeObjectForKey:transferID];
        SZFriendsFail(error, SZFriendsReceiveError(SZFriendsStoreErrorInvalid, @"unsolicited chunk"));
        return nil;
    }
    return record;
}

- (BOOL)onWriter:(BOOL (^)(SZFriendsStoreDB *db, NSError **error))body error:(NSError **)error {
    __block BOOL ok = NO;
    __block NSError *failure = nil;
    [_store performOnWriter:^(SZFriendsStoreDB *_Nullable db) {
        if (!db) {
            failure = SZFriendsReceiveError(SZFriendsStoreErrorOpenFailed, @"the store is closed");
            return;
        }
        NSError *inner = nil;
        ok = body(db, &inner);
        failure = inner;
    }];
    if (!ok && error) *error = failure;
    return ok;
}

- (BOOL)appendChunk:(NSData *)bytes atOffset:(uint64_t)offset toTransfer:(NSString *)transferID
   fromConversation:(NSString *)conversationID error:(NSError **)error {
    return [self onWriter:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        SZFriendsTransferRecord *record = [self receivingRecord:db transferID:transferID conversation:conversationID
                                                          error:inner];
        SZFriendsReceiving *receiving = record ? [self openIn:db record:record error:inner] : nil;
        if (!receiving) return NO;
        if (offset != receiving->written || bytes.length > record.size - receiving->written) {
            return SZFriendsFail(inner, SZFriendsReceiveError(SZFriendsStoreErrorInvalid, @"chunk out of place"));
        }
        const uint8_t *data = bytes.bytes;
        size_t done = 0;
        while (done < bytes.length) {
            ssize_t put = pwrite(receiving->fd, data + done, bytes.length - done, (off_t)(offset + done));
            if (put < 0 && errno == EINTR) continue;
            if (put <= 0) {
                int number = errno;
                ftruncate(receiving->fd, (off_t)receiving->written);
                SZFriendsStoreError code = number == ENOSPC ? SZFriendsStoreErrorDiskFull : SZFriendsStoreErrorDatabase;
                return SZFriendsFail(inner, SZFriendsReceiveError(code, @"cannot write the staging file"));
            }
            done += (size_t)put;
        }
        crypto_generichash_update(&receiving->hash, data, bytes.length);
        receiving->written += bytes.length;
        BOOL due = receiving->written - receiving->durable >= SZFriendsDurableBatchBytes ||
                   [self.clock() timeIntervalSinceDate:receiving.lastCommit] >= SZFriendsDurableBatchInterval ||
                   receiving->written == record.size;
        return due ? [self commit:receiving transfer:transferID db:db error:inner] : YES;
    } error:error];
}

- (BOOL)flushWithError:(NSError **)error {
    return [self onWriter:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        for (NSString *transferID in self->_open.allKeys) {
            if (![self commit:self->_open[transferID] transfer:transferID db:db error:inner]) return NO;
        }
        return YES;
    } error:error];
}

- (BOOL)markReceived:(NSString *)transferID at:(NSString *)finalPath size:(uint64_t)size db:(SZFriendsStoreDB *)db
               error:(NSError **)error {
    return [db transaction:^BOOL(NSError **inner) {
        NSDictionary *values = @{
            @"received_path" : finalPath, @"publishing" : @0, @"final_path" : [NSNull null],
            @"partial_path" : [NSNull null], @"verified_bytes" : @(size), @"received_at" : [NSDate date]
        };
        return SZFriendsTransferRowUpdate(db, transferID, values, inner) &&
               SZFriendsTransferRowApplyEvent(db, transferID, SZFriendsTransferEventVerified, nil, inner);
    } error:error];
}

// Records the destination before each rename, so a crash between rename and commit is finished at the next start
// instead of leaving a published file the store does not know (ADR 0003 § Crash recovery). The exclusive rename
// makes the no-overwrite rule hold even if something appeared at the destination after it was chosen.
- (BOOL)publish:(SZFriendsTransferRecord *)record from:(NSString *)partial db:(SZFriendsStoreDB *)db
          error:(NSError **)error {
    NSString *transferID = record.transferID;
    NSString *final = SZFriendsPublishReceivedFile(partial, record.fileName, _stateDirectory,
                                                   ^BOOL(NSString *candidate, NSError **inner) {
        return [db transaction:^BOOL(NSError **innermost) {
            NSDictionary *values = @{@"final_path" : candidate, @"publishing" : @1};
            return SZFriendsTransferRowUpdate(db, transferID, values, innermost);
        } error:inner];
    }, error);
    if (final == nil) return NO;
    SZFriendsStoreTestPoint("transfer.after_rename");
    return [self markReceived:transferID at:final size:record.size db:db error:error];
}

- (BOOL)finishTransfer:(NSString *)transferID finalDigest:(NSData *)finalDigest
      fromConversation:(NSString *)conversationID error:(NSError **)error {
    __block BOOL mismatch = NO;
    BOOL ok = [self onWriter:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        SZFriendsTransferRecord *record = [self receivingRecord:db transferID:transferID conversation:conversationID
                                                          error:inner];
        SZFriendsReceiving *receiving = record ? [self openIn:db record:record error:inner] : nil;
        if (!receiving) return NO;
        if (receiving->written != record.size) {
            return SZFriendsFail(inner, SZFriendsReceiveError(SZFriendsStoreErrorInvalid, @"file is incomplete"));
        }
        if (![self commit:receiving transfer:transferID db:db error:inner]) return NO;
        crypto_generichash_state state = receiving->hash; // final() consumes the state; keep ours intact
        uint8_t computed[32];
        crypto_generichash_final(&state, computed, sizeof computed);
        NSString *partial = receiving.partialPath;
        BOOL matches = finalDigest.length == 32 && record.contentDigest.length == 32 &&
                       sodium_memcmp(finalDigest.bytes, record.contentDigest.bytes, 32) == 0 &&
                       sodium_memcmp(computed, record.contentDigest.bytes, 32) == 0 &&
                       SZFriendsStagedFileMatches(receiving->fd, partial, record);
        close(receiving->fd); // complete and durable; closed before it is renamed or deleted
        receiving->fd = -1;
        [self->_open removeObjectForKey:transferID];
        if (matches) return [self publish:record from:partial db:db error:inner];
        mismatch = YES;
        return [self failMismatched:transferID partial:partial db:db error:inner];
    } error:error];
    if (ok && mismatch) {
        return SZFriendsFail(error, SZFriendsReceiveError(SZFriendsStoreErrorDigestMismatch, @"digest mismatch"));
    }
    return ok;
}

// ADR 0001: a mismatch deletes the file and fails the transfer; Try again starts over from zero.
- (BOOL)failMismatched:(NSString *)transferID partial:(NSString *)partial db:(SZFriendsStoreDB *)db
                 error:(NSError **)error {
    unlink(partial.fileSystemRepresentation);
    return [db transaction:^BOOL(NSError **inner) {
        NSDictionary *reset = @{@"verified_bytes" : @0, @"partial_path" : [NSNull null], @"publishing" : @0,
                                @"final_path" : [NSNull null]};
        return SZFriendsTransferRowUpdate(db, transferID, reset, inner) &&
               SZFriendsTransferRowApplyEvent(db, transferID, SZFriendsTransferEventFailed,
                                              SZFriendsTransferFailureDigestMismatch, inner);
    } error:error];
}

- (BOOL)recoverWithError:(NSError **)error {
    return [self onWriter:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        return [self recoverPublishingIn:db error:inner] && [self recoverReceivingIn:db error:inner] &&
               [self removeOrphansIn:db error:inner];
    } error:error];
}

@end

NS_ASSUME_NONNULL_END
