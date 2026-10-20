// Private to service/sync/: the engine's state and the functions its files share. Nothing outside the area includes it.

#import "service/sync/SZFriendsSync.h"

#import "service/identity/SZFriendsDeviceChain.h"
#import "service/identity/SZFriendsIdentity.h"
#import "service/store/SZFriendsStoreDevices.h"

NS_ASSUME_NONNULL_BEGIN

NSError *SZFriendsSyncMakeError(SZFriendsSyncError code, NSString *why);
BOOL SZFriendsSyncFail(NSError *_Nullable *_Nullable error, SZFriendsSyncError code, NSString *why);
void SZFriendsSyncPutU64(NSMutableData *data, uint64_t value);
uint64_t SZFriendsSyncGetU64(const uint8_t *bytes);
BOOL SZFriendsSyncLabelIsValid(NSString *_Nullable label);
NSData *SZFriendsSyncDigest(NSData *data);
NSArray<NSData *> *SZFriendsSyncSortedKeys(NSArray<NSData *> *keys);
NSString *SZFriendsSyncHex(NSData *data);
NSData *_Nullable SZFriendsSyncBytesFromHex(NSString *hex);

// Body field tags. Every body that names a conversation carries the author's own id for it (tag 1), so a device
// whose copy of that person has no key yet (an Add by ID still unanswered) still finds the conversation.
enum {
    SZFSTagConversation = 1,
    SZFSTagReleased = 2, // FILE HELD: u64 1, the author no longer holds the bytes (ADR 0016)
};

// Person field groups (the Person event's subject): each one a register of its own, so changes to different fields
// made on two devices at once both survive.
extern NSString *const SZFriendsSyncGroupRelation; // relation, the request's time and route, automatic acceptance
extern NSString *const SZFriendsSyncGroupProfile;  // their name, Friends ID and picture
extern NSString *const SZFriendsSyncGroupKeys;     // identity, static, presence and callback keys
extern NSString *const SZFriendsSyncGroupTrust;    // verified, comparison code
NSArray<NSString *> *SZFriendsSyncPersonGroups(void);

// Settings (the Setting event's subject).
extern NSString *const SZFriendsSyncSettingPresence; // our presence secret, which friends hold
extern NSString *const SZFriendsSyncSettingDevices;  // the own-devices presence secret
extern NSString *const SZFriendsSyncStateDevicesSecret; // where the store keeps the latter (sync_state)
// Which removals the secrets were last drawn after: a digest of the removed devices' keys, so a computer that was not
// the one to draw (or was away) knows the secrets it holds already follow those removals.
extern NSString *const SZFriendsSyncSettingRenewed;
extern NSString *const SZFriendsSyncStateRenewed;
// The presence secret this device last drew (and told friends), and whether sync has since replaced it with another
// device's draw, which friends must then hear from here too (-takePresenceSecretRetell).
extern NSString *const SZFriendsSyncStatePresenceDrawn;
extern NSString *const SZFriendsSyncStatePresenceRetell;

// Which conversation an event is about, as every device can name it: "you", "k:<root key hex>" or "c:<conversation>".
NSString *SZFriendsSyncRefForPerson(SZFriendsPersonRecord *person);

// Register keys, by this device's own conversation id.
NSString *SZFriendsSyncPersonKey(NSString *conversationID, NSString *group);
NSString *SZFriendsSyncReadKey(NSString *conversationID);

// Last writer wins: whether (lamport, author) is later than what the register holds (absent: always).
BOOL SZFriendsSyncIsLater(uint64_t lamport, NSData *author, SZFriendsSyncRegister *_Nullable current);

// Bodies (SZFriendsSyncBodies.m). Encoders give the exact bytes the register keeps for comparison; `full` adds what a
// body carries beyond it (a photo's bytes, where the register keeps its hash).
NSData *SZFriendsSyncPersonGroupBody(SZFriendsPersonRecord *person, NSString *group, BOOL full);
// Applies a group's fields to `person` (not saved). NO when the body is malformed. `photo` receives a photo's bytes.
BOOL SZFriendsSyncApplyPersonGroup(SZFriendsSyncFields *fields, NSString *group, SZFriendsPersonRecord *person,
                                   NSData *_Nullable *_Nullable photo);
NSData *SZFriendsSyncItemBody(SZFriendsItemRecord *item);
SZFriendsItemRecord *_Nullable SZFriendsSyncItemFromBody(SZFriendsSyncFields *fields, NSString *itemID);
NSData *SZFriendsSyncReadBody(NSString *conversationID, NSDate *receivedAt, NSString *itemID);
NSData *SZFriendsSyncOutboxBody(SZFriendsOutboxEntry *entry);
SZFriendsOutboxEntry *_Nullable SZFriendsSyncOutboxFromBody(SZFriendsSyncFields *fields, NSString *entryID);
// In-flight states fold into Queued: they are one device's session, not the message's fate.
SZFriendsOutboxState SZFriendsSyncOutboxFoldedState(SZFriendsOutboxState state);
NSData *SZFriendsSyncFileBody(SZFriendsSyncFileRecord *file);
SZFriendsSyncFileRecord *_Nullable SZFriendsSyncFileFromBody(SZFriendsSyncFields *fields, NSString *transferID);
SZFriendsSyncFileRecord *SZFriendsSyncFileFromTransfer(SZFriendsTransferRecord *transfer, NSString *_Nullable itemID);
// Delivered and received files and delivered messages stay so, whatever a later clock says.
BOOL SZFriendsSyncFileStateIsFinal(SZFriendsTransferState state);
NSData *SZFriendsSyncProfileBody(SZFriendsStore *store, BOOL full);

@interface SZFriendsSyncEngine ()
@property(nonatomic, readonly) NSMutableSet<NSString *> *changedConversations;
@property(nonatomic) BOOL profileChanged;
// Applied tombstones: [scope, vector], loaded on first use and kept up to date.
@property(nonatomic, strong, nullable) NSArray<NSArray *> *tombstones;
- (nullable NSData *)ownRootKey;
// Our chain's devices from the store's index (authorized first, the first device first).
- (NSArray<SZFriendsDeviceRecord *> *)ownDevices;
// What the device index says of our chain: changes whenever a device is added, revoked or renamed.
- (NSData *)ownChainFingerprint;
// The next event reads its sequence number and clock from the log again.
- (void)resetCounters;
// Signs and appends one event of ours (inside the caller's transaction), with the next sequence number and clock.
- (nullable SZFriendsSyncEvent *)recordKind:(SZFriendsSyncKind)kind
                                      scope:(NSString *)scope
                                    subject:(NSString *)subject
                                       body:(NSData *)body
                                      error:(NSError **)error;
// This device's conversation for an event's scope and the conversation id its author used; nil when not here yet.
- (nullable NSString *)conversationForScope:(NSString *)scope authorConversation:(nullable NSString *)conversation;
- (void)noteChangedConversation:(nullable NSString *)conversationID;
- (void)flushChanges;
// What we hold of the devices whose events we pass on (authorized or removed): a void device's events are not offered.
- (SZFriendsSyncVector *)offeredVector;
@end

typedef NS_ENUM(NSInteger, SZFriendsSyncApplyResult) {
    SZFriendsSyncApplyDone = 0,   // applied, or nothing to do: mark it applied
    SZFriendsSyncApplyWait = 1,   // needs something not here yet; try again later
    SZFriendsSyncApplyFailed = 2, // a store error; try again later
};

@interface SZFriendsSyncEngine (Apply)
- (SZFriendsSyncApplyResult)applyEvent:(SZFriendsSyncEvent *)event;
// Whether an applied tombstone covers this event in this conversation.
- (BOOL)tombstoneCovers:(SZFriendsSyncEvent *)event conversation:(NSString *)conversationID;
- (BOOL)applyTombstone:(SZFriendsSyncEvent *)event;
- (void)recountUnreadInConversation:(NSString *)conversationID;
@end

@interface SZFriendsSyncEngine (Capture)
- (NSUInteger)captureChanges;
@end

// SZFriendsSyncRevocation.m.
@interface SZFriendsSyncEngine (Revocation)
// For each device of `revoked`: the highest sequence number of its events we accept, from the records held and those
// in `events` (a record counts only from the device that signed that revocation). Absent: none of its events.
- (NSDictionary<NSData *, NSNumber *> *)revocationCoverageWithEvents:(NSArray<SZFriendsSyncEvent *> *)events
                                                              revoked:(NSSet<NSData *> *)revoked;
- (SZFriendsSyncApplyResult)applyRevocation:(SZFriendsSyncEvent *)event;
// The own-devices secret becomes `secret`; the one it replaces joins -previousOwnDevicesSecrets.
- (BOOL)replaceOwnDevicesSecret:(NSData *)secret;
@end

// SZFriendsSyncPurge.m.
@interface SZFriendsSyncEngine (Purge)
// A removed device's events past `covered`, which reached this device before the removal record did: gone from the
// log, the items only they brought gone (as erased history goes), and every value one of them last wrote worked out
// again from the events that remain. NO on a store failure (the record applies again later).
- (BOOL)dropEventsOfDevice:(NSData *)deviceKey after:(uint64_t)covered;
@end

NS_ASSUME_NONNULL_END
