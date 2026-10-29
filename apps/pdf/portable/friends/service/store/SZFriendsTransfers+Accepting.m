// Accepting an offer (SZFriendsTransfers.m): every check a manual or automatic acceptance makes, and a file already
// held here that fills the download at once.

#import <sodium.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

#import "service/store/SZFriendsStoreInternal.h"

NS_ASSUME_NONNULL_BEGIN

// Manual acceptance keeps this much free beyond the file itself, so a download never fills the disk completely.
static const uint64_t SZFriendsAcceptMargin = 16ULL << 20;

@implementation SZFriendsTransfers (Accepting)

// Every check a manual acceptance makes, so automatic acceptance gets exactly the same ones plus its own.
- (BOOL)acceptIn:(SZFriendsStoreDB *)db
        transfer:(NSString *)transferID
   automatically:(BOOL)automatically
       freeBytes:(uint64_t)freeBytes
           error:(NSError **)error {
    SZFriendsTransferRecord *record = SZFriendsTransferRowLoad(db, transferID);
    if (!record) return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorNotFound, transferID));
    if (record.outgoing || record.state != SZFriendsTransferStateWaitingForYou) {
        return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorStale, @"offer is not waiting"));
    }
    SZFriendsPersonRecord *person = SZFriendsStorePeople(db, @"WHERE conversation_id = ?", @[ record.conversationID ])
                                        .firstObject;
    if (person.relation != SZFriendsRelationFriend) {
        return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorInvalid, @"not an unblocked friend"));
    }
    if (automatically && (!person.autoAccept || person.keyChangePending)) {
        return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorStale, @"automatic acceptance is off"));
    }
    uint64_t remaining = record.size - record.verifiedBytes;
    uint64_t keep = automatically ? MAX(self.reserveBytes, SZFriendsAcceptMargin) : SZFriendsAcceptMargin;
    if (remaining > freeBytes || freeBytes - remaining < keep) {
        return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorDiskFull, @"not enough space"));
    }
    NSString *partial = SZFriendsEnsurePrivateDirectory(self.partialDirectory, error)
                            ? SZFriendsCreateStagingFile(self.partialDirectory, error)
                            : nil;
    if (!partial) return NO;
    NSDictionary *values = @{
        @"accepted_automatically" : @(automatically), @"partial_path" : partial, @"verified_bytes" : @0,
        @"asked_low_disk" : @0
    };
    if (SZFriendsTransferRowApplyEvent(db, transferID, SZFriendsTransferEventAccepted, nil, error) &&
        SZFriendsTransferRowUpdate(db, transferID, values, error)) {
        // The same file from the same friend, still here: filled locally (ADR 0018 § 9.5); the sender is answered
        // with the whole file durable and sends only DONE.
        [self fillFromHeldCopyIn:db record:record partial:partial freeBytes:freeBytes];
        return YES;
    }
    unlink(partial.fileSystemRepresentation); // the row will not name it once this rolls back
    return NO;
}

// A file this computer holds with the offered bytes: received from the same friend (or copied here from another of
// the person's computers), still where it was saved at its size, and still hashing to the digest. Never another
// friend's file: a friend learns at most that the person kept what that friend sent (ADR 0018 § 8).
- (nullable NSString *)heldCopyIn:(SZFriendsStoreDB *)db record:(SZFriendsTransferRecord *)record {
    if (record.contentDigest.length == 0) return nil;
    NSArray<SZFriendsTransferRecord *> *candidates = SZFriendsTransferRows(
        db, @"WHERE conversation_id = ? AND outgoing = 0 AND state = ? AND size = ? AND digest = ? AND transfer_id != ? "
            @"ORDER BY updated_at DESC LIMIT 4",
        @[ record.conversationID, @(SZFriendsTransferStateReceived), @(record.size), record.contentDigest,
           record.transferID ]);
    for (SZFriendsTransferRecord *candidate in candidates) {
        NSString *path = candidate.receivedPath;
        struct stat info;
        if (path == nil || stat(path.fileSystemRepresentation, &info) != 0 || !S_ISREG(info.st_mode) ||
            (uint64_t)info.st_size != record.size) {
            continue;
        }
        if ([SZFriendsFileDigest(path, UINT64_MAX, NULL) isEqualToData:record.contentDigest]) return path;
    }
    return nil;
}

// After acceptance: when this computer holds the offered file, a clone of it (a copy across volumes) becomes the
// staging file, durable, and the durable count is the whole file, so it completes without crossing the route. The
// clone is checked against the digest again, since the held file could change between the two reads.
- (BOOL)fillFromHeldCopyIn:(SZFriendsStoreDB *)db
                    record:(SZFriendsTransferRecord *)record
                   partial:(NSString *)partial
                 freeBytes:(uint64_t)freeBytes {
    if (record.outgoing || record.size == 0) return NO;
    NSString *source = [self heldCopyIn:db record:record];
    if (source == nil) return NO;
    NSString *filled = [partial stringByAppendingString:@".held"];
    uint64_t size = 0;
    NSData *digest = nil;
    BOOL ok = SZFriendsSnapshotFile(source, filled, freeBytes, &size, &digest, NULL, NULL) && size == record.size &&
              [digest isEqualToData:record.contentDigest];
    if (ok) {
        int fd = open(filled.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        ok = fd >= 0 && SZFriendsMakeDurable(fd);
        if (fd >= 0) close(fd);
    }
    ok = ok && rename(filled.fileSystemRepresentation, partial.fileSystemRepresentation) == 0;
    if (!ok) {
        unlink(filled.fileSystemRepresentation);
        return NO;
    }
    [self.receiver forgetTransfer:record.transferID];
    return SZFriendsTransferRowUpdate(db, record.transferID, @{@"verified_bytes" : @(record.size)}, NULL);
}

@end

NS_ASSUME_NONNULL_END
