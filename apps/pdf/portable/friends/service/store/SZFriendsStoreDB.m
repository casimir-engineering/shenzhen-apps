// The store's SQLite connection wrapper: pragmas, cached statements, binds, transactions and error mapping.

#import "service/store/SZFriendsStoreInternal.h"

NS_ASSUME_NONNULL_BEGIN

NSErrorDomain const SZFriendsStoreErrorDomain = @"SZFriendsStoreErrorDomain";

NSError *SZFriendsStoreMakeError(SZFriendsStoreError code, NSString *description) {
    return [NSError errorWithDomain:SZFriendsStoreErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : description}];
}

NSError *SZFriendsStoreSQLiteError(sqlite3 *_Nullable db, int resultCode, NSString *context) {
    int primary = resultCode & 0xff;
    SZFriendsStoreError code = SZFriendsStoreErrorDatabase;
    if (primary == SQLITE_FULL) code = SZFriendsStoreErrorDiskFull;
    else if (primary == SQLITE_CONSTRAINT) code = SZFriendsStoreErrorConstraint;
    const char *message = db ? sqlite3_errmsg(db) : sqlite3_errstr(resultCode);
    NSString *detail = [NSString stringWithFormat:@"%@: %s (SQLite %d)", context, message ?: "", resultCode];
    return [NSError errorWithDomain:SZFriendsStoreErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : detail, @"SQLiteResultCode" : @(resultCode)}];
}

BOOL SZFriendsFail(NSError *_Nullable *_Nullable out, NSError *error) {
    if (out) *out = error;
    return NO;
}

BOOL SZFriendsStoreIsValidIdentifier(NSString *_Nullable identifier) {
    NSUInteger length = identifier.length;
    if (length == 0 || length > 64) return NO;
    for (NSUInteger i = 0; i < length; i++) {
        unichar c = [identifier characterAtIndex:i];
        BOOL ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-';
        if (!ok) return NO;
    }
    return YES;
}

NSString *_Nullable SZFriendsColumnText(sqlite3_stmt *statement, int column) {
    const unsigned char *text = sqlite3_column_text(statement, column);
    if (!text) return nil;
    return [[NSString alloc] initWithBytes:text
                                    length:(NSUInteger)sqlite3_column_bytes(statement, column)
                                  encoding:NSUTF8StringEncoding];
}

NSData *_Nullable SZFriendsColumnBlob(sqlite3_stmt *statement, int column) {
    if (sqlite3_column_type(statement, column) == SQLITE_NULL) return nil;
    const void *bytes = sqlite3_column_blob(statement, column);
    int length = sqlite3_column_bytes(statement, column);
    return length > 0 ? [NSData dataWithBytes:bytes length:(NSUInteger)length] : [NSData data];
}

NSDate *_Nullable SZFriendsColumnDate(sqlite3_stmt *statement, int column) {
    if (sqlite3_column_type(statement, column) == SQLITE_NULL) return nil;
    return [NSDate dateWithTimeIntervalSince1970:sqlite3_column_double(statement, column)];
}

int64_t SZFriendsColumnInt(sqlite3_stmt *statement, int column) { return sqlite3_column_int64(statement, column); }

double SZFriendsColumnDouble(sqlite3_stmt *statement, int column) { return sqlite3_column_double(statement, column); }

@implementation SZFriendsStoreDB {
    sqlite3 *_db;
    NSMutableDictionary<NSString *, NSValue *> *_statements;
    NSUInteger _savepointDepth;
}

+ (nullable instancetype)openAtPath:(NSString *)path readOnly:(BOOL)readOnly error:(NSError **)error {
    // NOMUTEX: each connection is confined to one serial queue, so SQLite's own mutexes would only add cost.
    // Not SQLITE_OPEN_NOFOLLOW: it refuses a symlink anywhere in the path (/var is one, and so is a relocated home
    // folder); the store refuses a symlink at the database path itself when it pre-creates the file (O_NOFOLLOW).
    int flags = SQLITE_OPEN_NOMUTEX;
    flags |= readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE);
    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2(path.fileSystemRepresentation, &db, flags, NULL);
    if (rc != SQLITE_OK) {
        NSError *failure = SZFriendsStoreSQLiteError(db, rc, @"open");
        sqlite3_close_v2(db);
        SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorOpenFailed, failure.localizedDescription));
        return nil;
    }
    sqlite3_extended_result_codes(db, 1);
    SZFriendsStoreDB *connection = [[self alloc] init];
    connection->_db = db;
    connection->_statements = [NSMutableDictionary dictionary];
    // ADR 0003 § Pragmas. trusted_schema=OFF keeps SQL functions in the schema (triggers, views) from running
    // anything with side effects if the file were ever tampered with.
    NSString *common = @"PRAGMA busy_timeout=5000; PRAGMA trusted_schema=OFF; PRAGMA foreign_keys=ON;";
    // On macOS a plain fsync can leave data in the drive's cache; FULL plus F_FULLFSYNC on commits and checkpoints is
    // what makes a durable ACK true after a power cut (ADR 0003).
    NSString *writer = @"PRAGMA synchronous=FULL; PRAGMA fullfsync=ON; PRAGMA checkpoint_fullfsync=ON;";
    NSString *pragmas = readOnly ? [common stringByAppendingString:@"PRAGMA query_only=ON;"]
                                 : [common stringByAppendingString:writer];
    if (![connection exec:pragmas error:error]) {
        [connection close];
        return nil;
    }
    return connection;
}

- (nullable sqlite3 *)handle { return _db; }

- (void)close {
    for (NSValue *value in _statements.allValues) sqlite3_finalize(value.pointerValue);
    [_statements removeAllObjects];
    if (_db) sqlite3_close_v2(_db);
    _db = NULL;
}

- (void)dealloc { [self close]; }

- (NSError *)closedError { return SZFriendsStoreMakeError(SZFriendsStoreErrorOpenFailed, @"the store is closed"); }

- (BOOL)exec:(NSString *)sql error:(NSError **)error {
    if (!_db) return SZFriendsFail(error, [self closedError]);
    char *message = NULL;
    int rc = sqlite3_exec(_db, sql.UTF8String, NULL, NULL, &message);
    sqlite3_free(message);
    if (rc != SQLITE_OK) return SZFriendsFail(error, SZFriendsStoreSQLiteError(_db, rc, sql));
    return YES;
}

// A cached statement, or a fresh one when the cached copy is mid-step (a nested query with the same SQL).
- (nullable sqlite3_stmt *)statementFor:(NSString *)sql temporary:(BOOL *)temporary error:(NSError **)error {
    sqlite3_stmt *statement = [_statements[sql] pointerValue];
    *temporary = NO;
    if (statement && !sqlite3_stmt_busy(statement)) return statement;
    sqlite3_stmt *fresh = NULL;
    int rc = sqlite3_prepare_v2(_db, sql.UTF8String, -1, &fresh, NULL);
    if (rc != SQLITE_OK) {
        SZFriendsFail(error, SZFriendsStoreSQLiteError(_db, rc, sql));
        return NULL;
    }
    if (statement) *temporary = YES;
    else _statements[sql] = [NSValue valueWithPointer:fresh];
    return fresh;
}

- (BOOL)bind:(NSArray *)binds to:(sqlite3_stmt *)statement error:(NSError **)error {
    for (NSUInteger i = 0; i < binds.count; i++) {
        id value = binds[i];
        int index = (int)i + 1;
        int rc;
        if ([value isKindOfClass:[NSNull class]]) {
            rc = sqlite3_bind_null(statement, index);
        } else if ([value isKindOfClass:[NSString class]]) {
            rc = sqlite3_bind_text(statement, index, [value UTF8String], -1, SQLITE_TRANSIENT);
        } else if ([value isKindOfClass:[NSData class]]) {
            // An empty NSData may have NULL bytes, which sqlite3_bind_blob would store as NULL rather than x''.
            NSData *data = value;
            rc = data.length ? sqlite3_bind_blob(statement, index, data.bytes, (int)data.length, SQLITE_TRANSIENT)
                             : sqlite3_bind_zeroblob(statement, index, 0);
        } else if ([value isKindOfClass:[NSDate class]]) {
            rc = sqlite3_bind_double(statement, index, [value timeIntervalSince1970]);
        } else if ([value isKindOfClass:[NSNumber class]]) {
            const char *type = [value objCType];
            BOOL real = type[0] == 'd' || type[0] == 'f';
            rc = real ? sqlite3_bind_double(statement, index, [value doubleValue])
                      : sqlite3_bind_int64(statement, index, [value longLongValue]);
        } else {
            return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorInvalid,
                                                                @"unsupported bind value"));
        }
        if (rc != SQLITE_OK) return SZFriendsFail(error, SZFriendsStoreSQLiteError(_db, rc, @"bind"));
    }
    return YES;
}

- (BOOL)run:(NSString *)sql
      binds:(nullable NSArray *)binds
        row:(nullable void (^)(sqlite3_stmt *statement))row
      error:(NSError **)error {
    if (!_db) return SZFriendsFail(error, [self closedError]);
    BOOL temporary = NO;
    sqlite3_stmt *statement = [self statementFor:sql temporary:&temporary error:error];
    if (!statement) return NO;
    BOOL ok = [self bind:binds ?: @[] to:statement error:error];
    if (ok) {
        int rc;
        while ((rc = sqlite3_step(statement)) == SQLITE_ROW) {
            if (row) row(statement);
        }
        if (rc != SQLITE_DONE) ok = SZFriendsFail(error, SZFriendsStoreSQLiteError(_db, rc, sql));
    }
    // Reset at once so no read transaction lingers: an idle statement would pin an old WAL snapshot and keep the
    // truncating checkpoint after Delete history from completing.
    sqlite3_reset(statement);
    sqlite3_clear_bindings(statement);
    if (temporary) sqlite3_finalize(statement);
    return ok;
}

- (nullable id)scalar:(NSString *)sql binds:(nullable NSArray *)binds error:(NSError **)error {
    __block id value = nil;
    BOOL ok = [self run:sql binds:binds row:^(sqlite3_stmt *statement) {
        if (value) return;
        switch (sqlite3_column_type(statement, 0)) {
            case SQLITE_INTEGER: value = @(sqlite3_column_int64(statement, 0)); break;
            case SQLITE_FLOAT: value = @(sqlite3_column_double(statement, 0)); break;
            case SQLITE_TEXT: value = SZFriendsColumnText(statement, 0); break;
            case SQLITE_BLOB: value = SZFriendsColumnBlob(statement, 0); break;
            default: value = [NSNull null]; break;
        }
    } error:error];
    if (!ok || [value isKindOfClass:[NSNull class]]) return nil;
    return value;
}

- (BOOL)transaction:(BOOL (^)(NSError **error))body error:(NSError **)error {
    if (!_db) return SZFriendsFail(error, [self closedError]);
    BOOL nested = !sqlite3_get_autocommit(_db);
    NSString *savepoint = nested ? [NSString stringWithFormat:@"szf_%lu", (unsigned long)++_savepointDepth] : nil;
    // IMMEDIATE takes the write lock up front, so a transaction never fails half-way on a lock upgrade.
    NSString *begin = nested ? [@"SAVEPOINT " stringByAppendingString:savepoint] : @"BEGIN IMMEDIATE";
    NSError *failure = nil;
    BOOL ok = [self exec:begin error:&failure];
    if (ok) {
        ok = body(&failure);
        if (ok) {
            NSString *end = nested ? [@"RELEASE " stringByAppendingString:savepoint] : @"COMMIT";
            ok = [self exec:end error:&failure];
        }
        if (!ok) {
            NSString *undo = nested ? [NSString stringWithFormat:@"ROLLBACK TO %@; RELEASE %@", savepoint, savepoint]
                                    : @"ROLLBACK";
            // A failed COMMIT (disk full) may have ended the transaction already; then ROLLBACK has nothing to undo.
            if (!sqlite3_get_autocommit(_db) || nested) [self exec:undo error:NULL];
        }
    }
    if (nested) _savepointDepth--;
    if (!ok) {
        SZFriendsFail(error, failure ?: SZFriendsStoreMakeError(SZFriendsStoreErrorDatabase, @"transaction failed"));
    }
    return ok;
}

- (NSInteger)changes { return _db ? sqlite3_changes(_db) : 0; }

@end

NS_ASSUME_NONNULL_END
