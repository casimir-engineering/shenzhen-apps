// Sync between own devices, the store's part (schema v9, SZFriendsStoreSync.h): the event log, registers, sync state,
// syncable outbox entries and file records. History items, origins and deletions are SZFriendsStoreSyncHistory.m.

#import "service/store/SZFriendsStoreSync.h"
#import "service/store/SZFriendsStoreInternal.h"

NS_ASSUME_NONNULL_BEGIN

NSString *const SZFriendsYouConversationID = @"you";

@implementation SZFriendsSyncLogEvent
- (id)copyWithZone:(nullable NSZone *)zone {
    SZFriendsSyncLogEvent *copy = [[SZFriendsSyncLogEvent allocWithZone:zone] init];
    copy.author = self.author;
    copy.seq = self.seq;
    copy.lamport = self.lamport;
    copy.kind = self.kind;
    copy.scope = self.scope;
    copy.subject = self.subject;
    copy.header = self.header;
    copy.body = self.body;
    copy.applied = self.applied;
    return copy;
}
@end

@implementation SZFriendsSyncRegister
- (id)copyWithZone:(nullable NSZone *)zone {
    SZFriendsSyncRegister *copy = [[SZFriendsSyncRegister allocWithZone:zone] init];
    copy.lamport = self.lamport;
    copy.author = self.author;
    copy.value = self.value;
    return copy;
}
@end

@implementation SZFriendsSyncFileRecord
- (id)copyWithZone:(nullable NSZone *)zone {
    SZFriendsSyncFileRecord *copy = [[SZFriendsSyncFileRecord allocWithZone:zone] init];
    copy.transferID = self.transferID;
    copy.conversationID = self.conversationID;
    copy.itemID = self.itemID;
    copy.outgoing = self.outgoing;
    copy.state = self.state;
    copy.fileName = self.fileName;
    copy.uniformType = self.uniformType;
    copy.size = self.size;
    copy.contentDigest = self.contentDigest;
    copy.createdAt = self.createdAt;
    copy.holders = self.holders;
    return copy;
}
@end

static NSString *const SZFriendsSyncEventColumns =
    @"author, seq, lamport, kind, scope, subject, header, body, applied";

static SZFriendsSyncLogEvent *SZFriendsSyncEventFromRow(sqlite3_stmt *s) {
    SZFriendsSyncLogEvent *event = [[SZFriendsSyncLogEvent alloc] init];
    event.author = SZFriendsColumnBlob(s, 0) ?: [NSData data];
    event.seq = (uint64_t)SZFriendsColumnInt(s, 1);
    event.lamport = (uint64_t)SZFriendsColumnInt(s, 2);
    event.kind = (NSInteger)SZFriendsColumnInt(s, 3);
    event.scope = SZFriendsColumnText(s, 4) ?: @"";
    event.subject = SZFriendsColumnText(s, 5) ?: @"";
    event.header = SZFriendsColumnBlob(s, 6) ?: [NSData data];
    event.body = sqlite3_column_type(s, 7) == SQLITE_NULL ? nil : (SZFriendsColumnBlob(s, 7) ?: [NSData data]);
    event.applied = SZFriendsColumnInt(s, 8) != 0;
    return event;
}

@implementation SZFriendsStore (Sync)

#pragma mark Reads

// Sync reads go to the writer, so a merge running inside -performSyncTransaction: sees what it has written so far:
// a register written earlier in the same batch must decide the next event for it.
- (NSArray *)syncRows:(NSString *)sql binds:(NSArray *)binds map:(id (^)(sqlite3_stmt *s))map {
    __block NSMutableArray *rows = [NSMutableArray array];
    [self performOnWriter:^(SZFriendsStoreDB *_Nullable db) {
        NSError *error = nil;
        if (db && ![db run:sql binds:binds row:^(sqlite3_stmt *s) { [rows addObject:map(s)]; } error:&error]) {
            NSLog(@"Friends store: reading sync rows failed: %@", error.localizedDescription);
        }
    }];
    return rows;
}

- (nullable id)syncScalar:(NSString *)sql binds:(NSArray *)binds {
    __block id value = nil;
    [self performOnWriter:^(SZFriendsStoreDB *_Nullable db) { value = [db scalar:sql binds:binds error:NULL]; }];
    return value;
}

#pragma mark People

- (nullable SZFriendsPersonRecord *)syncPersonWithConversationID:(NSString *)conversationID {
    __block SZFriendsPersonRecord *person = nil;
    [self performOnWriter:^(SZFriendsStoreDB *_Nullable db) {
        if (db) person = SZFriendsStorePeople(db, @"WHERE conversation_id = ?", @[ conversationID ]).firstObject;
    }];
    return person;
}

- (nullable SZFriendsPersonRecord *)syncPersonWithIdentityKey:(NSData *)identityKey {
    __block SZFriendsPersonRecord *person = nil;
    [self performOnWriter:^(SZFriendsStoreDB *_Nullable db) {
        if (db) person = SZFriendsStorePeople(db, @"WHERE identity_pk = ?", @[ identityKey ]).firstObject;
    }];
    return person;
}

#pragma mark Event log

- (SZFriendsSyncVector *)syncVector {
    NSMutableDictionary<NSData *, NSNumber *> *vector = [NSMutableDictionary dictionary];
    [self syncRows:@"SELECT author, max(seq) FROM sync_events GROUP BY author" binds:@[] map:^id(sqlite3_stmt *s) {
        NSData *author = SZFriendsColumnBlob(s, 0);
        if (author) vector[author] = @((uint64_t)SZFriendsColumnInt(s, 1));
        return [NSNull null];
    }];
    return vector;
}

- (uint64_t)syncLamport {
    return [[self syncScalar:@"SELECT coalesce(max(lamport), 0) FROM sync_events" binds:@[]] unsignedLongLongValue];
}

- (NSUInteger)syncEventCount {
    return [[self syncScalar:@"SELECT count(*) FROM sync_events" binds:@[]] unsignedIntegerValue];
}

- (BOOL)appendSyncEvent:(SZFriendsSyncLogEvent *)event appended:(nullable BOOL *)appended error:(NSError **)error {
    if (appended) *appended = NO;
    if (event.author.length != 32 || event.seq < 1 || event.seq > INT64_MAX || event.lamport < 1 ||
        event.lamport > INT64_MAX || event.header.length == 0) {
        return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorInvalid, @"bad sync event"));
    }
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        NSNumber *last = [db scalar:@"SELECT coalesce(max(seq), 0) FROM sync_events WHERE author = ?"
                              binds:@[ event.author ]
                              error:inner];
        if (!last) return NO;
        if (event.seq <= last.unsignedLongLongValue) return YES; // held already: the log is contiguous
        if (event.seq != last.unsignedLongLongValue + 1) {
            return SZFriendsFail(inner, SZFriendsStoreMakeError(SZFriendsStoreErrorInvalid, @"a gap in the log"));
        }
        NSString *sql = [NSString stringWithFormat:@"INSERT INTO sync_events (%@) VALUES (?,?,?,?,?,?,?,?,?)",
                                                   SZFriendsSyncEventColumns];
        NSArray *binds = @[
            event.author, @(event.seq), @(event.lamport), @(event.kind), event.scope ?: @"", event.subject ?: @"",
            event.header, SZFriendsSQL(event.body), @(event.applied)
        ];
        if (![db run:sql binds:binds row:nil error:inner]) return NO;
        if (appended) *appended = YES;
        return YES;
    } error:error];
}

- (NSArray<SZFriendsSyncLogEvent *> *)syncEventsMissingFrom:(SZFriendsSyncVector *)vector limit:(NSUInteger)limit {
    // One range per author we hold: (author, seq > what the vector has). At most 128 authors (the chain's limit).
    NSMutableArray<SZFriendsSyncLogEvent *> *events = [NSMutableArray array];
    NSArray<NSData *> *authors = [[self syncVector].allKeys sortedArrayUsingComparator:^(NSData *a, NSData *b) {
        int order = memcmp(a.bytes, b.bytes, 32);
        return order < 0 ? NSOrderedAscending : (order > 0 ? NSOrderedDescending : NSOrderedSame);
    }];
    for (NSData *author in authors) {
        if (events.count >= limit) break;
        uint64_t held = [vector[author] unsignedLongLongValue];
        NSString *sql = [NSString stringWithFormat:@"SELECT %@ FROM sync_events WHERE author = ? AND seq > ? "
                                                   @"ORDER BY seq LIMIT ?",
                                                   SZFriendsSyncEventColumns];
        [events addObjectsFromArray:[self syncRows:sql
                                             binds:@[
                                                 author, @(MIN(held, (uint64_t)INT64_MAX)), @(limit - events.count)
                                             ]
                                               map:^id(sqlite3_stmt *s) { return SZFriendsSyncEventFromRow(s); }]];
    }
    return events;
}

- (nullable SZFriendsSyncLogEvent *)syncEventWithAuthor:(NSData *)author seq:(uint64_t)seq {
    NSString *sql = [NSString stringWithFormat:@"SELECT %@ FROM sync_events WHERE author = ? AND seq = ?",
                                               SZFriendsSyncEventColumns];
    return [self syncRows:sql binds:@[ author, @(MIN(seq, (uint64_t)INT64_MAX)) ] map:^id(sqlite3_stmt *s) {
        return SZFriendsSyncEventFromRow(s);
    }].firstObject;
}

- (NSArray<SZFriendsSyncLogEvent *> *)syncEventsOfAuthor:(NSData *)author afterSeq:(uint64_t)seq {
    NSString *sql = [NSString stringWithFormat:@"SELECT %@ FROM sync_events WHERE author = ? AND seq > ? ORDER BY seq",
                                               SZFriendsSyncEventColumns];
    return [self syncRows:sql binds:@[ author, @(MIN(seq, (uint64_t)INT64_MAX)) ] map:^id(sqlite3_stmt *s) {
        return SZFriendsSyncEventFromRow(s);
    }];
}

- (NSArray<SZFriendsSyncLogEvent *> *)unappliedSyncEvents {
    NSString *sql = [NSString stringWithFormat:@"SELECT %@ FROM sync_events WHERE applied = 0 "
                                               @"ORDER BY lamport, author, seq",
                                               SZFriendsSyncEventColumns];
    return [self syncRows:sql binds:@[] map:^id(sqlite3_stmt *s) { return SZFriendsSyncEventFromRow(s); }];
}

- (NSArray<SZFriendsSyncLogEvent *> *)syncEventsOfKind:(NSInteger)kind {
    NSString *sql = [NSString stringWithFormat:@"SELECT %@ FROM sync_events WHERE kind = ? ORDER BY author, seq",
                                               SZFriendsSyncEventColumns];
    return [self syncRows:sql binds:@[ @(kind) ] map:^id(sqlite3_stmt *s) { return SZFriendsSyncEventFromRow(s); }];
}

- (BOOL)hasBodilessSyncEventOfKind:(NSInteger)kind subject:(NSString *)subject {
    return [[self syncScalar:@"SELECT count(*) FROM sync_events WHERE kind = ? AND subject = ? AND body IS NULL"
                       binds:@[ @(kind), subject ]] integerValue] > 0;
}

- (BOOL)markSyncEventApplied:(NSData *)author seq:(uint64_t)seq error:(NSError **)error {
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        return [db run:@"UPDATE sync_events SET applied = 1 WHERE author = ? AND seq = ?"
                 binds:@[ author, @(MIN(seq, (uint64_t)INT64_MAX)) ]
                   row:nil
                 error:inner];
    } error:error];
}

#pragma mark Registers and state

- (nullable SZFriendsSyncRegister *)syncRegisterForKey:(NSString *)key {
    return [self syncRegistersWhere:@"WHERE key = ?" binds:@[ key ]][key];
}

- (NSDictionary<NSString *, SZFriendsSyncRegister *> *)syncRegistersWithPrefix:(NSString *)prefix {
    // substr rather than LIKE: keys hold ids with '_', which LIKE would read as a wildcard.
    return [self syncRegistersWhere:@"WHERE substr(key, 1, ?) = ?" binds:@[ @(prefix.length), prefix ]];
}

- (NSDictionary<NSString *, SZFriendsSyncRegister *> *)syncRegistersWhere:(NSString *)where binds:(NSArray *)binds {
    NSMutableDictionary<NSString *, SZFriendsSyncRegister *> *registers = [NSMutableDictionary dictionary];
    NSString *sql = [@"SELECT key, lamport, author, value FROM sync_registers " stringByAppendingString:where];
    [self syncRows:sql binds:binds map:^id(sqlite3_stmt *s) {
        SZFriendsSyncRegister *value = [[SZFriendsSyncRegister alloc] init];
        value.lamport = (uint64_t)SZFriendsColumnInt(s, 1);
        value.author = SZFriendsColumnBlob(s, 2) ?: [NSData data];
        value.value = SZFriendsColumnBlob(s, 3);
        NSString *key = SZFriendsColumnText(s, 0);
        if (key) registers[key] = value;
        return [NSNull null];
    }];
    return registers;
}

- (BOOL)setSyncRegister:(SZFriendsSyncRegister *)value forKey:(NSString *)key error:(NSError **)error {
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        return [db run:@"INSERT OR REPLACE INTO sync_registers (key, lamport, author, value) VALUES (?,?,?,?)"
                 binds:@[ key, @(MIN(value.lamport, (uint64_t)INT64_MAX)), value.author ?: [NSData data],
                          SZFriendsSQL(value.value) ]
                   row:nil
                 error:inner];
    } error:error];
}

- (nullable id)syncStateForKey:(NSString *)key {
    return [self syncScalar:@"SELECT value FROM sync_state WHERE key = ?" binds:@[ key ]];
}

- (NSDictionary<NSString *, id> *)syncStatesWithPrefix:(NSString *)prefix {
    NSString *escaped = [[prefix stringByReplacingOccurrencesOfString:@"%" withString:@""]
        stringByReplacingOccurrencesOfString:@"_" withString:@""];
    NSArray *rows = [self syncRows:@"SELECT key, value FROM sync_state WHERE key LIKE ? ORDER BY key"
                             binds:@[ [escaped stringByAppendingString:@"%"] ]
                               map:^id(sqlite3_stmt *s) {
                                   NSString *key = SZFriendsColumnText(s, 0) ?: @"";
                                   id value = sqlite3_column_type(s, 1) == SQLITE_INTEGER
                                                  ? @(sqlite3_column_int64(s, 1))
                                                  : (SZFriendsColumnText(s, 1) ?: (id)NSNull.null);
                                   return @[ key, value ];
                               }];
    NSMutableDictionary<NSString *, id> *states = [NSMutableDictionary dictionary];
    for (NSArray *row in rows) {
        if ([row[0] hasPrefix:prefix]) states[row[0]] = row[1];
    }
    return states;
}

- (BOOL)setSyncState:(nullable id)value forKey:(NSString *)key error:(NSError **)error {
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        if (value == nil) return [db run:@"DELETE FROM sync_state WHERE key = ?" binds:@[ key ] row:nil error:inner];
        return [db run:@"INSERT OR REPLACE INTO sync_state (key, value) VALUES (?, ?)" binds:@[ key, value ]
                   row:nil
                 error:inner];
    } error:error];
}

- (BOOL)performSyncTransaction:(BOOL (^)(NSError **error))body error:(NSError **)error {
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        (void)db;
        return body(inner);
    } error:error];
}

@end

NS_ASSUME_NONNULL_END
