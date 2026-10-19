// Transfer rows (table transfers), shared by the transfer manager and the outbox.

#import "service/store/SZFriendsStoreInternal.h"

NS_ASSUME_NONNULL_BEGIN

static NSString *const SZFriendsTransferColumns =
    @"transfer_id, conversation_id, outgoing, state, file_name, uniform_type, size, digest, verified_bytes, "
    @"accepted_automatically, asked_low_disk, staged_path, received_path, revision_source, revision_document_id, "
    @"revision_id, revision_label, revision_sha256, revision_size, bytes_per_second, failure_reason, created_at";

static SZFriendsTransferRecord *SZFriendsTransferFromRow(sqlite3_stmt *s) {
    SZFriendsTransferRecord *record = [[SZFriendsTransferRecord alloc] init];
    record.transferID = SZFriendsColumnText(s, 0) ?: @"";
    record.conversationID = SZFriendsColumnText(s, 1) ?: @"";
    record.outgoing = SZFriendsColumnInt(s, 2) != 0;
    record.state = (SZFriendsTransferState)SZFriendsColumnInt(s, 3);
    record.fileName = SZFriendsColumnText(s, 4) ?: @"";
    record.uniformType = SZFriendsColumnText(s, 5);
    record.size = (uint64_t)MAX(SZFriendsColumnInt(s, 6), 0);
    record.contentDigest = SZFriendsColumnBlob(s, 7) ?: [NSData data];
    record.verifiedBytes = (uint64_t)MAX(SZFriendsColumnInt(s, 8), 0);
    record.acceptedAutomatically = SZFriendsColumnInt(s, 9) != 0;
    record.askedBecauseDiskLow = SZFriendsColumnInt(s, 10) != 0;
    record.stagedPath = SZFriendsColumnText(s, 11);
    record.receivedPath = SZFriendsColumnText(s, 12);
    NSString *source = SZFriendsColumnText(s, 13);
    if (source) {
        SZFriendsRevision *revision = [[SZFriendsRevision alloc] init];
        revision.source = source;
        revision.documentID = SZFriendsColumnText(s, 14) ?: @"";
        revision.revisionID = SZFriendsColumnText(s, 15) ?: @"";
        revision.label = SZFriendsColumnText(s, 16);
        revision.sha256 = SZFriendsColumnBlob(s, 17);
        revision.size = (uint64_t)MAX(SZFriendsColumnInt(s, 18), 0);
        record.revision = revision;
    }
    record.measuredBytesPerSecond = SZFriendsColumnDouble(s, 19);
    record.failureReason = SZFriendsColumnText(s, 20);
    record.createdAt = SZFriendsColumnDate(s, 21);
    return record;
}

NSArray<SZFriendsTransferRecord *> *SZFriendsTransferRows(SZFriendsStoreDB *db, NSString *whereClause,
                                                          NSArray *binds) {
    NSString *sql = [NSString stringWithFormat:@"SELECT %@ FROM transfers %@", SZFriendsTransferColumns, whereClause];
    NSMutableArray *records = [NSMutableArray array];
    NSError *error = nil;
    if (![db run:sql binds:binds row:^(sqlite3_stmt *s) { [records addObject:SZFriendsTransferFromRow(s)]; }
           error:&error]) {
        NSLog(@"Friends store: reading transfers failed: %@", error.localizedDescription);
    }
    return records;
}

SZFriendsTransferRecord *_Nullable SZFriendsTransferRowLoad(SZFriendsStoreDB *db, NSString *transferID) {
    return SZFriendsTransferRows(db, @"WHERE transfer_id = ?", @[ transferID ]).firstObject;
}

NSString *_Nullable SZFriendsTransferRowPartialPath(SZFriendsStoreDB *db, NSString *transferID) {
    return [db scalar:@"SELECT partial_path FROM transfers WHERE transfer_id = ?" binds:@[ transferID ] error:NULL];
}

BOOL SZFriendsTransferRowInsert(SZFriendsStoreDB *db, SZFriendsTransferRecord *record, NSString *_Nullable partialPath,
                                NSError **error) {
    if (!SZFriendsStoreIsValidIdentifier(record.transferID) ||
        !SZFriendsStoreIsValidIdentifier(record.conversationID) ||
        record.contentDigest.length != 32 || record.size > SZFriendsTransferMaxFileSize) {
        return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorInvalid, @"bad transfer record"));
    }
    SZFriendsRevision *revision = record.revision;
    NSDate *now = [NSDate date];
    NSString *sql = [NSString stringWithFormat:@"INSERT INTO transfers (%@, partial_path, updated_at) VALUES "
                                               @"(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                                               SZFriendsTransferColumns];
    NSArray *binds = @[
        record.transferID, record.conversationID, @(record.outgoing), @(record.state), record.fileName,
        SZFriendsSQL(record.uniformType), @(record.size), record.contentDigest, @(record.verifiedBytes),
        @(record.acceptedAutomatically), @(record.askedBecauseDiskLow), SZFriendsSQL(record.stagedPath),
        SZFriendsSQL(record.receivedPath), SZFriendsSQL(revision.source), SZFriendsSQL(revision.documentID),
        SZFriendsSQL(revision.revisionID), SZFriendsSQL(revision.label), SZFriendsSQL(revision.sha256),
        revision ? @(revision.size) : [NSNull null], @(record.measuredBytesPerSecond),
        SZFriendsSQL(record.failureReason), record.createdAt ?: now, SZFriendsSQL(partialPath), now
    ];
    return [db run:sql binds:binds row:nil error:error];
}

BOOL SZFriendsTransferRowApplyEvent(SZFriendsStoreDB *db, NSString *transferID, SZFriendsTransferEvent event,
                                    NSString *_Nullable failureReason, NSError **error) {
    SZFriendsTransferRecord *record = SZFriendsTransferRowLoad(db, transferID);
    if (!record) return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorNotFound, @"unknown transfer"));
    SZFriendsTransferState next = SZFriendsTransferNextState(record.outgoing, record.state, event);
    if (next == record.state) {
        return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorStale, @"transfer state changed"));
    }
    NSString *reason = next == SZFriendsTransferStateFailed ? failureReason : nil;
    if (![db run:@"UPDATE transfers SET state = ?, failure_reason = ?, updated_at = ? WHERE transfer_id = ?"
           binds:@[ @(next), SZFriendsSQL(reason), [NSDate date], transferID ]
             row:nil
           error:error]) {
        return NO;
    }
    // Every state change passes here, so this is the one place an ended offer's picture is deleted.
    SZFriendsThumbnailRowsAfterTransferEvent(db, transferID, record.state, next);
    return YES;
}

BOOL SZFriendsTransferRowUpdate(SZFriendsStoreDB *db, NSString *transferID, NSDictionary<NSString *, id> *values,
                                NSError **error) {
    // Column names are spliced into SQL, so only bookkeeping columns are accepted, never a caller's string.
    static NSSet<NSString *> *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allowed = [NSSet setWithArray:@[
            @"verified_bytes", @"accepted_automatically", @"asked_low_disk", @"staged_path", @"partial_path",
            @"final_path", @"publishing", @"received_path", @"bytes_per_second", @"failure_reason"
        ]];
    });
    NSMutableArray *assignments = [NSMutableArray array];
    NSMutableArray *binds = [NSMutableArray array];
    for (NSString *column in values) {
        if (![allowed containsObject:column]) {
            return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorInvalid, @"unknown column"));
        }
        [assignments addObject:[column stringByAppendingString:@" = ?"]];
        [binds addObject:values[column]];
    }
    [assignments addObject:@"updated_at = ?"];
    [binds addObjectsFromArray:@[ [NSDate date], transferID ]];
    NSString *sql = [NSString stringWithFormat:@"UPDATE transfers SET %@ WHERE transfer_id = ?",
                                               [assignments componentsJoinedByString:@", "]];
    return [db run:sql binds:binds row:nil error:error];
}

NS_ASSUME_NONNULL_END
