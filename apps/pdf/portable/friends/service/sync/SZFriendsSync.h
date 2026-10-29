// Shenzhen Friends sync: one person's devices keep the same chats, friends and settings (friends-multi-device.md
// § Sync, ADR 0014).
//
// Helper-only. Every change becomes an **event** signed by the device that made it, with that device's sequence number
// and a Lamport clock. Devices exchange the events the other lacks (anti-entropy over version vectors, each author's
// events in order) on a session between two of the person's devices (frame SYNC), and apply them with merge rules
// under which every order of arrival gives the same store:
//   - messages, files and history events are add-only sets keyed by conversation and id;
//   - read markers take the maximum;
//   - relations, profiles, settings, outbox status and file records are last-writer-wins by Lamport clock, then
//     author key (a delivered message stays delivered, a received file stays received);
//   - a deletion (one chat or all) is a tombstone naming the version vector its device had: it removes exactly the
//     items that vector covers, everywhere, and a copy of them arriving later stays deleted;
//   - applying an event twice changes nothing.
//
// Local changes are not hooked one by one: SZFriendsSyncEngine scans the store for what changed since it last looked
// (-captureLocalChanges) and records events for it, so nothing a crash interrupted is lost to sync, and a profile
// that had one device turns its whole history into events the first time another device joins.

#import <Foundation/Foundation.h>

@class SZFriendsFrame;

#import "service/store/SZFriendsStoreSync.h"

NS_ASSUME_NONNULL_BEGIN

@class SZFriendsIdentity, SZFriendsPicture, SZFriendsDeviceChain;

extern NSErrorDomain const SZFriendsSyncErrorDomain;

typedef NS_ERROR_ENUM(SZFriendsSyncErrorDomain, SZFriendsSyncError) {
    SZFriendsSyncErrorMalformed = 1,    // bytes that do not decode
    SZFriendsSyncErrorForged = 2,       // a signature or body digest that does not verify
    SZFriendsSyncErrorUnauthorized = 3, // an author our own chain does not hold (or holds as void)
    SZFriendsSyncErrorOutOfOrder = 4,   // an author's events with a gap
    SZFriendsSyncErrorInactive = 5,     // no own chain with another device yet
};

typedef NS_ENUM(uint8_t, SZFriendsSyncKind) {
    SZFriendsSyncKindChain = 1,     // body: our encoded device chain
    SZFriendsSyncKindProfile = 2,   // name, picture, Friends ID
    SZFriendsSyncKindSetting = 3,   // subject: the setting (our presence secrets)
    SZFriendsSyncKindPerson = 4,    // subject: a group of a person's fields (relation, profile, keys, trust)
    SZFriendsSyncKindItem = 5,      // subject: the item id; a message, a file's history row or a history event
    SZFriendsSyncKindRead = 6,      // a conversation read through an item
    SZFriendsSyncKindOutbox = 7,    // subject: the entry id
    SZFriendsSyncKindFile = 8,      // subject: the transfer id; the record without its bytes
    SZFriendsSyncKindFileHeld = 9,  // subject: the transfer id; the author holds its bytes
    SZFriendsSyncKindTombstone = 10, // a deletion of one conversation's history (scope) or all of it (scope "")
    // subject: a device the author revoked (key hex); the events of it the author held then, the only ones of that
    // device any of ours accepts from then on (what it signed after its removal counts for nothing).
    SZFriendsSyncKindRevocation = 11
};

extern const NSUInteger SZFriendsSyncBodyMax;        // 60,000 bytes: one event fits one SYNC frame
extern const NSUInteger SZFriendsSyncMessageMax;     // 64,000 bytes: a SYNC frame's payload
extern const NSUInteger SZFriendsSyncLabelMax;       // 80 bytes: scope and subject
// Files at most this large copy to the person's other devices by themselves; larger ones when asked. Files in the
// You conversation always copy.
extern const uint64_t SZFriendsSyncAutoCopyMax;      // 25 MB (25,000,000 bytes)
extern const NSUInteger SZFriendsSyncFilePartMax;    // 48 KiB of file per FILE_PART message
// An event whose Lamport clock is further than this ahead of ours is refused, so no device can push the clocks to
// their end (where last writer wins would stop working) in a few events.
extern const uint64_t SZFriendsSyncLamportMargin;    // 2^32
// How long each authorized device after the first waits, per place in the order, before drawing new secrets after a
// removal the devices before it have not acted on.
extern const NSTimeInterval SZFriendsSyncSecretRenewalWait; // 600 s

// Whether a file's bytes copy to this device without being asked.
BOOL SZFriendsSyncCopiesAutomatically(uint64_t size, NSString *conversationID);

// The presence secret one of our devices advertises its tags under, nearby (SZFriendsPresenceTag): BLAKE2b-256 keyed
// with the own-devices secret over "SZFriends own device v1" || its device key. Friends never hold the own-devices
// secret, so these tags tell them nothing; our devices tell each other apart by them, and so know whom to dial.
NSData *_Nullable SZFriendsSyncDeviceTagSecret(NSData *ownDevicesSecret, NSData *deviceKey);
// The presence secret a person's device other than their first advertises its tags under, so friends know which of
// their devices they see and dial it with that device's static key: BLAKE2b-256 keyed with the person's presence
// secret (the one friends hold) over "SZFriends device presence v1" || the device key. The first device keeps the
// person's own tags, which friends without the chain still recognise.
NSData *_Nullable SZFriendsSyncFriendDeviceTagSecret(NSData *presenceSecret, NSData *deviceKey);

#pragma mark - Fields

// A body's fields: tag u8 | length u16 | value, tags strictly ascending. Decoding refuses anything else.
@interface SZFriendsSyncFields : NSObject
+ (nullable instancetype)fieldsWithData:(NSData *)data;
- (instancetype)init;
@property(nonatomic, readonly) NSData *encodedData;
- (void)setData:(nullable NSData *)value forTag:(uint8_t)tag;
- (void)setString:(nullable NSString *)value forTag:(uint8_t)tag;
- (void)setUInt64:(uint64_t)value forTag:(uint8_t)tag;
- (void)setDate:(nullable NSDate *)value forTag:(uint8_t)tag; // the exact double, so times round-trip unchanged
- (nullable NSData *)dataForTag:(uint8_t)tag;
- (nullable NSString *)stringForTag:(uint8_t)tag;
- (uint64_t)uint64ForTag:(uint8_t)tag; // 0 when absent or malformed
- (BOOL)hasTag:(uint8_t)tag;
- (nullable NSDate *)dateForTag:(uint8_t)tag;
@end

#pragma mark - Events

// One signed event. Header, all integers big-endian: version u8 (1) | kind u8 | author (32) | seq u64 | lamport u64 |
// milliseconds u64 | scope length u8 | scope | subject length u8 | subject | body length u32 | BLAKE2b-256 of the body
// (32) | Ed25519 signature (64) by the author over root key || every byte before it, domain "SZFriends sync event v1".
// The body travels beside the header and may be absent (a deletion dropped it): the header still verifies.
@interface SZFriendsSyncEvent : NSObject
+ (instancetype)eventSignedBy:(SZFriendsIdentity *)author
                      rootKey:(NSData *)rootKey
                         kind:(SZFriendsSyncKind)kind
                          seq:(uint64_t)seq
                      lamport:(uint64_t)lamport
                         date:(NSDate *)date
                        scope:(NSString *)scope
                      subject:(NSString *)subject
                         body:(NSData *)body;
// Verifies the header's signature against `author`'s key (the header names it) and the body against its digest.
+ (nullable instancetype)eventWithHeader:(NSData *)header
                                    body:(nullable NSData *)body
                                 rootKey:(NSData *)rootKey
                                   error:(NSError **)error;
// As the log keeps it (already verified when it was appended): decoded, not verified again.
+ (nullable instancetype)eventWithLogEvent:(SZFriendsSyncLogEvent *)logEvent;
@property(nonatomic, readonly) SZFriendsSyncKind kind;
@property(nonatomic, readonly) NSData *author;
@property(nonatomic, readonly) uint64_t seq;
@property(nonatomic, readonly) uint64_t lamport;
@property(nonatomic, readonly) NSDate *date;
@property(nonatomic, readonly) NSString *scope;
@property(nonatomic, readonly) NSString *subject;
@property(nonatomic, readonly, nullable) NSData *body;
@property(nonatomic, readonly) NSData *header;
- (SZFriendsSyncLogEvent *)logEvent;
@end

// Version vectors on the wire: count u16 | (author (32) | seq u64)*, authors ascending.
NSData *SZFriendsSyncEncodeVector(SZFriendsSyncVector *vector);
SZFriendsSyncVector *_Nullable SZFriendsSyncDecodeVector(NSData *data, NSUInteger *_Nullable consumed);
BOOL SZFriendsSyncVectorCovers(SZFriendsSyncVector *vector, NSData *author, uint64_t seq);

#pragma mark - Engine

@interface SZFriendsSyncEngine : NSObject
- (instancetype)initWithStore:(SZFriendsStore *)store
                     identity:(SZFriendsIdentity *)identity
            receivedDirectory:(NSString *)receivedDirectory NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) SZFriendsStore *store;
@property(nonatomic, readonly) SZFriendsIdentity *identity;
@property(nonatomic, readonly) NSString *receivedDirectory;
// Our own chain's root key, or nil while this device has no chain.
@property(nonatomic, readonly, nullable) NSData *rootKey;
// Sync runs once our own chain has held another device: before that nothing is recorded, and the first capture after
// turns everything already here into events.
@property(nonatomic, readonly, getter=isActive) BOOL active;
// Our devices other than this one that the chain authorizes now.
@property(nonatomic, readonly) NSArray<NSData *> *otherDeviceKeys;

// Records events for everything that changed in the store since the last capture. Returns how many.
- (NSUInteger)captureLocalChanges;
// Events from another of our devices, each author's in order: verified, appended, applied. Stops at the first event
// that fails (NO, error set); the ones before it are kept.
- (BOOL)receiveEvents:(NSArray<SZFriendsSyncEvent *> *)events error:(NSError **)error;
// Applies events waiting on something not here yet (an item before its conversation). Returns how many applied.
- (NSUInteger)applyPendingEvents;
// "Erase chat history" (nil: every chat): a tombstone for what this device has, applied here at once and carried to
// every other device. A tombstone covers only events older than itself by Lamport clock: what its device could have
// seen, never a device's future messages.
- (BOOL)deleteHistoryInConversation:(nullable NSString *)conversationID error:(NSError **)error;
- (SZFriendsSyncVector *)vector;
// Events `vector` lacks, each author's in order.
- (NSArray<SZFriendsSyncEvent *> *)eventsMissingFrom:(SZFriendsSyncVector *)vector limit:(NSUInteger)limit;
// The own-devices presence secret (32 bytes): own devices recognise each other nearby by tags derived from it and a
// device key, which friends cannot match. Made by the first device when sync starts, synced to the others.
- (nullable NSData *)ownDevicesSecret;
// The same, drawn now when this is the first device and none exists yet; nil on a device that has yet to learn it.
- (nullable NSData *)ensureOwnDevicesSecret;

// The store changed by sync (snapshots refresh): conversations touched, empty for profile-wide changes.
@property(nonatomic, copy, nullable) void (^onChange)(NSSet<NSString *> *conversationIDs);
// Events were recorded or received: sessions with our other devices send them on.
@property(nonatomic, copy, nullable) void (^onNewEvents)(void);
// History items another device brought that were not here before, once committed and the unread counts recounted
// (after onChange): what the helper's notifier looks at (ADR 0017).
@property(nonatomic, copy, nullable) void (^onItemsArrived)(NSArray<SZFriendsItemRecord *> *items);
// Keeps a synced photo (bytes of a picture another device stored) and returns its picture; nil: placeholder.
@property(nonatomic, copy, nullable) SZFriendsPicture *_Nullable (^storePicture)(NSData *imageBytes);
// The clock events are stamped with; tests set it.
@property(nonatomic, copy) NSDate * (^clock)(void);
@end

// Revocations and secrets (SZFriendsSyncRevocation.m).
@interface SZFriendsSyncEngine (Devices)
// This device just stored a chain revoking `deviceKey`: records which of that device's events it held, the only ones
// of that device our other devices accept from now on. Call right after the revocation is stored.
- (BOOL)recordRevocationOfDeviceKey:(NSData *)deviceKey error:(NSError **)error;
// A device of ours was revoked: new presence and own-devices secrets, which sync carries to our other devices (the
// caller tells friends the new presence secret). The first authorized device draws at once; should it not have done so
// (it is away) SZFriendsSyncSecretRenewalWait after this device first saw the removal, the second draws, then the third
// after twice that, and so on in the order every device computes alike. Nothing is drawn once sync brought secrets
// drawn after the same removals. Returns the new presence secret, or nil when nothing was drawn.
- (nullable NSData *)renewSecretsAfterRevocation;
// When this device will draw if nobody has by then (call -renewSecretsAfterRevocation again at that time); nil when
// nothing waits.
- (nullable NSDate *)secretRenewalDueDate;
// YES once (then NO) after sync replaced a presence secret this device drew and told friends: two of our devices drew
// for the same removals (the first came back after the next one's turn), the other's won, and friends must hear it
// from here too, or the ones that heard this device last would keep a secret that matches nothing.
- (BOOL)takePresenceSecretRetell;
// Without an engine (before the chain holds a second device): the own-devices secret a store holds, drawn when absent
// and `create` (a device approving a join hands it to the new computer); and the one a joined device receives.
+ (nullable NSData *)ownDevicesSecretInStore:(SZFriendsStore *)store creating:(BOOL)create;
+ (BOOL)adoptOwnDevicesSecret:(NSData *)secret inStore:(SZFriendsStore *)store;
// What a device that just joined took from the welcome, made its starting point rather than an edit of its own: the
// profile it received is held at clock 0, so anything the profile's devices record wins over it and it is never
// recorded again here; and this device's clock starts from `clock`, the approving device's once it had recorded what
// the profile held before the join, so a change made here right away wins over all of that.
+ (BOOL)adoptJoinCopyWithClock:(uint64_t)clock inStore:(SZFriendsStore *)store;
// The own-devices secrets this device held before the current one, newest first (at most 4): a computer removed while
// away still advertises under one of them, which is how our devices find it to tell it so.
- (NSArray<NSData *> *)previousOwnDevicesSecrets;
// What another of our devices last said it holds (its HELLO or ACK), kept across sessions; nil before it said.
- (nullable SZFriendsSyncVector *)vectorHeldByDevice:(NSData *)deviceKey;
- (void)noteDevice:(NSData *)deviceKey holds:(SZFriendsSyncVector *)vector;
// Every other authorized device of ours holds an event that carried this item (You's "On all your computers").
- (BOOL)itemReachedEveryDevice:(NSString *)itemID inConversation:(NSString *)conversationID;
// Every other authorized device of ours holds this file's bytes.
- (BOOL)fileReachedEveryDevice:(NSString *)transferID;
// The items of `conversationID` (messages by their events, files by their bytes) every other device holds: what a
// snapshot of You shows as on all your computers, read in two queries whatever the number of items.
- (NSSet<NSString *> *)itemsOnEveryDeviceInConversation:(NSString *)conversationID;
@end

// Where this device has a transfer's bytes (ADR 0016): a received file where it was saved, at its size; for one of
// ours, the snapshot, a copy, or the file it was sent from while unchanged (size and modification time). Nil: none.
NSString *_Nullable SZFriendsSyncLocalPathOfTransfer(SZFriendsTransferRecord *transfer);

@interface SZFriendsSyncEngine (Files)
// Files: transfer records whose bytes are on another device and not here, the ones that copy by themselves (or were
// asked for) first.
- (NSArray<SZFriendsSyncFileRecord *> *)filesWanted;
// "Get": copy this file's bytes here at the next chance, whatever its size.
- (BOOL)requestFile:(NSString *)transferID error:(NSError **)error;
// Get was pressed for it (and the copy has not finished).
- (BOOL)isFileRequested:(NSString *)transferID;
// Cancel after Get: the file stays where it is; what arrived so far waits in received/.partial/ for another Get.
- (BOOL)cancelFileRequest:(NSString *)transferID error:(NSError **)error;
// Where this device keeps a file's bytes, or nil.
- (nullable NSString *)localPathOfFile:(NSString *)transferID;
// The bytes of a file copied from `holder` arrived whole at `path` (verified against the record's digest by the
// caller): published in received/, recorded as a transfer here, and announced. NO when the record is unknown.
- (BOOL)adoptCopiedFile:(NSString *)transferID atPath:(NSString *)path error:(NSError **)error;
@end

#pragma mark - Exchange

// One session with another of our devices: HELLO (each side's vector), then the events the other lacks, each author's
// in order, at most SZFriendsSyncWindow messages unacknowledged, then everything new as it happens; and file copies.
// Every message is a SYNC frame's payload. Runs on the caller's queue.
extern const NSUInteger SZFriendsSyncWindow; // 4 EVENTS messages in flight

@interface SZFriendsSyncExchange : NSObject
- (instancetype)initWithEngine:(SZFriendsSyncEngine *)engine
                     peerKey:(NSData *)peerDeviceKey
                          send:(void (^)(NSData *message))send NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) NSData *peerKey;
// Sends HELLO.
- (void)start;
// A message from the peer. NO: it broke the protocol (malformed, forged, unauthorized); end the session.
- (BOOL)receiveMessage:(NSData *)message error:(NSError **)error;
// Something new to send (a capture, events from a third device): sends what the peer lacks, within the window.
- (void)pump;
// The peer said HELLO and has acknowledged everything we hold.
@property(nonatomic, readonly) BOOL peerCaughtUp;
// We have the peer's HELLO and nothing it sent is waiting to apply.
@property(nonatomic, readonly) BOOL helloReceived;
// File copies running on this session, by transfer id.
@property(nonatomic, readonly) NSUInteger filesInFlight;
// The file this side is copying from the peer, and the share of it here; nil and 0 when none.
@property(nonatomic, readonly, nullable) NSString *copyingTransferID;
@property(nonatomic, readonly) double copyingFraction;
// The file the peer is copying from this side (its latest WANT), and how far that copy has got; nil once done.
@property(nonatomic, readonly, nullable) NSString *servingTransferID;
@property(nonatomic, readonly) double servingFraction;
// Copies from several holders at once (ADR 0018 § 9.6, the helper's pulls): when set, this side's own requester starts
// no copy on this session, and the answers to a pull's asks go to `pullAnswer` first: BLOCKS FOLLOW with the holder's
// tree (`root` set), or NONE (`root` nil; `gone` for "not here"). YES when it was the pull's.
@property(nonatomic) BOOL pulls;
@property(nonatomic, copy, nullable) BOOL (^pullAnswer)(NSString *transferID, NSData *_Nullable root, uint8_t shift,
                                                       BOOL gone);
// Requester by blocks (ADR 0018 § 4): set on a session that negotiated fast transfers, so this side's copies go by
// blocks (7 WANT BLOCKS, resumed from the map beside the partial copy); otherwise by offset (4 WANT).
@property(nonatomic) BOOL fast;
// Session frames for a copy by blocks (HAVE), sent in order after the SYNC messages.
@property(nonatomic, copy, nullable) void (^sendFrame)(SZFriendsFrame *frame);
// The file copying by blocks now, whose HASHES and PARTs on this session are its own.
@property(nonatomic, readonly, nullable) NSString *copyingByBlocks;
// HASHES or a PART of the copy by blocks: NO when this exchange is not copying that file by blocks.
- (BOOL)receiveHashes:(NSData *)hashes index:(uint32_t)index forTransfer:(NSString *)transferID;
- (BOOL)receivePart:(NSData *)data offset:(uint64_t)offset forTransfer:(NSString *)transferID;
// The peer asks for a file by blocks (7 WANT BLOCKS, ADR 0018 § 4, on sessions with fast transfers): the file held
// here at `path`, its size, the block shift and the blocks wanted (packed (first, count) pairs). The owner serves it
// (8 BLOCKS FOLLOW, then HASHES and PARTs on the session), or answers -sendNone:. A file not held here is answered
// NONE before this is called.
@property(nonatomic, copy, nullable) void (^wantBlocks)(NSString *transferID, NSString *path, uint64_t size,
                                                         uint8_t shift, NSData *ranges);
// 6 NONE for that file: this side cannot give its bytes.
- (void)sendNone:(NSString *)transferID;
// Sends a message the owner built (8 BLOCKS FOLLOW), marking that file as served.
- (void)sendServing:(NSString *)transferID message:(NSData *)message;
// That file's serve by blocks is done or given up: it is no longer shown as being copied from here.
- (void)finishedServing:(NSString *)transferID;
// How much of that file the other computer has acknowledged so far (a copy by blocks): the You row's percentage.
- (void)servingProgress:(NSString *)transferID fraction:(double)fraction;
// The session ended: partial copies stay for the next one.
- (void)stop;
@end

// The ranges of a WANT BLOCKS (u32be pairs, first and count, none empty) as packed host-order pairs; nil when
// malformed.
NSData *_Nullable SZFriendsCopyRangesDecode(const uint8_t *bytes, NSUInteger length);

NS_ASSUME_NONNULL_END
