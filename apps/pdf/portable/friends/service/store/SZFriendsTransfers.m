// SZFriendsTransfers: offers in both directions, answers, and the checks each answer must pass. Receiving bytes
// (chunks, digest, publishing, recovery) is SZFriendsTransferReceiver; file helpers are SZFriendsTransferFiles.

#import <sodium.h>
#import <sys/stat.h>
#import <unistd.h>

#import "service/store/SZFriendsStoreInternal.h"

NS_ASSUME_NONNULL_BEGIN

// Manual acceptance keeps this much free beyond the file itself, so a download never fills the disk completely.
static const uint64_t SZFriendsAcceptMargin = 16ULL << 20;

static NSError *SZFriendsTransferError(SZFriendsStoreError code, NSString *why) {
    return SZFriendsStoreMakeError(code, why);
}

@implementation SZFriendsTransfers {
    SZFriendsStore *_store;
    NSString *_stateDirectory;
    NSString *_partialDirectory;
    NSString *_outgoingDirectory;
    SZFriendsTransferReceiver *_receiver;
    NSMutableSet<NSString *> *_checkedSnapshots; // hashed this run; touched only on the store queue
}

@synthesize receiver = _receiver;

- (instancetype)initWithStore:(SZFriendsStore *)store stateDirectory:(NSString *)stateDirectory {
    if ((self = [super init])) {
        // libsodium must be initialised before BLAKE2b picks its implementation; repeated calls are harmless.
        if (sodium_init() < 0) NSLog(@"Friends transfers: libsodium failed to initialise");
        _store = store;
        _stateDirectory = [stateDirectory copy];
        _receivedDirectory = [stateDirectory stringByAppendingPathComponent:@"received"];
        _partialDirectory = [_receivedDirectory stringByAppendingPathComponent:@".partial"];
        _outgoingDirectory = [stateDirectory stringByAppendingPathComponent:@"outgoing"];
        _freeBytesProvider = ^uint64_t(NSString *path) { return SZFriendsVolumeFreeBytes(path); };
        _reserveBytes = SZFriendsTransferDefaultReserveBytes;
        _checkedSnapshots = [NSMutableSet set];
        for (NSString *directory in @[ _receivedDirectory, _partialDirectory, _outgoingDirectory ]) {
            NSError *error = nil;
            if (!SZFriendsEnsurePrivateDirectory(directory, &error)) {
                NSLog(@"Friends transfers: %@", error.localizedDescription);
            }
        }
        _receiver = [[SZFriendsTransferReceiver alloc] initWithStore:store stateDirectory:stateDirectory];
        NSError *error = nil;
        if (![_receiver recoverWithError:&error]) {
            NSLog(@"Friends transfers: recovery failed: %@", error.localizedDescription);
        }
    }
    return self;
}

#pragma mark - Reads

- (NSArray<SZFriendsTransferRecord *> *)rowsWhere:(NSString *)where binds:(NSArray *)binds {
    __block NSArray *rows = @[];
    [_store performRead:^(SZFriendsStoreDB *_Nullable db) { if (db) rows = SZFriendsTransferRows(db, where, binds); }];
    return rows;
}

- (nullable SZFriendsTransferRecord *)transferWithID:(NSString *)transferID {
    return [self rowsWhere:@"WHERE transfer_id = ?" binds:@[ transferID ]].firstObject;
}

- (nullable SZFriendsTransferRecord *)transferWithID:(NSString *)transferID inConversation:(NSString *)conversationID {
    return [self rowsWhere:@"WHERE transfer_id = ? AND conversation_id = ?" binds:@[ transferID, conversationID ]]
        .firstObject;
}

- (NSArray<SZFriendsTransferRecord *> *)transfersInConversation:(NSString *)conversationID {
    return [self rowsWhere:@"WHERE conversation_id = ? ORDER BY created_at DESC, transfer_id"
                     binds:@[ conversationID ]];
}

- (NSUInteger)pendingIncomingOfferCountForConversation:(NSString *)conversationID {
    return [self rowsWhere:@"WHERE conversation_id = ? AND outgoing = 0 AND state = ?"
                     binds:@[ conversationID, @(SZFriendsTransferStateWaitingForYou) ]].count;
}

- (NSArray<SZFriendsTransferRecord *> *)unfinishedIncomingTransfersForConversation:(NSString *)conversationID {
    return [self rowsWhere:@"WHERE conversation_id = ? AND outgoing = 0 AND state = ? ORDER BY created_at"
                     binds:@[ conversationID, @(SZFriendsTransferStateReceiving) ]];
}

#pragma mark - Outgoing

- (nullable SZFriendsTransferRecord *)stageOutgoingFileAtPath:(NSString *)path
                                                     revision:(nullable SZFriendsRevision *)revision
                                               conversationID:(NSString *)conversationID
                                                        error:(NSError **)error {
    return [self stageOutgoingFileAtPath:path displayName:nil revision:revision conversationID:conversationID
                                   error:error];
}

- (nullable SZFriendsTransferRecord *)stageOutgoingFileAtPath:(NSString *)path
                                                  displayName:(nullable NSString *)displayName
                                                     revision:(nullable SZFriendsRevision *)revision
                                               conversationID:(NSString *)conversationID
                                                        error:(NSError **)error {
    if (!SZFriendsStoreIsValidIdentifier(conversationID)) {
        SZFriendsFail(error, SZFriendsTransferError(SZFriendsStoreErrorInvalid, @"bad conversation id"));
        return nil;
    }
    if (![_store personWithConversationID:conversationID]) {
        SZFriendsFail(error, SZFriendsTransferError(SZFriendsStoreErrorNotFound, @"unknown conversation"));
        return nil;
    }
    if (!SZFriendsEnsurePrivateDirectory(_outgoingDirectory, error)) return nil;
    NSString *transferID = SZFriendsNewIdentifier();
    NSString *snapshot = [_outgoingDirectory stringByAppendingPathComponent:transferID];
    uint64_t size = 0;
    NSData *digest = nil, *sha256 = nil;
    if (!SZFriendsSnapshotFile(path, snapshot, self.freeBytesProvider(_stateDirectory), &size, &digest,
                               revision.sha256 ? &sha256 : NULL, error)) {
        return nil;
    }
    // The person picked an exact revision; if the file now holds other bytes, sending them would be sending
    // something they did not choose (brief § Transfers: never substitute a newer source).
    if (revision && (size != revision.size || (revision.sha256 && ![sha256 isEqualToData:revision.sha256]))) {
        unlink(snapshot.fileSystemRepresentation);
        SZFriendsFail(error, SZFriendsTransferError(SZFriendsStoreErrorSourceChanged, path));
        return nil;
    }
    SZFriendsTransferRecord *record = [[SZFriendsTransferRecord alloc] init];
    record.transferID = transferID;
    record.conversationID = conversationID;
    record.outgoing = YES;
    record.state = SZFriendsTransferStateQueued;
    record.fileName = SZFriendsSanitizedFileName(displayName.length ? displayName : path.lastPathComponent);
    record.uniformType = SZFriendsUniformTypeForName(record.fileName);
    record.size = size;
    record.contentDigest = digest;
    record.stagedPath = snapshot;
    record.revision = revision;
    record.createdAt = [NSDate date];
    BOOL ok = [_store performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        if (!SZFriendsTransferRowInsert(db, record, nil, inner)) return NO;
        [self->_checkedSnapshots addObject:transferID]; // just hashed
        return YES;
    } error:error];
    if (!ok) {
        unlink(snapshot.fileSystemRepresentation);
        return nil;
    }
    return record;
}

- (BOOL)discardStagedTransfer:(NSString *)transferID error:(NSError **)error {
    __block NSString *snapshot = nil;
    BOOL ok = [_store performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        SZFriendsTransferRecord *record = SZFriendsTransferRowLoad(db, transferID);
        if (!record) return SZFriendsFail(inner, SZFriendsTransferError(SZFriendsStoreErrorNotFound, transferID));
        NSNumber *uses = [db scalar:@"SELECT (SELECT count(*) FROM messages WHERE transfer_id = ?1) + "
                                    @"(SELECT count(*) FROM outbox WHERE item_id = ?1)"
                              binds:@[ transferID ]
                              error:inner];
        if (!uses) return NO;
        if (!record.outgoing || record.state != SZFriendsTransferStateQueued || uses.integerValue > 0) {
            return SZFriendsFail(inner, SZFriendsTransferError(SZFriendsStoreErrorStale, @"already offered"));
        }
        snapshot = record.stagedPath;
        return [db run:@"DELETE FROM transfers WHERE transfer_id = ?" binds:@[ transferID ] row:nil error:inner];
    } error:error];
    if (ok && snapshot) SZFriendsRemovePrivateFiles(_stateDirectory, @[ snapshot ]);
    return ok;
}

#pragma mark - Incoming offers and this person's answers

- (nullable SZFriendsTransferRecord *)recordIncomingOfferWithID:(NSString *)transferID
                                                 conversationID:(NSString *)conversationID
                                                       fileName:(NSString *)proposedName
                                                    uniformType:(nullable NSString *)uniformType
                                                           size:(uint64_t)size
                                                  contentDigest:(NSData *)contentDigest
                                                         sentAt:(NSDate *)sentAt
                                                          error:(NSError **)error {
    __block SZFriendsTransferRecord *result = nil;
    BOOL ok = [_store performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        if (!SZFriendsStoreIsValidIdentifier(transferID) || uniformType.length > 255) {
            return SZFriendsFail(inner, SZFriendsTransferError(SZFriendsStoreErrorInvalid, @"bad offer id or type"));
        }
        // Ids are scoped to the friend who chose them and compared without case: a resent OFFER (its ACK was lost)
        // is the same offer, but an id another friend used, one of ours, or one differing only in case is refused.
        // APFS folds case, and two such transfers once shared one staging file (security review).
        NSArray<SZFriendsTransferRecord *> *clashes =
            SZFriendsTransferRows(db, @"WHERE transfer_id = ? COLLATE NOCASE", @[ transferID ]);
        for (SZFriendsTransferRecord *existing in clashes) {
            BOOL resent = !existing.outgoing && [existing.transferID isEqualToString:transferID] &&
                          [existing.conversationID isEqualToString:conversationID];
            if (!resent) {
                return SZFriendsFail(inner, SZFriendsTransferError(SZFriendsStoreErrorInvalid, @"offer id in use"));
            }
        }
        if (clashes.count > 0) {
            result = clashes.firstObject;
            return YES;
        }
        SZFriendsPersonRecord *person = SZFriendsStorePeople(db, @"WHERE conversation_id = ?", @[ conversationID ])
                                            .firstObject;
        if (person.relation != SZFriendsRelationFriend) {
            return SZFriendsFail(inner, SZFriendsTransferError(SZFriendsStoreErrorInvalid, @"not an unblocked friend"));
        }
        NSNumber *pending = [db scalar:@"SELECT count(*) FROM transfers WHERE conversation_id = ? AND outgoing = 0 "
                                       @"AND state = ?"
                                 binds:@[ conversationID, @(SZFriendsTransferStateWaitingForYou) ]
                                 error:inner];
        if (!pending) return NO;
        NSString *reason = nil;
        if (!SZFriendsValidateOffer(proposedName, size, contentDigest, pending.unsignedIntegerValue, &reason)) {
            return SZFriendsFail(inner, SZFriendsTransferError(SZFriendsStoreErrorInvalid, reason));
        }
        SZFriendsTransferRecord *record = [[SZFriendsTransferRecord alloc] init];
        record.transferID = transferID;
        record.conversationID = conversationID;
        record.state = SZFriendsTransferStateWaitingForYou;
        record.fileName = SZFriendsSanitizedFileName(proposedName);
        record.uniformType = uniformType;
        record.size = size;
        record.contentDigest = contentDigest;
        record.createdAt = [NSDate date];
        if (!SZFriendsTransferRowInsert(db, record, nil, inner)) return NO;
        SZFriendsItemRecord *item = [[SZFriendsItemRecord alloc] init];
        item.itemID = transferID;
        item.conversationID = conversationID;
        item.kind = SZFriendsItemKindTransfer;
        item.direction = SZFriendsDirectionIncoming;
        item.transferID = transferID;
        item.text = record.fileName;
        item.sentAt = sentAt;
        item.receivedAt = record.createdAt;
        if (!SZFriendsStoreInsertItem(db, item, NULL, inner)) return NO;
        result = record;
        return YES;
    } error:error];
    return ok ? result : nil;
}

// Every check a manual acceptance makes, so automatic acceptance gets exactly the same ones plus its own.
- (BOOL)acceptIn:(SZFriendsStoreDB *)db
        transfer:(NSString *)transferID
   automatically:(BOOL)automatically
       freeBytes:(uint64_t)freeBytes
           error:(NSError **)error {
    SZFriendsTransferRecord *record = SZFriendsTransferRowLoad(db, transferID);
    if (!record) return SZFriendsFail(error, SZFriendsTransferError(SZFriendsStoreErrorNotFound, transferID));
    if (record.outgoing || record.state != SZFriendsTransferStateWaitingForYou) {
        return SZFriendsFail(error, SZFriendsTransferError(SZFriendsStoreErrorStale, @"offer is not waiting"));
    }
    SZFriendsPersonRecord *person = SZFriendsStorePeople(db, @"WHERE conversation_id = ?", @[ record.conversationID ])
                                        .firstObject;
    if (person.relation != SZFriendsRelationFriend) {
        return SZFriendsFail(error, SZFriendsTransferError(SZFriendsStoreErrorInvalid, @"not an unblocked friend"));
    }
    if (automatically && (!person.autoAccept || person.keyChangePending)) {
        return SZFriendsFail(error, SZFriendsTransferError(SZFriendsStoreErrorStale, @"automatic acceptance is off"));
    }
    uint64_t remaining = record.size - record.verifiedBytes;
    uint64_t keep = automatically ? MAX(self.reserveBytes, SZFriendsAcceptMargin) : SZFriendsAcceptMargin;
    if (remaining > freeBytes || freeBytes - remaining < keep) {
        return SZFriendsFail(error, SZFriendsTransferError(SZFriendsStoreErrorDiskFull, @"not enough space"));
    }
    NSString *partial = SZFriendsEnsurePrivateDirectory(_partialDirectory, error)
                            ? SZFriendsCreateStagingFile(_partialDirectory, error)
                            : nil;
    if (!partial) return NO;
    NSDictionary *values = @{
        @"accepted_automatically" : @(automatically), @"partial_path" : partial, @"verified_bytes" : @0,
        @"asked_low_disk" : @0
    };
    if (SZFriendsTransferRowApplyEvent(db, transferID, SZFriendsTransferEventAccepted, nil, error) &&
        SZFriendsTransferRowUpdate(db, transferID, values, error)) {
        return YES;
    }
    unlink(partial.fileSystemRepresentation); // the row will not name it once this rolls back
    return NO;
}

- (SZFriendsAutoAcceptDecision)applyAutomaticAcceptanceToTransfer:(NSString *)transferID error:(NSError **)error {
    uint64_t freeBytes = [self freeBytesForReceiving]; // outside the queue: it may touch the disk
    __block SZFriendsAutoAcceptDecision decision = SZFriendsAutoAcceptAsk;
    BOOL ok = [_store performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        SZFriendsTransferRecord *record = SZFriendsTransferRowLoad(db, transferID);
        if (!record) return SZFriendsFail(inner, SZFriendsTransferError(SZFriendsStoreErrorNotFound, transferID));
        if (record.outgoing || record.state != SZFriendsTransferStateWaitingForYou) return YES;
        SZFriendsPersonRecord *person =
            SZFriendsStorePeople(db, @"WHERE conversation_id = ?", @[ record.conversationID ]).firstObject;
        decision = SZFriendsAutoAcceptDecide(person.autoAccept, person.keyChangePending,
                                             person.relation != SZFriendsRelationFriend,
                                             record.size - record.verifiedBytes, freeBytes, self.reserveBytes);
        if (decision == SZFriendsAutoAcceptAskLowDisk) {
            return SZFriendsTransferRowUpdate(db, transferID, @{@"asked_low_disk" : @1}, inner);
        }
        if (decision != SZFriendsAutoAcceptDownload) return YES;
        return [self acceptIn:db transfer:transferID automatically:YES freeBytes:freeBytes error:inner];
    } error:error];
    return ok ? decision : SZFriendsAutoAcceptAsk;
}

- (BOOL)acceptTransfer:(NSString *)transferID automatically:(BOOL)automatically error:(NSError **)error {
    uint64_t freeBytes = [self freeBytesForReceiving];
    return [_store performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        return [self acceptIn:db transfer:transferID automatically:automatically freeBytes:freeBytes error:inner];
    } error:error];
}

// Applies `event` after `check` approves the row, clears the private paths when `dropFiles`, and deletes those
// files once the change has committed (a rollback must not leave a row pointing at a deleted file).
- (BOOL)move:(NSString *)transferID
       event:(SZFriendsTransferEvent)event
      reason:(nullable NSString *)reason
   dropFiles:(BOOL)dropFiles
       check:(nullable BOOL (^)(SZFriendsTransferRecord *record, NSError **error))check
       error:(NSError **)error {
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    BOOL ok = [_store performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        SZFriendsTransferRecord *record = SZFriendsTransferRowLoad(db, transferID);
        if (!record) return SZFriendsFail(inner, SZFriendsTransferError(SZFriendsStoreErrorNotFound, transferID));
        if (check && !check(record, inner)) return NO;
        if (!SZFriendsTransferRowApplyEvent(db, transferID, event, reason, inner)) return NO;
        if (!dropFiles) return YES;
        NSString *partial = SZFriendsTransferRowPartialPath(db, transferID);
        if (partial) [files addObject:partial];
        if (record.stagedPath) [files addObject:record.stagedPath];
        return SZFriendsTransferRowUpdate(db, transferID, @{@"partial_path" : [NSNull null],
                                                            @"staged_path" : [NSNull null]}, inner);
    } error:error];
    if (ok) [_receiver forgetTransfer:transferID]; // a download that stopped receiving holds no open file
    if (ok && dropFiles) SZFriendsRemovePrivateFiles(_stateDirectory, files);
    return ok;
}

// outgoing: 1 ours only, 0 theirs only, -1 either. `conversationID` is the peer the answer came from, which must own
// the transfer; nil only for this person's own actions, never for anything a peer sent (a peer answer with no
// conversation is refused, not waved through).
static BOOL (^SZFriendsCheck(NSString *_Nullable conversationID, BOOL local, int outgoing))(SZFriendsTransferRecord *,
                                                                                           NSError **) {
    return ^BOOL(SZFriendsTransferRecord *record, NSError **error) {
        BOOL sender = local || (conversationID.length > 0 && [record.conversationID isEqualToString:conversationID]);
        BOOL direction = outgoing < 0 || record.outgoing == (outgoing == 1);
        if (sender && direction) return YES;
        return SZFriendsFail(error, SZFriendsTransferError(SZFriendsStoreErrorInvalid, @"not this friend's transfer"));
    };
}

// A peer naming a transfer: it must be theirs, in the given direction.
static BOOL (^SZFriendsFrom(NSString *conversationID, int outgoing))(SZFriendsTransferRecord *, NSError **) {
    return SZFriendsCheck(conversationID, NO, outgoing);
}

- (BOOL)declineTransfer:(NSString *)transferID error:(NSError **)error {
    return [self move:transferID event:SZFriendsTransferEventDeclined reason:nil dropFiles:YES
                check:SZFriendsCheck(nil, YES, 0) error:error];
}

- (BOOL)cancelTransfer:(NSString *)transferID error:(NSError **)error {
    return [self move:transferID event:SZFriendsTransferEventCancelled reason:nil dropFiles:YES check:nil error:error];
}

- (BOOL)failTransfer:(NSString *)transferID reason:(NSString *)reason error:(NSError **)error {
    return [self move:transferID event:SZFriendsTransferEventFailed reason:reason dropFiles:NO check:nil error:error];
}

- (BOOL)retryTransfer:(NSString *)transferID error:(NSError **)error {
    return [_store performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        SZFriendsTransferRecord *record = SZFriendsTransferRowLoad(db, transferID);
        if (!record) return SZFriendsFail(inner, SZFriendsTransferError(SZFriendsStoreErrorNotFound, transferID));
        if (record.state != SZFriendsTransferStateFailed) {
            return SZFriendsFail(inner, SZFriendsTransferError(SZFriendsStoreErrorStale, @"not failed"));
        }
        struct stat info;
        if (record.outgoing && (!record.stagedPath || lstat(record.stagedPath.fileSystemRepresentation, &info) != 0)) {
            return SZFriendsFail(inner, SZFriendsTransferError(SZFriendsStoreErrorFileMissing, @"snapshot is gone"));
        }
        NSString *created = nil;
        if (!record.outgoing) {
            NSString *existing = SZFriendsTransferRowPartialPath(db, transferID);
            BOOL present = existing && lstat(existing.fileSystemRepresentation, &info) == 0;
            if (!present) {
                created = SZFriendsEnsurePrivateDirectory(self->_partialDirectory, inner)
                              ? SZFriendsCreateStagingFile(self->_partialDirectory, inner)
                              : nil;
                if (!created) return NO;
            }
        }
        NSDictionary *fresh = created ? @{@"partial_path" : created, @"verified_bytes" : @0} : nil;
        if ((!fresh || SZFriendsTransferRowUpdate(db, transferID, fresh, inner)) &&
            SZFriendsTransferRowApplyEvent(db, transferID, SZFriendsTransferEventRetry, nil, inner)) {
            return YES;
        }
        if (created) unlink(created.fileSystemRepresentation); // rolled back: no row names it
        return NO;
    } error:error];
}

#pragma mark - The other side's answers

- (BOOL)markOfferDelivered:(NSString *)transferID fromConversation:(NSString *)conversationID
                     error:(NSError **)error {
    return [self move:transferID event:SZFriendsTransferEventOfferDelivered reason:nil dropFiles:NO
                check:SZFriendsFrom(conversationID, 1) error:error];
}

// Re-hashes an outgoing snapshot once per helper run before resuming from it (ADR 0001 § Resume), outside the
// store queue because a large file takes a while.
- (BOOL)snapshotMatches:(SZFriendsTransferRecord *)record {
    __block BOOL known = NO;
    [_store performOnWriter:^(SZFriendsStoreDB *_Nullable db) {
        (void)db;
        known = [self->_checkedSnapshots containsObject:record.transferID];
    }];
    if (known) return YES;
    NSData *digest = record.stagedPath ? SZFriendsFileDigest(record.stagedPath, UINT64_MAX, NULL) : nil;
    if (!digest || ![digest isEqualToData:record.contentDigest]) return NO;
    [_store performOnWriter:^(SZFriendsStoreDB *_Nullable db) {
        (void)db;
        [self->_checkedSnapshots addObject:record.transferID];
    }];
    return YES;
}

- (BOOL)peerAnsweredTransfer:(NSString *)transferID
                    accepted:(BOOL)accepted
                      offset:(uint64_t)offset
            fromConversation:(NSString *)conversationID
                       error:(NSError **)error {
    if (!accepted) {
        return [self move:transferID event:SZFriendsTransferEventDeclined reason:nil dropFiles:YES
                    check:SZFriendsFrom(conversationID, 1) error:error];
    }
    SZFriendsTransferRecord *current = [self transferWithID:transferID];
    if (!current) return SZFriendsFail(error, SZFriendsTransferError(SZFriendsStoreErrorNotFound, transferID));
    if (!SZFriendsFrom(conversationID, 1)(current, error)) return NO;
    if (offset > current.size) {
        return SZFriendsFail(error, SZFriendsTransferError(SZFriendsStoreErrorInvalid, @"offset beyond the file"));
    }
    BOOL resuming = current.state == SZFriendsTransferStateSending;
    if (!resuming && SZFriendsTransferNextState(YES, current.state, SZFriendsTransferEventAccepted) == current.state) {
        return SZFriendsFail(error, SZFriendsTransferError(SZFriendsStoreErrorStale, @"offer is no longer offered"));
    }
    if (![self snapshotMatches:current]) {
        [self failTransfer:transferID reason:SZFriendsTransferFailureSourceMissing error:NULL];
        return SZFriendsFail(error, SZFriendsTransferError(SZFriendsStoreErrorSourceChanged, @"snapshot changed"));
    }
    if (resuming) return YES;
    return [self move:transferID event:SZFriendsTransferEventAccepted reason:nil dropFiles:NO
                check:SZFriendsFrom(conversationID, 1) error:error];
}

- (BOOL)peerCancelledTransfer:(NSString *)transferID fromConversation:(NSString *)conversationID
                        error:(NSError **)error {
    return [self move:transferID event:SZFriendsTransferEventCancelled reason:nil dropFiles:YES
                check:SZFriendsFrom(conversationID, -1) error:error];
}

- (BOOL)peerVerifiedTransfer:(NSString *)transferID fromConversation:(NSString *)conversationID
                       error:(NSError **)error {
    return [self move:transferID event:SZFriendsTransferEventVerified reason:nil dropFiles:YES
                check:SZFriendsFrom(conversationID, 1) error:error];
}

- (BOOL)setMeasuredBytesPerSecond:(double)bytesPerSecond forTransfer:(NSString *)transferID
                            error:(NSError **)error {
    return [_store performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        return SZFriendsTransferRowUpdate(db, transferID, @{@"bytes_per_second" : @(MAX(bytesPerSecond, 0.0))}, inner);
    } error:error];
}

#pragma mark - Receiving

- (BOOL)appendChunk:(NSData *)bytes atOffset:(uint64_t)offset toTransfer:(NSString *)transferID
   fromConversation:(NSString *)conversationID error:(NSError **)error {
    return [_receiver appendChunk:bytes atOffset:offset toTransfer:transferID fromConversation:conversationID
                            error:error];
}

- (BOOL)finishTransfer:(NSString *)transferID finalDigest:(NSData *)finalDigest
      fromConversation:(NSString *)conversationID error:(NSError **)error {
    return [_receiver finishTransfer:transferID finalDigest:finalDigest fromConversation:conversationID error:error];
}

- (BOOL)flushProgressWithError:(NSError **)error { return [_receiver flushWithError:error]; }

@end

NS_ASSUME_NONNULL_END
