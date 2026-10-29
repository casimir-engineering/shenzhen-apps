// What a restart finds in the receiver's folders (SZFriendsTransferReceiver.m): files published but not yet marked, downloads
// resumed from their durable prefix, and partial files no row names any more.

#import "service/store/SZFriendsTransferReceiverInternal.h"

NS_ASSUME_NONNULL_BEGIN

@implementation SZFriendsTransferReceiver (Recovery)

- (BOOL)recoverPublishingIn:(SZFriendsStoreDB *)db error:(NSError **)error {
    NSMutableArray<NSArray *> *rows = [NSMutableArray array];
    BOOL ok = [db run:@"SELECT transfer_id, partial_path, final_path, size FROM transfers WHERE publishing = 1"
                binds:nil
                  row:^(sqlite3_stmt *s) {
                      [rows addObject:@[ SZFriendsColumnText(s, 0) ?: @"", SZFriendsSQL(SZFriendsColumnText(s, 1)),
                                         SZFriendsSQL(SZFriendsColumnText(s, 2)), @(SZFriendsColumnInt(s, 3)) ]];
                  }
                error:error];
    if (!ok) return NO;
    for (NSArray *row in rows) {
        NSString *transferID = row[0];
        NSString *partial = [row[1] isKindOfClass:[NSString class]] ? row[1] : nil;
        NSString *final = [row[2] isKindOfClass:[NSString class]] ? row[2] : nil;
        uint64_t size = [row[3] unsignedLongLongValue];
        struct stat info;
        BOOL staged = partial && lstat(partial.fileSystemRepresentation, &info) == 0;
        BOOL published = final && lstat(final.fileSystemRepresentation, &info) == 0;
        SZFriendsTransferRecord *record = staged ? SZFriendsTransferRowLoad(db, transferID) : nil;
        // A copy across volumes renamed before the crash, its staged file not yet removed: the published file is it.
        if (record && published && SZFriendsStagedFileMatchesAtPath(final, record)) {
            unlink(partial.fileSystemRepresentation);
            if (![self markReceived:transferID at:final size:size db:db error:error]) return NO;
            continue;
        }
        // A copy across volumes the crash interrupted: its hidden part file goes, and the copy is redone.
        if (final) unlink(SZFriendsReceivedPartPath(final).fileSystemRepresentation);
        if (record && !SZFriendsStagedFileMatchesAtPath(partial, record)) {
            // Changed on disk since it was verified: never published as if it were what the friend sent.
            if (![self failMismatched:transferID partial:partial db:db error:error]) return NO;
        } else if (record) {
            if (![self publish:record from:partial db:db error:error]) return NO;
        } else if (published) {
            // Renamed before the crash, committed after it: the digest was verified before the rename.
            if (![self markReceived:transferID at:final size:size db:db error:error]) return NO;
        } else {
            // Both gone (only a damaged disk does this): start the download again rather than claim the file.
            NSString *fresh = SZFriendsCreateStagingFile(_partialDirectory, error);
            if (!fresh) return NO;
            NSDictionary *values = @{@"publishing" : @0, @"final_path" : [NSNull null], @"partial_path" : fresh,
                                     @"verified_bytes" : @0};
            if (![db transaction:^BOOL(NSError **inner) {
                    return SZFriendsTransferRowUpdate(db, transferID, values, inner);
                } error:error]) {
                return NO;
            }
        }
    }
    return YES;
}
- (BOOL)recoverReceivingIn:(SZFriendsStoreDB *)db error:(NSError **)error {
    NSArray<SZFriendsTransferRecord *> *receiving =
        SZFriendsTransferRows(db, @"WHERE outgoing = 0 AND state = ?", @[ @(SZFriendsTransferStateReceiving) ]);
    for (SZFriendsTransferRecord *record in receiving) {
        NSString *partial = SZFriendsTransferRowPartialPath(db, record.transferID);
        struct stat info;
        if (!partial || lstat(partial.fileSystemRepresentation, &info) != 0) {
            NSString *fresh = SZFriendsCreateStagingFile(_partialDirectory, error);
            if (!fresh || ![db transaction:^BOOL(NSError **inner) {
                    return SZFriendsTransferRowUpdate(db, record.transferID,
                                                      @{@"partial_path" : fresh, @"verified_bytes" : @0}, inner);
                } error:error]) {
                return NO;
            }
            continue;
        }
        // A download by blocks keeps blocks beyond its durable prefix: its map re-checks them as it reopens (ADR 0018
        // § 4), so nothing is cut here.
        NSString *map = [_partialDirectory stringByAppendingPathComponent:
                                               [record.transferID stringByAppendingString:@".map"]];
        NSData *mapBytes = [NSData dataWithContentsOfFile:map];
        if (mapBytes && [SZFriendsBlockMap mapWithData:mapBytes].leaves != nil) continue;
        // Opening truncates past the durable count and corrects a count the disk no longer backs.
        [_open removeObjectForKey:record.transferID];
        BOOL opened = [db transaction:^BOOL(NSError **inner) {
            return [self openIn:db record:record error:inner] != nil;
        } error:error];
        if (!opened) return NO;
    }
    return YES;
}
// Staging files no row references (a download cancelled mid-crash, a snapshot staged and never offered) hold
// document bytes nobody will use; they go. Rows staged but never offered go with them.
// Copies kept across restarts are given up after this long without a byte arriving (ADR 0018 § 4).
static const NSTimeInterval SZFriendsCopyKeepSeconds = 30 * 24 * 3600;

// A Get again or own-device copy's partial file or received-blocks record (again-<id>, sync-<id>, and <…>.map), changed
// within SZFriendsCopyKeepSeconds: it stays, so the copy resumes from what arrived.
static BOOL SZFriendsIsRecentCopy(NSString *path, NSString *name) {
    NSString *stem = [name hasSuffix:@".map"] ? [name substringToIndex:name.length - 4] : name;
    NSString *identifier = [stem hasPrefix:@"again-"] ? [stem substringFromIndex:6]
                           : [stem hasPrefix:@"sync-"] ? [stem substringFromIndex:5]
                                                       : nil;
    if (identifier.length == 0 || identifier.length > 64) return NO;
    for (NSUInteger i = 0; i < identifier.length; i++) {
        unichar c = [identifier characterAtIndex:i];
        BOOL allowed = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
        if (!allowed) return NO;
    }
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) != 0 || !S_ISREG(info.st_mode)) return NO;
    return [NSDate date].timeIntervalSince1970 - (double)info.st_mtimespec.tv_sec < SZFriendsCopyKeepSeconds;
}
- (BOOL)removeOrphansIn:(SZFriendsStoreDB *)db error:(NSError **)error {
    BOOL ok = [db transaction:^BOOL(NSError **inner) {
        return [db run:@"DELETE FROM transfers WHERE outgoing = 1 AND state = 0 AND transfer_id NOT IN "
                       @"(SELECT transfer_id FROM messages WHERE transfer_id IS NOT NULL) AND transfer_id NOT IN "
                       @"(SELECT item_id FROM outbox WHERE item_id IS NOT NULL)"
                 binds:nil
                   row:nil
                 error:inner];
    } error:error];
    if (!ok) return NO;
    NSMutableSet<NSString *> *referenced = [NSMutableSet set];
    ok = [db run:@"SELECT staged_path, partial_path FROM transfers" binds:nil row:^(sqlite3_stmt *s) {
        for (int column = 0; column < 2; column++) {
            NSString *path = SZFriendsColumnText(s, column);
            if (path) [referenced addObject:path.stringByStandardizingPath];
        }
    } error:error];
    if (!ok) return NO;
    // ADR 0018 § 4: the sidecars of transfers still open stay (received/.partial/<id>.map, outgoing/<id>.tree); a
    // released helper's sweep deletes them, and this one then rebuilds them.
    NSString *outgoingDirectory = [_stateDirectory stringByAppendingPathComponent:@"outgoing"];
    ok = [db run:@"SELECT transfer_id, outgoing FROM transfers WHERE state IN (0, 1, 2, 3, 4)" binds:nil
             row:^(sqlite3_stmt *s) {
                 NSString *transferID = SZFriendsColumnText(s, 0);
                 if (transferID == nil) return;
                 NSString *path = SZFriendsColumnInt(s, 1)
                                      ? [outgoingDirectory stringByAppendingPathComponent:
                                                               [transferID stringByAppendingString:@".tree"]]
                                      : [self->_partialDirectory stringByAppendingPathComponent:
                                                                     [transferID stringByAppendingString:@".map"]];
                 [referenced addObject:path.stringByStandardizingPath];
             }
           error:error];
    if (!ok) return NO;
    NSMutableArray<NSString *> *orphans = [NSMutableArray array];
    NSString *outgoing = [_stateDirectory stringByAppendingPathComponent:@"outgoing"];
    for (NSString *directory in @[ _partialDirectory, outgoing ]) {
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:NULL]) {
            NSString *path = [directory stringByAppendingPathComponent:name];
            if ([referenced containsObject:path.stringByStandardizingPath]) continue;
            if ([directory isEqualToString:_partialDirectory] && SZFriendsIsRecentCopy(path, name)) continue;
            [orphans addObject:path];
        }
    }
    SZFriendsRemovePrivateFiles(_stateDirectory, orphans);
    return YES;
}

@end

NS_ASSUME_NONNULL_END
