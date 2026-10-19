// Conversation history (table messages): idempotent inserts, windows for snapshots, and history deletion rows.

#import "service/store/SZFriendsStoreInternal.h"

NS_ASSUME_NONNULL_BEGIN

// The outbox join gives each outgoing item its delivery state in the same query that reads the window.
static NSString *const SZFriendsItemSelect =
    @"SELECT m.item_id, m.conversation_id, m.kind, m.direction, m.sent_at, m.received_at, m.body, m.transfer_id, "
    @"m.event_kind, m.event_args, o.state, o.failure_reason, m.via_assistant, m.cancelled, o.attempts FROM messages m "
    @"LEFT JOIN outbox o ON o.conversation_id = m.conversation_id AND o.item_id = m.item_id ";

static SZFriendsItemRecord *SZFriendsItemFromRow(sqlite3_stmt *s) {
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
    item.outboxState = sqlite3_column_type(s, 10) == SQLITE_NULL ? -1 : (NSInteger)SZFriendsColumnInt(s, 10);
    item.outboxFailureReason = SZFriendsColumnText(s, 11);
    item.viaAssistant = SZFriendsColumnInt(s, 12) != 0;
    item.cancelled = SZFriendsColumnInt(s, 13) != 0;
    item.outboxWritten = SZFriendsColumnInt(s, 14) > 0; // NULL (no entry) reads as 0
    return item;
}

static NSArray<SZFriendsItemRecord *> *SZFriendsItemQuery(SZFriendsStoreDB *db, NSString *tail, NSArray *binds) {
    NSMutableArray *items = [NSMutableArray array];
    NSError *error = nil;
    if (![db run:[SZFriendsItemSelect stringByAppendingString:tail]
             binds:binds
               row:^(sqlite3_stmt *s) { [items addObject:SZFriendsItemFromRow(s)]; }
             error:&error]) {
        NSLog(@"Friends store: reading history failed: %@", error.localizedDescription);
    }
    return items;
}

BOOL SZFriendsStoreInsertItem(SZFriendsStoreDB *db, SZFriendsItemRecord *item, BOOL *_Nullable inserted,
                              NSError **error) {
    if (inserted) *inserted = NO;
    if (!SZFriendsStoreIsValidIdentifier(item.conversationID) || !SZFriendsStoreIsValidIdentifier(item.itemID) ||
        item.kind < SZFriendsItemKindMessage || item.kind > SZFriendsItemKindEvent ||
        (item.direction != SZFriendsDirectionIncoming && item.direction != SZFriendsDirectionOutgoing)) {
        return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorInvalid, @"bad history item"));
    }
    NSNumber *known = [db scalar:@"SELECT count(*) FROM friends WHERE conversation_id = ?"
                           binds:@[ item.conversationID ]
                           error:error];
    if (!known) return NO;
    if (known.integerValue == 0) {
        return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorNotFound, @"unknown conversation"));
    }
    NSNumber *duplicate = [db scalar:@"SELECT count(*) FROM messages WHERE conversation_id = ? AND item_id = ?"
                               binds:@[ item.conversationID, item.itemID ]
                               error:error];
    if (!duplicate) return NO;
    // A redelivery after a lost ACK: already durable, so the caller acknowledges again and nothing changes.
    if (duplicate.integerValue > 0) return YES;
    // So is one this person erased on any of their devices (SZFriendsStoreSync.h): the deletion took it everywhere.
    // (A store opened with an older test schema has no such table: nothing was erased there.)
    NSNumber *erased = [db scalar:@"SELECT count(*) FROM sync_deleted WHERE conversation_id = ? AND item_id = ?"
                            binds:@[ item.conversationID, item.itemID ]
                            error:NULL];
    if (erased.integerValue > 0) return YES;
    NSDate *received = item.receivedAt ?: [NSDate date];
    NSDate *sent = item.sentAt ?: received;
    // A sender's fast clock must not pin its messages below everything that arrives later (ADR 0001 § Messages).
    if (item.direction == SZFriendsDirectionIncoming && [sent compare:received] == NSOrderedDescending) sent = received;
    NSString *body = item.kind == SZFriendsItemKindEvent ? nil : item.text;
    if (item.kind == SZFriendsItemKindTransfer && !body && item.transferID) {
        // A file's history row is found by its name, so the name is indexed with the messages.
        body = [db scalar:@"SELECT file_name FROM transfers WHERE transfer_id = ?" binds:@[ item.transferID ]
                    error:NULL];
    }
    NSString *arguments = nil;
    if (item.eventArguments.count && [NSJSONSerialization isValidJSONObject:item.eventArguments]) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:item.eventArguments options:NSJSONWritingSortedKeys
                                                         error:NULL];
        arguments = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : nil;
    }
    NSString *insert = @"INSERT INTO messages (conversation_id, item_id, kind, direction, body, folded, transfer_id, "
                       @"event_kind, event_args, sent_at, received_at, via_assistant) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)";
    // Only messages and files are ever sent by an assistant; an event never is, whatever a caller set.
    BOOL viaAssistant = item.viaAssistant && item.kind != SZFriendsItemKindEvent;
    NSArray *binds = @[
        item.conversationID, item.itemID, @(item.kind), @(item.direction), SZFriendsSQL(body),
        SZFriendsSQL(body ? SZFriendsSearchFoldItem(body, item.kind) : nil), SZFriendsSQL(item.transferID),
        SZFriendsSQL(item.eventKind), SZFriendsSQL(arguments), sent, received, @(viaAssistant)
    ];
    if (![db run:insert binds:binds row:nil error:error]) return NO;
    BOOL unread = item.direction == SZFriendsDirectionIncoming && item.kind != SZFriendsItemKindEvent;
    NSString *touch = @"UPDATE friends SET last_interaction_at = max(last_interaction_at, ?), "
                      @"unread_count = unread_count + ? WHERE conversation_id = ?";
    if (![db run:touch binds:@[ received, @(unread ? 1 : 0), item.conversationID ] row:nil error:error]) return NO;
    if (inserted) *inserted = YES;
    return YES;
}

// (sent_at, item_id) of one item: the display-order position windows are measured from.
static BOOL SZFriendsItemAnchor(SZFriendsStoreDB *db, NSString *conversationID, NSString *itemID, double *sentAt) {
    NSNumber *value = [db scalar:@"SELECT sent_at FROM messages WHERE conversation_id = ? AND item_id = ?"
                           binds:@[ conversationID, itemID ]
                           error:NULL];
    if (!value) return NO;
    *sentAt = value.doubleValue;
    return YES;
}

NSArray<SZFriendsItemRecord *> *SZFriendsStoreItems(SZFriendsStoreDB *db, NSString *conversationID,
                                                    NSString *_Nullable beforeItemID, NSUInteger limit,
                                                    BOOL *_Nullable hasEarlier) {
    if (hasEarlier) *hasEarlier = NO;
    NSString *where = @"WHERE m.conversation_id = ? ";
    NSMutableArray *binds = [NSMutableArray arrayWithObject:conversationID];
    if (beforeItemID) {
        double anchor = 0;
        if (!SZFriendsItemAnchor(db, conversationID, beforeItemID, &anchor)) return @[];
        where = [where stringByAppendingString:@"AND (m.sent_at < ? OR (m.sent_at = ? AND m.item_id <= ?)) "];
        [binds addObjectsFromArray:@[ @(anchor), @(anchor), beforeItemID ]];
    }
    // One extra row answers hasEarlier without a second query.
    NSString *tail = [where stringByAppendingString:@"ORDER BY m.sent_at DESC, m.item_id DESC LIMIT ?"];
    [binds addObject:@(limit + 1)];
    NSArray *newestFirst = SZFriendsItemQuery(db, tail, binds);
    if (hasEarlier) *hasEarlier = newestFirst.count > limit;
    NSRange window = NSMakeRange(0, MIN(limit, newestFirst.count));
    return [[newestFirst subarrayWithRange:window] reverseObjectEnumerator].allObjects;
}

NSArray<SZFriendsItemRecord *> *_Nullable SZFriendsStoreItemsAround(SZFriendsStoreDB *db, NSString *conversationID,
                                                                   NSString *itemID, NSUInteger before,
                                                                   NSUInteger after) {
    double anchor = 0;
    if (!SZFriendsItemAnchor(db, conversationID, itemID, &anchor)) return nil;
    NSArray *earlier = SZFriendsItemQuery(db,
        @"WHERE m.conversation_id = ? AND (m.sent_at < ? OR (m.sent_at = ? AND m.item_id < ?)) "
        @"ORDER BY m.sent_at DESC, m.item_id DESC LIMIT ?",
        @[ conversationID, @(anchor), @(anchor), itemID, @(before) ]);
    NSArray *later = SZFriendsItemQuery(db,
        @"WHERE m.conversation_id = ? AND (m.sent_at > ? OR (m.sent_at = ? AND m.item_id >= ?)) "
        @"ORDER BY m.sent_at, m.item_id LIMIT ?",
        @[ conversationID, @(anchor), @(anchor), itemID, @(after + 1) ]);
    NSMutableArray *items = [NSMutableArray arrayWithArray:earlier.reverseObjectEnumerator.allObjects];
    [items addObjectsFromArray:later];
    return items;
}

BOOL SZFriendsStoreDeleteHistoryRows(SZFriendsStoreDB *db, NSString *_Nullable conversationID,
                                     NSMutableArray<NSString *> *files, NSError **error) {
    NSString *filter = conversationID ? @"WHERE conversation_id = ?" : @"";
    NSArray *binds = conversationID ? @[ conversationID ] : @[];
    NSString *paths = [NSString stringWithFormat:@"SELECT staged_path, partial_path FROM transfers %@", filter];
    BOOL ok = [db run:paths binds:binds row:^(sqlite3_stmt *s) {
        for (int column = 0; column < 2; column++) {
            NSString *path = SZFriendsColumnText(s, column);
            if (path.length) [files addObject:path];
        }
    } error:error];
    if (!ok) return NO;
    // Their previews too: the rows cascade with the transfers, the files are removed after the commit.
    SZFriendsThumbnailFilesOfTransfers(db, filter, binds, files);
    // Entries with an item deliver history; deleting the history deletes what they would have sent. Requests,
    // answers and presence secrets carry no item and stay queued.
    NSString *outbox = conversationID ? @"DELETE FROM outbox WHERE item_id IS NOT NULL AND conversation_id = ?"
                                      : @"DELETE FROM outbox WHERE item_id IS NOT NULL";
    NSArray<NSString *> *statements = @[
        outbox, [@"DELETE FROM transfers " stringByAppendingString:filter],
        [@"DELETE FROM messages " stringByAppendingString:filter],
        [@"UPDATE friends SET unread_count = 0 " stringByAppendingString:filter]
    ];
    for (NSString *sql in statements) {
        if (![db run:sql binds:binds row:nil error:error]) return NO;
    }
    return YES;
}

@implementation SZFriendsStore (Assistant)

- (BOOL)markItemSentByAssistant:(NSString *)itemID inConversation:(NSString *)conversationID error:(NSError **)error {
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        NSNumber *found = [db scalar:@"SELECT count(*) FROM messages WHERE conversation_id = ? AND item_id = ? AND "
                                     @"kind IN (?, ?)"
                               binds:@[ conversationID, itemID, @(SZFriendsItemKindMessage),
                                        @(SZFriendsItemKindTransfer) ]
                               error:inner];
        if (!found) return NO;
        if (found.integerValue == 0) {
            return SZFriendsFail(inner, SZFriendsStoreMakeError(SZFriendsStoreErrorNotFound, @"no such item"));
        }
        return [db run:@"UPDATE messages SET via_assistant = 1 WHERE conversation_id = ? AND item_id = ?"
                 binds:@[ conversationID, itemID ]
                   row:nil
                 error:inner];
    } error:error];
}

- (NSArray<SZFriendsItemRecord *> *)outgoingMessagesWithIDs:(NSArray<NSString *> *)itemIDs {
    if (itemIDs.count == 0) return @[];
    NSMutableArray *placeholders = [NSMutableArray arrayWithCapacity:itemIDs.count];
    for (NSUInteger i = 0; i < itemIDs.count; i++) [placeholders addObject:@"?"];
    // Direction and kind in the query: a friend chooses the ids of what they send, so an incoming message may carry
    // the id of one of ours, and must never report its status.
    NSString *tail = [NSString stringWithFormat:@"WHERE m.direction = ? AND m.kind = ? AND m.item_id IN (%@)",
                                                [placeholders componentsJoinedByString:@","]];
    NSMutableArray *binds = [NSMutableArray arrayWithObjects:@(SZFriendsDirectionOutgoing), @(SZFriendsItemKindMessage),
                                                             nil];
    [binds addObjectsFromArray:itemIDs];
    __block NSArray<SZFriendsItemRecord *> *found = @[];
    [self performRead:^(SZFriendsStoreDB *_Nullable db) {
        if (db) found = SZFriendsItemQuery(db, tail, binds);
    }];
    NSMutableArray<SZFriendsItemRecord *> *ordered = [NSMutableArray arrayWithCapacity:found.count];
    for (NSString *itemID in [NSOrderedSet orderedSetWithArray:itemIDs])
        for (SZFriendsItemRecord *item in found)
            if ([item.itemID isEqualToString:itemID]) [ordered addObject:item];
    return ordered;
}

@end

NS_ASSUME_NONNULL_END
