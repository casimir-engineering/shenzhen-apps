// Shenzhen Friends store: friends, conversations, messages, settings and local search in one SQLite file.
//
// Helper-only, single writer. <state dir>/friends.sqlite in WAL mode holds friends, conversations, messages,
// the outbox, transfers, the chosen name, automatic-acceptance choices and the FTS index (brief § Storage).
// Versioned forward-only migrations; crash recovery by transaction. Nothing outside the helper opens the file:
// apps ask the helper over the client protocol.
//
// Search uses FTS5's trigram tokenizer, which segments Chinese where the default tokenizer does not, plus a
// substring scan for one- and two-character queries (trigrams need three), so 合同 finds 合同.
//
// ADR 0003 is the decision (schema v1, pragmas, FTS probe, migrations with min_reader_version, crash recovery,
// durable progress, deletes); this header is its interface. Outbox (SZFriendsOutbox.h) and transfers
// (SZFriendsTransfers.h) live beside this header and share the file. Link with -lsqlite3 (system SQLite).

#import <Foundation/Foundation.h>

#import "avatars/SZFriendsAvatars.h"

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const SZFriendsStoreErrorDomain;

typedef NS_ERROR_ENUM(SZFriendsStoreErrorDomain, SZFriendsStoreError) {
    SZFriendsStoreErrorOpenFailed = 1,
    // A newer helper raised min_reader_version above this helper's schema: leave the file alone and tell clients
    // an update is needed (list banner update_required), never downgrade it.
    SZFriendsStoreErrorNewerSchema = 2,
    SZFriendsStoreErrorMigrationFailed = 3,
    SZFriendsStoreErrorNotFound = 4,
    SZFriendsStoreErrorConstraint = 5,
    SZFriendsStoreErrorDiskFull = 6,
    SZFriendsStoreErrorDatabase = 7,           // any other SQLite failure (I/O, corruption); logged with its code
    SZFriendsStoreErrorFileMissing = 8,        // a path does not exist or is not a readable regular file
    SZFriendsStoreErrorFolderNotSupported = 9, // a path is a folder
    SZFriendsStoreErrorSourceChanged = 10,     // a bound revision no longer matches its file
    SZFriendsStoreErrorStale = 11,             // the offer or request changed state meanwhile; nothing was done
    SZFriendsStoreErrorInvalid = 12,           // a malformed value: bad id, wrong key length, out-of-order chunk
    SZFriendsStoreErrorDigestMismatch = 13,    // received bytes did not match the offer; the partial file is gone
    // A save would have changed a person's identity key, or their static key outside the reviewed path
    // (-acceptPendingStaticKeyForConversation:). Identity keys never change (ADR 0001): another key is another person.
    SZFriendsStoreErrorKeyChangeRefused = 14,
};

// The PROTOCOL.md § Replies and errors code the helper sends for a store error ("disk_full", "file_missing",
// "folder_not_supported", "source_changed", "stale", "not_found", "invalid_field"), or "internal". The words the
// person reads come from the presentation catalog; store errors carry log text only.
NSString *SZFriendsStoreProtocolErrorCode(NSError *_Nullable error);

// A new opaque identifier: 32 lowercase hex digits of 128 random bits. Used for conversation, item, outbox entry and
// transfer ids that this Mac issues; it satisfies PROTOCOL.md's id rule ([A-Za-z0-9_-], at most 64 bytes).
NSString *SZFriendsNewIdentifier(void);

// The newest schema this code writes (PRAGMA user_version). v1 is ADR 0003's schema; v2 adds what the M1 security
// reviews asked for (pending static keys, Add by ID answers, case-insensitive transfer ids); v3 what the wave-3
// re-check did (when a waiting request began, host attestations of Friends IDs); v4 marks what the assistant sent and
// keeps the ID an unconfirmed Add by ID answer was for; v5 marks messages the person cancelled
// (SZFriendsStoreSchema.m).
extern const NSInteger SZFriendsStoreSchemaVersion;
extern const NSUInteger SZFriendsIDRequestMaxPending;    // 4 (ADR 0004 step 3)
extern const NSTimeInterval SZFriendsIDRequestLifetime;  // 7 days
// Distinct identity keys one Add by ID token admits (security review: anyone who hears the broadcast can answer it,
// so a token must not open the door to an unbounded number of strangers).
extern const NSUInteger SZFriendsIDRequestMaxAnswers;    // 3
// Of those, how many may go to keys without a host attestation (the -...attested: forms below): 2.
extern const NSUInteger SZFriendsIDRequestMaxUnattestedAnswers;
// A friend request nobody answered lapses after 14 days (-expireIncomingRequestsAtDate:error:): until answered, the
// requester's key is one the helper knows, so the wait must end (wave-3 security re-check, key policy).
extern const NSTimeInterval SZFriendsIncomingRequestLifetime;
// A friend request we sent to someone visible nearby lapses after 7 days unanswered (-expireOutgoingRequestsAtDate:):
// until then their key may reach our hidden listener to answer, and that must not last for ever (wave-4 re-check).
extern const NSTimeInterval SZFriendsOutgoingRequestLifetime;
// Longest attestation the store keeps, in bytes: room for the signed fields and a signature, not for a payload.
extern const NSUInteger SZFriendsAttestationMaxLength;   // 1024

#pragma mark - Records

typedef NS_ENUM(NSInteger, SZFriendsRelation) {
    SZFriendsRelationIncomingRequest = 0, // they asked; waiting for this person's answer
    SZFriendsRelationOutgoingRequest = 1, // we asked; waiting for theirs
    SZFriendsRelationFriend = 2,
    SZFriendsRelationRemoved = 3,         // history kept; either side may send a new request
    SZFriendsRelationBlocked = 4,         // cannot reconnect or send offers until unblocked
};

// One person and their one conversation. The conversation id is the person's handle everywhere in Friends.
// A person is identified by their Ed25519 identity key alone (ADR 0001 § Keys): a known Friends ID arriving with
// another key is a stranger, never this person.
@interface SZFriendsPersonRecord : NSObject <NSCopying>
@property(nonatomic, copy) NSString *conversationID;   // opaque, [A-Za-z0-9_-], <= 64 bytes
// Ed25519, 32 bytes, UNIQUE. Nil only for an outgoing request by ID nobody has answered yet. Once set it never
// changes: -savePerson: refuses (KeyChangeRefused), because another identity key is always another person.
@property(nonatomic, copy, nullable) NSData *identityKey;
// X25519 Noise static key from their certificate, 32 bytes: what IK dials. Nil until a handshake revealed it. Once
// set it changes only through the reviewed path below (-notePresentedStaticKey:..., then
// -acceptPendingStaticKeyForConversation:); -savePerson: refuses any other change.
@property(nonatomic, copy, nullable) NSData *staticKey;
// A different static key this person presented, certified by their same identity key, waiting for the person's
// review. Filled on reads; -savePerson: never writes it (and clears it when it saves keyChangePending off).
@property(nonatomic, copy, nullable) NSData *pendingStaticKey;
@property(nonatomic, copy, nullable) NSString *friendsID; // last one they told us; display and requests only
@property(nonatomic, copy, nullable) NSString *name;   // nil until they choose one; friends then see the ID
@property(nonatomic, copy) SZFriendsPicture *picture;
@property(nonatomic) SZFriendsRelation relation;
// Six digits from the code exchange in the session that created the friendship, kept so the codes can be
// compared later (details view). Nil for a QR add, which is verified by the key itself.
@property(nonatomic, copy, nullable) NSString *comparisonCode;
@property(nonatomic) BOOL verified;
@property(nonatomic, copy, nullable) NSDate *verifiedAt;
@property(nonatomic) BOOL autoAccept;                  // per friend, off by default; cleared on key change and block
@property(nonatomic) BOOL keyChangePending;            // a new key was presented; needs explicit review
@property(nonatomic, copy, nullable) NSData *presenceSecret; // theirs (32 bytes): we match their presence tags
// Incoming Add by ID only (ADR 0004 step 4): the requester's 16-byte token, which our IK callback presents after
// Accept, and their 32-byte callback secret, whose tags tell us they are nearby. Cleared once delivered.
@property(nonatomic, copy, nullable) NSData *callbackToken;
@property(nonatomic, copy, nullable) NSData *callbackSecret;
@property(nonatomic, copy) NSDate *lastInteractionAt;  // message, file, request or acceptance; sorts the list
@property(nonatomic) NSInteger unreadCount;
@property(nonatomic, copy, nullable) NSDate *requestAt; // the card's "asked ..." time; asking again refreshes it
@property(nonatomic) BOOL requestFoundNearby;          // nearby versus by Friends ID, for the request card
// When the request now waiting began, in either direction; nil unless the relation is IncomingRequest or
// OutgoingRequest. Filled on reads; -savePerson: ignores it: it starts the request at requestAt (never later than the
// save) when the person becomes a request, and keeps it while they stay one, so a repeated request cannot move it.
// The helper's IK window for someone whose request waits, and SZFriendsIncomingRequestLifetime, count from it.
@property(nonatomic, copy, nullable) NSDate *pendingRequestSince;
// The host's word that this identity key holds friendsID (an Add by ID answer presenting its check-in attestation,
// which the helper verified against the pinned host keys). Filled on reads; -savePerson: ignores all three, and
// -confirmFriendsID:... writes them. Confirmed only while friendsID is still the ID the attestation covers: a PROFILE
// naming another ID voids it, and the attestation and its day then read back nil too.
@property(nonatomic) BOOL friendsIDConfirmed;
@property(nonatomic, copy, nullable) NSData *friendsIDAttestation;      // the host's bytes; opaque to the store
@property(nonatomic, copy, nullable) NSString *friendsIDAttestationDay; // the day it covers, YYYY-MM-DD (host's)
// The Friends ID our Add by ID asked for, on a row whose answer the host did not confirm and which waits for the
// person's acceptance as an IncomingRequest (wave-4 re-check: an unattested ACCEPT is a card, not a friendship).
// Saved only with relation IncomingRequest and read back nil for any other relation, so moving on voids it.
@property(nonatomic, copy, nullable) NSString *unconfirmedAnswerID;
// When the person took this someone off their list (remove_friend): the row and its history stay, but no list shows
// them. Saved only with relation Removed or Blocked and read back nil for any other, so a new request from either
// side, an acceptance or an Add by ID brings them back.
@property(nonatomic, copy, nullable) NSDate *leftListAt;
@end

// An Add by ID this person sent (ADR 0004 steps 1 and 3; table id_requests). Pending until someone answers: it is
// offered to each newly seen device and its callback tags are advertised. Answered after the first IK callback, it
// is no longer offered or advertised but its token still admits up to SZFriendsIDRequestMaxAnswers distinct keys
// until it expires, so a second holder of an unreserved ID can still answer (brief § Friends ID).
@interface SZFriendsIDRequestRecord : NSObject <NSCopying>
@property(nonatomic, copy) NSString *conversationID; // the outgoing request row in the list
@property(nonatomic, copy) NSString *targetFriendsID;
@property(nonatomic, copy) NSData *requestToken;     // 16 random bytes; the holder's IK callback presents it
@property(nonatomic, copy) NSData *callbackSecret;   // 32 random bytes; callback tags derive from it
@property(nonatomic, copy) NSDate *createdAt;
@property(nonatomic, copy) NSDate *expiresAt;        // createdAt + 7 days
// Filled on reads; -saveIDRequest: ignores both. Nil and 0 while pending.
@property(nonatomic, copy, nullable) NSDate *answeredAt; // the first answering key's callback
@property(nonatomic) NSUInteger answeringKeyCount;       // distinct identity keys admitted with the token
@end

typedef NS_ENUM(NSInteger, SZFriendsDirection) {
    SZFriendsDirectionIncoming = 0,
    SZFriendsDirectionOutgoing = 1,
};

typedef NS_ENUM(NSInteger, SZFriendsItemKind) {
    SZFriendsItemKindMessage = 0,
    SZFriendsItemKindTransfer = 1, // one file offer and its whole life; SZFriendsTransferRecord has the detail
    SZFriendsItemKindEvent = 2,    // "You are now friends", key changed, declined, cancelled...
};

// One entry in a conversation's history. Display order is sender timestamp, then id (brief § Session protocol).
@interface SZFriendsItemRecord : NSObject <NSCopying>
@property(nonatomic, copy) NSString *itemID;     // message id (random 128-bit from the sender, hex) or local id
@property(nonatomic, copy) NSString *conversationID;
@property(nonatomic) SZFriendsItemKind kind;
@property(nonatomic) SZFriendsDirection direction;
@property(nonatomic, copy) NSDate *sentAt;       // sender's timestamp, clamped to receivedAt (ADR 0001 § Messages)
@property(nonatomic, copy) NSDate *receivedAt;   // when this Mac stored it; equals sentAt for outgoing items
@property(nonatomic, copy, nullable) NSString *text;           // messages
@property(nonatomic, copy, nullable) NSString *transferID;     // transfers
@property(nonatomic, copy, nullable) NSString *eventKind;      // events: stable key into the strings catalog
@property(nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> *eventArguments;
// The assistant sent this message or file for one of the two people (PROTOCOL.md via_assistant): either side's.
@property(nonatomic) BOOL viaAssistant;
// Filled on reads from the outbox entry that delivers this item, so a snapshot needs one query; ignored on insert.
// -1 when nothing of ours is in flight for it (incoming items, events).
@property(nonatomic) NSInteger outboxState;                    // SZFriendsOutboxState or -1
@property(nonatomic, copy, nullable) NSString *outboxFailureReason; // SZFriendsOutboxFailure... when Failed
// That entry was written to a session at least once (its attempts): queued again after the session dropped, it may
// already be on the friend's Mac, so it can no longer be cancelled.
@property(nonatomic) BOOL outboxWritten;
// The person withdrew this outgoing message before it left (-[SZFriendsOutbox cancelMessage:...]); it has no outbox
// entry any more. Read from the store; ignored on insert, since nothing is cancelled before it was queued.
@property(nonatomic) BOOL cancelled;
@end

#pragma mark - Search

@interface SZFriendsSearchHit : NSObject
@property(nonatomic, readonly) NSString *conversationID;
@property(nonatomic, readonly) NSString *itemID;
@property(nonatomic, readonly) SZFriendsItemKind kind;     // Message, or Transfer for a file name
@property(nonatomic, readonly) NSDate *sentAt;
@property(nonatomic, readonly) SZFriendsDirection direction;
@property(nonatomic, readonly) NSString *text;             // full text of the matching message or file name
@property(nonatomic, readonly) NSArray<NSValue *> *matchRanges; // NSRange values into `text`
@end

// A bounded excerpt of `text` for a result row or an assistant tool (PROTOCOL.md § Limits: 280 characters): at
// most `maxLength` UTF-16 units including the "…" marking each cut, centred on the first match, never splitting a
// composed character, with line breaks shown as spaces. `excerptRanges` receives the match ranges that fall inside
// it, shifted into the excerpt.
NSString *SZFriendsSearchExcerpt(NSString *text, NSArray<NSValue *> *matchRanges, NSUInteger maxLength,
                                 NSArray<NSValue *> *_Nullable *_Nullable excerptRanges);

#pragma mark - Store

@interface SZFriendsStore : NSObject
// Opens (creating and migrating as needed) <stateDirectory>/friends.sqlite, 0600 inside a 0700 directory. Callers
// never touch SQLite: methods may be called from any thread; writes run on the store's own serial queue (the
// single writer, shared with the outbox and transfers) and reads on a read-only connection, so a snapshot or a
// search never waits behind a commit. Opening also returns outbox entries left Connecting or Sending to Queued.
+ (nullable instancetype)storeInDirectory:(NSString *)stateDirectory error:(NSError **)error;
@property(nonatomic, readonly) NSInteger schemaVersion; // of the file, which may be newer than this code's
- (void)close;

// People, newest interaction first: the Friends list order.
- (NSArray<SZFriendsPersonRecord *> *)peopleByLatestInteraction;
- (nullable SZFriendsPersonRecord *)personWithConversationID:(NSString *)conversationID;
// By identity key, which is the person's root key; or by the device key of any device their chain authorizes
// (SZFriendsStoreDevices.h). A revoked device finds nobody, unless it is the root itself: ask -isRevokedDeviceKey:.
- (nullable SZFriendsPersonRecord *)personWithIdentityKey:(NSData *)identityKey;
// Inserts or updates by conversation id; an empty conversationID gets a new SZFriendsNewIdentifier(), written back
// into `person`. Rules enforced here rather than trusted to callers:
//   - a stored identity key never changes, and a stored static key changes only through the reviewed path below:
//     a save that would change either (or clear it) is refused with KeyChangeRefused and changes nothing. Setting a
//     key where none is stored (the first handshake, an Add by ID callback) is allowed;
//   - automatic acceptance is stored off whenever the person is blocked or has a key change pending;
//   - the unread count of an existing person is kept (-insertItem: and -markConversationRead: own it), and the
//     latest interaction never moves backwards, so saving a stale copy cannot lose an arriving message;
//   - key, secret and token lengths are checked (Invalid), and an identity key held by someone else is Constraint.
- (BOOL)savePerson:(SZFriendsPersonRecord *)person error:(NSError **)error;

// The reviewed path for a static key change (ADR 0001 § Keys; brief: a key change needs explicit review and is never
// accepted silently). A known person whose handshake presents another static key: when `certificate` (their
// identity key || signature, SZFriendsIdentity staticCertificate) verifies for `staticKey` and names this
// conversation's identity key, the key is kept as pendingStaticKey and keyChangePending is set, which turns
// automatic acceptance off; IK keeps dialing the old key. A certificate naming any other identity key is a stranger,
// never this person: KeyChangeRefused, nothing stored. The stored static key itself presented again is a no-op.
// NotFound for an unknown conversation; Invalid for a person with no identity key or a malformed key.
- (BOOL)notePresentedStaticKey:(NSData *)staticKey
                   certificate:(NSData *)certificate
               forConversation:(NSString *)conversationID
                         error:(NSError **)error;
// The person accepted the change (accept_key_change): the pending key becomes the one IK dials, keyChangePending
// clears, and nothing the old key earned carries over (verified and automatic acceptance off). Stale when no key is
// pending.
- (BOOL)acceptPendingStaticKeyForConversation:(NSString *)conversationID error:(NSError **)error;

// History. `limit` items ending at (and including) `beforeItemID`, or the newest when nil, oldest first.
- (NSArray<SZFriendsItemRecord *> *)itemsInConversation:(NSString *)conversationID
                                            beforeItemID:(nullable NSString *)beforeItemID
                                                   limit:(NSUInteger)limit
                                              hasEarlier:(nullable BOOL *)hasEarlier;
// The item and up to `before` items before and `after` items after it, oldest first: assistant_read and a search
// result opening at its message. Nil when the item is not in that conversation.
- (nullable NSArray<SZFriendsItemRecord *> *)itemsInConversation:(NSString *)conversationID
                                                    aroundItemID:(NSString *)itemID
                                                          before:(NSUInteger)before
                                                           after:(NSUInteger)after;
// One item, or nil when it is not in that conversation (the delivery layer building a MSG frame for an entry).
- (nullable SZFriendsItemRecord *)itemWithID:(NSString *)itemID inConversation:(NSString *)conversationID;
// Idempotent by (sender identity key, item id): a duplicate delivery returns YES and changes nothing, so the
// recipient can acknowledge only after this commit and retries never duplicate (brief § Outbox and delivery).
// Item ids are unique within a conversation whatever the direction, so an id always names one item. Incoming
// sentAt is clamped to receivedAt; a new incoming message or file raises the unread count, and every new item
// moves the person's latest interaction to its receivedAt.
- (BOOL)insertItem:(SZFriendsItemRecord *)item error:(NSError **)error;
- (BOOL)markConversationRead:(NSString *)conversationID error:(NSError **)error;

// Local search; never touches the network. `conversationIDs` nil means every conversation; an empty array
// means none (the assistant's scope is enforced by passing exactly the scoped ids).
- (NSArray<SZFriendsSearchHit *> *)searchFor:(NSString *)query
                             conversationIDs:(nullable NSArray<NSString *> *)conversationIDs
                                       limit:(NSUInteger)limit;

// The local profile: the name friends see (nil until chosen), picture, Friends ID and its reservation state.
@property(nonatomic, copy, nullable) NSString *profileName;
@property(nonatomic, copy) SZFriendsPicture *profilePicture;
@property(nonatomic, copy, nullable) NSString *friendsID;
@property(nonatomic) NSInteger friendsIDState;          // SZFriendsIDState from SZFriendsIdentity.h
// For the one-time "Your ID changed" notice; set to nil by `dismiss_banner`.
@property(nonatomic, copy, nullable) NSString *previousFriendsID;
// Reservation collisions in a row (ADR 0006): three or more means draw three-word IDs from then on, so once the
// stored count reaches three a lower value is ignored (only Reset clears it).
@property(nonatomic) NSUInteger idCollisionsInARow;

// Helper-wide settings (table settings), shared by every app that hosts Friends.
// Whether Nearby permissions were requested: adapters start at launch only once the user has been asked.
@property(nonatomic) BOOL nearbyPermissionsRequested;
// ADR 0018 § 1, settings key transfers.fast: fast transfers on unless it holds 0. No app shows it; it is the way
// back for a release. Read as the helper starts.
@property(nonatomic, readonly) BOOL fastTransfersEnabled;
// Our 32-byte presence secret, sent to each friend on acceptance; replaced on every remove or block (ADR 0004).
@property(nonatomic, copy, nullable) NSData *ownPresenceSecret;
// Absolute end of the person's 5 minutes of public visibility, or nil. Stored so a restart, sleep or a second
// app can never extend it; the helper stops visibility at once when it finds this in the past. While a stored
// deadline is still ahead, a later one is ignored (start_visibility repeated does not extend it); nil or an
// earlier date always applies.
@property(nonatomic, copy, nullable) NSDate *visibilityDeadline;

// Explicit delete actions. History deletion removes messages, transfer records, the outbox entries delivering them
// and their index rows, the private copies those transfers held (outgoing snapshots, partial downloads) and the
// pre-migration backups, then rebuilds the index, VACUUMs and truncates the WAL so the text does not survive in
// free pages; it keeps friends, keys and the files in received/. Reset is the helper's job (it also deletes the
// identity and releases the ID on the host) and calls -deleteEverythingExceptReceivedFilesWithError:, which empties
// every table and removes pictures/, outgoing/, received/.partial/ and the backups, leaving an empty store open.
- (BOOL)deleteHistoryInConversation:(nullable NSString *)conversationID error:(NSError **)error;
- (BOOL)deleteEverythingExceptReceivedFilesWithError:(NSError **)error;
@end

@interface SZFriendsStore (AddByID)
// Add by ID requests this person sent. At most 4 pending (unanswered): -saveIDRequest: refuses a fifth
// (Constraint), which the helper answers with rate_limited; answered requests do not count, since they no longer
// advertise callback tags. Expired requests no longer count, are dropped on the next save, and are never returned:
// an expired token admits nobody. expiresAt is clamped to createdAt + 7 days. Saving a new token for a conversation
// replaces its request and forgets who answered the old one.
// Pending requests (unexpired, unanswered): what the helper offers to new devices and whose callback tags it
// advertises.
- (NSArray<SZFriendsIDRequestRecord *> *)pendingIDRequestsAtDate:(NSDate *)now;
// Any unexpired request with this token, answered or not.
- (nullable SZFriendsIDRequestRecord *)idRequestWithToken:(NSData *)requestToken;
- (nullable SZFriendsIDRequestRecord *)idRequestWithToken:(NSData *)requestToken atDate:(NSDate *)now;
- (BOOL)saveIDRequest:(SZFriendsIDRequestRecord *)request error:(NSError **)error;
// add_by_id: the "Request sent" row and its request in one transaction, so a refused fifth request (Constraint)
// leaves no row behind. The row never holds a key. The newest keyless row with this Friends ID that is waiting or was
// withdrawn (OutgoingRequest or Removed) is reused, else a new one is made; a row holding an identity key is never
// reused, whatever Friends ID it last told us: that person may no longer hold the ID, and making their row a request
// again would let their key back in by IK before anyone answered (wave-3 security re-check, key change handling). If
// that same key answers, -conversationForIDRequestAnswerWithToken:... gives them their own row back. The row is
// stamped request.createdAt; request.conversationID is set to it, and returned.
- (nullable NSString *)startIDRequest:(SZFriendsIDRequestRecord *)request error:(NSError **)error;
- (BOOL)deleteIDRequestForConversation:(NSString *)conversationID error:(NSError **)error;
// A pure read for the listener's key policy, which must not write before the session is live: YES when the token
// names an unexpired request, `identityKey` is not blocked, and that key already answered it or fewer than
// SZFriendsIDRequestMaxAnswers distinct keys have.
- (BOOL)idRequestWithToken:(NSData *)requestToken admitsIdentityKey:(NSData *)identityKey atDate:(NSDate *)now;
// An IK callback presenting a token went live (ADR 0004 step 4): which conversation it belongs to, decided and
// recorded in one transaction, so a crash cannot admit a key twice or lose one.
//   - the same key answering again returns the conversation it got the first time;
//   - a known person with this key (not blocked) keeps their conversation: the same key answers, so its row is reused.
//     If they hold the ID asked for (the last Friends ID they told us, or an attested answer below), it is their row
//     coming back: a request row still keyless folds into theirs (the request, its outbox entries and any history
//     move; the empty row goes), so they stay one row and the returned id is not the one add_by_id gave; and a
//     removed person becomes an outgoing request again, as that row was, so their answer lands, without the
//     comparison code or automatic acceptance their old friendship had. Otherwise nothing about them changes;
//   - otherwise the request's own row takes the key if it has none yet ("Request sent" learns who answered);
//   - otherwise (the row already holds another key) a new conversation is made for this key, an outgoing request
//     to the requested Friends ID: a different identity key is always a different person, never merged;
//   - each new key counts toward SZFriendsIDRequestMaxAnswers (Constraint beyond it), and the request becomes
//     answered: no longer offered or advertised, still admitting its token until it expires.
// NotFound for an unknown or expired token, Invalid for a blocked key or malformed keys.
- (nullable NSString *)conversationForIDRequestAnswerWithToken:(NSData *)requestToken
                                                   identityKey:(NSData *)identityKey
                                                     staticKey:(NSData *)staticKey
                                                        atDate:(NSDate *)now
                                                         error:(NSError **)error;
// The same two with the attestation phase (wave-3 re-check, Add by ID): `attested` says the answering key presented a
// host attestation, checked by the helper, for the requested ID and that key. Keys without one may take at most
// SZFriendsIDRequestMaxUnattestedAnswers of the slots, so the last stays for a holder the host vouches for and three
// throwaway keys from one stranger can no longer lock the real holder out. The forms above let any key take every
// slot, as before attestations; the helper moves to these once its callbacks carry them.
- (BOOL)idRequestWithToken:(NSData *)requestToken
         admitsIdentityKey:(NSData *)identityKey
                  attested:(BOOL)attested
                    atDate:(NSDate *)now;
- (nullable NSString *)conversationForIDRequestAnswerWithToken:(NSData *)requestToken
                                                   identityKey:(NSData *)identityKey
                                                     staticKey:(NSData *)staticKey
                                                      attested:(BOOL)attested
                                                        atDate:(NSDate *)now
                                                         error:(NSError **)error;
@end

@interface SZFriendsStore (Requests)
// Friend requests nobody answered for SZFriendsIncomingRequestLifetime, counted from pendingRequestSince, lapse: the
// helper calls this at start and from a timer. A row that holds nothing but the request (no history, transfers or
// outbox entries) is deleted, with its picture file once no other row or the profile uses it; any other row (a former
// friend asking again) becomes Removed with its history kept. Either way the requester's key stops being one the
// helper accepts, their callback token and secret are dropped, and either side may ask again. Returns the lapsed
// people as they were before (empty when none), or nil with an error and nothing changed.
- (nullable NSArray<SZFriendsPersonRecord *> *)expireIncomingRequestsAtDate:(NSDate *)now error:(NSError **)error;
// Requests we sent that can no longer be answered lapse the same way (wave-4 security re-check): one to someone found
// nearby after SZFriendsOutgoingRequestLifetime from pendingRequestSince, and an Add by ID row once no unexpired
// request of ours names it or was answered by its key (a keyless "Request sent" row whose request expired, or the row
// of a key whose answer slot expired with the request). A row holding no history or transfers is deleted, with its
// queued request; any other becomes Removed with its history kept. Returns the lapsed people as they were.
- (nullable NSArray<SZFriendsPersonRecord *> *)expireOutgoingRequestsAtDate:(NSDate *)now error:(NSError **)error;
// For the listener's key policy, a pure read: YES while an unexpired Add by ID request of ours admitted this identity
// key, which is how long an answer from it may still arrive over IK.
- (BOOL)identityKeyAnswersUnexpiredIDRequest:(NSData *)identityKey atDate:(NSDate *)now;
@end

@interface SZFriendsStore (Assistant)
// An incoming OFFER that said the friend's assistant sent it: marks the history item the transfer area recorded for
// it (messages carry the mark on insert). Idempotent; NotFound when that conversation has no such message or file.
- (BOOL)markItemSentByAssistant:(NSString *)itemID inConversation:(NSString *)conversationID error:(NSError **)error;
// This person's outgoing messages among `itemIDs`, each with its delivery state, in the order of `itemIDs`: the
// message_status view, which follows what an assistant sent without opening (and so reading) its conversation.
// Incoming messages, files, events and unknown ids are left out.
- (NSArray<SZFriendsItemRecord *> *)outgoingMessagesWithIDs:(NSArray<NSString *> *)itemIDs;
@end

@interface SZFriendsStore (Attestation)
// Theirs: the helper verified an attestation (the host's signature over a Friends ID, an identity key and a day)
// against the pinned host keys, and it names this person's identity key. Stores it and sets friendsID to the ID it
// covers, which makes friendsIDConfirmed YES. The store cannot check the signature; it checks the shape: an ID of 1
// to 64 bytes, a day written YYYY-MM-DD, 1 to SZFriendsAttestationMaxLength bytes (Invalid otherwise, or for a person
// with no identity key yet). NotFound for an unknown conversation.
- (BOOL)confirmFriendsID:(NSString *)friendsID
             attestation:(NSData *)attestation
                     day:(NSString *)day
         forConversation:(NSString *)conversationID
                   error:(NSError **)error;
// An attestation the helper no longer trusts (too old, or a newer one names someone else): not confirmed any more.
- (BOOL)clearFriendsIDConfirmationForConversation:(NSString *)conversationID error:(NSError **)error;
// Ours: the latest attestation a check-in returned for this Mac's Friends ID, kept so our IK callback can present it
// while the host is unreachable. Both read back nil until one is saved, and again once friendsID changes (a
// collision rename voids the old ID's attestation). Saving refuses an attestation for any ID but the current
// friendsID (Stale), so a late reply about an old ID cannot attach to a new one; shape checks as above.
@property(nonatomic, readonly, copy, nullable) NSData *friendsIDAttestation;
@property(nonatomic, readonly, copy, nullable) NSString *friendsIDAttestationDay;
- (BOOL)saveFriendsIDAttestation:(NSData *)attestation
                             day:(NSString *)day
                    forFriendsID:(NSString *)friendsID
                           error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
