// A download by blocks checked before it is saved (ADR 0018 § 5), and our own offers served by blocks: the sender's
// tree, a peer that took an offer by blocks, and the blocks read for it (SZFriendsTransfers.h, BlockCheck).

#import <fcntl.h>
#import <sodium.h>
#import <sys/stat.h>
#import <unistd.h>

#import "service/store/SZFriendsBlockDownload.h"

NS_ASSUME_NONNULL_BEGIN

@implementation SZFriendsTransfers (BlockCheck)

// ADR 0018 § 5: every block durable, the file is read back through the descriptor that wrote it, its tree and BLAKE2b
// digest computed in one pass on every core, and it is published only when both match the offer. Otherwise it is
// deleted and the transfer fails (DigestMismatch), as a CHUNK transfer whose digest differs.
- (BOOL)finishBlockTransfer:(NSString *)transferID fromConversation:(NSString *)conversationID
                      error:(NSError **)error {
    SZFriendsBlockCheck *check = [self beginBlockCheck:transferID fromConversation:conversationID error:error];
    if (check == nil) return NO;
    [check run];
    return [self completeBlockCheck:check error:error];
}

- (nullable SZFriendsBlockCheck *)beginBlockCheck:(NSString *)transferID
                                 fromConversation:(NSString *)conversationID
                                            error:(NSError **)error {
    __block SZFriendsBlockCheck *check = nil;
    BOOL ok = [self.receiver onWriter:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        SZFriendsBlockDownload *download = [self openBlocks:transferID conversation:conversationID db:db error:inner];
        if (download == nil || ![self flushBlocks:download transfer:transferID db:db error:inner]) return NO;
        if (download.checking) {
            return SZFriendsFail(inner, SZFriendsBlockError(SZFriendsStoreErrorStale, @"being checked"));
        }
        if (!download.durable.full) {
            return SZFriendsFail(inner, SZFriendsBlockError(SZFriendsStoreErrorInvalid, @"file is incomplete"));
        }
        SZFriendsTransferRecord *record = SZFriendsTransferRowLoad(db, transferID);
        struct stat opened, named;
        check = [[SZFriendsBlockCheck alloc] init];
        check.same = fstat(download->fd, &opened) == 0 &&
                     lstat(download.partial.fileSystemRepresentation, &named) == 0 && S_ISREG(named.st_mode) &&
                     opened.st_dev == named.st_dev && opened.st_ino == named.st_ino &&
                     (uint64_t)opened.st_size == record.size;
        check->fd = dup(download->fd);
        check.transferID = transferID;
        check.conversationID = conversationID;
        check.download = download;
        check.geometry = download.assembly.geometry;
        check.root = download.assembly.root;
        check.digest = record.contentDigest ?: [NSData data];
        download.checking = YES;
        return YES;
    } error:error];
    return ok ? check : nil;
}

- (BOOL)completeBlockCheck:(SZFriendsBlockCheck *)check error:(NSError **)error {
    __block BOOL mismatch = NO;
    NSString *transferID = check.transferID;
    NSString *mapPath = [self blockMapPathForTransfer:transferID];
    BOOL ok = [self.receiver onWriter:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        SZFriendsBlockDownload *download = self.receiver.blockDownloads[transferID];
        if (download == nil || download != check.download) {
            // Cancelled or declined while it was read: nothing to save.
            return SZFriendsFail(inner, SZFriendsBlockError(SZFriendsStoreErrorStale, @"no longer receiving"));
        }
        download.checking = NO;
        SZFriendsTransferRecord *record = SZFriendsTransferRowLoad(db, transferID);
        NSString *partial = download.partial;
        [self.receiver.blockDownloads removeObjectForKey:transferID]; // closes both descriptors
        unlink(mapPath.fileSystemRepresentation);
        if (check.matches && record != nil) return [self.receiver publish:record from:partial db:db error:inner];
        mismatch = YES;
        return [self.receiver failMismatched:transferID partial:partial db:db error:inner];
    } error:error];
    if (ok && mismatch) {
        return SZFriendsFail(error, SZFriendsBlockError(SZFriendsStoreErrorDigestMismatch, @"digest mismatch"));
    }
    return ok;
}

#pragma mark - Sending

- (BOOL)senderTreeForTransfer:(SZFriendsTransferRecord *)record
                      compute:(BOOL)compute
                     geometry:(SZFriendsBlockGeometry *)geometry
                         root:(NSData *_Nullable *_Nonnull)root
                       leaves:(NSData *_Nullable *_Nonnull)leaves {
    NSString *path = [self senderTreePathForTransfer:record.transferID];
    NSData *bytes = [NSData dataWithContentsOfFile:path];
    NSData *digest = nil;
    if (bytes) {
        NSData *stored = SZFriendsSenderTreeDecode(bytes, geometry, root, &digest);
        if (stored && [digest isEqualToData:record.contentDigest] && geometry->size == record.size) {
            *leaves = stored;
            return YES;
        }
    }
    if (!compute || !SZFriendsGeometryForSize(record.size, geometry) || record.stagedPath == nil) return NO;
    int fd = open(record.stagedPath.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return NO;
    struct stat info;
    NSData *hashedLeaves = nil, *hashedDigest = nil;
    BOOL ok = fstat(fd, &info) == 0 && (uint64_t)info.st_size == record.size &&
              SZFriendsHashFileTree(fd, *geometry, &hashedLeaves, &hashedDigest) &&
              [hashedDigest isEqualToData:record.contentDigest];
    close(fd);
    if (!ok) return NO;
    *leaves = hashedLeaves;
    *root = SZFriendsTreeRootOfLeaves(*geometry, hashedLeaves);
    // A cache: a write that fails only costs hashing again.
    SZFriendsWriteSidecar(path, SZFriendsSenderTreeEncode(*geometry, *root, record.contentDigest, hashedLeaves));
    return YES;
}

- (nullable SZFriendsTransferRecord *)peerTookBlocks:(NSString *)transferID
                                    fromConversation:(NSString *)conversationID
                                               first:(BOOL *)first
                                               error:(NSError **)error {
    __block SZFriendsTransferRecord *result = nil;
    __block BOOL accepted = NO;
    BOOL ok = [self.store performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        SZFriendsTransferRecord *record = SZFriendsTransferRowLoad(db, transferID);
        if (record == nil || !record.outgoing || ![record.conversationID isEqualToString:conversationID]) {
            return SZFriendsFail(inner, SZFriendsBlockError(SZFriendsStoreErrorInvalid, @"not our offer to them"));
        }
        if (record.state == SZFriendsTransferStateSending) {
            accepted = NO;
        } else if (SZFriendsTransferNextState(YES, record.state, SZFriendsTransferEventAccepted) ==
                   SZFriendsTransferStateSending) {
            accepted = YES;
        } else {
            return SZFriendsFail(inner, SZFriendsBlockError(SZFriendsStoreErrorStale, @"offer is no longer offered"));
        }
        struct stat info;
        if (record.stagedPath == nil || stat(record.stagedPath.fileSystemRepresentation, &info) != 0 ||
            (uint64_t)info.st_size != record.size) {
            SZFriendsTransferRowApplyEvent(db, transferID, SZFriendsTransferEventFailed,
                                           SZFriendsTransferFailureSourceMissing, NULL);
            return SZFriendsFail(inner, SZFriendsBlockError(SZFriendsStoreErrorFileMissing, @"snapshot missing"));
        }
        if (accepted && !SZFriendsTransferRowApplyEvent(db, transferID, SZFriendsTransferEventAccepted, nil, inner)) {
            return NO;
        }
        result = SZFriendsTransferRowLoad(db, transferID);
        return YES;
    } error:error];
    *first = accepted;
    return ok ? result : nil;
}

- (nullable NSData *)readOutgoingBlock:(uint32_t)index
                           ofTransfer:(SZFriendsTransferRecord *)record
                             geometry:(SZFriendsBlockGeometry)geometry {
    if (record.stagedPath == nil) return nil;
    int fd = open(record.stagedPath.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return nil;
    uint64_t offset = 0;
    NSUInteger length = 0;
    SZFriendsGeometrySpan(geometry, index, &offset, &length);
    NSData *data = SZFriendsReadAt(fd, offset, length);
    close(fd);
    return data;
}

@end

NS_ASSUME_NONNULL_END
