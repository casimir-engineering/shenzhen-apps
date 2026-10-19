// File previews in the store (SZFriendsTransferThumbnails.h): table transfer_thumbnails (schema v6) and the PNG files
// it names in <state dir>/thumbnails/.

#import "service/store/SZFriendsTransferThumbnails.h"

#import <unistd.h>

#import "service/store/SZFriendsStoreInternal.h"

NS_ASSUME_NONNULL_BEGIN

static NSString *const SZFriendsThumbnailDirectoryName = @"thumbnails";
// SZFriendsThumbnailMaxSide and SZFriendsThumbnailMaxBytes, repeated in the schema's CHECKs: the store links nothing
// of the thumbnails area, so its suite stands alone.
static const NSUInteger SZFriendsStoreThumbnailMaxSide = 192;

@implementation SZFriendsThumbnailRecord
@end

// The names SZFriendsWriteThumbnailFile gives: 32 lowercase hex digits and ".png". A row never names anything else,
// so a path read back from the database cannot point outside the directory.
static BOOL SZFriendsIsThumbnailName(NSString *name) {
    if (name.length != 36 || ![name hasSuffix:@".png"]) return NO;
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
    return [[name substringToIndex:32] stringByTrimmingCharactersInSet:hex].length == 0;
}

// The thumbnails directory beside the database file: the store's own location, so a data function holding only a
// connection still finds it.
static NSString *_Nullable SZFriendsThumbnailDirectoryForDB(SZFriendsStoreDB *db) {
    const char *file = db.handle ? sqlite3_db_filename(db.handle, "main") : NULL;
    if (file == NULL || file[0] == 0) return nil;
    return [@(file).stringByDeletingLastPathComponent stringByAppendingPathComponent:SZFriendsThumbnailDirectoryName];
}

static void SZFriendsUnlinkThumbnail(NSString *_Nullable directory, NSString *_Nullable name) {
    if (directory == nil || !SZFriendsIsThumbnailName(name)) return;
    unlink([directory stringByAppendingPathComponent:name].fileSystemRepresentation);
}

void SZFriendsThumbnailRowsAfterTransferEvent(SZFriendsStoreDB *db, NSString *transferID,
                                              SZFriendsTransferState previous, SZFriendsTransferState next) {
    // Declined, cancelled, or failed while still an offer nobody accepted (expired, refused, source gone before
    // sending): the brief deletes those pictures. A file that failed after acceptance keeps its picture for Try again.
    BOOL wasOffer = previous == SZFriendsTransferStateQueued || previous == SZFriendsTransferStateOffered ||
                    previous == SZFriendsTransferStateWaitingForYou;
    BOOL ended = next == SZFriendsTransferStateDeclined || next == SZFriendsTransferStateCancelled ||
                 (next == SZFriendsTransferStateFailed && wasOffer);
    if (!ended) return;
    NSString *name = [db scalar:@"SELECT png_name FROM transfer_thumbnails WHERE transfer_id = ?" binds:@[ transferID ]
                          error:NULL];
    if (name == nil) return;
    if ([db run:@"DELETE FROM transfer_thumbnails WHERE transfer_id = ?" binds:@[ transferID ] row:nil error:NULL]) {
        // Unlinked at once rather than after the commit: if the transaction rolls back, the row names a missing file,
        // which the helper shows as no picture; a picture of a declined document must not outlive the decline.
        NSString *file = [name isKindOfClass:NSString.class] ? name : nil;
        SZFriendsUnlinkThumbnail(SZFriendsThumbnailDirectoryForDB(db), file);
    }
}

void SZFriendsThumbnailFilesOfTransfers(SZFriendsStoreDB *db, NSString *whereClause, NSArray *binds,
                                        NSMutableArray<NSString *> *files) {
    NSString *directory = SZFriendsThumbnailDirectoryForDB(db);
    NSString *sql = [NSString stringWithFormat:@"SELECT png_name FROM transfer_thumbnails WHERE transfer_id IN "
                                               @"(SELECT transfer_id FROM transfers %@)",
                                               whereClause];
    [db run:sql binds:binds row:^(sqlite3_stmt *s) {
        NSString *name = SZFriendsColumnText(s, 0);
        if (directory && SZFriendsIsThumbnailName(name)) {
            [files addObject:[directory stringByAppendingPathComponent:name]];
        }
    } error:NULL];
}

// `directory` is the one callers know the state directory by, so paths compare equal to the ones they wrote (the
// database's own name for it may be the same place spelled through /private).
static SZFriendsThumbnailRecord *_Nullable SZFriendsThumbnailRow(SZFriendsStoreDB *db, NSString *transferID,
                                                                 NSString *directory) {
    __block SZFriendsThumbnailRecord *record = nil;
    [db run:@"SELECT transfer_id, source, width, height, png_name, qoi, delivered FROM transfer_thumbnails "
            @"WHERE transfer_id = ?"
        binds:@[ transferID ]
          row:^(sqlite3_stmt *s) {
              NSString *name = SZFriendsColumnText(s, 4);
              if (!SZFriendsIsThumbnailName(name)) return;
              record = [[SZFriendsThumbnailRecord alloc] init];
              record.transferID = SZFriendsColumnText(s, 0) ?: transferID;
              record.source = (SZFriendsThumbnailSource)SZFriendsColumnInt(s, 1);
              record.width = (NSUInteger)SZFriendsColumnInt(s, 2);
              record.height = (NSUInteger)SZFriendsColumnInt(s, 3);
              record.path = [directory stringByAppendingPathComponent:name];
              record.qoi = SZFriendsColumnBlob(s, 5);
              record.delivered = SZFriendsColumnInt(s, 6) != 0;
          }
        error:NULL];
    return record;
}

static NSError *SZFriendsThumbnailError(SZFriendsStoreError code, NSString *why) {
    return SZFriendsStoreMakeError(code, why);
}

@implementation SZFriendsTransfers (Thumbnails)

- (SZFriendsStore *)thumbnailStore {
    return self.store;
}

- (NSString *)thumbnailDirectory {
    return [self.thumbnailStore.stateDirectory stringByAppendingPathComponent:SZFriendsThumbnailDirectoryName];
}

// The file name inside our directory for a path a caller wrote, or nil for anything else.
- (nullable NSString *)thumbnailNameForPath:(nullable NSString *)path {
    if (path == nil) return nil;
    NSString *directory = self.thumbnailDirectory.stringByStandardizingPath;
    NSString *name = path.lastPathComponent;
    BOOL inside = [path.stringByDeletingLastPathComponent.stringByStandardizingPath isEqualToString:directory];
    return inside && SZFriendsIsThumbnailName(name) ? name : nil;
}

- (nullable SZFriendsThumbnailRecord *)thumbnailForTransfer:(NSString *)transferID {
    NSString *directory = self.thumbnailDirectory;
    __block SZFriendsThumbnailRecord *record = nil;
    [self.thumbnailStore performRead:^(SZFriendsStoreDB *_Nullable db) {
        if (db) record = SZFriendsThumbnailRow(db, transferID, directory);
    }];
    return record;
}

- (BOOL)checkName:(nullable NSString *)name width:(NSUInteger)width height:(NSUInteger)height error:(NSError **)error {
    if (name == nil || width == 0 || height == 0 || width > SZFriendsStoreThumbnailMaxSide ||
        height > SZFriendsStoreThumbnailMaxSide) {
        return SZFriendsFail(error, SZFriendsThumbnailError(SZFriendsStoreErrorInvalid, @"bad thumbnail"));
    }
    return YES;
}

- (BOOL)setOutgoingThumbnailForTransfer:(NSString *)transferID
                                   path:(NSString *)path
                                  width:(NSUInteger)width
                                 height:(NSUInteger)height
                                    qoi:(NSData *)qoi
                                  error:(NSError **)error {
    NSString *name = [self thumbnailNameForPath:path];
    if (![self checkName:name width:width height:height error:error]) return NO;
    NSString *directory = self.thumbnailDirectory;
    return [self.thumbnailStore performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        SZFriendsTransferRecord *transfer = SZFriendsTransferRowLoad(db, transferID);
        BOOL pending = transfer.outgoing && (transfer.state == SZFriendsTransferStateQueued ||
                                             transfer.state == SZFriendsTransferStateOffered);
        if (!pending || SZFriendsThumbnailRow(db, transferID, directory) != nil) {
            return SZFriendsFail(inner,
                                 SZFriendsThumbnailError(SZFriendsStoreErrorStale, @"no longer a pending offer"));
        }
        return [db run:@"INSERT INTO transfer_thumbnails (transfer_id, source, width, height, png_name, qoi, "
                       @"delivered, created_at) VALUES (?, ?, ?, ?, ?, ?, 0, ?)"
                 binds:@[ transferID, @(SZFriendsThumbnailSourceLocal), @(width), @(height), name, qoi, NSDate.date ]
                   row:nil
                 error:inner];
    } error:error];
}

- (NSArray<SZFriendsThumbnailRecord *> *)thumbnailsToSendInConversation:(NSString *)conversationID {
    NSString *directory = self.thumbnailDirectory;
    __block NSMutableArray<SZFriendsThumbnailRecord *> *records = [NSMutableArray array];
    [self.thumbnailStore performRead:^(SZFriendsStoreDB *_Nullable db) {
        NSMutableArray<NSString *> *ids = [NSMutableArray array];
        [db run:@"SELECT t.transfer_id FROM transfer_thumbnails t JOIN transfers r ON r.transfer_id = t.transfer_id "
                @"WHERE r.conversation_id = ? AND r.outgoing = 1 AND r.state IN (?, ?) AND t.delivered = 0 AND "
                @"t.qoi IS NOT NULL ORDER BY r.created_at, r.transfer_id"
            binds:@[ conversationID, @(SZFriendsTransferStateQueued), @(SZFriendsTransferStateOffered) ]
              row:^(sqlite3_stmt *s) { [ids addObject:SZFriendsColumnText(s, 0) ?: @""]; }
            error:NULL];
        for (NSString *transferID in ids) {
            SZFriendsThumbnailRecord *record = SZFriendsThumbnailRow(db, transferID, directory);
            if (record) [records addObject:record];
        }
    }];
    return records;
}

- (BOOL)markThumbnailDelivered:(NSString *)transferID fromConversation:(NSString *)conversationID
                         error:(NSError **)error {
    return [self.thumbnailStore performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        SZFriendsTransferRecord *transfer = SZFriendsTransferRowLoad(db, transferID);
        if (transfer == nil || !transfer.outgoing || ![transfer.conversationID isEqualToString:conversationID]) {
            return SZFriendsFail(inner, SZFriendsThumbnailError(SZFriendsStoreErrorInvalid, @"not our offer to them"));
        }
        // The QOI was kept only to be sent; the PNG stays for our own history.
        return [db run:@"UPDATE transfer_thumbnails SET delivered = 1, qoi = NULL WHERE transfer_id = ?"
                 binds:@[ transferID ]
                   row:nil
                 error:inner];
    } error:error];
}

static BOOL SZFriendsMayRecordReceived(SZFriendsStoreDB *db, NSString *transferID, NSString *conversationID) {
    SZFriendsTransferRecord *transfer = SZFriendsTransferRowLoad(db, transferID);
    BOOL waiting = transfer.state == SZFriendsTransferStateWaitingForYou ||
                   transfer.state == SZFriendsTransferStateReceiving;
    NSNumber *existing = [db scalar:@"SELECT count(*) FROM transfer_thumbnails WHERE transfer_id = ?"
                              binds:@[ transferID ]
                              error:NULL];
    return transfer != nil && !transfer.outgoing && waiting && conversationID.length > 0 &&
           [transfer.conversationID isEqualToString:conversationID] && existing != nil && existing.integerValue == 0;
}

- (BOOL)mayRecordReceivedThumbnailForTransfer:(NSString *)transferID fromConversation:(NSString *)conversationID {
    __block BOOL allowed = NO;
    [self.thumbnailStore performRead:^(SZFriendsStoreDB *_Nullable db) {
        allowed = db != nil && SZFriendsMayRecordReceived(db, transferID, conversationID);
    }];
    return allowed;
}

- (BOOL)recordReceivedThumbnailForTransfer:(NSString *)transferID
                          fromConversation:(NSString *)conversationID
                                      path:(NSString *)path
                                     width:(NSUInteger)width
                                    height:(NSUInteger)height
                                     error:(NSError **)error {
    NSString *name = [self thumbnailNameForPath:path];
    if (![self checkName:name width:width height:height error:error]) return NO;
    return [self.thumbnailStore performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        if (!SZFriendsMayRecordReceived(db, transferID, conversationID)) {
            return SZFriendsFail(inner, SZFriendsThumbnailError(SZFriendsStoreErrorStale, @"not a waiting offer"));
        }
        return [db run:@"INSERT INTO transfer_thumbnails (transfer_id, source, width, height, png_name, qoi, "
                       @"delivered, created_at) VALUES (?, ?, ?, ?, ?, NULL, 0, ?)"
                 binds:@[ transferID, @(SZFriendsThumbnailSourceSender), @(width), @(height), name, NSDate.date ]
                   row:nil
                 error:inner];
    } error:error];
}

- (BOOL)replaceThumbnailOfReceivedTransfer:(NSString *)transferID
                                 localPath:(nullable NSString *)path
                                     width:(NSUInteger)width
                                    height:(NSUInteger)height
                                     error:(NSError **)error {
    NSString *name = [self thumbnailNameForPath:path];
    if (path != nil && ![self checkName:name width:width height:height error:error]) return NO;
    __block NSString *replaced = nil;
    BOOL ok = [self.thumbnailStore performWrite:^BOOL(SZFriendsStoreDB *db, NSError **inner) {
        SZFriendsTransferRecord *transfer = SZFriendsTransferRowLoad(db, transferID);
        if (transfer == nil || transfer.outgoing || transfer.state != SZFriendsTransferStateReceived) {
            return SZFriendsFail(inner, SZFriendsThumbnailError(SZFriendsStoreErrorStale, @"not a received file"));
        }
        replaced = [db scalar:@"SELECT png_name FROM transfer_thumbnails WHERE transfer_id = ?" binds:@[ transferID ]
                        error:NULL];
        if (![db run:@"DELETE FROM transfer_thumbnails WHERE transfer_id = ?" binds:@[ transferID ] row:nil
               error:inner]) {
            return NO;
        }
        if (name == nil) return YES;
        return [db run:@"INSERT INTO transfer_thumbnails (transfer_id, source, width, height, png_name, qoi, "
                       @"delivered, created_at) VALUES (?, ?, ?, ?, ?, NULL, 0, ?)"
                 binds:@[ transferID, @(SZFriendsThumbnailSourceLocal), @(width), @(height), name, NSDate.date ]
                   row:nil
                 error:inner];
    } error:error];
    if (ok && [replaced isKindOfClass:NSString.class] && ![replaced isEqual:name]) {
        SZFriendsUnlinkThumbnail(self.thumbnailDirectory, replaced);
    }
    return ok;
}

- (void)removeUnreferencedThumbnailFiles {
    NSString *directory = self.thumbnailDirectory;
    NSMutableSet<NSString *> *referenced = [NSMutableSet set];
    __block BOOL read = NO;
    [self.thumbnailStore performOnWriter:^(SZFriendsStoreDB *_Nullable db) {
        read = [db run:@"SELECT png_name FROM transfer_thumbnails" binds:nil
                   row:^(sqlite3_stmt *s) { [referenced addObject:SZFriendsColumnText(s, 0) ?: @""]; }
                 error:NULL];
        if (!read) return;
        // On the writer queue, so no file written and recorded meanwhile can be taken for a leftover.
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:NULL]) {
            if (![referenced containsObject:name]) SZFriendsUnlinkThumbnail(directory, name);
        }
    }];
}

@end

NS_ASSUME_NONNULL_END
