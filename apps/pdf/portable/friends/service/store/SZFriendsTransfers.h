// Shenzhen Friends transfers: offers, staging, received files and automatic acceptance.
//
// Helper-only; transfer records persist in friends.sqlite beside SZFriendsStore. Rules from the brief
// (§ Transfers), each enforced here rather than in a caller:
//   - On Send, each file is bound to an immutable snapshot; a newer source is never substituted.
//   - No file bytes move before acceptance, unless the recipient turned on automatic acceptance for this
//     friend; automatic acceptance gets every check and limit a manual one gets and falls back to asking when
//     disk space is short. Received files never open by themselves.
//   - Accepted files stream to a private temporary file, named by this Mac and never by the sender, and are
//     published into the folder received files go to (Downloads unless the person chose another) only after the
//     final digest matches the offer, both as streamed and as read back from disk. Names are sanitized; no
//     traversal, symlink escape or overwrite; the quarantine attribute is set.
//   - Everything a peer names (an offer id, a chunk, DONE, an answer) is checked against the conversation it came
//     from, which must own the transfer; there is no unchecked form.
//   - Resume restarts from the recipient's verified byte count, bound to offer id, sender, recipient and hash;
//     the same mechanism moves a transfer between routes.
//   - Cancel stops remaining work and removes incomplete files; it cannot retract what already arrived.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class SZFriendsStore;

// PROTOCOL.md transfer.state uses the same names in lowercase with underscores.
typedef NS_ENUM(NSInteger, SZFriendsTransferState) {
    SZFriendsTransferStateQueued = 0,        // outgoing; the friend is not reachable yet
    SZFriendsTransferStateOffered = 1,       // outgoing; offer delivered, waiting for their answer
    SZFriendsTransferStateWaitingForYou = 2, // incoming; offer received, waiting for this person's answer
    SZFriendsTransferStateSending = 3,
    SZFriendsTransferStateReceiving = 4,
    SZFriendsTransferStateDelivered = 5,     // outgoing; their Mac verified the digest
    SZFriendsTransferStateReceived = 6,      // incoming; verified and published (receivedPath)
    SZFriendsTransferStateDeclined = 7,
    SZFriendsTransferStateCancelled = 8,
    SZFriendsTransferStateFailed = 9,
};

typedef NS_ENUM(NSInteger, SZFriendsTransferEvent) {
    SZFriendsTransferEventOfferDelivered = 0, // outgoing: the recipient's Mac acknowledged the OFFER
    SZFriendsTransferEventAccepted = 1,       // they accepted ours, or this person (or automatic acceptance) theirs
    SZFriendsTransferEventDeclined = 2,
    SZFriendsTransferEventCancelled = 3,      // either side withdrew an unanswered offer or stopped a transfer
    SZFriendsTransferEventVerified = 4,       // the whole-file digest matched: theirs (DONE acknowledged) or ours
    SZFriendsTransferEventFailed = 5,         // digest mismatch, source gone, not delivered in 30 days
    SZFriendsTransferEventRetry = 6,          // Try again: outgoing offers again, incoming resumes receiving
};

// Pure transition function, tested exhaustively. Returns `state` unchanged when the event does not apply: an
// acceptance of an offer no longer offered (ADR 0001), Cancel after the file arrived (it cannot be retracted).
SZFriendsTransferState SZFriendsTransferNextState(BOOL outgoing, SZFriendsTransferState state,
                                                  SZFriendsTransferEvent event);

// The exact revision a host bound an attachment to (PROTOCOL.md file.revision). Optional: a plain Finder file
// has none, and the helper snapshots whatever bytes the path holds when Send is pressed.
@interface SZFriendsRevision : NSObject <NSCopying>
@property(nonatomic, copy) NSString *source;     // host app id that issued it
@property(nonatomic, copy) NSString *documentID;
@property(nonatomic, copy) NSString *revisionID;
@property(nonatomic, copy, nullable) NSString *label; // "version saved today, 14:02"
@property(nonatomic, copy, nullable) NSData *sha256;  // when present, the snapshot must match or Send fails
@property(nonatomic) uint64_t size;
@end

@interface SZFriendsTransferRecord : NSObject <NSCopying>
@property(nonatomic, copy) NSString *transferID;     // = offer id, random 128-bit hex
@property(nonatomic, copy) NSString *conversationID;
@property(nonatomic) BOOL outgoing;
@property(nonatomic) SZFriendsTransferState state;
@property(nonatomic, copy) NSString *fileName;       // sanitized display name
@property(nonatomic, copy, nullable) NSString *uniformType;
@property(nonatomic) uint64_t size;
// BLAKE2b-256 of the whole file, carried in OFFER and checked after DONE (ADR 0001 § Files). Distinct from the
// host's optional revision SHA-256, which only proves the snapshot is the revision the person picked.
@property(nonatomic, copy) NSData *contentDigest;
@property(nonatomic) uint64_t verifiedBytes;          // resume point: bytes written, fsynced and committed
@property(nonatomic) BOOL acceptedAutomatically;
// Automatic acceptance was on but free space was short, so this offer asks instead ("Not enough space to
// download this automatically").
@property(nonatomic) BOOL askedBecauseDiskLow;
@property(nonatomic, copy, nullable) NSString *stagedPath;   // outgoing snapshot inside the state directory
@property(nonatomic, copy, nullable) NSString *receivedPath; // published file, once received
@property(nonatomic, copy, nullable) SZFriendsRevision *revision;
@property(nonatomic) double measuredBytesPerSecond;   // for "about 6 min" estimates; 0 when unknown
@property(nonatomic, copy, nullable) NSString *failureReason; // while Failed: SZFriendsTransferFailure... or an
                                                              // SZFriendsOutboxFailure... key
@property(nonatomic, copy, nullable) NSDate *createdAt;
// Outgoing: the file the person chose, and its modification time (nanoseconds since 1970) when it was snapshotted. While
// it is unchanged this computer still holds the file's bytes after the snapshot is gone (ADR 0016). Never synced.
@property(nonatomic, copy, nullable) NSString *sourcePath;
@property(nonatomic) int64_t sourceModifiedNs;
@end

// A file's modification time in nanoseconds since 1970, or 0 when it cannot be read.
int64_t SZFriendsFileModifiedNs(NSString *path);

extern NSString *const SZFriendsTransferFailureDigestMismatch; // "digest_mismatch": the bytes did not match
extern NSString *const SZFriendsTransferFailureSourceMissing;  // "source_missing": the snapshot is gone

#pragma mark - Pure checks (unit-tested without a store)

// Limits an offer must meet before anything is allocated for it (brief § Transfers: oversized metadata, floods).
extern const uint64_t SZFriendsTransferMaxFileSize;           // 2^53 - 1: PROTOCOL.md sizes are JSON integers
extern const NSUInteger SZFriendsTransferMaxNameBytes;        // 1,024 bytes of UTF-8 as offered
extern const NSUInteger SZFriendsTransferMaxPendingOffers;    // 200 unanswered offers per friend
extern const uint64_t SZFriendsTransferDefaultReserveBytes;   // 1 GiB kept free by automatic acceptance

// A safe file name for received/: strips path separators, NULs, control and bidi-override characters, leading
// dots and trailing spaces; keeps the extension; caps the length; never empty ("Untitled").
NSString *SZFriendsSanitizedFileName(NSString *proposedName);

// The path inside `directory` for `name` that overwrites nothing ("Site photos (2).pdf"). Never leaves directory.
NSString *SZFriendsUniqueDestination(NSString *directory, NSString *name);

#pragma mark - Where received files go (PROTOCOL.md § Views, settings and received)

// The person's choice, one absolute folder path in this file in the state directory; never synced.
extern NSString *const SZFriendsReceivedFolderFileName; // "received-folder"
extern NSString *const SZFriendsDownloadsDirEnvironment; // "SZFRIENDS_DOWNLOADS_DIR", for tests

// Downloads: $SZFRIENDS_DOWNLOADS_DIR when set; <state>/Downloads when the state directory is not the default one (a
// test or probe helper, so it never reaches the person's real Downloads); else the account's Downloads folder.
NSString *SZFriendsDefaultReceivedFolder(NSString *stateDirectory);
// The folder the person chose, or nil for Downloads.
NSString *_Nullable SZFriendsChosenReceivedFolder(NSString *stateDirectory);
// The chosen folder, else Downloads: what Settings shows and Show in Finder opens.
NSString *SZFriendsReceivedFolder(NSString *stateDirectory);

typedef NS_ENUM(NSInteger, SZFriendsReceivedFolderResult) {
    SZFriendsReceivedFolderOK = 0,
    SZFriendsReceivedFolderInvalidPath = 1, // not an absolute path (invalid_field)
    SZFriendsReceivedFolderMissing = 2,     // does not exist or cannot be read (file_missing)
    SZFriendsReceivedFolderNotAllowed = 3,  // not a folder, not writable, or inside the state directory (not_allowed)
    SZFriendsReceivedFolderFailed = 4,      // the choice could not be saved (internal)
};
// set_received_folder: stores the folder's real path atomically, or clears the choice when it is Downloads.
SZFriendsReceivedFolderResult SZFriendsSetReceivedFolder(NSString *stateDirectory, NSString *path,
                                                         NSError **error);

// When the folder a file was meant for could not take it, where it went instead: one word in this file in the state
// directory, beside received-folder ("downloads" or "kept"), until a file is saved where it was meant to be or the
// folder is changed, so Settings can say so (PROTOCOL.md § Views, settings: data.received.note). Survives a restart.
extern NSString *const SZFriendsReceivedFallbackFileName; // "received-fallback"
typedef NS_ENUM(NSInteger, SZFriendsReceivedFallback) {
    SZFriendsReceivedFallbackNone = 0,
    SZFriendsReceivedFallbackDownloads = 1, // the chosen folder could not take it; Downloads did
    SZFriendsReceivedFallbackKept = 2,      // nor could Downloads; it is in <state>/received/
};
SZFriendsReceivedFallback SZFriendsLastReceivedFallback(NSString *stateDirectory);

// Where a published file sits, for its "Saved to …" (PROTOCOL.md § transfer status_label): the default Downloads,
// another folder (named by its last path component), or <state>/received/ (older files, the last resort).
typedef NS_ENUM(NSInteger, SZFriendsSavedPlace) {
    SZFriendsSavedPlaceKept = 0,
    SZFriendsSavedPlaceDownloads = 1,
    SZFriendsSavedPlaceFolder = 2,
};
SZFriendsSavedPlace SZFriendsSavedPlaceOfFile(NSString *stateDirectory, NSString *path);

// Publishes a verified, staged file (inside <state>/received/.partial/) as `fileName` in the chosen folder, else
// Downloads, else <state>/received/: whichever is there and takes it (a missing, read-only or refused folder, a
// full volume, passes to the next), so a file is never lost. Quarantined first; never replaces anything ("Name
// (2).ext", exclusive rename). Across volumes the bytes are copied into SZFriendsReceivedPartPath(final), made
// durable, quarantined and renamed, and the staged file is removed. `willPublish` runs before each attempt with the
// path it will take (the receiver records it for crash recovery); returning NO stops. Returns the published path.
NSString *_Nullable SZFriendsPublishReceivedFile(NSString *staged, NSString *fileName, NSString *stateDirectory,
                                                 BOOL (^_Nullable willPublish)(NSString *finalPath, NSError **error),
                                                 NSError **error);
// The hidden file a copy across volumes writes before it takes `finalPath`: ".<name>.part" beside it.
NSString *SZFriendsReceivedPartPath(NSString *finalPath);

// Sending a staged snapshot (ADR 0018 § 9.1): opened once per transfer and session, read-only, read-ahead on, so each
// chunk is one pread at its offset instead of a seek and a read. Nil when the snapshot is gone.
NSFileHandle *_Nullable SZFriendsOpenSnapshotForSending(NSString *path);
// Exactly `length` bytes at `offset`, or nil (the snapshot shrank or vanished: nothing true can be sent from it).
NSData *_Nullable SZFriendsReadSnapshotAt(NSFileHandle *snapshot, uint64_t offset, NSUInteger length);

// The two halves of a durability batch (ADR 0018 § 4, as szfriends-core's store/disk.rs). OrderWrites: the file's
// writes reach the drive before anything written after it (F_BARRIERFSYNC; fsync where that is refused), without
// flushing the drive's cache. MakeDurable: everything written so far survives a power cut (F_FULLFSYNC, which on Apple
// storage flushes the drive's whole cache; fsync where that is refused). A batch orders its data, writes what records
// it, and flushes once: a commit to the store, which runs F_FULLFSYNC itself, is that one flush.
BOOL SZFriendsOrderWrites(int fd);
BOOL SZFriendsMakeDurable(int fd);

// Offer metadata a peer sent (the helper reads it from the OFFER frame; the session codec has already checked
// field lengths), checked before any buffer is allocated: name, declared size, digest length, and the number of
// offers this friend has pending (floods). Returns NO with a reason for the log; the peer learns only that the
// offer was refused.
BOOL SZFriendsValidateOffer(NSString *name, uint64_t declaredSize, NSData *contentDigest,
                            NSUInteger pendingOffersFromSender, NSString *_Nullable *_Nullable reason);

// Automatic acceptance decision for one incoming offer. Off by default; turns itself off on a key change or
// block (the store clears the switch); still asks when free space after the file would fall below
// `reserveBytes`. Verification is not required: the brief ties the switch to the friend's key, not to codes.
typedef NS_ENUM(NSInteger, SZFriendsAutoAcceptDecision) {
    SZFriendsAutoAcceptAsk = 0,
    SZFriendsAutoAcceptDownload = 1,
    SZFriendsAutoAcceptAskLowDisk = 2, // ask, and say why ("Not enough space to download this automatically")
};
// `keyChangePending`: the friend presented a new key not yet reviewed; never download automatically then, even
// if the store has not cleared the switch yet.
SZFriendsAutoAcceptDecision SZFriendsAutoAcceptDecide(BOOL autoAcceptOn, BOOL keyChangePending, BOOL blocked,
                                                      uint64_t fileSize, uint64_t freeBytes, uint64_t reserveBytes);

// One published incoming file (PROTOCOL.md § Views, received).
typedef NS_ENUM(NSInteger, SZFriendsReceivedSource) {
    SZFriendsReceivedSourceFriend = 0, // a friend's offer
    SZFriendsReceivedSourceLink = 1,   // a download link (receive_link)
    SZFriendsReceivedSourceDevice = 2, // a copy from another of the person's computers (fetch_from_device)
};
@interface SZFriendsReceivedFile : NSObject
@property(nonatomic, copy) NSString *transferID;
@property(nonatomic, copy) NSString *path;
@property(nonatomic, copy) NSDate *receivedAt;
@property(nonatomic) SZFriendsReceivedSource source;
@end

#pragma mark - Transfer manager

@interface SZFriendsTransfers : NSObject
// Also runs ADR 0003's crash recovery for files: finishes publishing a file renamed before its commit, truncates
// each staging file to its durable byte count, and deletes private files no row references, along with staged
// transfers nobody offered. Create one per helper run, before any staging.
- (instancetype)initWithStore:(SZFriendsStore *)store
               stateDirectory:(NSString *)stateDirectory NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// <state dir>/received/: incoming bytes stage in received/.partial/, and it is the last folder a file falls back to.
// Outgoing snapshots live in outgoing/.
@property(nonatomic, readonly) NSString *receivedDirectory;

// Free space on the state directory's volume, for acceptance checks; tests and the harness inject a fake.
@property(nonatomic, copy) uint64_t (^freeBytesProvider)(NSString *path);
// What automatic acceptance leaves free after the file (SZFriendsTransferDefaultReserveBytes by default). Manual
// acceptance only needs the file itself to fit.
@property(nonatomic) uint64_t reserveBytes;

// Binds a file to an immutable snapshot (APFS clone when possible, copy otherwise) before offering, and records
// the transfer as Queued. Fails for a missing source (FileMissing), a folder (FolderNotSupported), a revision
// whose size or hash no longer matches (SourceChanged), or insufficient space for the snapshot (DiskFull); the
// helper turns the code into catalog text with SZFriendsStoreProtocolErrorCode.
- (nullable SZFriendsTransferRecord *)stageOutgoingFileAtPath:(NSString *)path
                                                     revision:(nullable SZFriendsRevision *)revision
                                               conversationID:(NSString *)conversationID
                                                        error:(NSError **)error;
// The same, offering the file under PROTOCOL.md file.display_name (sanitized) instead of the path's last component.
- (nullable SZFriendsTransferRecord *)stageOutgoingFileAtPath:(NSString *)path
                                                  displayName:(nullable NSString *)displayName
                                                     revision:(nullable SZFriendsRevision *)revision
                                               conversationID:(NSString *)conversationID
                                                        error:(NSError **)error;
// Drops a staged transfer that was never offered (no history item refers to it) with its snapshot: one bad file in
// an intent sends none (PROTOCOL.md § Intents, Files). Stale once offered; then Cancel applies.
- (BOOL)discardStagedTransfer:(NSString *)transferID error:(NSError **)error;

// An OFFER from a friend, with its history item, in one transaction. Runs SZFriendsValidateOffer with this
// friend's pending count and refuses anyone who is not an unblocked friend (Invalid). The name is sanitized.
// Idempotent by offer id within the conversation: a resent OFFER returns the existing record unchanged. An id that
// matches, ignoring case, another friend's transfer, one of ours, or another of theirs in different case is refused
// (Invalid): ids are compared without case because the file system folds it.
- (nullable SZFriendsTransferRecord *)recordIncomingOfferWithID:(NSString *)transferID
                                                 conversationID:(NSString *)conversationID
                                                       fileName:(NSString *)proposedName
                                                    uniformType:(nullable NSString *)uniformType
                                                           size:(uint64_t)size
                                                  contentDigest:(NSData *)contentDigest
                                                         sentAt:(NSDate *)sentAt
                                                          error:(NSError **)error;
// Decides automatic acceptance for a recorded offer from the friend's switch, key state, block and free space,
// and acts on it: Download accepts it automatically (every manual check applies); AskLowDisk marks the offer
// askedBecauseDiskLow and leaves it waiting.
- (SZFriendsAutoAcceptDecision)applyAutomaticAcceptanceToTransfer:(NSString *)transferID error:(NSError **)error;

- (nullable SZFriendsTransferRecord *)transferWithID:(NSString *)transferID;
// The transfer only if it belongs to `conversationID`: the lookup for an id a peer named (CANCEL, OFFER_REPLY).
- (nullable SZFriendsTransferRecord *)transferWithID:(NSString *)transferID inConversation:(NSString *)conversationID;
- (NSArray<SZFriendsTransferRecord *> *)transfersInConversation:(NSString *)conversationID;
- (NSUInteger)pendingIncomingOfferCountForConversation:(NSString *)conversationID;
// Inbound transfers still Receiving: on every new session the recipient sends PROGRESS for each (ADR 0001).
- (NSArray<SZFriendsTransferRecord *> *)unfinishedIncomingTransfersForConversation:(NSString *)conversationID;

// This person's answers. Accept checks that the file fits (DiskFull leaves the offer waiting) and, when automatic,
// that the switch is still on and no key change is pending; Stale when the offer is no longer waiting.
- (BOOL)acceptTransfer:(NSString *)transferID automatically:(BOOL)automatically error:(NSError **)error;
- (BOOL)declineTransfer:(NSString *)transferID error:(NSError **)error;
- (BOOL)cancelTransfer:(NSString *)transferID error:(NSError **)error;
// Try again on a transfer that failed after acceptance: an incoming one resumes receiving from its verified bytes
// (from zero after a digest mismatch); an outgoing one is queued to be offered again if its snapshot still exists
// (FileMissing otherwise). An offer that was never delivered is retried through its outbox entry instead, which
// moves the transfer with it.
- (BOOL)retryTransfer:(NSString *)transferID error:(NSError **)error;
- (BOOL)failTransfer:(NSString *)transferID reason:(NSString *)reason error:(NSError **)error;

// The other side's answers, checked against the sender: `conversationID` must own the transfer (Invalid otherwise,
// and for an empty one). A late or replayed answer is Stale and changes nothing.
// Their Mac acknowledged our OFFER (the outbox does this itself for an offer entry it delivers).
- (BOOL)markOfferDelivered:(NSString *)transferID fromConversation:(NSString *)conversationID
                     error:(NSError **)error;
// Accepted: continues from `offset` only for our own offer to this friend, with offset within the file and the
// snapshot still hashing to the offered digest (checked once per helper run); otherwise Stale or SourceChanged.
- (BOOL)peerAnsweredTransfer:(NSString *)transferID
                    accepted:(BOOL)accepted
                      offset:(uint64_t)offset
            fromConversation:(NSString *)conversationID
                       error:(NSError **)error;
- (BOOL)peerCancelledTransfer:(NSString *)transferID fromConversation:(NSString *)conversationID
                        error:(NSError **)error;
// Their Mac verified our file: Delivered, and the outgoing snapshot is deleted.
- (BOOL)peerVerifiedTransfer:(NSString *)transferID fromConversation:(NSString *)conversationID
                       error:(NSError **)error;
- (BOOL)setMeasuredBytesPerSecond:(double)bytesPerSecond forTransfer:(NSString *)transferID
                            error:(NSError **)error;

// Receiving side of a chunk stream, from the conversation that owns the transfer (a chunk or DONE for another
// friend's transfer, or with no conversation, is refused as unsolicited: Invalid). Appends to the private temporary
// file after checking the offset equals the verified count. Finishing publishes the file only when
// `finalDigest`, the digest of the streamed bytes and the digest of the staged file read back from disk all match the
// offer's contentDigest; otherwise the file is deleted and the transfer fails (DigestMismatch). Durable progress
// (what PROGRESS may report) advances only after F_FULLFSYNC and a commit, batched every 4 MiB or 1 s (ADR 0003).
- (BOOL)appendChunk:(NSData *)bytes atOffset:(uint64_t)offset toTransfer:(NSString *)transferID
   fromConversation:(NSString *)conversationID error:(NSError **)error;
- (BOOL)finishTransfer:(NSString *)transferID finalDigest:(NSData *)finalDigest
      fromConversation:(NSString *)conversationID error:(NSError **)error;
// Makes every received byte durable now (session lost, handover, exit), so the next resume starts from it.
- (BOOL)flushProgressWithError:(NSError **)error;
@end

@interface SZFriendsTransfers (ReceivedFolder)
// The folder received files go to (SZFriendsReceivedFolder): what Settings shows and Show in Finder opens.
@property(nonatomic, readonly) NSString *destinationDirectory;
// Free space for a download: the staging volume's, and the destination folder's when it is on another volume.
- (uint64_t)freeBytesForReceiving;
// The received view: incoming files in state Received whose published file still exists, newest first.
- (NSArray<SZFriendsReceivedFile *> *)receivedFilesWithLimit:(NSUInteger)limit;
@end

NS_ASSUME_NONNULL_END
