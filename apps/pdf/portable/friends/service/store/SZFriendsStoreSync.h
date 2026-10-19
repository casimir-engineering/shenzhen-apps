// Shenzhen Friends store: what sync between one person's own devices keeps (schema v9; friends-multi-device.md § Sync).
//
// Helper-only. The sync area (service/sync/) owns the meaning: it signs, verifies and merges events and decides what
// each one changes. The store keeps the log and the merge state and applies the few changes that must be atomic with
// the rows they touch (an item and its origin, a deletion and the items it covers). Nothing here verifies a
// signature: an event reaches -appendSyncEvent: only after the sync area checked it.
//
//   - The **event log** holds every device's events by (author device key, sequence number), contiguous per author,
//     so a version vector (author -> highest sequence held) says exactly what a device has. A deletion drops the
//     bodies of the events it covers; their signed headers stay, so the log stays whole and verifiable.
//   - **Registers** hold last-writer-wins values (relation, profile, settings, outbox status...) with the Lamport
//     clock and author of the event that wrote them, and the value as last applied or captured.
//   - **Origins** say which events put each history item here. A deletion removes exactly the items one of whose
//     origins it covers, and marks them deleted, so a copy arriving later from another device stays deleted.
//   - **Files** are transfer records as the whole profile knows them, with the devices holding the file's bytes.
//
// Every method may be called from any thread, like the rest of the store.

#import <Foundation/Foundation.h>

#import "service/store/SZFriendsOutbox.h"
#import "service/store/SZFriendsStore.h"
#import "service/store/SZFriendsTransfers.h"

NS_ASSUME_NONNULL_BEGIN

// The conversation with yourself ("You"): what goes there reaches every one of this person's devices. It has a row in
// the people table with no keys, made on first use (-ensureYouConversation:), and is never dialed or offered.
extern NSString *const SZFriendsYouConversationID; // "you"
// The sync state key (-syncStateForKey:) holding the last history row a scan for new items read; a deletion clears it.
extern NSString *const SZFriendsSyncCaptureRowKey;

// author -> highest sequence number held, as NSData (32 bytes) -> NSNumber (uint64).
typedef NSDictionary<NSData *, NSNumber *> SZFriendsSyncVector;

// One event as the log keeps it. `header` is the signed header exactly as its author wrote it; `body` is nil once a
// deletion dropped it (or when it arrived that way).
@interface SZFriendsSyncLogEvent : NSObject <NSCopying>
@property(nonatomic, copy) NSData *author;
@property(nonatomic) uint64_t seq;
@property(nonatomic) uint64_t lamport;
@property(nonatomic) NSInteger kind;
@property(nonatomic, copy) NSString *scope;   // whose conversation or setting it is about ("" for the profile)
@property(nonatomic, copy) NSString *subject; // what in it: an item id, a field group, an entry id
@property(nonatomic, copy) NSData *header;
@property(nonatomic, copy, nullable) NSData *body;
@property(nonatomic) BOOL applied;            // its change is in the store (or it can never apply)
@end

// A last-writer-wins value: the clock and author of the event that wrote it, and the value's bytes.
@interface SZFriendsSyncRegister : NSObject <NSCopying>
@property(nonatomic) uint64_t lamport;
@property(nonatomic, copy) NSData *author;
@property(nonatomic, copy, nullable) NSData *value;
@end

// A transfer record as the profile knows it (sync_files): which devices hold its bytes, whatever this device has.
@interface SZFriendsSyncFileRecord : NSObject <NSCopying>
@property(nonatomic, copy) NSString *transferID;
@property(nonatomic, copy) NSString *conversationID; // this device's conversation id
@property(nonatomic, copy, nullable) NSString *itemID;
@property(nonatomic) BOOL outgoing;
@property(nonatomic) SZFriendsTransferState state;
@property(nonatomic, copy) NSString *fileName;
@property(nonatomic, copy, nullable) NSString *uniformType;
@property(nonatomic) uint64_t size;
@property(nonatomic, copy) NSData *contentDigest;
@property(nonatomic, copy) NSDate *createdAt;
@property(nonatomic, copy) NSArray<NSData *> *holders; // device keys, sorted
@end

@interface SZFriendsStore (Sync)

// Every read in this header goes to the store's writer, so inside -performSyncTransaction: it sees the transaction's
// own writes (reads elsewhere in the store do not).

#pragma mark People

- (nullable SZFriendsPersonRecord *)syncPersonWithConversationID:(NSString *)conversationID;
// The person whose identity (root) key this is, never one of their other devices.
- (nullable SZFriendsPersonRecord *)syncPersonWithIdentityKey:(NSData *)identityKey;

#pragma mark Event log

- (SZFriendsSyncVector *)syncVector;
// The highest Lamport clock in the log; 0 when it is empty.
- (uint64_t)syncLamport;
// Appends an event that follows its author's last one. A copy already held is YES with `appended` NO; a gap (a
// sequence number past the next one) is Invalid and stores nothing, so the log stays contiguous per author.
- (BOOL)appendSyncEvent:(SZFriendsSyncLogEvent *)event appended:(nullable BOOL *)appended error:(NSError **)error;
// Events `vector` lacks, by author then sequence, at most `limit`.
- (NSArray<SZFriendsSyncLogEvent *> *)syncEventsMissingFrom:(SZFriendsSyncVector *)vector limit:(NSUInteger)limit;
- (nullable SZFriendsSyncLogEvent *)syncEventWithAuthor:(NSData *)author seq:(uint64_t)seq;
// One author's events past `seq`, in order.
- (NSArray<SZFriendsSyncLogEvent *> *)syncEventsOfAuthor:(NSData *)author afterSeq:(uint64_t)seq;
// Events not applied yet, by Lamport clock, author and sequence.
- (NSArray<SZFriendsSyncLogEvent *> *)unappliedSyncEvents;
- (NSArray<SZFriendsSyncLogEvent *> *)syncEventsOfKind:(NSInteger)kind;
// Whether a deletion dropped the body of an event of `kind` about `subject` (a file record whose item went).
- (BOOL)hasBodilessSyncEventOfKind:(NSInteger)kind subject:(NSString *)subject;
- (BOOL)markSyncEventApplied:(NSData *)author seq:(uint64_t)seq error:(NSError **)error;
- (NSUInteger)syncEventCount;

#pragma mark Registers and state

- (nullable SZFriendsSyncRegister *)syncRegisterForKey:(NSString *)key;
- (NSDictionary<NSString *, SZFriendsSyncRegister *> *)syncRegistersWithPrefix:(NSString *)prefix;
- (BOOL)setSyncRegister:(SZFriendsSyncRegister *)value forKey:(NSString *)key error:(NSError **)error;
- (nullable id)syncStateForKey:(NSString *)key;
- (BOOL)setSyncState:(nullable id)value forKey:(NSString *)key error:(NSError **)error;

// Runs `body` as one transaction on the store's writer: store methods called inside it join it, and nothing commits
// unless the body returns YES. This header's reads see its writes; the rest of the store's reads (people lookups,
// profile) go to the read connection and see only what was committed.
- (BOOL)performSyncTransaction:(BOOL (^)(NSError **error))body error:(NSError **)error;

@end

// SZFriendsStoreSyncHistory.m.
@interface SZFriendsStore (SyncHistory)

// The conversation with yourself, made when missing.
- (BOOL)ensureYouConversation:(NSError **)error;
// Items with no origin yet (what this device has not turned into events), oldest row first, after row `afterRow`;
// `lastRow` receives the last row read, so a scan can go on from there.
- (NSArray<SZFriendsItemRecord *> *)itemsWithoutSyncOriginAfterRow:(int64_t)afterRow
                                                             limit:(NSUInteger)limit
                                                           lastRow:(int64_t *)lastRow;
// The events that put this item here, as [author (NSData), seq (NSNumber)] pairs: one per device that captured it.
- (NSArray<NSArray *> *)syncOriginsOfItem:(NSString *)itemID inConversation:(NSString *)conversationID;
// The same for every item of a conversation at once, by item id.
- (NSDictionary<NSString *, NSArray<NSArray *> *> *)syncOriginsInConversation:(NSString *)conversationID;
- (BOOL)addSyncOriginForItem:(NSString *)itemID
              inConversation:(NSString *)conversationID
                      author:(NSData *)author
                         seq:(uint64_t)seq
                       error:(NSError **)error;
// An item copied from another device, as one transaction: inserted when absent, otherwise its times lowered to the
// earliest any device saw (so every device shows the same times), with its origin recorded. An item a deletion
// took stays deleted: YES, nothing inserted. The unread count is the sync area's (-recountUnread...).
- (BOOL)mergeSyncedItem:(SZFriendsItemRecord *)item author:(NSData *)author seq:(uint64_t)seq error:(NSError **)error;
- (BOOL)isSyncDeletedItem:(NSString *)itemID inConversation:(NSString *)conversationID;
// A deletion: every item in `conversationID` (nil: every conversation) one of whose origins `vector` covers goes, with
// its transfer, file record and outbox entry, and stays deleted. The events that carried them lose their bodies (the
// item's origins, and the `fileKind` and `outboxKind` events naming its transfer or entry), and the free pages are
// wiped as -deleteHistoryInConversation: does. Returns the conversations that lost items, or nil on failure.
- (nullable NSArray<NSString *> *)deleteSyncedItemsInConversation:(nullable NSString *)conversationID
                                                        coveredBy:(SZFriendsSyncVector *)vector
                                                         fileKind:(NSInteger)fileKind
                                                       outboxKind:(NSInteger)outboxKind
                                                            error:(NSError **)error;
// One item a deletion covers that arrived after it (or arrived without its body): gone, and marked so it stays gone.
- (BOOL)markSyncDeletedItem:(NSString *)itemID
             inConversation:(NSString *)conversationID
                   fileKind:(NSInteger)fileKind
                 outboxKind:(NSInteger)outboxKind
                      error:(NSError **)error;
// A removed device's events past `seq` (ADR 0014 § What a removed computer still counts for): gone from the log, as if
// they had never arrived. The items only they put here go as a deletion takes them (with their transfer, file record
// and outbox entry, free pages wiped) but are not marked deleted; items another device put here too keep their other
// origins. Returns the conversations that lost items, or nil on failure.
- (nullable NSArray<NSString *> *)purgeSyncEventsOfAuthor:(NSData *)author
                                                 afterSeq:(uint64_t)seq
                                                 fileKind:(NSInteger)fileKind
                                               outboxKind:(NSInteger)outboxKind
                                                    error:(NSError **)error;
// Drops one event's body (an event a deletion covers that could not apply, so it carried nothing here).
- (BOOL)dropBodyOfSyncEvent:(NSData *)author seq:(uint64_t)seq error:(NSError **)error;
// Unread count = incoming messages and files received after (receivedAt, itemID); every incoming one without a marker.
- (BOOL)recountUnreadInConversation:(NSString *)conversationID
                   readThroughDate:(nullable NSDate *)receivedAt
                            itemID:(nullable NSString *)itemID
                             error:(NSError **)error;
// The newest incoming message or file (by receivedAt, then id), or nil.
- (nullable SZFriendsItemRecord *)newestIncomingItemInConversation:(NSString *)conversationID;
// The incoming message or file with exactly `newer` incoming ones after it: with the unread count, the last one read.
- (nullable SZFriendsItemRecord *)incomingItemInConversation:(NSString *)conversationID newerCount:(NSUInteger)newer;

@end

// SZFriendsStoreSyncFiles.m.
@interface SZFriendsStore (SyncFiles)

#pragma mark Outbox

// Entries other devices may deliver too: messages, requests and presence secrets (not file offers or answers, whose
// bytes and receivers live on the device that made them).
- (NSArray<SZFriendsOutboxEntry *> *)syncableOutboxEntries;
// An entry from another device: inserted when absent (in a conversation this device has), else its state, failure
// and payload replaced. In-flight states arrive as Queued.
- (BOOL)mergeSyncedOutboxEntry:(SZFriendsOutboxEntry *)entry error:(NSError **)error;

#pragma mark Files

- (nullable SZFriendsSyncFileRecord *)syncFileWithID:(NSString *)transferID;
- (NSArray<SZFriendsSyncFileRecord *> *)syncFiles;
- (BOOL)saveSyncFile:(SZFriendsSyncFileRecord *)file error:(NSError **)error;
// Every transfer row here, and the history item showing one.
- (NSArray<SZFriendsTransferRecord *> *)allTransferRecords;
- (nullable NSString *)itemIDForTransfer:(NSString *)transferID inConversation:(NSString *)conversationID;
// Transfers this device holds the bytes of: ours with a staged copy, received here, or copied from another device.
- (NSArray<SZFriendsTransferRecord *> *)transfersWithLocalBytes;
- (nullable SZFriendsTransferRecord *)transferRecordWithID:(NSString *)transferID;
// A transfers row for a file whose bytes were copied from another device, in the state the profile's record has,
// pointing at `path` (in received/). An outgoing copy holds a received path and no snapshot, which is how
// -setState:ofCopiedTransfer: tells it from the device that sends it.
- (BOOL)insertCopiedTransfer:(SZFriendsTransferRecord *)transfer path:(NSString *)path error:(NSError **)error;
- (BOOL)setState:(SZFriendsTransferState)state ofCopiedTransfer:(NSString *)transferID error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
