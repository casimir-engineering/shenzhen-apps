// Private to the store area: the SQLite connection wrapper, the queues the store, outbox and transfers share, the
// migration list, the data functions behind SZFriendsStore's methods, and the hooks the store's own tests use.
// Nothing outside friends/service/store/ includes this header; other areas use the three public headers.

#import <Foundation/Foundation.h>
#import <sqlite3.h>

#import "service/store/SZFriendsOutbox.h"
#import "service/store/SZFriendsStore.h"
#import "service/store/SZFriendsTransfers.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Connection

// One SQLite connection. Not thread-safe by design: each connection is used only on its owner's serial queue, which
// is what makes the store a single writer (ADR 0003).
@interface SZFriendsStoreDB : NSObject
// Opens with the ADR 0003 pragmas. The write connection also gets WAL, synchronous=FULL and F_FULLFSYNC on every
// commit and checkpoint; the read connection is query_only.
+ (nullable instancetype)openAtPath:(NSString *)path readOnly:(BOOL)readOnly error:(NSError **)error;
@property(nonatomic, readonly, nullable) sqlite3 *handle;
- (void)close;
// Several statements, no binds (DDL, PRAGMA).
- (BOOL)exec:(NSString *)sql error:(NSError **)error;
// One statement with positional binds (NSNull, NSString, NSData, NSNumber, NSDate); `row` sees each result row.
- (BOOL)run:(NSString *)sql
      binds:(nullable NSArray *)binds
        row:(nullable void (^)(sqlite3_stmt *statement))row
      error:(NSError **)error;
// First column of the first row as an object (NSNumber, NSString, NSData), or nil.
- (nullable id)scalar:(NSString *)sql binds:(nullable NSArray *)binds error:(NSError **)error;
// BEGIN IMMEDIATE ... COMMIT, or a SAVEPOINT when already inside a transaction, so data functions compose. The body
// returning NO, or a failed COMMIT, rolls everything back.
- (BOOL)transaction:(BOOL (^)(NSError **error))body error:(NSError **)error;
@property(nonatomic, readonly) NSInteger changes;
@end

// NSNull for nil, so optional values can sit in a binds array.
static inline id SZFriendsSQL(id _Nullable value) { return value ?: (id)[NSNull null]; }

NSString *_Nullable SZFriendsColumnText(sqlite3_stmt *statement, int column);
NSData *_Nullable SZFriendsColumnBlob(sqlite3_stmt *statement, int column);
NSDate *_Nullable SZFriendsColumnDate(sqlite3_stmt *statement, int column);
int64_t SZFriendsColumnInt(sqlite3_stmt *statement, int column);
double SZFriendsColumnDouble(sqlite3_stmt *statement, int column);

NSError *SZFriendsStoreMakeError(SZFriendsStoreError code, NSString *description);
// Maps SQLITE_FULL to DiskFull and constraint failures to Constraint; everything else is Database.
NSError *SZFriendsStoreSQLiteError(sqlite3 *_Nullable db, int resultCode, NSString *context);
// Stores `error` through `out` when the caller asked for it; returns NO so callers can `return SZFriendsFail(...)`.
BOOL SZFriendsFail(NSError *_Nullable *_Nullable out, NSError *error);

// [A-Za-z0-9_-], 1 to 64 bytes: the opaque id rule of PROTOCOL.md § Framing, applied to every id the store keeps.
BOOL SZFriendsStoreIsValidIdentifier(NSString *_Nullable identifier);

#pragma mark - Migrations

@interface SZFriendsStoreMigration : NSObject
+ (instancetype)migrationToVersion:(NSInteger)version
                  minReaderVersion:(NSInteger)minReaderVersion
                             apply:(BOOL (^)(SZFriendsStoreDB *db, NSError **error))apply;
@property(nonatomic, readonly) NSInteger version;
// The oldest schema version that can still read the store after this migration. 0 leaves it unchanged: additive
// changes keep it, so an older helper (an older Shenzhen Files) still opens the store.
@property(nonatomic, readonly) NSInteger minReaderVersion;
@property(nonatomic, readonly) BOOL (^apply)(SZFriendsStoreDB *db, NSError **error);
@end

// Every migration ever shipped, oldest first. A shipped migration is never edited; changes append a new one.
NSArray<SZFriendsStoreMigration *> *SZFriendsStoreShippedMigrations(void);

// user_version and meta.min_reader_version as found, before anything is written.
BOOL SZFriendsStoreReadVersions(SZFriendsStoreDB *db, NSInteger *userVersion, NSInteger *minReaderVersion,
                                NSError **error);
// Backs up with VACUUM INTO (when the file already holds a schema), then runs each pending migration in its own
// transaction together with its version bump. Returns the resulting user_version, or -1 with an error that leaves
// the database at its last committed version and the backup intact.
NSInteger SZFriendsStoreMigrate(SZFriendsStoreDB *db, NSString *databasePath,
                                NSArray<SZFriendsStoreMigration *> *migrations, NSError **error);

#pragma mark - Store internals

@interface SZFriendsStoreOptions : NSObject
@property(nonatomic, copy, nullable) NSArray<SZFriendsStoreMigration *> *migrations; // nil: the shipped list
@property(nonatomic) BOOL disableTrigram; // behave as on a SQLite without the trigram tokenizer (ADR 0003 probe)
@end

@interface SZFriendsStore ()
+ (nullable instancetype)storeInDirectory:(NSString *)stateDirectory
                                  options:(nullable SZFriendsStoreOptions *)options
                                    error:(NSError **)error;
@property(nonatomic, readonly) NSString *stateDirectory;
@property(nonatomic, readonly) NSString *databasePath;
@property(nonatomic, readonly) BOOL searchUsesIndex; // NO when the trigram probe failed: substring scan only
// The write connection on the store queue, inside one transaction (a savepoint when nested). Outbox and transfers
// use it so an entry, its history item and its transfer row commit together.
- (BOOL)performWrite:(BOOL (^)(SZFriendsStoreDB *db, NSError **error))body error:(NSError **)error;
// The write connection on the store queue without a transaction (VACUUM, checkpoints, file work in order).
- (void)performOnWriter:(void (^)(SZFriendsStoreDB *_Nullable db))body;
// The read-only connection on its own queue: snapshots and search never wait behind a write.
- (void)performRead:(void (^)(SZFriendsStoreDB *_Nullable db))body;
@end

// Data functions behind SZFriendsStore's methods. Each takes the connection it must use, so a caller inside a
// write transaction reads its own uncommitted rows.
NSArray<SZFriendsPersonRecord *> *SZFriendsStorePeople(SZFriendsStoreDB *db, NSString *_Nullable whereClause,
                                                       NSArray *_Nullable binds);
BOOL SZFriendsStoreSavePerson(SZFriendsStoreDB *db, SZFriendsPersonRecord *person, NSError **error);
NSArray<SZFriendsIDRequestRecord *> *SZFriendsStoreIDRequests(SZFriendsStoreDB *db, NSString *whereClause,
                                                              NSArray *binds);
BOOL SZFriendsStoreSaveIDRequest(SZFriendsStoreDB *db, SZFriendsIDRequestRecord *request, NSDate *now,
                                 NSError **error);
// The reviewed static-key change behind -notePresentedStaticKey:... and -acceptPendingStaticKeyForConversation:.
BOOL SZFriendsStoreNotePresentedStaticKey(SZFriendsStoreDB *db, NSString *conversationID, NSData *staticKey,
                                          NSData *certificate, NSError **error);
BOOL SZFriendsStoreAcceptPendingStaticKey(SZFriendsStoreDB *db, NSString *conversationID, NSError **error);

// Inserts unless (conversation, item id) exists; `inserted` says which. Updates the person's unread count and latest
// interaction in the same transaction.
BOOL SZFriendsStoreInsertItem(SZFriendsStoreDB *db, SZFriendsItemRecord *item, BOOL *_Nullable inserted,
                              NSError **error);
NSArray<SZFriendsItemRecord *> *SZFriendsStoreItems(SZFriendsStoreDB *db, NSString *conversationID,
                                                    NSString *_Nullable beforeItemID, NSUInteger limit,
                                                    BOOL *_Nullable hasEarlier);
NSArray<SZFriendsItemRecord *> *_Nullable SZFriendsStoreItemsAround(SZFriendsStoreDB *db, NSString *conversationID,
                                                                   NSString *itemID, NSUInteger before,
                                                                   NSUInteger after);
// Deletes history rows (messages, transfers, the outbox entries delivering them) for one conversation or all, and
// appends the private files those transfers held (outgoing snapshots, partial downloads) to `files`.
BOOL SZFriendsStoreDeleteHistoryRows(SZFriendsStoreDB *db, NSString *_Nullable conversationID,
                                     NSMutableArray<NSString *> *files, NSError **error);

// Foundation's case, diacritic and width folding with no locale, so stored and query text fold identically on
// every Mac whatever its language.
NSString *SZFriendsSearchFold(NSString *text);
// What a history row's `folded` column holds: a message folded as a reader sees it, each mention as its "@Name" label
// and never the Friends ID and key in its link (ADR 0007); a file's name folded as it is.
NSString *SZFriendsSearchFoldItem(NSString *body, SZFriendsItemKind kind);
// Creates the FTS table when the trigram probe passes and keeps it in step with temporary triggers on this
// connection; without trigram, marks the index stale whenever messages change so a later helper rebuilds it.
BOOL SZFriendsStorePrepareSearch(SZFriendsStoreDB *db, BOOL allowTrigram, BOOL *usesIndex, NSError **error);
// Rebuilds the index from the messages table (after deletes, so removed text leaves the index's segments too).
BOOL SZFriendsStoreRebuildSearch(SZFriendsStoreDB *db, NSError **error);
NSArray<SZFriendsSearchHit *> *SZFriendsStoreSearch(SZFriendsStoreDB *db, NSString *query,
                                                    NSArray<NSString *> *_Nullable conversationIDs,
                                                    NSUInteger limit, BOOL useIndex);

@interface SZFriendsSearchHit ()
- (instancetype)initWithConversationID:(NSString *)conversationID
                                itemID:(NSString *)itemID
                                  kind:(SZFriendsItemKind)kind
                                sentAt:(NSDate *)sentAt
                             direction:(SZFriendsDirection)direction
                                  text:(NSString *)text
                           matchRanges:(NSArray<NSValue *> *)matchRanges;
@end

// Copies every read-write property through KVC, so record classes stay one declaration each.
id SZFriendsCopyRecord(id record);

#pragma mark - Transfers internals

// Transfer rows, shared by the transfer manager and the outbox (an offer's entry moves its transfer).
SZFriendsTransferRecord *_Nullable SZFriendsTransferRowLoad(SZFriendsStoreDB *db, NSString *transferID);
NSArray<SZFriendsTransferRecord *> *SZFriendsTransferRows(SZFriendsStoreDB *db, NSString *whereClause,
                                                          NSArray *binds);
BOOL SZFriendsTransferRowInsert(SZFriendsStoreDB *db, SZFriendsTransferRecord *record, NSString *_Nullable partialPath,
                                NSError **error);
// Applies one state-machine event. Returns NO with Stale when the event does not apply in the current state, so a
// late or replayed answer changes nothing (ADR 0001: an ACCEPT for an offer no longer offered is ignored).
BOOL SZFriendsTransferRowApplyEvent(SZFriendsStoreDB *db, NSString *transferID, SZFriendsTransferEvent event,
                                    NSString *_Nullable failureReason, NSError **error);
// Column = value updates for the row's bookkeeping fields (paths, counts, flags), with updated_at.
BOOL SZFriendsTransferRowUpdate(SZFriendsStoreDB *db, NSString *transferID, NSDictionary<NSString *, id> *values,
                                NSError **error);
NSString *_Nullable SZFriendsTransferRowPartialPath(SZFriendsStoreDB *db, NSString *transferID);

// The receiving side's in-memory state (open staging files, running digests, unflushed byte counts). Owned by
// SZFriendsTransfers and used only on the store queue. Every chunk and DONE names the sending conversation, which
// must own the transfer: an empty one owns nothing.
@interface SZFriendsTransferReceiver : NSObject
- (instancetype)initWithStore:(SZFriendsStore *)store stateDirectory:(NSString *)stateDirectory;
@property(nonatomic, copy) NSDate * (^clock)(void);
- (BOOL)appendChunk:(NSData *)bytes atOffset:(uint64_t)offset toTransfer:(NSString *)transferID
   fromConversation:(NSString *)conversationID error:(NSError **)error;
- (BOOL)finishTransfer:(NSString *)transferID finalDigest:(NSData *)finalDigest
      fromConversation:(NSString *)conversationID error:(NSError **)error;
- (BOOL)flushWithError:(NSError **)error;
// Forgets the open file of a transfer that was cancelled, declined or failed elsewhere.
- (void)forgetTransfer:(NSString *)transferID;
// ADR 0003 § Crash recovery for files: finish publishing, truncate staging files to their durable count, delete
// files no row references.
- (BOOL)recoverWithError:(NSError **)error;
// Shared with the block downloads (SZFriendsBlockDownloads.m), on the store queue.
@property(nonatomic, readonly) SZFriendsStore *store;
@property(nonatomic, readonly) NSString *partialDirectory;
@property(nonatomic, readonly) NSMutableDictionary<NSString *, id> *blockDownloads; // transfer id -> download
- (BOOL)onWriter:(BOOL (^)(SZFriendsStoreDB *db, NSError **error))body error:(NSError **)error;
- (BOOL)publish:(SZFriendsTransferRecord *)record from:(NSString *)partial db:(SZFriendsStoreDB *)db
          error:(NSError **)error;
- (BOOL)failMismatched:(NSString *)transferID partial:(NSString *)partial db:(SZFriendsStoreDB *)db
                 error:(NSError **)error;
@end

@interface SZFriendsTransfers ()
@property(nonatomic, readonly) SZFriendsTransferReceiver *receiver; // tests drive its clock
@property(nonatomic, readonly) SZFriendsStore *store;              // for the Thumbnails category
@property(nonatomic, readonly) NSString *partialDirectory;         // received/.partial
@end

// SZFriendsTransfers+Accepting.m.
@interface SZFriendsTransfers (Accepting)
- (BOOL)acceptIn:(SZFriendsStoreDB *)db
        transfer:(NSString *)transferID
   automatically:(BOOL)automatically
       freeBytes:(uint64_t)freeBytes
           error:(NSError **)error;
- (nullable NSString *)heldCopyIn:(SZFriendsStoreDB *)db record:(SZFriendsTransferRecord *)record;
- (BOOL)fillFromHeldCopyIn:(SZFriendsStoreDB *)db
                    record:(SZFriendsTransferRecord *)record
                   partial:(NSString *)partial
                 freeBytes:(uint64_t)freeBytes;
@end

// File previews (SZFriendsTransferThumbnails.m). After a transfer's state changes inside a write: the picture of an
// offer that ended without its file (declined, cancelled, failed before acceptance) goes, row and file.
void SZFriendsThumbnailRowsAfterTransferEvent(SZFriendsStoreDB *db, NSString *transferID,
                                              SZFriendsTransferState previous, SZFriendsTransferState next);
// Appends the PNG paths of the transfers `whereClause` selects (as in "FROM transfers <whereClause>") to `files`.
void SZFriendsThumbnailFilesOfTransfers(SZFriendsStoreDB *db, NSString *whereClause, NSArray *binds,
                                        NSMutableArray<NSString *> *files);

// Sets com.apple.quarantine on a received file, as a browser download would.
BOOL SZFriendsSetQuarantine(NSString *path, NSError **error);
// BLAKE2b-256 of a file's first `length` bytes (the whole file when length is UINT64_MAX).
NSData *_Nullable SZFriendsFileDigest(NSString *path, uint64_t length, NSError **error);
// Space available for important use on the volume holding `path` (what Finder would free up included).
uint64_t SZFriendsVolumeFreeBytes(NSString *path);
// A private directory (0700) that is a real directory, not a symlink planted to redirect files elsewhere.
BOOL SZFriendsEnsurePrivateDirectory(NSString *path, NSError **error);
// Creates the staging file for an accepted download, <received>/.partial/<fresh identifier>.part, 0600, with
// O_EXCL and O_NOFOLLOW, quarantined, and returns its path (kept in partial_path). The name never comes from the
// sender: their transfer id once named it, and two ids differing only in case shared one file on APFS (security
// review, staging file names). Nil with DiskFull or Database when it cannot be created.
NSString *_Nullable SZFriendsCreateStagingFile(NSString *partialDirectory, NSError **error);
// Copies `source` to `destination` as an immutable snapshot (APFS clone, or a copy when space allows), then reads
// the snapshot back for its size, BLAKE2b-256 and, when asked, SHA-256. Errors carry the store codes the
// stage call reports (FileMissing, FolderNotSupported, DiskFull).
BOOL SZFriendsSnapshotFile(NSString *source, NSString *destination, uint64_t freeBytes, uint64_t *size,
                           NSData *_Nullable *_Nonnull digest, NSData *_Nullable *_Nullable sha256,
                           NSError **error);
// The uniform type identifier for a file name's extension, or nil.
NSString *_Nullable SZFriendsUniformTypeForName(NSString *name);
// Unlinks files the store itself placed (outgoing snapshots, partial downloads, previews). A path read from a row is
// never trusted to point elsewhere, and published files in received/ are never touched.
void SZFriendsRemovePrivateFiles(NSString *stateDirectory, NSArray<NSString *> *paths);

#pragma mark - Test hooks

// Called at named points where a crash must be survivable ("transfer.after_rename"). Only the store's tests set it;
// production leaves it NULL, so each point costs one load and branch.
extern void (*_Nullable SZFriendsStoreTestHook)(const char *point);
// Forces the copy path of SZFriendsSnapshotFile, where free space is checked; a clone needs none, so the low-disk
// refusal is unreachable on APFS otherwise. Tests only.
extern BOOL SZFriendsSnapshotDisableClone;
// Publishes received files as if the destination were on another volume (the copy through a hidden part file), which
// a test cannot otherwise reach without mounting a volume. Tests only.
extern BOOL SZFriendsPublishAcrossVolumes;
static inline void SZFriendsStoreTestPoint(const char *point) {
    if (SZFriendsStoreTestHook) SZFriendsStoreTestHook(point);
}

NS_ASSUME_NONNULL_END
