// SZFriendsStore: opening, the two connections and their queues, profile and settings, and the delete actions.
// The data work lives in focused files (People, History, Search, Schema); methods here route it to the right
// connection on the right queue.

#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

#import "service/store/SZFriendsStoreInternal.h"

NS_ASSUME_NONNULL_BEGIN

void (*_Nullable SZFriendsStoreTestHook)(const char *point) = NULL;

static void *const SZFriendsStoreQueueKey = (void *)&SZFriendsStoreQueueKey;
static void *const SZFriendsStoreReadQueueKey = (void *)&SZFriendsStoreReadQueueKey;

@implementation SZFriendsStoreOptions
@end

@implementation SZFriendsStore {
    SZFriendsStoreDB *_writer;
    SZFriendsStoreDB *_reader;
    dispatch_queue_t _queue;
    dispatch_queue_t _readQueue;
}

@synthesize stateDirectory = _stateDirectory, databasePath = _databasePath, searchUsesIndex = _searchUsesIndex;
@synthesize schemaVersion = _schemaVersion;

+ (nullable instancetype)storeInDirectory:(NSString *)stateDirectory error:(NSError **)error {
    return [self storeInDirectory:stateDirectory options:nil error:error];
}

static BOOL SZFriendsOpenFailure(NSError **error, NSString *why) {
    return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorOpenFailed, why));
}

+ (nullable instancetype)storeInDirectory:(NSString *)stateDirectory
                                  options:(nullable SZFriendsStoreOptions *)options
                                    error:(NSError **)error {
    NSFileManager *files = NSFileManager.defaultManager;
    if (![files fileExistsAtPath:stateDirectory] &&
        ![files createDirectoryAtPath:stateDirectory withIntermediateDirectories:YES
                           attributes:@{NSFilePosixPermissions : @0700} error:error]) {
        return nil;
    }
    NSString *path = [stateDirectory stringByAppendingPathComponent:@"friends.sqlite"];
    // Created 0600 before SQLite sees it: SQLite gives the -wal and -shm files the database's own mode, so the whole
    // history stays private to this user even with a permissive umask.
    int fd = open(path.fileSystemRepresentation, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) {
        SZFriendsOpenFailure(error, [NSString stringWithFormat:@"cannot open %@: %s", path, strerror(errno)]);
        return nil;
    }
    fchmod(fd, 0600);
    close(fd);
    SZFriendsStoreDB *writer = [SZFriendsStoreDB openAtPath:path readOnly:NO error:error];
    if (!writer) return nil;
    NSArray<SZFriendsStoreMigration *> *migrations = options.migrations ?: SZFriendsStoreShippedMigrations();
    NSInteger codeVersion = 0;
    for (SZFriendsStoreMigration *migration in migrations) codeVersion = MAX(codeVersion, migration.version);
    NSInteger fileVersion = 0, minReader = 0;
    if (!SZFriendsStoreReadVersions(writer, &fileVersion, &minReader, error)) {
        [writer close];
        return nil;
    }
    // Checked before anything writes, so a store a newer app upgraded is left exactly as it was (ADR 0002).
    if (minReader > codeVersion) {
        [writer close];
        NSString *why = [NSString stringWithFormat:@"the store needs schema v%ld; this helper reads up to v%ld",
                                                   (long)minReader, (long)codeVersion];
        SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorNewerSchema, why));
        return nil;
    }
    NSString *mode = [writer scalar:@"PRAGMA journal_mode=WAL" binds:nil error:error];
    if (![mode isEqualToString:@"wal"]) {
        [writer close];
        SZFriendsOpenFailure(error, @"the store could not switch to WAL");
        return nil;
    }
    NSInteger version = SZFriendsStoreMigrate(writer, path, migrations, error);
    BOOL usesIndex = NO;
    BOOL ok = version >= 0 && SZFriendsStorePrepareSearch(writer, !options.disableTrigram, &usesIndex, error);
    // ADR 0003 § Crash recovery: an entry caught mid-send after a crash is sent again under the same id; the
    // recipient deduplicates, so this can never deliver twice.
    ok = ok && [writer run:@"UPDATE outbox SET state = ?, updated_at = ? WHERE state IN (?, ?)"
                     binds:@[ @(SZFriendsOutboxStateQueued), [NSDate date], @(SZFriendsOutboxStateConnecting),
                              @(SZFriendsOutboxStateSending) ]
                       row:nil
                     error:error];
    SZFriendsStoreDB *reader = ok ? [SZFriendsStoreDB openAtPath:path readOnly:YES error:error] : nil;
    if (!reader) {
        [writer close];
        return nil;
    }
    SZFriendsStore *store = [[self alloc] init];
    store->_writer = writer;
    store->_reader = reader;
    store->_stateDirectory = [stateDirectory copy];
    store->_databasePath = path;
    store->_schemaVersion = version;
    store->_searchUsesIndex = usesIndex;
    store->_queue = dispatch_queue_create("SZFriends.store", DISPATCH_QUEUE_SERIAL);
    store->_readQueue = dispatch_queue_create("SZFriends.store.read", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(store->_queue, SZFriendsStoreQueueKey, (__bridge void *)store, NULL);
    dispatch_queue_set_specific(store->_readQueue, SZFriendsStoreReadQueueKey, (__bridge void *)store, NULL);
    return store;
}

- (void)close {
    [self performOnWriter:^(SZFriendsStoreDB *_Nullable db) {
        (void)db;
        [self performRead:^(SZFriendsStoreDB *_Nullable reader) { [reader close]; }];
        self->_reader = nil;
        [self->_writer close];
        self->_writer = nil;
    }];
}

- (void)dealloc {
    [_reader close];
    [_writer close];
}

#pragma mark - Queues

// Inline when already on the queue, so a write block may call store methods without deadlocking.
- (void)performOnWriter:(void (^)(SZFriendsStoreDB *_Nullable db))body {
    if (dispatch_get_specific(SZFriendsStoreQueueKey) == (__bridge void *)self) {
        body(_writer);
        return;
    }
    dispatch_sync(_queue, ^{ body(self->_writer); });
}

- (void)performRead:(void (^)(SZFriendsStoreDB *_Nullable db))body {
    if (dispatch_get_specific(SZFriendsStoreReadQueueKey) == (__bridge void *)self) {
        body(_reader);
        return;
    }
    dispatch_sync(_readQueue, ^{ body(self->_reader); });
}

- (BOOL)performWrite:(BOOL (^)(SZFriendsStoreDB *db, NSError **error))body error:(NSError **)error {
    __block BOOL ok = NO;
    __block NSError *failure = nil;
    [self performOnWriter:^(SZFriendsStoreDB *_Nullable db) {
        if (!db) {
            failure = SZFriendsStoreMakeError(SZFriendsStoreErrorOpenFailed, @"the store is closed");
            return;
        }
        NSError *inner = nil;
        ok = [db transaction:^BOOL(NSError **bodyError) { return body(db, bodyError); } error:&inner];
        failure = inner;
    }];
    if (!ok && error) *error = failure;
    return ok;
}

#pragma mark - People and history

- (NSArray<SZFriendsPersonRecord *> *)peopleByLatestInteraction {
    __block NSArray *people = @[];
    [self performRead:^(SZFriendsStoreDB *_Nullable db) { if (db) people = SZFriendsStorePeople(db, nil, nil); }];
    return people;
}

- (nullable SZFriendsPersonRecord *)personWhere:(NSString *)where binds:(NSArray *)binds {
    __block SZFriendsPersonRecord *person = nil;
    [self performRead:^(SZFriendsStoreDB *_Nullable db) {
        if (db) person = SZFriendsStorePeople(db, where, binds).firstObject;
    }];
    return person;
}

- (nullable SZFriendsPersonRecord *)personWithConversationID:(NSString *)conversationID {
    return [self personWhere:@"WHERE conversation_id = ?" binds:@[ conversationID ]];
}

- (nullable SZFriendsPersonRecord *)personWithIdentityKey:(NSData *)identityKey {
    // The person whose identity (root) key this is; failing that, the person a friend's chain says this device
    // speaks for (ADR 0012), so every lookup by a session's key finds a friend's other devices too. Revoked and void
    // devices are not in the second clause; our own devices never are.
    return [self personWhere:@"WHERE identity_pk = coalesce((SELECT identity_pk FROM friends WHERE identity_pk = ?), "
                             @"(SELECT d.root_pk FROM chain_devices d JOIN device_chains c ON c.root_pk = d.root_pk "
                             @"WHERE d.device_pk = ? AND d.state = 1 AND c.own = 0))"
                       binds:@[ identityKey, identityKey ]];
}

- (BOOL)savePerson:(SZFriendsPersonRecord *)person error:(NSError **)error {
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        return SZFriendsStoreSavePerson(db, person, inner);
    } error:error];
}

- (BOOL)notePresentedStaticKey:(NSData *)staticKey
                   certificate:(NSData *)certificate
               forConversation:(NSString *)conversationID
                         error:(NSError **)error {
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        return SZFriendsStoreNotePresentedStaticKey(db, conversationID, staticKey, certificate, inner);
    } error:error];
}

- (BOOL)acceptPendingStaticKeyForConversation:(NSString *)conversationID error:(NSError **)error {
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        return SZFriendsStoreAcceptPendingStaticKey(db, conversationID, inner);
    } error:error];
}

- (NSArray<SZFriendsItemRecord *> *)itemsInConversation:(NSString *)conversationID
                                            beforeItemID:(nullable NSString *)beforeItemID
                                                   limit:(NSUInteger)limit
                                              hasEarlier:(nullable BOOL *)hasEarlier {
    __block NSArray *items = @[];
    __block BOOL earlier = NO;
    [self performRead:^(SZFriendsStoreDB *_Nullable db) {
        if (db) items = SZFriendsStoreItems(db, conversationID, beforeItemID, limit, &earlier);
    }];
    if (hasEarlier) *hasEarlier = earlier;
    return items;
}

- (nullable NSArray<SZFriendsItemRecord *> *)itemsInConversation:(NSString *)conversationID
                                                    aroundItemID:(NSString *)itemID
                                                          before:(NSUInteger)before
                                                           after:(NSUInteger)after {
    __block NSArray *items = nil;
    [self performRead:^(SZFriendsStoreDB *_Nullable db) {
        if (db) items = SZFriendsStoreItemsAround(db, conversationID, itemID, before, after);
    }];
    return items;
}

- (nullable SZFriendsItemRecord *)itemWithID:(NSString *)itemID inConversation:(NSString *)conversationID {
    return [self itemsInConversation:conversationID aroundItemID:itemID before:0 after:0].firstObject;
}

- (BOOL)insertItem:(SZFriendsItemRecord *)item error:(NSError **)error {
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        return SZFriendsStoreInsertItem(db, item, NULL, inner);
    } error:error];
}

- (BOOL)markConversationRead:(NSString *)conversationID error:(NSError **)error {
    return [self performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        return [db run:@"UPDATE friends SET unread_count = 0 WHERE conversation_id = ?"
                 binds:@[ conversationID ]
                   row:nil
                 error:inner];
    } error:error];
}

- (NSArray<SZFriendsSearchHit *> *)searchFor:(NSString *)query
                             conversationIDs:(nullable NSArray<NSString *> *)conversationIDs
                                       limit:(NSUInteger)limit {
    __block NSArray *hits = @[];
    BOOL useIndex = _searchUsesIndex;
    [self performRead:^(SZFriendsStoreDB *_Nullable db) {
        if (db) hits = SZFriendsStoreSearch(db, query, conversationIDs, limit, useIndex);
    }];
    return hits;
}

#pragma mark - Profile and settings

- (nullable id)readValue:(NSString *)sql binds:(NSArray *)binds {
    __block id value = nil;
    [self performRead:^(SZFriendsStoreDB *_Nullable db) { value = [db scalar:sql binds:binds error:NULL]; }];
    return value;
}

- (nullable id)profileValue:(NSString *)column {
    return [self readValue:[NSString stringWithFormat:@"SELECT %@ FROM profile WHERE id = 1", column] binds:@[]];
}

// Setters cannot report errors through the property syntax, so a failure is logged; the next read shows the truth.
- (void)writeLogged:(NSString *)what body:(BOOL (^)(SZFriendsStoreDB *db, NSError **error))body {
    NSError *error = nil;
    if (![self performWrite:body error:&error]) {
        NSLog(@"Friends store: saving %@ failed: %@", what, error.localizedDescription);
    }
}

- (void)setProfileColumns:(NSDictionary<NSString *, id> *)values {
    [self writeLogged:@"the profile" body:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        if (![db exec:@"INSERT INTO profile(id) VALUES (1) ON CONFLICT(id) DO NOTHING" error:inner]) return NO;
        for (NSString *column in values) {
            NSString *sql = [NSString stringWithFormat:@"UPDATE profile SET %@ = ? WHERE id = 1", column];
            if (![db run:sql binds:@[ values[column] ] row:nil error:inner]) return NO;
        }
        return YES;
    }];
}

- (nullable NSString *)profileName { return [self profileValue:@"name"]; }
- (void)setProfileName:(nullable NSString *)name { [self setProfileColumns:@{@"name" : SZFriendsSQL(name)}]; }
- (nullable NSString *)friendsID { return [self profileValue:@"friends_id"]; }
- (void)setFriendsID:(nullable NSString *)value { [self setProfileColumns:@{@"friends_id" : SZFriendsSQL(value)}]; }
- (NSInteger)friendsIDState { return [[self profileValue:@"friends_id_state"] integerValue]; }
- (void)setFriendsIDState:(NSInteger)state { [self setProfileColumns:@{@"friends_id_state" : @(state)}]; }
- (nullable NSString *)previousFriendsID { return [self profileValue:@"previous_friends_id"]; }
- (void)setPreviousFriendsID:(nullable NSString *)value {
    [self setProfileColumns:@{@"previous_friends_id" : SZFriendsSQL(value)}];
}
- (NSUInteger)idCollisionsInARow { return [[self profileValue:@"id_collisions"] unsignedIntegerValue]; }

- (void)setIdCollisionsInARow:(NSUInteger)count {
    [self writeLogged:@"the collision count" body:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        if (![db exec:@"INSERT INTO profile(id) VALUES (1) ON CONFLICT(id) DO NOTHING" error:inner]) return NO;
        // ADR 0006: three collisions in a row switch to three-word IDs for good; a later reset to zero would quietly
        // switch back to the crowded two-word space.
        NSString *sql = @"UPDATE profile SET id_collisions = ? WHERE id = 1 AND NOT (id_collisions >= 3 AND ? < 3)";
        return [db run:sql binds:@[ @(count), @(count) ] row:nil error:inner];
    }];
}

- (SZFriendsPicture *)profilePicture {
    __block SZFriendsPicture *picture = nil;
    [self performRead:^(SZFriendsStoreDB *_Nullable db) {
        [db run:@"SELECT picture_kind, picture_set, picture_index, picture_path, picture_sha256 FROM profile "
                @"WHERE id = 1"
            binds:nil
              row:^(sqlite3_stmt *s) {
                  int64_t kind = SZFriendsColumnInt(s, 0);
                  NSString *path = SZFriendsColumnText(s, 3);
                  NSData *sha = SZFriendsColumnBlob(s, 4);
                  if (kind == SZFriendsPictureKindAnimal) {
                      picture = [SZFriendsPicture animalWithSet:(NSInteger)SZFriendsColumnInt(s, 1)
                                                          index:(NSInteger)SZFriendsColumnInt(s, 2)];
                  } else if (kind == SZFriendsPictureKindImage && path && sha) {
                      picture = [SZFriendsPicture imageAtPath:path sha256:sha];
                  }
              }
            error:NULL];
    }];
    return picture ?: [SZFriendsPicture placeholder];
}

- (void)setProfilePicture:(SZFriendsPicture *)picture {
    SZFriendsPicture *value = picture ?: [SZFriendsPicture placeholder];
    [self setProfileColumns:@{
        @"picture_kind" : @(value.kind), @"picture_set" : @(value.animalSet), @"picture_index" : @(value.animalIndex),
        @"picture_path" : SZFriendsSQL(value.imagePath), @"picture_sha256" : SZFriendsSQL(value.imageSHA256)
    }];
}

- (nullable id)setting:(NSString *)key {
    return [self readValue:@"SELECT value FROM settings WHERE key = ?" binds:@[ key ]];
}

- (void)setSetting:(nullable id)value forKey:(NSString *)key {
    [self writeLogged:key body:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        if (!value) return [db run:@"DELETE FROM settings WHERE key = ?" binds:@[ key ] row:nil error:inner];
        return [db run:@"INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET "
                       @"value = excluded.value"
                 binds:@[ key, value ]
                   row:nil
                 error:inner];
    }];
}

- (BOOL)nearbyPermissionsRequested { return [[self setting:@"nearby_permissions_requested"] boolValue]; }
- (BOOL)fastTransfersEnabled {
    id value = [self setting:@"transfers.fast"];
    return value == nil || [value integerValue] != 0;
}
- (void)setNearbyPermissionsRequested:(BOOL)value {
    [self setSetting:@(value ? 1 : 0) forKey:@"nearby_permissions_requested"];
}
- (nullable NSData *)ownPresenceSecret {
    id value = [self setting:@"own_presence_secret"];
    return [value isKindOfClass:[NSData class]] ? value : nil;
}
- (void)setOwnPresenceSecret:(nullable NSData *)secret { [self setSetting:secret forKey:@"own_presence_secret"]; }

- (nullable NSDate *)visibilityDeadline {
    id value = [self setting:@"visibility_deadline"];
    return [value isKindOfClass:[NSNumber class]] ? [NSDate dateWithTimeIntervalSince1970:[value doubleValue]] : nil;
}

- (void)setVisibilityDeadline:(nullable NSDate *)deadline {
    [self writeLogged:@"the visibility deadline" body:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        if (!deadline) return [db run:@"DELETE FROM settings WHERE key = 'visibility_deadline'" binds:nil row:nil
                                error:inner];
        // Repeating start_visibility, a second app or a restart must never extend a running deadline (brief).
        NSString *sql = @"INSERT INTO settings(key, value) VALUES ('visibility_deadline', ?1) ON CONFLICT(key) DO "
                        @"UPDATE SET value = CASE WHEN value > ?2 AND ?1 > value THEN value ELSE ?1 END";
        return [db run:sql binds:@[ @(deadline.timeIntervalSince1970), @(NSDate.date.timeIntervalSince1970) ]
                   row:nil
                 error:inner];
    }];
}

#pragma mark - Delete actions

- (void)removeBackups {
    NSString *prefix = [_databasePath.lastPathComponent stringByAppendingString:@".before-v"];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:_stateDirectory error:NULL]) {
        if ([name hasPrefix:prefix]) {
            unlink([_stateDirectory stringByAppendingPathComponent:name].fileSystemRepresentation);
        }
    }
}

// VACUUM rewrites the file without free pages; the truncating checkpoint then empties the WAL, which still holds
// the pre-delete pages. Reads are held off meanwhile so no snapshot pins old frames (ADR 0003 § Deletes).
- (BOOL)compact:(SZFriendsStoreDB *)db error:(NSError **)error {
    __block BOOL ok = NO;
    __block NSError *failure = nil;
    [self performRead:^(SZFriendsStoreDB *_Nullable reader) {
        (void)reader;
        ok = [db exec:@"VACUUM" error:&failure];
        if (!ok) return;
        __block int busy = 1;
        ok = [db run:@"PRAGMA wal_checkpoint(TRUNCATE)" binds:nil
                 row:^(sqlite3_stmt *s) { busy = (int)SZFriendsColumnInt(s, 0); }
               error:&failure];
        if (ok && busy) {
            ok = NO;
            failure = SZFriendsStoreMakeError(SZFriendsStoreErrorDatabase, @"the WAL could not be truncated");
        }
    }];
    if (!ok && error) *error = failure;
    return ok;
}

- (BOOL)deleteRows:(BOOL (^)(SZFriendsStoreDB *db, NSMutableArray *files, NSError **error))rows
       directories:(NSArray<NSString *> *)directories
             error:(NSError **)error {
    __block BOOL ok = NO;
    __block NSError *failure = nil;
    [self performOnWriter:^(SZFriendsStoreDB *_Nullable db) {
        if (!db) {
            failure = SZFriendsStoreMakeError(SZFriendsStoreErrorOpenFailed, @"the store is closed");
            return;
        }
        NSMutableArray<NSString *> *files = [NSMutableArray array];
        ok = [db transaction:^BOOL(NSError **inner) {
            if (!rows(db, files, inner)) return NO;
            // Deleted rows leave their trigrams in the index's old segments until a merge; a rebuild drops them now.
            return self->_searchUsesIndex ? SZFriendsStoreRebuildSearch(db, inner) : YES;
        } error:&failure];
        if (!ok) return;
        SZFriendsRemovePrivateFiles(self->_stateDirectory, files);
        for (NSString *directory in directories) {
            NSString *path = [self->_stateDirectory stringByAppendingPathComponent:directory];
            [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
        }
        // Backups taken before a migration still hold the deleted text.
        [self removeBackups];
        ok = [self compact:db error:&failure];
    }];
    if (!ok && error) *error = failure;
    return ok;
}

- (BOOL)deleteHistoryInConversation:(nullable NSString *)conversationID error:(NSError **)error {
    return [self deleteRows:^BOOL(SZFriendsStoreDB *db, NSMutableArray *files, NSError **inner) {
        return SZFriendsStoreDeleteHistoryRows(db, conversationID, files, inner);
    } directories:@[] error:error];
}

- (BOOL)deleteEverythingExceptReceivedFilesWithError:(NSError **)error {
    return [self deleteRows:^BOOL(SZFriendsStoreDB *db, NSMutableArray *files, NSError **inner) {
        if (!SZFriendsStoreDeleteHistoryRows(db, nil, files, inner)) return NO;
        // Device chains too: Reset Friends makes a new identity, so this device starts a new chain (ADR 0012).
        NSString *wipe = @"DELETE FROM outbox; DELETE FROM id_request_answers; DELETE FROM id_requests; "
                         @"DELETE FROM friends; DELETE FROM profile; DELETE FROM settings; DELETE FROM links; "
                         @"DELETE FROM invites; DELETE FROM device_chains; DELETE FROM sync_events; "
                         @"DELETE FROM sync_registers; DELETE FROM sync_origins; DELETE FROM sync_deleted; "
                         @"DELETE FROM sync_files; DELETE FROM sync_state; "
                         @"DELETE FROM meta WHERE key = 'search_stale';";
        if (![db exec:wipe error:inner]) return NO;
        return [db run:@"UPDATE meta SET value = ? WHERE key = 'store_id'" binds:@[ SZFriendsNewIdentifier() ]
                   row:nil
                 error:inner];
    } directories:@[ @"pictures", @"outgoing", @"received/.partial", @"thumbnails", @"links" ] error:error];
}

@end

NS_ASSUME_NONNULL_END
