// Sync between own devices, the store's part for the outbox and files (schema v9, SZFriendsStoreSync.h): outbox
// entries other devices may deliver too, the profile's file records with who holds their bytes, and copies of files
// whose bytes came from another device.

#import "service/store/SZFriendsStoreSync.h"
#import "service/store/SZFriendsStoreInternal.h"

NS_ASSUME_NONNULL_BEGIN

// SZFriendsStoreSync.m: reads on the writer, so a transaction sees its own writes.
@interface SZFriendsStore (SyncReads)
- (NSArray *)syncRows:(NSString *)sql binds:(NSArray *)binds map:(id (^)(sqlite3_stmt *s))map;
- (nullable id)syncScalar:(NSString *)sql binds:(NSArray *)binds;
@end
static NSArray<NSData *> *SZFriendsSyncHolders(NSData *_Nullable packed) {
    NSMutableArray<NSData *> *holders = [NSMutableArray array];
    for (NSUInteger offset = 0; offset + 32 <= packed.length; offset += 32) {
        [holders addObject:[packed subdataWithRange:NSMakeRange(offset, 32)]];
    }
    return holders;
}

static NSData *SZFriendsSyncPackHolders(NSArray<NSData *> *holders) {
    NSMutableSet<NSData *> *unique = [NSMutableSet set];
    for (NSData *key in holders) {
        if (key.length == 32) [unique addObject:key];
    }
    NSArray<NSData *> *sorted = [unique.allObjects sortedArrayUsingComparator:^NSComparisonResult(NSData *a,
                                                                                                  NSData *b) {
        int order = memcmp(a.bytes, b.bytes, 32);
        return order < 0 ? NSOrderedAscending : (order > 0 ? NSOrderedDescending : NSOrderedSame);
    }];
    NSMutableData *packed = [NSMutableData data];
    for (NSData *key in sorted) [packed appendData:key];
    return packed;
}

static NSString *const SZFriendsSyncFileColumns = @"transfer_id, conversation_id, item_id, outgoing, state, file_name, "
                                                  @"uniform_type, size, digest, created_at, holders";

static SZFriendsSyncFileRecord *SZFriendsSyncFileFromRow(sqlite3_stmt *s) {
    SZFriendsSyncFileRecord *file = [[SZFriendsSyncFileRecord alloc] init];
    file.transferID = SZFriendsColumnText(s, 0) ?: @"";
    file.conversationID = SZFriendsColumnText(s, 1) ?: @"";
    file.itemID = SZFriendsColumnText(s, 2);
    file.outgoing = SZFriendsColumnInt(s, 3) != 0;
    file.state = (SZFriendsTransferState)SZFriendsColumnInt(s, 4);
    file.fileName = SZFriendsColumnText(s, 5) ?: @"";
    file.uniformType = SZFriendsColumnText(s, 6);
    file.size = (uint64_t)SZFriendsColumnInt(s, 7);
    file.contentDigest = SZFriendsColumnBlob(s, 8) ?: [NSData data];
    file.createdAt = SZFriendsColumnDate(s, 9) ?: [NSDate dateWithTimeIntervalSince1970:0];
    file.holders = SZFriendsSyncHolders(SZFriendsColumnBlob(s, 10));
    return file;
}

static NSString *const SZFriendsSyncEntryColumns = @"entry_id, conversation_id, kind, state, created_at, queued_at, "
                                                   @"attempts, item_id, client_token, failure_reason, payload";

static SZFriendsOutboxEntry *SZFriendsSyncEntryFromRow(sqlite3_stmt *s) {
    SZFriendsOutboxEntry *entry = [[SZFriendsOutboxEntry alloc] init];
    entry.entryID = SZFriendsColumnText(s, 0) ?: @"";
    entry.conversationID = SZFriendsColumnText(s, 1) ?: @"";
    entry.kind = (SZFriendsOutboxKind)SZFriendsColumnInt(s, 2);
    entry.state = (SZFriendsOutboxState)SZFriendsColumnInt(s, 3);
    entry.createdAt = SZFriendsColumnDate(s, 4) ?: [NSDate dateWithTimeIntervalSince1970:0];
    entry.queuedAt = SZFriendsColumnDate(s, 5);
    entry.attempts = (NSUInteger)SZFriendsColumnInt(s, 6);
    entry.itemID = SZFriendsColumnText(s, 7);
    entry.clientToken = SZFriendsColumnText(s, 8);
    entry.failureReason = SZFriendsColumnText(s, 9);
    entry.payload = SZFriendsColumnBlob(s, 10);
    return entry;
}

@implementation SZFriendsStore (SyncFiles)

#pragma mark Outbox

- (NSArray<SZFriendsOutboxEntry *> *)syncableOutboxEntries {
    NSString *sql = [NSString stringWithFormat:@"SELECT %@ FROM outbox WHERE kind IN (?, ?, ?) ORDER BY entry_id",
                                               SZFriendsSyncEntryColumns];
    return [self syncRows:sql
                    binds:@[ @(SZFriendsOutboxKindMessage), @(SZFriendsOutboxKindRequest),
                             @(SZFriendsOutboxKindPresenceSecret) ]
                      map:^id(sqlite3_stmt *s) { return SZFriendsSyncEntryFromRow(s); }];
}

- (BOOL)mergeSyncedOutboxEntry:(SZFriendsOutboxEntry *)entry error:(NSError **)error {
    if (!SZFriendsStoreIsValidIdentifier(entry.entryID) || !SZFriendsStoreIsValidIdentifier(entry.conversationID) ||
        (entry.itemID && !SZFriendsStoreIsValidIdentifier(entry.itemID)) ||
        (entry.kind != SZFriendsOutboxKindMessage && entry.kind != SZFriendsOutboxKindRequest &&
         entry.kind != SZFriendsOutboxKindPresenceSecret) ||
        entry.state < SZFriendsOutboxStateQueued || entry.state > SZFriendsOutboxStateFailed) {
        return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorInvalid, @"bad synced outbox entry"));
    }
    // In flight means "on that device's session": here it waits for a route like anything queued.
    SZFriendsOutboxState state = entry.state;
    if (state == SZFriendsOutboxStateConnecting || state == SZFriendsOutboxStateSending) {
        state = SZFriendsOutboxStateQueued;
    }
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        NSNumber *held = [db scalar:@"SELECT state FROM outbox WHERE entry_id = ?" binds:@[ entry.entryID ] error:NULL];
        NSDate *now = [NSDate date];
        if (held != nil) {
            // A session of ours may be writing it now: that stays as it is unless it is over.
            NSInteger current = held.integerValue;
            BOOL inFlight = current == SZFriendsOutboxStateConnecting || current == SZFriendsOutboxStateSending;
            if (inFlight && state == SZFriendsOutboxStateQueued) return YES;
            return [db run:@"UPDATE outbox SET state = ?, failure_reason = ?, payload = ?, updated_at = ? "
                           @"WHERE entry_id = ?"
                     binds:@[ @(state), SZFriendsSQL(entry.failureReason), SZFriendsSQL(entry.payload), now,
                              entry.entryID ]
                       row:nil
                     error:inner];
        }
        NSNumber *known = [db scalar:@"SELECT count(*) FROM friends WHERE conversation_id = ?"
                               binds:@[ entry.conversationID ]
                               error:inner];
        if (!known) return NO;
        if (known.integerValue == 0) {
            return SZFriendsFail(inner, SZFriendsStoreMakeError(SZFriendsStoreErrorNotFound, @"unknown person"));
        }
        NSDate *created = entry.createdAt ?: now;
        NSString *sql = [NSString stringWithFormat:@"INSERT INTO outbox (%@, updated_at) "
                                                   @"VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                                                   SZFriendsSyncEntryColumns];
        NSArray *binds = @[
            entry.entryID, entry.conversationID, @(entry.kind), @(state), created, entry.queuedAt ?: created, @0,
            SZFriendsSQL(entry.itemID), [NSNull null], SZFriendsSQL(entry.failureReason), SZFriendsSQL(entry.payload),
            now
        ];
        return [db run:sql binds:binds row:nil error:inner];
    } error:error];
}

#pragma mark Files

- (nullable SZFriendsSyncFileRecord *)syncFileWithID:(NSString *)transferID {
    NSString *sql = [NSString stringWithFormat:@"SELECT %@ FROM sync_files WHERE transfer_id = ?",
                                               SZFriendsSyncFileColumns];
    return [self syncRows:sql binds:@[ transferID ] map:^id(sqlite3_stmt *s) {
        return SZFriendsSyncFileFromRow(s);
    }].firstObject;
}

- (NSArray<SZFriendsSyncFileRecord *> *)syncFiles {
    NSString *sql = [NSString stringWithFormat:@"SELECT %@ FROM sync_files ORDER BY transfer_id",
                                               SZFriendsSyncFileColumns];
    return [self syncRows:sql binds:@[] map:^id(sqlite3_stmt *s) { return SZFriendsSyncFileFromRow(s); }];
}

- (BOOL)saveSyncFile:(SZFriendsSyncFileRecord *)file error:(NSError **)error {
    if (!SZFriendsStoreIsValidIdentifier(file.transferID) || !SZFriendsStoreIsValidIdentifier(file.conversationID) ||
        (file.itemID && !SZFriendsStoreIsValidIdentifier(file.itemID)) || file.contentDigest.length != 32 ||
        file.fileName.length == 0 || file.size > SZFriendsTransferMaxFileSize) {
        return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorInvalid, @"bad file record"));
    }
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        NSString *sql = [NSString stringWithFormat:@"INSERT OR REPLACE INTO sync_files (%@) "
                                                   @"VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                                                   SZFriendsSyncFileColumns];
        NSArray *binds = @[
            file.transferID, file.conversationID, SZFriendsSQL(file.itemID), @(file.outgoing), @(file.state),
            file.fileName, SZFriendsSQL(file.uniformType), @(file.size), file.contentDigest,
            file.createdAt ?: [NSDate date], SZFriendsSyncPackHolders(file.holders ?: @[])
        ];
        return [db run:sql binds:binds row:nil error:inner];
    } error:error];
}

- (NSArray<SZFriendsTransferRecord *> *)transfersWithLocalBytes {
    __block NSArray *records = @[];
    [self performOnWriter:^(SZFriendsStoreDB *_Nullable db) {
        if (!db) return;
        // Ours being sent (its snapshot), received here, or copied here from another of our devices.
        records = SZFriendsTransferRows(db,
                                        @"WHERE (outgoing = 1 AND "
                                        @"(staged_path IS NOT NULL OR received_path IS NOT NULL)) "
                                        @"OR (outgoing = 0 AND state = ? AND received_path IS NOT NULL) "
                                        @"ORDER BY transfer_id",
                                        @[ @(SZFriendsTransferStateReceived) ]);
    }];
    return records;
}

- (NSArray<SZFriendsTransferRecord *> *)allTransferRecords {
    __block NSArray *records = @[];
    [self performOnWriter:^(SZFriendsStoreDB *_Nullable db) {
        if (db) records = SZFriendsTransferRows(db, @"ORDER BY transfer_id", @[]);
    }];
    return records;
}

- (nullable NSString *)itemIDForTransfer:(NSString *)transferID inConversation:(NSString *)conversationID {
    id value = [self syncScalar:@"SELECT item_id FROM messages WHERE conversation_id = ? AND transfer_id = ?"
                          binds:@[ conversationID, transferID ]];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

- (nullable SZFriendsTransferRecord *)transferRecordWithID:(NSString *)transferID {
    __block SZFriendsTransferRecord *record = nil;
    [self performOnWriter:^(SZFriendsStoreDB *_Nullable db) {
        if (db) record = SZFriendsTransferRows(db, @"WHERE transfer_id = ?", @[ transferID ]).firstObject;
    }];
    return record;
}

- (BOOL)setState:(SZFriendsTransferState)state ofCopiedTransfer:(NSString *)transferID error:(NSError **)error {
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        // Only a copy: an outgoing row holding a received file and no snapshot of its own is one another device sent.
        return [db run:@"UPDATE transfers SET state = ?, updated_at = ? WHERE transfer_id = ? AND outgoing = 1 AND "
                       @"received_path IS NOT NULL AND staged_path IS NULL"
                 binds:@[ @(state), [NSDate date], transferID ]
                   row:nil
                 error:inner];
    } error:error];
}

- (BOOL)insertCopiedTransfer:(SZFriendsTransferRecord *)transfer path:(NSString *)path error:(NSError **)error {
    SZFriendsTransferRecord *row = [transfer copy];
    row.receivedPath = path;
    row.stagedPath = nil;
    row.verifiedBytes = row.size;
    row.revision = nil;
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        NSNumber *held = [db scalar:@"SELECT count(*) FROM transfers WHERE transfer_id = ?"
                              binds:@[ row.transferID ]
                              error:inner];
        if (!held) return NO;
        if (held.integerValue > 0) {
            return [db run:@"UPDATE transfers SET received_path = coalesce(received_path, ?), updated_at = ? "
                           @"WHERE transfer_id = ?"
                     binds:@[ path, [NSDate date], row.transferID ]
                       row:nil
                     error:inner];
        }
        // A copy from another of the person's computers, received here now (PROTOCOL.md § Views, received).
        return SZFriendsTransferRowInsert(db, row, nil, inner) &&
               SZFriendsTransferRowUpdate(db, row.transferID, @{@"received_at" : [NSDate date],
                                                                @"received_via" : @(SZFriendsReceivedSourceDevice)},
                                          inner);
    } error:error];
}

@end

NS_ASSUME_NONNULL_END
