// Shenzhen Friends presentation: the strings catalog and the builder of display-ready snapshots.
//
// Logic lives in the service, not the views (brief § Containment and porting). This layer turns plain facts
// into exactly the `data` objects PROTOCOL.md documents per view: rows already sorted, labels such as
// "Yesterday" or "Over Bluetooth, about 6 min", countdown text, badge counts and which buttons show. Views
// render them and nothing more, so a second toolkit reimplements drawing only.
//
// Pure: no store, radios, sockets or clock reads. Inputs are the fact objects below, which the helper fills
// from the store, discovery and sessions; time is passed in. That keeps the builder's output testable against
// the golden fixtures in portable/friends/fixtures/ byte for byte.
//
// Every user-facing string Friends shows comes from SZFriendsStrings, written for the person reading it and
// about what happens to their message ("Sends when Mei is nearby with ShenzhenPDF, Shenzhen Files or Shenzhen 3D
// open", never "Queued (no route)"). Three exceptions (PROTOCOL.md § Principles): the client library's
// connection-state lines and the host adapter's Settings checkbox and disclosure, shown while no helper runs, and the
// host's `#` picker placeholder, which names what that host offers.
//
// Tests compare the builder's output with fixtures/snapshots/*.json as parsed JSON (NSDictionary equality), not
// as bytes: dictionaries have no key order. The fixtures' clock is Monday 12 October 2026, 14:47:48 in
// Asia/Hong_Kong (UTC+8); inject it as `now` and the audience's timeZone.

#import <Foundation/Foundation.h>

#import "avatars/SZFriendsAvatars.h"
#import "service/discovery/SZFriendsDiscovery.h"

NS_ASSUME_NONNULL_BEGIN

@class SZFriendsDevicesFacts;

#pragma mark - Who the snapshot is for

// The parts of a client's hello that change wording. Each connection gets snapshots written for its own app.
@interface SZFriendsAudience : NSObject
@property(nonatomic, copy) NSString *appName;   // "ShenzhenPDF": "...the next time ShenzhenPDF reaches..."
@property(nonatomic, copy) NSString *revealIn;  // "Finder": "Show in Finder"
@property(nonatomic, copy) NSString *locale;    // M1 ships English only; reserved for translations
@property(nonatomic, copy) NSSet<NSString *> *capabilities; // e.g. "assistant.drafts" adds "/ Ask the assistant"
@property(nonatomic, copy) NSSet<NSString *> *openFormats;  // received files in these formats offer Open
@property(nonatomic, copy) NSTimeZone *timeZone;
// What the helper announces in this client's welcome (PROTOCOL.md § Capabilities). "online" lets the words say
// Online, Connecting and "online or nearby"; without it (an M1 build) nothing a snapshot says mentions the Internet.
@property(nonatomic, copy) NSSet<NSString *> *helperCapabilities;
@end

#pragma mark - Facts (inputs)

typedef NS_ENUM(NSInteger, SZFriendsPersonRelation) {
    SZFriendsPersonRelationIncomingRequest = 0,
    SZFriendsPersonRelationOutgoingRequest = 1,
    SZFriendsPersonRelationFriend = 2,
    SZFriendsPersonRelationRemoved = 3,
    SZFriendsPersonRelationBlocked = 4,
};

// Where online attempts toward a friend stand, from the online driver. Shown only to an audience whose helper announces
// "online", and only while no session is up: a live session's route says how the friend is connected.
typedef NS_ENUM(NSInteger, SZFriendsOnlineReach) {
    SZFriendsOnlineReachUnknown = 0,     // no attempt has run since the last network change, or online is off
    SZFriendsOnlineReachConnecting = 1,  // an attempt toward or from this friend is running (direct, then the relay)
    SZFriendsOnlineReachUnreachable = 2, // the last attempt failed, relay included, and is backing off
};

@interface SZFriendsPersonFacts : NSObject
@property(nonatomic, copy) NSString *conversationID;
@property(nonatomic, copy, nullable) NSString *name;      // nil: the Friends ID is the title
@property(nonatomic, copy, nullable) NSString *friendsID;
// Ed25519, 32 bytes; nil for a request by ID nobody answered yet. Mentions find people by it, never by name or ID.
@property(nonatomic, copy, nullable) NSData *identityKey;
@property(nonatomic, copy) SZFriendsPicture *picture;
@property(nonatomic) SZFriendsPersonRelation relation;
@property(nonatomic) SZFriendsRouteKind routeKind;
@property(nonatomic) SZFriendsRouteMethod routeMethod;
// Kind Local with method Internet or Relay (the nearby service's live route for an online session) shows as Online.
@property(nonatomic) SZFriendsOnlineReach onlineReach;
@property(nonatomic) BOOL verified;
@property(nonatomic, copy, nullable) NSDate *verifiedAt;
// The Friends host attested that `friendsID` is reserved for this person's identity key (ADR 0005, attestation), so
// the row and details mark the ID as confirmed. Several people may answer one Add by ID; only the attested one is
// the holder. It proves the ID, not who is at the keyboard: codes still decide `verified`.
@property(nonatomic) BOOL friendsIDConfirmed;
@property(nonatomic) BOOL autoAccept;
@property(nonatomic) BOOL keyChangePending;
@property(nonatomic) NSInteger unreadCount;
@property(nonatomic) NSInteger offersWaiting;              // incoming offers waiting for this person's answer
@property(nonatomic, copy) NSDate *lastInteractionAt;
// The conversation's newest item of any kind (an event too): whether it has history at all.
@property(nonatomic, copy, nullable) NSString *lastPreviewItemID;
// The newest message or file (a file received through a link included), which a friend's list row shows, and how many
// files went together with that file: sent or received one after the other, a minute apart at most.
@property(nonatomic, copy, nullable) NSString *lastMessageItemID;
@property(nonatomic) NSInteger lastMessageFileCount;
@property(nonatomic, copy, nullable) NSDate *requestAt;
@property(nonatomic) BOOL requestFoundNearby;
// An answer to our own Add by ID that the Friends host could not confirm, waiting for the person's acceptance as an
// IncomingRequest (PROTOCOL.md § Views, conversation): the Friends ID we asked for, which the row and the request card
// name. Nil for every other row.
@property(nonatomic, copy, nullable) NSString *unconfirmedAnswerID;
// Six ASCII digits as the session derived them ("418270"); the builder groups them for display ("418 270").
// Nil until a session has run the code exchange (ADR 0001).
@property(nonatomic, copy, nullable) NSString *comparisonCode;
@property(nonatomic) NSInteger receivedFileCount;
@property(nonatomic, copy, nullable) NSString *receivedRevealPath;
// In the list only because they sent this person a file through a download link, and not a friend (relation
// Removed): the row says what they sent rather than "No longer friends", and their files offer Add.
@property(nonatomic) BOOL linkContact;
// The person took them off the list (remove_friend): no list shows them and they count for no badge, but their
// conversation and details still open, from search or a view already showing them. Only someone Removed or Blocked.
@property(nonatomic) BOOL leftList;
// Every discovery method that sees this friend nearby right now (SZFriendsRouteMethod numbers: LAN, PeerToPeerWiFi,
// Bluetooth), for the row's "found" (client capability nearby.found). Empty or nil while they are not nearby.
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *foundMethods;
@end

// Event kinds the helper records in history (store item eventKind) and the catalog words for each. The store
// keeps the string; only this layer turns it into text, so a new kind needs a catalog entry here first.
extern NSString *const SZFriendsEventNowFriends;  // "now_friends": "You are now friends"
extern NSString *const SZFriendsEventVerified;    // "verified": the person confirmed the codes match
extern NSString *const SZFriendsEventKeyChanged;  // "key_changed": the friend presented a new key
extern NSString *const SZFriendsEventKeyAccepted; // "key_accepted": the person continued with the new key
extern NSString *const SZFriendsEventBlocked;     // "blocked"
extern NSString *const SZFriendsEventUnblocked;   // "unblocked"
extern NSString *const SZFriendsEventRemoved;     // "removed": either side removed the friendship
// Links (PROTOCOL.md § Links). The first has the argument "file", the file's name.
extern NSString *const SZFriendsEventReceivedLinkFile;   // "received_through_link": "Sent you {file} through a link"
extern NSString *const SZFriendsEventAddedThroughOurLink;   // "added_through_your_link": they used our friend link
extern NSString *const SZFriendsEventAddedThroughTheirLink; // "added_through_their_link": we used theirs

typedef NS_ENUM(NSInteger, SZFriendsItemFactsKind) {
    SZFriendsItemFactsKindMessage = 0,
    SZFriendsItemFactsKindTransfer = 1,
    SZFriendsItemFactsKindEvent = 2,
};

// Get again on a file a friend sent (PROTOCOL.md § Getting a file again).
typedef NS_ENUM(NSInteger, SZFriendsAgainState) {
    SZFriendsAgainNone = 0,
    SZFriendsAgainAsked = 1, // Get again pressed: waiting for the friend, or copying
    SZFriendsAgainGone = 2,  // the friend's computer answered that it no longer has the file
};

@interface SZFriendsItemFacts : NSObject
@property(nonatomic, copy) NSString *itemID;
// Set where an item is shown away from its conversation (message_status), so its status can name the friend.
@property(nonatomic, copy, nullable) NSString *conversationID;
@property(nonatomic) SZFriendsItemFactsKind kind;
@property(nonatomic) BOOL outgoing;
@property(nonatomic, copy) NSDate *sentAt;
@property(nonatomic, copy, nullable) NSString *text;
// The assistant sent this message or file for one of the two people (via_assistant): the item names it.
@property(nonatomic) BOOL viaAssistant;
// SZFriendsOutboxState for outgoing messages, from SZFriendsItemRecord.outboxState. -1 (nothing in flight) on an
// outgoing message gives it no status at all: no word is true when the store has no record of its delivery.
@property(nonatomic) NSInteger outboxState;
// The person withdrew this outgoing message before it left (cancel_message): it says "Cancelled" and offers nothing.
@property(nonatomic) BOOL cancelled;
// Its outbox entry was written to a session at least once (SZFriendsItemRecord.outboxWritten): waiting again after the
// session dropped, it may already be on the friend's Mac, so it offers no Cancel.
@property(nonatomic) BOOL outboxWritten;
// Why a Failed item failed, as the store keys it: SZFriendsItemRecord.outboxFailureReason for a message,
// SZFriendsTransferRecord.failureReason for a transfer (an SZFriendsOutboxFailure... or SZFriendsTransferFailure...
// key). It picks the words and whether Try again shows; nil or an unknown key keeps the general "Not delivered",
// "Not sent" or "Didn't arrive". Ignored unless the item is Failed.
@property(nonatomic, copy, nullable) NSString *failureReason;
// Transfers.
@property(nonatomic, copy, nullable) NSString *transferID;
@property(nonatomic, copy, nullable) NSString *fileName;
@property(nonatomic, copy, nullable) NSString *fileExtension;
@property(nonatomic) uint64_t fileSize;
@property(nonatomic) uint64_t bytesDone;
@property(nonatomic) NSInteger transferState;               // SZFriendsTransferState
@property(nonatomic) BOOL acceptedAutomatically;
@property(nonatomic) BOOL askedBecauseDiskLow;
@property(nonatomic) SZFriendsRouteMethod transferRoute;
@property(nonatomic) double bytesPerSecond;                 // measured on the current route; 0 when unknown
// Progress by route (PROTOCOL.md § Fast transfers): bytes each route carried for this transfer (SZFriendsRouteMethod
// -> bytes; nil or empty when the helper counted none), the routes carrying it right now, the seconds left at the
// smoothed speed (counting down steadily; 0 when unknown), and how many devices it comes from at once, of them how
// many are the person's own computers (under 2 says nothing).
@property(nonatomic, copy, nullable) NSDictionary<NSNumber *, NSNumber *> *routeBytes;
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *activeRoutes;
@property(nonatomic) double secondsLeft;
@property(nonatomic) NSUInteger holders;
@property(nonatomic) NSUInteger ownHolders; // of `holders`, the person's own computers
// Every block arrived and the whole file has been checked for over a second before it is saved (PROTOCOL.md § Fast
// transfers): "Finishing…".
@property(nonatomic) BOOL finishing;
// The Wi-Fi Direct boost (ADR 0019) on this Mac, for this transfer: 0 none, 1 asking (Go faster, Not now), 2
// connecting, 3 direct, 4 rejoining, 5 did not get back on its Wi-Fi by itself (SZFriendsBoostStage's values).
@property(nonatomic) NSInteger boostStage;
@property(nonatomic, copy, nullable) NSString *boostNetwork; // this Mac's Wi-Fi by name, when it knows it
@property(nonatomic) BOOL boostLeavesWiFi;
@property(nonatomic) BOOL boostOverEthernet;
@property(nonatomic) double boostBluetoothSeconds;
@property(nonatomic) double boostDirectSeconds;
@property(nonatomic, copy, nullable) NSString *localPath;   // received file, once published
// Where a received file was saved, for its "Saved to {folder}": the default Downloads, else the name of the folder it
// is in; neither (older files, or kept in the helper's own folder) keeps "Received".
@property(nonatomic) BOOL savedToDownloads;
@property(nonatomic, copy, nullable) NSString *savedFolderName;
// A file received or copied here (or by another computer of the profile) whose bytes this computer no longer has: the
// person moved or deleted it (PROTOCOL.md § Getting a file again). localPath is nil then. Where it can come from is
// SZFriendsDevicesFacts.files (another computer) or the `again` facts below (the friend who sent it).
@property(nonatomic) BOOL fileMissing;
// Get again on a friend's file (fetch_from_friend): asked and waiting or copying, or answered that they no longer
// have it; whether a session with that friend is live, so it copies now; and how much arrived.
@property(nonatomic) SZFriendsAgainState again;
@property(nonatomic) BOOL againConnected;
@property(nonatomic) double againFraction;
// The uniform type identifier the file name's extension names, from which, or from the extension, views draw the
// type's icon when there is no preview; nil when there is none.
@property(nonatomic, copy, nullable) NSString *fileTypeIdentifier;
// The file's preview (brief § Transfers, Thumbnails before acceptance): a PNG the helper wrote, its size in pixels, and
// whether it is the sender's picture (before the file arrived) or one made on this Mac from the file. Nil path, or a
// zero side: no preview, and the views draw the type's icon.
@property(nonatomic, copy, nullable) NSString *thumbnailPath;
@property(nonatomic) NSUInteger thumbnailWidth;
@property(nonatomic) NSUInteger thumbnailHeight;
@property(nonatomic) BOOL thumbnailFromSender;
// Events.
@property(nonatomic, copy, nullable) NSString *eventKind;
@property(nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> *eventArguments;
@end

@interface SZFriendsNearbyPersonFacts : NSObject
// Ephemeral handle for a public entry (send_request takes it); nil for a friend seen by presence tag.
@property(nonatomic, copy, nullable) NSString *nearbyID;
@property(nonatomic, copy, nullable) NSString *conversationID; // set for friends and pending requests
@property(nonatomic, copy, nullable) NSString *name;
@property(nonatomic, copy, nullable) NSString *friendsID;
@property(nonatomic, copy) SZFriendsPicture *picture;
@property(nonatomic) SZFriendsPersonRelation relation;      // strangers use OutgoingRequest only once asked
@property(nonatomic) BOOL isStranger;
@property(nonatomic) SZFriendsRouteMethod routeMethod;
// Every discovery method that sees this person right now (SZFriendsRouteMethod numbers), for the row's "found".
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *foundMethods;
@end

// How long after a method starts working an empty Nearby keeps saying it is looking (8 seconds).
extern const NSTimeInterval SZFriendsNearbySearchingSeconds;

@interface SZFriendsNearbyFacts : NSObject
@property(nonatomic, copy, nullable) NSDate *visibilityDeadline; // nil when not visible
@property(nonatomic) SZFriendsAdapterState networkState;
@property(nonatomic) SZFriendsAdapterState bluetoothState;
@property(nonatomic) BOOL searching;                        // at least one method is working and looking
// When the first method started working, since Nearby last started (activation, wake, a radio coming back); nil
// while none works. For SZFriendsNearbySearchingSeconds after it an empty Nearby still says it is looking, because
// a first result takes a few seconds and "nobody" that early is a guess (nearbyRefreshDateWithFacts:now:).
@property(nonatomic, copy, nullable) NSDate *workingSince;
@property(nonatomic, copy) NSArray<SZFriendsNearbyPersonFacts *> *people;
@end

typedef NS_ENUM(NSInteger, SZFriendsIdentityFactsState) {
    SZFriendsIdentityFactsStateReady = 0,
    SZFriendsIdentityFactsStateUnavailable = 1,
};

// Why the list shows the `update_required` banner, if it does; the two need different words.
typedef NS_ENUM(NSInteger, SZFriendsUpdateNeed) {
    SZFriendsUpdateNeedNone = 0,
    SZFriendsUpdateNeedOnline = 1, // the Friends host says online Friends needs a newer app; Nearby still works
    SZFriendsUpdateNeedStore = 2,  // another app on this computer updated the Friends data past what this helper reads
};

// One download link as "Your links" shows it.
@interface SZFriendsDownloadLinkFacts : NSObject
@property(nonatomic, copy) NSString *linkID; // base64url of the 16-byte id, as revoke_link takes it
@property(nonatomic, copy) NSString *fileName;
@property(nonatomic) NSUInteger downloads;
@property(nonatomic, copy) NSDate *expiresAt;
@end

@interface SZFriendsLinksFacts : NSObject
@property(nonatomic, copy, nullable) NSString *friendURL; // nil while no link can be made (no Friends host)
@property(nonatomic, copy) NSArray<SZFriendsDownloadLinkFacts *> *downloads; // live ones, newest first
@property(nonatomic, copy) NSDate *now;                                      // what expiry words count from
@end

typedef NS_ENUM(NSInteger, SZFriendsReceivedFallbackFacts) {
    SZFriendsReceivedFallbackFactsNone = 0,
    SZFriendsReceivedFallbackFactsDownloads = 1, // went to Downloads instead
    SZFriendsReceivedFallbackFactsKept = 2,      // kept by the app (no folder took it)
};

@interface SZFriendsProfileFacts : NSObject
@property(nonatomic, copy, nullable) NSString *name;
@property(nonatomic, copy) NSString *friendsID;
@property(nonatomic) NSInteger friendsIDState;               // SZFriendsIDState (identity header)
// The ID before a collision rename; set until the person dismisses the notice (`dismiss_banner`).
@property(nonatomic, copy, nullable) NSString *previousFriendsID;
@property(nonatomic, copy) SZFriendsPicture *picture;
@property(nonatomic, copy) NSData *identityPublicKey;        // Ed25519, for the QR payload
// Unavailable: the list shows the identity_unavailable banner (reset action with its confirmation) and the
// profile's id.state is "unavailable", whatever friendsIDState says.
@property(nonatomic) SZFriendsIdentityFactsState identityState;
@property(nonatomic) SZFriendsUpdateNeed updateNeed;
@property(nonatomic, copy) NSString *receivedDirectory;  // the folder received files go to
// That folder's name when the person chose it; nil while it is Downloads (PROTOCOL.md § Views, settings).
@property(nonatomic, copy, nullable) NSString *receivedFolderName;
// Where the last received file went when that folder could not take it, until one is saved there or the folder
// changes (data.received.note).
@property(nonatomic) SZFriendsReceivedFallbackFacts receivedFallback;
// The profile's "Your links" (PROTOCOL.md § Links), for an audience whose helper announces "links"; nil shows none.
@property(nonatomic, strong, nullable) SZFriendsLinksFacts *links;
@end

// One local search hit (store search), with what the result row needs to say who and when.
@interface SZFriendsSearchHitFacts : NSObject
@property(nonatomic, copy) NSString *conversationID;
@property(nonatomic, copy) NSString *itemID;
@property(nonatomic, copy) NSDate *sentAt;
@property(nonatomic) BOOL outgoing;
@property(nonatomic, copy) NSString *text;                  // message text or file name
@property(nonatomic, copy) NSArray<NSValue *> *matchRanges; // NSRange values into `text`
@end

// Who the mentions in a snapshot resolve against (PROTOCOL.md § Mentions): this person's own identity and Friends
// list, from the same facts the snapshot shows. A friend is matched by identity key only, so a sender cannot make a
// stranger look like a friend by borrowing a friend's name or ID.
@interface SZFriendsMentionDirectory : NSObject
- (instancetype)initWithPeople:(NSArray<SZFriendsPersonFacts *> *)people
                       profile:(SZFriendsProfileFacts *)profile NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) SZFriendsProfileFacts *profile;
- (nullable SZFriendsPersonFacts *)personWithIdentityKey:(NSData *)identityKey;
- (NSArray<SZFriendsPersonFacts *> *)peopleWithFriendsID:(NSString *)friendsID;
@end

#pragma mark - Strings catalog

// One place for every user-facing string. M1 ships English (en-GB conventions, as in the mockups).
@interface SZFriendsStrings : NSObject
- (instancetype)initWithAudience:(SZFriendsAudience *)audience NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// welcome.strings: static chrome labels keyed as PROTOCOL.md § Static strings lists.
- (NSDictionary<NSString *, NSString *> *)staticStrings;

// "14:32" today, "Yesterday", a weekday within six days, "3 Oct" this year, "3 Oct 2025" otherwise.
- (NSString *)timeLabelForDate:(NSDate *)date now:(NSDate *)now;
// "Nearby, on your network", "Nearby, over Bluetooth", "Online, direct", "Not nearby right now"...
- (NSString *)routeLabelForKind:(SZFriendsRouteKind)kind method:(SZFriendsRouteMethod)method;
// "Over Bluetooth, about 6 min", "Through the Friends relay, about 3 min"; nil on fast routes, where no estimate is
// worth showing. On the relay the rate is capped at what the relay allows, and assumed when not measured yet.
- (nullable NSString *)transferEstimateForRemainingBytes:(uint64_t)bytes
                                          bytesPerSecond:(double)bytesPerSecond
                                                   route:(SZFriendsRouteMethod)route;
- (NSString *)countdownLabelForRemaining:(NSTimeInterval)remaining;              // "4:12"
- (NSString *)countdownAccessibilityLabelForRemaining:(NSTimeInterval)remaining; // "4 minutes 12 seconds left"
- (NSString *)sizeLabelForBytes:(uint64_t)bytes;                                 // "2.4 MB"
- (NSString *)badgeLabelForCount:(NSInteger)count;                               // "", "2", "99+"
// reply error.message for a PROTOCOL.md error code, written for the person; nil for protocol errors (bad_frame,
// hello_required...) where the view has nothing useful to say. `details` fills names and sizes.
- (nullable NSString *)messageForErrorCode:(NSString *)code details:(NSDictionary<NSString *, id> *)details;
// result.message of add_by_id: what happens next, nearby only; with `online`, once this Mac reaches friends online
// (the request then also goes through the Friends host).
- (NSString *)addByIDSentMessageForID:(NSString *)friendsID;
- (NSString *)addByIDSentMessageForID:(NSString *)friendsID online:(BOOL)online;
@end

@interface SZFriendsStrings (SZFriendsMentions)
// result.message of add_from_mention, naming the person as the mention did ("Request sent to Leo Park…").
- (NSString *)addFromMentionSentMessageForName:(NSString *)name;
- (NSString *)addFromMentionSentMessageForName:(NSString *)name online:(BOOL)online;
@end

#pragma mark - Snapshot builder

// Each method returns one view's `data` object exactly as PROTOCOL.md specifies it. The helper wraps it in a
// snapshot frame and sends it only when it differs from the last one sent on that subscription.
@interface SZFriendsSnapshotBuilder : NSObject
- (instancetype)initWithStrings:(SZFriendsStrings *)strings audience:(SZFriendsAudience *)audience
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// The animal set avatars are validated against and colored from: +[SZFriendsAnimalSet bundledSet] unless set.
// Tests and probes pass a set loaded from avatars/animals/manifest.json, since they run outside the helper bundle.
@property(nonatomic, strong, nullable) SZFriendsAnimalSet *animalSet;
// What mentions in conversations and search results resolve against; the helper sets it from each pass's facts. Nil
// shows every mention as plain text under the name its sender wrote, which claims nothing about who it is. The list
// resolves its previews against the people and profile it is given, whatever this holds.
@property(nonatomic, strong, nullable) SZFriendsMentionDirectory *mentionDirectory;
// One profile on several computers (SZFriendsPresentationDevices.h), for an audience whose helper announces "devices";
// nil keeps every snapshot as one computer shows it.
@property(nonatomic, strong, nullable) SZFriendsDevicesFacts *devices;

// `people` in any order; the builder sorts by latest interaction and counts rows waiting for an answer.
- (NSDictionary<NSString *, id> *)badgeWithPeople:(NSArray<SZFriendsPersonFacts *> *)people;
// `previewItems` is keyed by item id: each row describes previewItems[person.lastMessageItemID].
- (NSDictionary<NSString *, id> *)listWithPeople:(NSArray<SZFriendsPersonFacts *> *)people
                                    previewItems:(NSDictionary<NSString *, SZFriendsItemFacts *> *)previewItems
                                         profile:(SZFriendsProfileFacts *)profile
                                           query:(NSString *)query
                                             now:(NSDate *)now;
- (NSDictionary<NSString *, id> *)nearbyWithFacts:(SZFriendsNearbyFacts *)nearby
                                         profile:(SZFriendsProfileFacts *)profile
                                           query:(NSString *)query
                                             now:(NSDate *)now;
// When the Nearby snapshot may next change with no new fact (an empty search turning into "nobody visible"), or
// nil. The builder reads no clock, so the helper rebuilds Nearby at this instant and sends it only if it differs;
// the visible countdown's once-a-second refresh is separate (PROTOCOL.md § Snapshots).
- (nullable NSDate *)nearbyRefreshDateWithFacts:(SZFriendsNearbyFacts *)nearby now:(NSDate *)now;
// `waitingElsewhere`: rows waiting for an answer other than this one (the back arrow's count).
- (NSDictionary<NSString *, id> *)conversationForPerson:(SZFriendsPersonFacts *)person
                                                  items:(NSArray<SZFriendsItemFacts *> *)items
                                             hasEarlier:(BOOL)hasEarlier
                                        highlightItemID:(nullable NSString *)highlightItemID
                                       waitingElsewhere:(NSInteger)waitingElsewhere
                                                    now:(NSDate *)now;
- (NSDictionary<NSString *, id> *)detailsForPerson:(SZFriendsPersonFacts *)person
                                  waitingElsewhere:(NSInteger)waitingElsewhere
                                               now:(NSDate *)now;
- (NSDictionary<NSString *, id> *)profileWithFacts:(SZFriendsProfileFacts *)profile
                                  waitingElsewhere:(NSInteger)waitingElsewhere;
// Settings' optional `nearby` line (PROTOCOL.md § settings): whether Nearby has the access and radios it needs, with
// the button that fixes it. The helper adds it to `settings`; a builder used without Nearby facts leaves it out.
- (NSDictionary<NSString *, id> *)nearbyAccessWithFacts:(SZFriendsNearbyFacts *)nearby
                                                profile:(SZFriendsProfileFacts *)profile;
- (NSDictionary<NSString *, id> *)settingsWithProfile:(SZFriendsProfileFacts *)profile
                                               people:(NSArray<SZFriendsPersonFacts *> *)people;
// A message_status snapshot's data: each of `messages` that is an outgoing message with a delivery record, in the
// given order, with the status object its conversation item carries. `people`, keyed by conversation id, names the
// friend ("Sends when Priya is nearby"); the helper passes only this person's outgoing messages.
- (NSDictionary<NSString *, id> *)messageStatusWithMessages:(NSArray<SZFriendsItemFacts *> *)messages
                                                     people:(NSDictionary<NSString *, SZFriendsPersonFacts *> *)people;
// The `result` object of a successful search_messages reply (conversation search and Cmd+K).
- (NSDictionary<NSString *, id> *)searchResultWithHits:(NSArray<SZFriendsSearchHitFacts *> *)hits
                                                people:(NSDictionary<NSString *, SZFriendsPersonFacts *> *)people
                                                  more:(BOOL)more
                                                   now:(NSDate *)now;
@end

// Links (SZFriendsSnapshotBuilder+Links.m; PROTOCOL.md § Links): open_link's cards and the intents' messages.
@interface SZFriendsSnapshotBuilder (SZFriendsLinks)
// A friend link's card: "Add Mei?", the Friends ID, why the request is accepted at once, Add (add_from_link with the
// payload); or, when this person is already a friend, saying so with nothing to press.
- (NSDictionary<NSString *, id> *)friendLinkCardWithName:(nullable NSString *)name
                                               friendsID:(NSString *)friendsID
                                                 payload:(NSString *)payload
                                           alreadyFriend:(BOOL)alreadyFriend;
// A download link's card: what pressing Download does (receive_link with the payload).
- (NSDictionary<NSString *, id> *)downloadLinkCardWithPayload:(NSString *)payload;
- (NSString *)linkRequestSentMessageForName:(NSString *)name;
- (NSString *)linkRequestSentMessageForName:(NSString *)name online:(BOOL)online;
- (NSString *)linkReceivingMessageForFile:(NSString *)fileName sender:(nullable NSString *)name;
- (NSString *)downloadLinkMadeMessageUntil:(NSDate *)expiresAt;
@end

NS_ASSUME_NONNULL_END
