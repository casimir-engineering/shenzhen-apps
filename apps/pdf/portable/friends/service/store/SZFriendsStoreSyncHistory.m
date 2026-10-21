// Sync between own devices, history (schema v9, SZFriendsStoreSync.h): the You conversation, which events put each item
// here (origins), items copied from other devices, deletions that take exactly what the deleting device had seen,
// and unread counts worked out from a read marker every device agrees on.

#import "service/store/SZFriendsStoreSync.h"
#import "service/store/SZFriendsStoreInternal.h"

NS_ASSUME_NONNULL_BEGIN

// SZFriendsStore.m's delete path: rows in one transaction, then the private files and a compaction, so deleted text
// does not survive in free pages (ADR 0003 § Deletes).
@interface SZFriendsStore (SZFriendsSyncDeleting)
- (BOOL)deleteRows:(BOOL (^)(SZFriendsStoreDB *db, NSMutableArray *files, NSError **error))rows
       directories:(NSArray<NSString *> *)directories
             error:(NSError **)error;
@end

NSString *const SZFriendsSyncCaptureRowKey = @"capture_row";
NSString *const SZFriendsSyncStateJoinClock = @"join_clock";

static SZFriendsItemRecord *SZFriendsSyncItemFromRow(sqlite3_stmt *s) {
    SZFriendsItemRecord *item = [[SZFriendsItemRecord alloc] init];
    item.itemID = SZFriendsColumnText(s, 0) ?: @"";
    item.conversationID = SZFriendsColumnText(s, 1) ?: @"";
    item.kind = (SZFriendsItemKind)SZFriendsColumnInt(s, 2);
    item.direction = (SZFriendsDirection)SZFriendsColumnInt(s, 3);
    item.sentAt = SZFriendsColumnDate(s, 4) ?: [NSDate dateWithTimeIntervalSince1970:0];
    item.receivedAt = SZFriendsColumnDate(s, 5) ?: item.sentAt;
    NSString *body = SZFriendsColumnText(s, 6);
    if (item.kind != SZFriendsItemKindEvent) item.text = body;
    item.transferID = SZFriendsColumnText(s, 7);
    item.eventKind = SZFriendsColumnText(s, 8);
    NSData *arguments = [SZFriendsColumnText(s, 9) dataUsingEncoding:NSUTF8StringEncoding];
    id parsed = arguments ? [NSJSONSerialization JSONObjectWithData:arguments options:0 error:NULL] : nil;
    if ([parsed isKindOfClass:[NSDictionary class]]) item.eventArguments = parsed;
    item.viaAssistant = SZFriendsColumnInt(s, 10) != 0;
    item.cancelled = SZFriendsColumnInt(s, 11) != 0;
    item.outboxState = -1;
    return item;
}

static NSString *const SZFriendsSyncItemColumns = @"m.item_id, m.conversation_id, m.kind, m.direction, m.sent_at, "
                                                  @"m.received_at, m.body, m.transfer_id, m.event_kind, m.event_args, "
                                                  @"m.via_assistant, m.cancelled";

// Removes items with their transfers, previews and outbox entries, adding the private files to `files`, marks them
// deleted for good (unless `keepable`), and drops the bodies of the events that carried them: the item's own events
// (its origins), and the file record and outbox events naming its transfer or entry. `items` holds [conversation id,
// item id] pairs.
static BOOL SZFriendsSyncDeleteItems(SZFriendsStoreDB *db, NSArray<NSArray<NSString *> *> *items,
                                     NSInteger fileKind, NSInteger outboxKind, NSMutableArray<NSString *> *files,
                                     BOOL keepable, NSError **error) {
    for (NSArray<NSString *> *pair in items) {
        NSArray *binds = @[ pair[0], pair[1] ];
        NSString *transfer = [db scalar:@"SELECT transfer_id FROM messages WHERE conversation_id = ? AND item_id = ?"
                                  binds:binds
                                  error:NULL];
        if (![transfer isKindOfClass:[NSString class]]) {
            transfer = [db scalar:@"SELECT transfer_id FROM sync_files WHERE conversation_id = ? AND item_id = ?"
                            binds:binds
                            error:NULL];
        }
        if ([transfer isKindOfClass:[NSString class]]) {
            BOOL ok = [db run:@"SELECT staged_path, partial_path FROM transfers WHERE transfer_id = ?"
                        binds:@[ transfer ]
                          row:^(sqlite3_stmt *s) {
                              for (int column = 0; column < 2; column++) {
                                  NSString *path = SZFriendsColumnText(s, column);
                                  if (path.length) [files addObject:path];
                              }
                          }
                        error:error];
            if (!ok) return NO;
            SZFriendsThumbnailFilesOfTransfers(db, @"WHERE transfer_id = ?", @[ transfer ], files);
            NSArray<NSString *> *drops = @[
                @"DELETE FROM transfers WHERE transfer_id = ?", @"DELETE FROM sync_files WHERE transfer_id = ?",
                @"UPDATE sync_events SET body = NULL WHERE subject = ? AND kind = ?"
            ];
            for (NSString *sql in drops) {
                NSArray *dropBinds = [sql hasPrefix:@"UPDATE"] ? @[ transfer, @(fileKind) ] : @[ transfer ];
                if (![db run:sql binds:dropBinds row:nil error:error]) return NO;
            }
        }
        BOOL entries = [db run:@"UPDATE sync_events SET body = NULL WHERE kind = ? AND subject IN "
                               @"(SELECT entry_id FROM outbox WHERE conversation_id = ? AND item_id = ?)"
                         binds:@[ @(outboxKind), pair[0], pair[1] ]
                           row:nil
                         error:error];
        if (!entries) return NO;
        NSString *origins = @"UPDATE sync_events SET body = NULL WHERE (author, seq) IN "
                            @"(SELECT author, seq FROM sync_origins WHERE conversation_id = ? AND item_id = ?)";
        NSArray<NSString *> *statements = @[
            origins,
            @"DELETE FROM outbox WHERE conversation_id = ? AND item_id = ?",
            @"DELETE FROM messages WHERE conversation_id = ? AND item_id = ?",
            @"DELETE FROM sync_origins WHERE conversation_id = ? AND item_id = ?",
            @"INSERT OR IGNORE INTO sync_deleted (conversation_id, item_id) VALUES (?, ?)",
        ];
        for (NSString *sql in statements) {
            if (keepable && [sql hasPrefix:@"INSERT"]) continue;
            if (![db run:sql binds:binds row:nil error:error]) return NO;
        }
    }
    // Deleted rows at the top of the table free their row numbers for reuse, so the next scan starts from the start.
    return [db run:@"DELETE FROM sync_state WHERE key = ?" binds:@[ SZFriendsSyncCaptureRowKey ] row:nil error:error];
}

@implementation SZFriendsStore (SyncHistory)

- (BOOL)ensureYouConversation:(NSError **)error {
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        return [db run:@"INSERT OR IGNORE INTO friends (conversation_id, relation, last_interaction_at) VALUES (?,?,?)"
                 binds:@[ SZFriendsYouConversationID, @(SZFriendsRelationFriend), [NSDate date] ]
                   row:nil
                 error:inner];
    } error:error];
}

- (NSArray<SZFriendsItemRecord *> *)itemsWithoutSyncOriginAfterRow:(int64_t)afterRow
                                                             limit:(NSUInteger)limit
                                                           lastRow:(int64_t *)lastRow {
    __block NSMutableArray<SZFriendsItemRecord *> *items = [NSMutableArray array];
    __block int64_t last = afterRow;
    [self performOnWriter:^(SZFriendsStoreDB *_Nullable db) {
        NSString *sql = [NSString stringWithFormat:
            @"SELECT %@, m.seq FROM messages m WHERE m.seq > ? AND NOT EXISTS (SELECT 1 FROM sync_origins o "
            @"WHERE o.conversation_id = m.conversation_id AND o.item_id = m.item_id) ORDER BY m.seq LIMIT ?",
            SZFriendsSyncItemColumns];
        [db run:sql binds:@[ @(afterRow), @(limit) ] row:^(sqlite3_stmt *s) {
            [items addObject:SZFriendsSyncItemFromRow(s)];
            last = SZFriendsColumnInt(s, 12);
        } error:NULL];
    }];
    *lastRow = last;
    return items;
}

- (NSArray<NSArray *> *)syncOriginsOfItem:(NSString *)itemID inConversation:(NSString *)conversationID {
    NSMutableArray<NSArray *> *origins = [NSMutableArray array];
    [self performRead:^(SZFriendsStoreDB *_Nullable db) {
        [db run:@"SELECT author, seq FROM sync_origins WHERE conversation_id = ? AND item_id = ?"
            binds:@[ conversationID, itemID ]
              row:^(sqlite3_stmt *s) {
                  NSData *author = SZFriendsColumnBlob(s, 0);
                  if (author.length == 32) [origins addObject:@[ author, @(SZFriendsColumnInt(s, 1)) ]];
              }
            error:NULL];
    }];
    return origins;
}

- (NSDictionary<NSString *, NSArray<NSArray *> *> *)syncOriginsInConversation:(NSString *)conversationID {
    NSMutableDictionary<NSString *, NSMutableArray<NSArray *> *> *origins = [NSMutableDictionary dictionary];
    [self performRead:^(SZFriendsStoreDB *_Nullable db) {
        [db run:@"SELECT item_id, author, seq FROM sync_origins WHERE conversation_id = ?"
            binds:@[ conversationID ]
              row:^(sqlite3_stmt *s) {
                  NSString *itemID = SZFriendsColumnText(s, 0);
                  NSData *author = SZFriendsColumnBlob(s, 1);
                  if (itemID == nil || author.length != 32) return;
                  if (origins[itemID] == nil) origins[itemID] = [NSMutableArray array];
                  [origins[itemID] addObject:@[ author, @(SZFriendsColumnInt(s, 2)) ]];
              }
            error:NULL];
    }];
    return origins;
}

- (BOOL)addSyncOriginForItem:(NSString *)itemID
              inConversation:(NSString *)conversationID
                      author:(NSData *)author
                         seq:(uint64_t)seq
                       error:(NSError **)error {
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        return [db run:@"INSERT OR IGNORE INTO sync_origins (conversation_id, item_id, author, seq) VALUES (?,?,?,?)"
                 binds:@[ conversationID, itemID, author, @(MIN(seq, (uint64_t)INT64_MAX)) ]
                   row:nil
                 error:inner];
    } error:error];
}

- (BOOL)mergeSyncedItem:(SZFriendsItemRecord *)item author:(NSData *)author seq:(uint64_t)seq error:(NSError **)error {
    if (!SZFriendsStoreIsValidIdentifier(item.conversationID) || !SZFriendsStoreIsValidIdentifier(item.itemID) ||
        author.length != 32) {
        return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorInvalid, @"bad synced item"));
    }
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        NSArray *key = @[ item.conversationID, item.itemID ];
        NSNumber *deleted = [db scalar:@"SELECT count(*) FROM sync_deleted WHERE conversation_id = ? AND item_id = ?"
                                 binds:key
                                 error:inner];
        if (!deleted) return NO;
        if (deleted.integerValue > 0) return YES; // a deletion took it: a late copy changes nothing
        NSDate *received = item.receivedAt ?: [NSDate date];
        NSDate *sent = item.sentAt ?: received;
        if (item.direction == SZFriendsDirectionIncoming && [sent compare:received] == NSOrderedDescending) {
            sent = received;
        }
        BOOL inserted = NO;
        if (!SZFriendsStoreInsertItem(db, item, &inserted, inner)) return NO;
        if (!inserted) {
            // The same message reached two of our devices: each keeps the earliest time any of them saw, so every
            // device shows it in the same place.
            if (![db run:@"UPDATE messages SET received_at = min(received_at, ?), sent_at = min(sent_at, ?) "
                         @"WHERE conversation_id = ? AND item_id = ?"
                   binds:@[ received, sent, item.conversationID, item.itemID ]
                     row:nil
                   error:inner]) {
                return NO;
            }
        }
        return [db run:@"INSERT OR IGNORE INTO sync_origins (conversation_id, item_id, author, seq) VALUES (?,?,?,?)"
                 binds:@[ item.conversationID, item.itemID, author, @(MIN(seq, (uint64_t)INT64_MAX)) ]
                   row:nil
                 error:inner];
    } error:error];
}

- (BOOL)isSyncDeletedItem:(NSString *)itemID inConversation:(NSString *)conversationID {
    __block BOOL deleted = NO;
    [self performOnWriter:^(SZFriendsStoreDB *_Nullable db) {
        deleted = [[db scalar:@"SELECT count(*) FROM sync_deleted WHERE conversation_id = ? AND item_id = ?"
                        binds:@[ conversationID, itemID ]
                        error:NULL] integerValue] > 0;
    }];
    return deleted;
}

- (nullable NSArray<NSString *> *)deleteSyncedItemsInConversation:(nullable NSString *)conversationID
                                                        coveredBy:(SZFriendsSyncVector *)vector
                                                         fileKind:(NSInteger)fileKind
                                                       outboxKind:(NSInteger)outboxKind
                                                            error:(NSError **)error {
    __block NSMutableSet<NSString *> *conversations = [NSMutableSet set];
    BOOL ok = [self deleteRows:^BOOL(SZFriendsStoreDB *db, NSMutableArray *files, NSError **inner) {
        NSMutableOrderedSet<NSArray<NSString *> *> *items = [NSMutableOrderedSet orderedSet];
        for (NSData *author in vector) {
            uint64_t upTo = MIN([vector[author] unsignedLongLongValue], (uint64_t)INT64_MAX);
            if (author.length != 32 || upTo == 0) continue;
            NSString *sql = conversationID
                                ? @"SELECT DISTINCT conversation_id, item_id FROM sync_origins WHERE author = ? AND "
                                  @"seq <= ? AND conversation_id = ?"
                                : @"SELECT DISTINCT conversation_id, item_id FROM sync_origins WHERE author = ? AND "
                                  @"seq <= ?";
            NSArray *binds = conversationID ? @[ author, @(upTo), conversationID ] : @[ author, @(upTo) ];
            BOOL read = [db run:sql binds:binds row:^(sqlite3_stmt *s) {
                NSString *conversation = SZFriendsColumnText(s, 0), *item = SZFriendsColumnText(s, 1);
                if (conversation && item) [items addObject:@[ conversation, item ]];
            } error:inner];
            if (!read) return NO;
        }
        for (NSArray<NSString *> *pair in items) [conversations addObject:pair[0]];
        return SZFriendsSyncDeleteItems(db, items.array, fileKind, outboxKind, files, NO, inner);
    } directories:@[] error:error];
    return ok ? [conversations.allObjects sortedArrayUsingSelector:@selector(compare:)] : nil;
}

- (BOOL)markSyncDeletedItem:(NSString *)itemID
             inConversation:(NSString *)conversationID
                   fileKind:(NSInteger)fileKind
                 outboxKind:(NSInteger)outboxKind
                      error:(NSError **)error {
    if (!SZFriendsStoreIsValidIdentifier(conversationID) || !SZFriendsStoreIsValidIdentifier(itemID)) {
        return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorInvalid, @"bad item"));
    }
    NSArray *pair = @[ @[ conversationID, itemID ] ];
    __block BOOL present = YES;
    [self performOnWriter:^(SZFriendsStoreDB *_Nullable db) {
        present = [[db scalar:@"SELECT count(*) FROM messages WHERE conversation_id = ? AND item_id = ?"
                        binds:pair.firstObject
                        error:NULL] integerValue] > 0;
    }];
    // Nothing of it was ever written here: marking it is enough, and needs no compaction (or a transaction of its own).
    if (!present) {
        return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
            return SZFriendsSyncDeleteItems(db, pair, fileKind, outboxKind, [NSMutableArray array], NO, inner);
        } error:error];
    }
    return [self deleteRows:^BOOL(SZFriendsStoreDB *db, NSMutableArray *files, NSError **inner) {
        return SZFriendsSyncDeleteItems(db, pair, fileKind, outboxKind, files, NO, inner);
    } directories:@[] error:error];
}

- (nullable NSArray<NSString *> *)purgeSyncEventsOfAuthor:(NSData *)author
                                                 afterSeq:(uint64_t)seq
                                                 fileKind:(NSInteger)fileKind
                                               outboxKind:(NSInteger)outboxKind
                                                    error:(NSError **)error {
    if (author.length != 32) return @[];
    NSArray *past = @[ author, @(MIN(seq, (uint64_t)INT64_MAX)) ];
    if ([[self syncEventsOfAuthor:author afterSeq:seq] count] == 0) return @[];
    __block NSMutableSet<NSString *> *conversations = [NSMutableSet set];
    BOOL ok = [self deleteRows:^BOOL(SZFriendsStoreDB *db, NSMutableArray *files, NSError **inner) {
        // Items every origin of which is one of these events: nothing else ever put them here.
        NSMutableArray<NSArray<NSString *> *> *items = [NSMutableArray array];
        NSString *only = @"SELECT DISTINCT conversation_id, item_id FROM sync_origins o WHERE author = ?1 AND seq > ?2 "
                         @"AND NOT EXISTS (SELECT 1 FROM sync_origins p WHERE p.conversation_id = o.conversation_id "
                         @"AND p.item_id = o.item_id AND NOT (p.author = ?1 AND p.seq > ?2))";
        BOOL read = [db run:only binds:past row:^(sqlite3_stmt *s) {
            NSString *conversation = SZFriendsColumnText(s, 0), *item = SZFriendsColumnText(s, 1);
            if (conversation && item) [items addObject:@[ conversation, item ]];
        } error:inner];
        if (!read || !SZFriendsSyncDeleteItems(db, items, fileKind, outboxKind, files, YES, inner)) return NO;
        for (NSArray<NSString *> *pair in items) [conversations addObject:pair[0]];
        return [db run:@"DELETE FROM sync_origins WHERE author = ? AND seq > ?" binds:past row:nil error:inner] &&
               [db run:@"DELETE FROM sync_events WHERE author = ? AND seq > ?" binds:past row:nil error:inner];
    } directories:@[] error:error];
    return ok ? [conversations.allObjects sortedArrayUsingSelector:@selector(compare:)] : nil;
}

- (BOOL)dropBodyOfSyncEvent:(NSData *)author seq:(uint64_t)seq error:(NSError **)error {
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        return [db run:@"UPDATE sync_events SET body = NULL WHERE author = ? AND seq = ?"
                 binds:@[ author, @(MIN(seq, (uint64_t)INT64_MAX)) ]
                   row:nil
                 error:inner];
    } error:error];
}

- (BOOL)recountUnreadInConversation:(NSString *)conversationID
                   readThroughDate:(nullable NSDate *)receivedAt
                            itemID:(nullable NSString *)itemID
                             error:(NSError **)error {
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        NSString *count =
            @"SELECT count(*) FROM messages WHERE conversation_id = ? AND direction = ? AND kind IN (?, ?)";
        NSMutableArray *binds = [NSMutableArray arrayWithArray:@[
            conversationID, @(SZFriendsDirectionIncoming), @(SZFriendsItemKindMessage), @(SZFriendsItemKindTransfer)
        ]];
        if (receivedAt != nil) {
            count = [count stringByAppendingString:@" AND (received_at > ? OR (received_at = ? AND item_id > ?))"];
            [binds addObjectsFromArray:@[ receivedAt, receivedAt, itemID ?: @"" ]];
        }
        NSString *sql = [NSString stringWithFormat:@"UPDATE friends SET unread_count = (%@) WHERE conversation_id = ?",
                                                   count];
        [binds addObject:conversationID];
        return [db run:sql binds:binds row:nil error:inner];
    } error:error];
}

- (nullable SZFriendsItemRecord *)newestIncomingItemInConversation:(NSString *)conversationID {
    return [self incomingItemInConversation:conversationID newerCount:0];
}

- (nullable SZFriendsItemRecord *)incomingItemInConversation:(NSString *)conversationID newerCount:(NSUInteger)newer {
    __block SZFriendsItemRecord *item = nil;
    [self performOnWriter:^(SZFriendsStoreDB *_Nullable db) {
        NSString *sql = [NSString stringWithFormat:@"SELECT %@ FROM messages m WHERE m.conversation_id = ? AND "
                                                   @"m.direction = ? AND m.kind IN (?, ?) "
                                                   @"ORDER BY m.received_at DESC, m.item_id DESC LIMIT 1 OFFSET ?",
                                                   SZFriendsSyncItemColumns];
        [db run:sql
              binds:@[ conversationID, @(SZFriendsDirectionIncoming), @(SZFriendsItemKindMessage),
                       @(SZFriendsItemKindTransfer), @(newer) ]
                row:^(sqlite3_stmt *s) { item = SZFriendsSyncItemFromRow(s); }
              error:NULL];
    }];
    return item;
}

@end

NS_ASSUME_NONNULL_END
