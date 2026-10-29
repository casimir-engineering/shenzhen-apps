// SZFriendsNearbyService's shared state and the methods its files call on one another. Internal to nearby/.
//
// Split by concern so each file reads on its own: SZFriendsNearbyService.m (lifecycle, advertising, visibility),
// +Dial (whom to connect to and how), +Sessions (channels, key policy, the session race), +Delivery (outbox to
// frames, acknowledgements), +Inbound (frames from friends), +Transfers (chunk flow), +RequestByID (Add by ID
// nearby), +Facts (what snapshots show), +Limits (what someone who is not a friend may cost, SZFriendsNearbyLimits.h).

#import "service/helper/nearby/SZFriendsNearbyService.h"

#import "service/discovery/SZFriendsDiscoveryCoordinator.h"
#import "service/helper/nearby/SZFriendsNearbyLimits.h"
#import "service/helper/SZFriendsHelperInternal.h"
#import "service/helper/SZFriendsHelperTesting.h"
#import "service/helper/nearby/SZFriendsPeerLink.h"
#import "service/host/SZFriendsHostConnection.h"
#import "service/notify/SZFriendsNotify.h"
#import "service/online/driver/SZFriendsOnlineDriver.h"
#import "service/session/SZFriendsSession.h"
#import "service/thumbnails/SZFriendsThumbnails.h"
#import "service/transfer/SZFriendsBlockExchange.h"

NS_ASSUME_NONNULL_BEGIN

@class SZFriendsSyncEngine;

// How long a dial may stay unanswered before its entries go back to Queued: the handshake timeout plus a margin.
extern const NSTimeInterval SZFriendsNearbyConnectingTimeout;

@interface SZFriendsNearbyService () <SZFriendsDiscoveryCoordinatorDelegate>
@property(nonatomic, readonly) SZFriendsHelperServices *services;
@property(nonatomic, readonly) dispatch_queue_t queue;
@property(nonatomic, readonly) NSArray<id<SZFriendsDiscoveryAdapter>> *adapters;
@property(nonatomic, readonly, nullable) SZFriendsDiscoveryCoordinator *coordinator;
@property(nonatomic, readonly) SZFriendsVisibility *visibility;
@property(nonatomic, readonly) NSMutableSet<SZFriendsPeerLink *> *links;
@property(nonatomic, readonly) NSMutableDictionary<NSString *, SZFriendsPeerLink *> *activeLinks; // by conversation
// From browse handshakes, by identity key hex: the profile fields a public entry served, and its static key.
@property(nonatomic, readonly) NSMutableDictionary<NSString *, NSDictionary<NSNumber *, NSData *> *> *publicProfiles;
@property(nonatomic, readonly) NSMutableDictionary<NSString *, NSData *> *publicStaticKeys;
@property(nonatomic, readonly) NSMutableDictionary<NSString *, SZFriendsPicture *> *publicPictures;
// When each one-shot attempt may be made again ("browse|<endpoint>", "probe|<conversation>|<endpoint>|<window>",
// "byid|<token>|<endpoint>|<window>"), so each happens once per endpoint and presence window.
@property(nonatomic, readonly) NSMutableDictionary<NSString *, NSDate *> *attempts;
@property(nonatomic, readonly) NSMutableSet<NSString *> *dialing; // purpose|method|endpoint with a dial in flight
@property(nonatomic, readonly) NSMutableDictionary<NSString *, NSDate *> *retryAfter; // conversation -> backoff
@property(nonatomic, readonly) NSMutableDictionary<NSString *, NSNumber *> *failures; // conversation -> count
// conversation -> how many sessions in a row the friend closed for one it holds with another of our computers
@property(nonatomic, readonly) NSMutableDictionary<NSString *, NSNumber *> *keptElsewhere;
@property(nonatomic, readonly) NSMutableDictionary<NSString *, NSDate *> *byIDSenders; // sender key hex -> last
// Add by ID: when REQUEST_BY_ID last went to a device, by request token (hex), with that day's callback secret. Only
// in memory: after a restart nothing is advertised until the next broadcast, which no device could match before.
@property(nonatomic, readonly) NSMutableDictionary<NSString *, NSDate *> *callbackBroadcasts;
@property(nonatomic) NSUInteger callbackRefreshGeneration;
@property(nonatomic) BOOL handingOver;
@property(nonatomic) BOOL shutDown;
// Reset Friends is under way (or failed): nothing is advertised and nobody is dialed until it completes.
@property(nonatomic) BOOL resetting;
@property(nonatomic) BOOL reconsiderScheduled;
@property(nonatomic) CFAbsoluteTime lastProgressChange;
@property(nonatomic) BOOL progressChangeScheduled;
// Makes our previews and the local ones of received files (+Thumbnails); created on first use, so a helper that never
// sends or receives a file starts no QuickLook work.
@property(nonatomic, strong, nullable) SZFriendsThumbnailMaker *thumbnailMaker;
// Friends over the Internet (+Online): made when the check-in client attaches the host, nil before and after stop.
@property(nonatomic, strong, nullable) SZFriendsOnlineDriver *onlineDriver;
// The driver has been available once since it was made (SZFriendsNearbyService.h, reachesFriendsOnline).
@property(nonatomic) BOOL onlineOffered;
// open_conversation, by conversation: when the person last opened it (+Online's "just opened").
@property(nonatomic, strong, nullable) NSMutableDictionary<NSString *, NSDate *> *conversationsOpenedAt;
// When the pending +Online refresh fires: a Connecting window ends then.
@property(nonatomic, copy, nullable) NSDate *onlineReachRefreshAt;
// Add by ID online (+ByIDOnline), by "<token hex>|<callback day>": NSNull while the request is on its way, YES once
// its holder's RECEIVED arrived that day, or the date before which it is not sent again. Only in memory.
@property(nonatomic, strong, nullable) NSMutableDictionary<NSString *, id> *onlineIDRequests;
// Sync with our own devices (+Sync): the engine once our chain holds another device, live sessions by device key
// (hex), when a failed dial to one may be tried again, and whether a capture is due.
@property(nonatomic, strong, nullable) SZFriendsSyncEngine *syncEngine;
@property(nonatomic, strong, nullable) NSMutableDictionary<NSString *, SZFriendsPeerLink *> *syncLinkTable;
@property(nonatomic, strong, nullable) NSMutableDictionary<NSString *, NSDate *> *syncDialAfterTable;
@property(nonatomic) BOOL syncCaptureScheduled;
@property(nonatomic) BOOL secretRenewalScheduled; // waiting for this computer's turn to draw new secrets (+Devices)
// How long after start a waiting turn is looked at again (+Devices); 0: the default. Tests set it.
@property(nonatomic) NSTimeInterval secretRenewalResumeDelay;
@property(nonatomic, copy, nullable) NSString *syncKnownDevices; // our devices and states, as last matched
// Another of the person's computers removed this one (+Devices): nothing is advertised, dialed or sent any more.
@property(nonatomic) BOOL removedFromProfile;
@property(nonatomic, copy, nullable) NSData *ownRootKeyCache; // our root, kept for when this computer is removed
// Giving files again to friends who ask (+Again, ADR 0016): files whose digest was checked this run, by transfer id
// ("path|size|mtime" as checked), and when each person's checks ran in the last hour, by conversation.
@property(nonatomic, strong, nullable) NSMutableDictionary<NSString *, NSString *> *againVerified;
@property(nonatomic, strong, nullable) NSMutableDictionary<NSString *, NSMutableArray<NSDate *> *> *againChecks;

// Core.
- (void)changed;
// Progress-only changes, at most 4 per second (PROTOCOL.md § Snapshots).
- (void)progressChanged;
- (void)refreshAdvertisement;
- (void)rebuildTagMatcher;
- (NSData *)localIdentityKey;
// The name, Friends ID and picture friends see, as PROFILE fields (also the public entry's profile).
- (NSDictionary<NSNumber *, NSData *> *)profileFields;
- (int64_t)currentWindow;
@end

// One connection attempt: which sighting, why, for whom, with what handshake, after what stagger.
@interface SZFriendsDialPlan : NSObject
+ (instancetype)planWithSighting:(SZFriendsSighting *)sighting
                         purpose:(SZFriendsLinkPurpose)purpose
                         options:(SZFriendsHandshakeOptions *)options;
@property(nonatomic, strong) SZFriendsSighting *sighting;
@property(nonatomic) SZFriendsLinkPurpose purpose;
@property(nonatomic, copy) SZFriendsHandshakeOptions *options;
@property(nonatomic, copy, nullable) NSString *conversationID;
@property(nonatomic) NSTimeInterval delay;
@property(nonatomic) BOOL probe;                             // SZFriendsPeerLink.probe
@property(nonatomic, copy, nullable) NSData *requestToken;  // NN: the Add by ID request to carry
@property(nonatomic, copy, nullable) NSString *attemptKey;  // NN: its one-shot entry in `attempts`
@property(nonatomic, copy, nullable) NSString *ownDeviceHex; // IK to one of our devices: which (+Sync)
// A lane of `laneHead`'s group (ADR 0018 § 6), reserved in its exchange as `laneSerial` (+Blocks).
@property(nonatomic, weak, nullable) SZFriendsPeerLink *laneHead;
@property(nonatomic) uint64_t laneSerial;
@end

// Explicit rank (ADR 0011 § Route rank): dialing a friend at `sighting` is pointless while a live session runs on
// `live`, unless the sighting's route ranks before it. Never the raw route numbers: Bluetooth (3) ranks after
// Internet (4).
BOOL SZFriendsNearbyDialIsPointless(SZFriendsRouteMethod live, SZFriendsRouteMethod sighting);

@interface SZFriendsNearbyService (Dial)
// Looks at every candidate and pending entry again on the next turn (coalesced).
- (void)scheduleReconsider;
- (void)scheduleReconsiderAfter:(NSTimeInterval)delay;
- (void)reconsider;
// NO when an attempt at that endpoint for that purpose is already running, or no adapter has it.
- (BOOL)dial:(SZFriendsDialPlan *)plan;
- (void)browseOfEndpointFailed:(NSString *)endpointID;
// An NN request that did not reach its device: tried again after a while rather than the next day.
- (void)byIDAttemptFailed:(NSString *)attemptKey;
- (void)noteFailureForConversation:(NSString *)conversationID;
- (void)noteSuccessForConversation:(NSString *)conversationID;
- (void)noteEndOfLink:(SZFriendsPeerLink *)link;
// The friend closed our live session for the one it holds with another of our computers, and none replaces it here.
- (void)noteSessionKeptElsewhereForConversation:(NSString *)conversationID;
// How an IK dial to a person ended before going live, per endpoint (SZFriendsRouteRacer's endpoint backoff): a
// device re-advertising a captured tag learns who dials it, so a failing endpoint is dialed rarely for that person.
- (void)noteDialToEndpoint:(nullable NSString *)endpointID
                    method:(NSInteger)method
              conversation:(nullable NSString *)conversationID
                 succeeded:(BOOL)succeeded;
- (BOOL)mayDialConversation:(NSString *)conversationID;
- (void)pruneAttempts;
// IK toward a person on `route`, presenting their Add by ID token until our ACCEPT reaches them.
- (SZFriendsHandshakeOptions *)ikOptionsForPerson:(SZFriendsPersonRecord *)person route:(SZFriendsRouteMethod)route;
@end

// Add by ID online (SZFriendsNearbyService+ByIDOnline.m): each pending request goes to the ID's holder through the
// host (the driver's NN exchange), and the holder's IK callback is admitted as nearby admits it.
@interface SZFriendsNearbyService (ByIDOnline)
// After a reconsider: pending requests not yet received online this day (and not waiting to retry) are sent.
- (void)offerRequestsByIDOnline;
@end

@interface SZFriendsNearbyService (Sessions)
- (void)acceptStream:(id<SZFriendsByteStream>)stream route:(SZFriendsRouteMethod)route publicEntry:(BOOL)publicEntry;
// A link for a dialed stream, configured from the plan but not started, so the caller can finish setting it up.
- (SZFriendsPeerLink *)linkForInitiatorStream:(id<SZFriendsByteStream>)stream plan:(SZFriendsDialPlan *)plan;
- (void)startLink:(SZFriendsPeerLink *)link;
// The link now belongs to this conversation: adopt it or settle the session race (ADR 0001 § Session race).
- (void)attachLink:(SZFriendsPeerLink *)link toConversation:(NSString *)conversationID;
// What the session race keeps of a new live link and the live one carrying the same peer (+Sessions).
typedef NS_ENUM(NSInteger, SZFriendsRaceOutcome) {
    SZFriendsRaceKeepsNew,
    SZFriendsRaceKeepsCurrent,
    SZFriendsRaceWaits, // a double dial on one class, answered here: the initiator closes one
};
- (SZFriendsRaceOutcome)raceOfLink:(SZFriendsPeerLink *)link against:(SZFriendsPeerLink *)current;
// What the racer knows a dialed peer by: a conversation, or "dev-" and one of our devices' keys (+Sessions).
- (nullable NSString *)raceNameOfLink:(SZFriendsPeerLink *)link;
- (void)closeLinksForConversation:(NSString *)conversationID;
- (nullable SZFriendsPeerLink *)liveLinkForConversation:(NSString *)conversationID;
// Starts the comparison-code exchange on a link that creates a friendship, once, and only while the person has no
// code yet: a stored code is never replaced (ADR 0001 § Comparison codes).
- (void)runCodeExchangeOnLink:(SZFriendsPeerLink *)link;
// Records a code once both the code and the conversation are known, unless the person already has one.
- (void)storeComparisonCodeOfLink:(SZFriendsPeerLink *)link;
// A known person presented another static key, certified (when `certificate` verifies) by their same identity: the
// store keeps it for review and turns automatic acceptance off; a history event says so once. Returns the person as
// stored now (re-read, so a later save cannot undo the review), or nil when they are gone.
- (nullable SZFriendsPersonRecord *)notePresentedStaticKey:(NSData *)staticKey
                                               certificate:(nullable NSData *)certificate
                                                    person:(SZFriendsPersonRecord *)person;
@end

// Who may open a session to us (SZFriendsNearbyService+KeyPolicy.m).
@interface SZFriendsNearbyService (KeyPolicy)
// The key policy (SZFriendsRemoteKeyPolicy) for a responder link: reads only, no store write, no token consumed
// (ADR 0001: IK message 1 can be replayed); marks the link a stranger when it admits someone who is not a friend.
- (BOOL)allowRemoteKey:(nullable NSData *)key
               pattern:(SZFriendsHandshakePattern)pattern
                 token:(nullable NSData *)token
                  link:(nullable SZFriendsPeerLink *)link
           publicEntry:(BOOL)publicEntry;
// Whether a known person may open IK to our hidden listener now, with `token` judged `attested` (rules in the file).
- (BOOL)person:(SZFriendsPersonRecord *)person
    mayOpenIKWithToken:(nullable NSData *)token
              attested:(BOOL)attested
                   now:(NSDate *)now;
@end

// Device chains on sessions (SZFriendsNearbyService+Chain.m, ADR 0012): our chain to every friend, theirs kept, revoked
// devices refused, and a friend's other devices checked against the static key their chain gives them.
// Sync with this person's other devices (SZFriendsNearbyService+Sync.m; service/sync/SZFriendsSync.h).
@interface SZFriendsNearbyService (Sync)
@property(nonatomic, readonly) NSMutableDictionary<NSString *, SZFriendsPeerLink *> *syncLinks;
@property(nonatomic, readonly) NSMutableDictionary<NSString *, NSDate *> *syncDialAfter;
// The engine, made once our chain holds another device; nil before, and while shut down or resetting.
- (nullable SZFriendsSyncEngine *)activeSyncEngine;
// Another device our chain authorizes (never this one).
- (BOOL)isOwnDeviceKey:(NSData *)key;
// A session went live: YES when it is with one of our devices, which it now carries sync for (or was closed).
- (BOOL)syncAdoptsLiveLink:(SZFriendsPeerLink *)link;
// CHAIN and SYNC on a session with one of our devices.
- (void)link:(SZFriendsPeerLink *)link receivedOwnDeviceFrame:(SZFriendsFrame *)frame;
- (void)syncLinkClosed:(SZFriendsPeerLink *)link;
// The live session carrying our sync with the device whose key is `hex`, if any (+Sync).
- (nullable SZFriendsPeerLink *)liveSyncLinkForDeviceHex:(NSString *)hex;
- (void)pumpSyncExchanges;
- (void)scheduleSyncCapture;
// Our devices as the store's index lists them now: matched, advertised and dialed anew when they changed.
- (void)noticeOwnDevicesChange;
// Nearby: what our devices' tags are matched by ("dev-<key hex>" -> its tag secret), and our own tag to advertise.
- (NSDictionary<NSString *, NSArray<NSData *> *> *)ownDeviceTagSecrets;
- (nullable NSData *)ownDeviceTagAtDate:(NSDate *)date;
// A candidate the merger named as one of our devices: dialed with IK when no session runs. YES: it was one.
- (BOOL)reachOwnDeviceCandidate:(SZFriendsCandidate *)candidate;
// After a reconsider: a device that just joined probes unrecognised devices nearby for its siblings, and every device
// asks the driver for ours with no session on a route ranking before Internet.
- (void)reachOwnDevices;
- (nullable SZFriendsOnlineFriend *)onlineOwnDeviceWithKey:(NSData *)deviceKey;
- (SZFriendsRouteMethod)nearbyRouteToOwnDevice:(NSData *)deviceKey;
// The driver connected to one of our devices and we dial: YES when `key` is one of ours (the session is started).
- (BOOL)openOwnDeviceStream:(id<SZFriendsByteStream>)stream route:(SZFriendsRouteMethod)route device:(NSData *)key;
@end

// Friends' other devices (SZFriendsNearbyService+FriendDevices.m): our tags as one of several devices, theirs matched
// per device, and each dialed with the static key their chain gives it, nearby and online.
@interface SZFriendsNearbyService (FriendDevices)
// Not the first device of a profile with several: the tag friends find this device by; nil: the person's own tag.
- (nullable NSData *)ownFriendPresenceTagAtDate:(NSDate *)date;
// "fdev-<device key hex>-<conversation id>" -> that device's tag secret, for every friend's other authorized devices.
- (NSDictionary<NSString *, NSArray<NSData *> *> *)friendDeviceTagSecrets;
// A candidate the merger named as a friend's other device: dialed while no session carries their conversation.
- (BOOL)reachFriendDeviceCandidate:(SZFriendsCandidate *)candidate;
- (void)reachOtherDevicesOfFriendOnline:(SZFriendsPersonRecord *)person;
- (nullable SZFriendsOnlineFriend *)onlineFriendDeviceWithKey:(NSData *)deviceKey;
- (BOOL)openFriendDeviceStream:(id<SZFriendsByteStream>)stream
                         route:(SZFriendsRouteMethod)route
                        device:(NSData *)deviceKey;
@end
// The conversation a "fdev-" name is about, with the device key; nil for any other name.
NSString *_Nullable SZFriendsNearbyFriendDeviceConversation(NSString *_Nullable name, NSData *_Nullable *_Nullable key);

@interface SZFriendsNearbyService (Chain)
// When a session goes live: closes it and returns YES for a device a kept chain revoked (either direction); otherwise
// notes the device's last connection.
- (BOOL)chainRefusesLiveLink:(SZFriendsPeerLink *)link;
// Sends our chain (writing its genesis first for an existing profile) on a live session with a friend that
// negotiated minor 2.
- (void)sendChainOnLink:(SZFriendsPeerLink *)link;
- (void)link:(SZFriendsPeerLink *)link person:(SZFriendsPersonRecord *)person receivedChain:(SZFriendsFrame *)frame;
// First contact: before our request or our answer to an Add by ID goes on a session, a device other than our first
// sends our chain, so the other side keys us by our root rather than by this device (ADR 0012, Consequences).
- (void)sendFirstContactChainOnLink:(SZFriendsPeerLink *)link;
// A stranger's chain before their request: kept on the link once it verifies and names the session's device.
- (void)link:(SZFriendsPeerLink *)link receivedFirstContactChain:(SZFriendsFrame *)frame;
// The root a request on `link` speaks for, with its chain stored once the person is: nil for no chain.
- (nullable NSData *)firstContactRootOnLink:(SZFriendsPeerLink *)link staticKey:(NSData *_Nullable *_Nullable)staticKey;
// For a session with a friend's device other than their first: YES when the chain gave that device the static key the
// handshake used. Sets `handled` to NO for the first device, whose static key is the person's (keyChangedOnLink).
- (BOOL)otherDeviceOfPerson:(SZFriendsPersonRecord *)person
          matchesStaticKeyOnLink:(SZFriendsPeerLink *)link
                         handled:(BOOL *)handled;
@end

// The limits of SZFriendsNearbyLimits.h applied to links (SZFriendsNearbyService+Limits.m).
@interface SZFriendsNearbyService (Limits)
// Responder links admitted as strangers and not yet closed.
- (NSUInteger)strangerLinkCount;
// Whether a live link is with a friend (and not a token-admitted session still creating the friendship).
- (BOOL)linkIsWithFriend:(SZFriendsPeerLink *)link;
// The cap is full: closes the stranger session idle longest so a newcomer can take its place; NO when none exists.
- (BOOL)makeRoomForStranger;
// The idle clock of a session with someone who is not a friend starts again.
- (void)noteApplicationFrameOnLink:(SZFriendsPeerLink *)link;
// An application frame arrived: restarts the idle clock only when it moves a request forward (SZFriendsNearbyLimits.h).
- (void)noteFrame:(SZFriendsFrame *)frame onLink:(SZFriendsPeerLink *)link;
// Arms the idle and lifetime check when a link goes live.
- (void)armIdleCheckForLink:(SZFriendsPeerLink *)link;
// Sends CLOSE on the link after `delay`, unless it closed meanwhile.
- (void)closeLink:(SZFriendsPeerLink *)link after:(NSTimeInterval)delay;
@end

@interface SZFriendsNearbyService (Delivery)
- (void)deliverPendingForConversation:(NSString *)conversationID;
- (void)deliverPendingOnLink:(SZFriendsPeerLink *)link;
- (BOOL)hasDeliverableEntriesForPerson:(SZFriendsPersonRecord *)person;
- (void)markConnectingForConversation:(NSString *)conversationID;
- (void)handleAck:(SZFriendsFrame *)frame onLink:(SZFriendsPeerLink *)link;
- (void)sendAckForID:(NSData *)wireID onLink:(SZFriendsPeerLink *)link;
- (void)sendProfileOnLink:(SZFriendsPeerLink *)link;
// A link ended: what it had in flight goes back to Queued for the next session.
- (void)requeueEntriesOfLink:(SZFriendsPeerLink *)link;
// A friend's REQUEST was answered with an acceptance: it goes now, then what this link wrote before it, again.
- (void)deliverAcceptanceThenResendOnLink:(SZFriendsPeerLink *)link;
- (void)applyEvent:(SZFriendsOutboxEvent)event toEntry:(NSString *)entryID;
// The frame an entry becomes for this person now, or nil (also exposed for the helper's tests).
- (nullable SZFriendsFrame *)frameForEntry:(SZFriendsOutboxEntry *)entry
                                    person:(SZFriendsPersonRecord *)person
                                    wireID:(NSString *_Nullable *_Nonnull)wireID;
@end

// A stranger's picture as Nearby shows it: their animal when their public profile names one, otherwise the
// placeholder (initials). Picture bytes from a public entry are never decoded (+Facts.m).
@interface SZFriendsNearbyService (PublicPictures)
- (SZFriendsPicture *)publicPictureForKey:(NSString *)keyHex fields:(NSDictionary<NSNumber *, NSData *> *)fields;
@end

// A history event ("now_friends", "key_changed"...) in a conversation, now.
void SZFriendsNearbyRecordEvent(SZFriendsStore *store, NSString *eventKind, NSString *conversationID);

// Friends over the Internet (SZFriendsNearbyService+Online.m): the driver's delegate. Attaching and stopping are in
// SZFriendsNearbyService.h.
@interface SZFriendsNearbyService (Online) <SZFriendsOnlineDriverDelegate>
// After a reconsider: friends with something waiting and no session ranking before Internet are reached online.
- (void)reachFriendsOnline;
// A session went live or ended: the attempts hear the routes outside them again.
- (void)onlineRoutesChanged;
// The outbox changed for this conversation: a message or file queued after the friend's last online failure makes
// that failure old news (SZFriendsOnlineDriver.h, -forgetFailureForFriend:).
- (void)onlineOutboxChangedForConversation:(NSString *)conversationID;
@end

@interface SZFriendsNearbyService (Inbound)
- (void)link:(SZFriendsPeerLink *)link receivedFrame:(SZFriendsFrame *)frame;
// Our request to this conversation arrived (an answer, or a callback presenting its token): Delivered.
- (void)acknowledgeRequestEntriesOfConversation:(NSString *)conversationID;
- (void)applyProfile:(NSDictionary<NSNumber *, NSData *> *)fields toPerson:(SZFriendsPersonRecord *)person;
// Name, Friends ID and picture from PROFILE fields (or a public profile), cleaned and validated; not saved.
- (void)updatePerson:(SZFriendsPersonRecord *)person withProfile:(NSDictionary<NSNumber *, NSData *> *)fields;
// An outbox entry with no history item (answers, presence secrets), as the router queues them.
- (void)enqueueKind:(SZFriendsOutboxKind)kind
     conversationID:(NSString *)conversationID
            payload:(nullable NSDictionary *)payload;
@end

@interface SZFriendsNearbyService (Transfers)
// A link was adopted: one receiver per unfinished inbound transfer, each announcing its durable offset.
- (void)startTransfersOnLink:(SZFriendsPeerLink *)link;
- (void)link:(SZFriendsPeerLink *)link receivedChunkFrame:(SZFriendsFrame *)frame;
- (void)link:(SZFriendsPeerLink *)link receivedProgressFrame:(SZFriendsFrame *)frame;
- (void)link:(SZFriendsPeerLink *)link receivedDoneFrame:(SZFriendsFrame *)frame;
- (void)link:(SZFriendsPeerLink *)link transferAcknowledged:(NSString *)transferID;
- (void)stopTransfer:(NSString *)transferID;
- (void)pumpLink:(SZFriendsPeerLink *)link;
// Moves every receiver's bytes to disk and reports what became durable.
- (void)flushProgressOnLink:(SZFriendsPeerLink *)link;
- (BOOL)transfersInFlight;
// YES when `bytes` more would go faster than the tests' cap: the pump runs again once they may.
- (BOOL)paceLink:(SZFriendsPeerLink *)link bytes:(NSUInteger)bytes rate:(double)rate;
// PING and silence for whatever the link carries now (ADR 0018 § 7).
- (void)updateLivenessOnLink:(SZFriendsPeerLink *)link;
@end

// Files by blocks on fast sessions (ADR 0018; SZFriendsNearbyService+Blocks.m).
@interface SZFriendsNearbyService (Blocks)
// The link's exchange, made on first use; nil unless the link is a live friend's session that negotiated them.
- (nullable SZFriendsBlockExchange *)blocksOnLink:(SZFriendsPeerLink *)link;
- (void)link:(SZFriendsPeerLink *)link receivedBlockFrame:(SZFriendsFrame *)frame;
// A responder's session whose IK message 1 carried a Lane token: admitted into the group of the live session with the
// same device whose handshake hash and a free index make that token, or closed with CLOSE LaneRefused.
- (void)admitLane:(SZFriendsPeerLink *)link;
// One of our lanes went live: it joins its head's group.
- (void)joinLane:(SZFriendsPeerLink *)link toHead:(SZFriendsPeerLink *)head;
// The head is closing while lanes live (ADR 0018 § 6: the group goes on): its lowest live lane takes the group, as the
// link to adopt in its place; nil when none can (the caller ends the group as before).
- (nullable SZFriendsPeerLink *)handOverGroupOfLink:(SZFriendsPeerLink *)head;
@end

// Get again and own-device copies served by blocks (ADR 0018 § 4; SZFriendsNearbyService+Copies.m).
@interface SZFriendsNearbyService (Copies)
// Serves the file at `path` by blocks on the link: BLOCKS FOLLOW (AGAIN 5, or SYNC 8 when `sync`) with its tree at
// `shift`, then the leaves and the blocks in `ranges`. NO when it cannot (the caller answers NONE).
- (BOOL)serveCopyOnLink:(SZFriendsPeerLink *)link
               transfer:(NSString *)transferID
                   path:(NSString *)path
                   size:(uint64_t)size
                  shift:(uint8_t)shift
                 ranges:(NSData *)ranges
                   sync:(BOOL)sync;
// A HAVE for a file served by blocks on this link: YES when it was one.
- (BOOL)link:(SZFriendsPeerLink *)link receivedCopyHave:(SZFriendsFrame *)frame;
// HASHES or a PART of a file this side copies by blocks on this link (Get again, or from another of our devices): YES
// when it was one.
- (BOOL)link:(SZFriendsPeerLink *)link receivedCopyFrame:(SZFriendsFrame *)frame;
@end

// File previews (brief § Transfers, Thumbnails before acceptance; SZFriendsNearbyService+Thumbnails.m).
@interface SZFriendsNearbyService (ThumbnailFrames)
// After the outbox entries: our previews of offers already on this link or delivered, to a peer that knows THUMBNAIL.
- (void)sendThumbnailsOnLink:(SZFriendsPeerLink *)link;
// A THUMBNAIL from a friend: kept when it may be, acknowledged whatever was decided.
- (void)link:(SZFriendsPeerLink *)link person:(SZFriendsPersonRecord *)person receivedThumbnail:(SZFriendsFrame *)frame;
// The ACK for one of our THUMBNAIL frames (token "thumb:<transfer id>"): nothing more to send.
- (void)link:(SZFriendsPeerLink *)link thumbnailAcknowledged:(NSString *)transferID;
// A received file's digest checked: our own preview of it replaces the sender's, or none does.
- (void)makeLocalThumbnailForReceivedTransfer:(NSString *)transferID;
@end
// The ACK token prefix for THUMBNAIL frames (SZFriendsPeerLink -expectAckForID:token:).
extern NSString *const SZFriendsThumbnailAckPrefix;

// Add by ID callback secrets (ADR 0004 step 3, as the security review narrowed it). The stored secret is a master
// that never leaves this Mac: each day of a request's life has its own secret, keyed from the master, which that
// day's broadcasts carry. SZFriendsCallbackTagsToAdvertise then puts a day's tags on the air only within 6 hours of
// the last broadcast that carried them and only that day, so whoever heard one broadcast can recognise us for
// hours, not for the request's 7 days, and cannot work out the next day's secret. WHY derived rather than drawn and
// stored: the same property with no stored state beyond the request itself.
// Whole days since the request was made (0 on the first day).
int64_t SZFriendsCallbackDay(NSDate *createdAt, NSDate *now);
// BLAKE2b-256 keyed with the master over "SZFriends callback day v1" || u64be(day); empty for a malformed master.
NSData *SZFriendsCallbackSecretForDay(NSData *masterSecret, int64_t day);

@interface SZFriendsNearbyService (RequestByID)
- (void)sendRequestByIDOnLink:(SZFriendsPeerLink *)link;
- (void)link:(SZFriendsPeerLink *)link receivedRequestByID:(SZFriendsFrame *)frame;
// Holder, nearby or online, once RECEIVED went back: the request as the person sees it (or accepted at once).
- (void)receivedRequestByID:(SZFriendsFrame *)frame handshakeHash:(NSData *)handshakeHash;
// Requester: REQUEST_BY_ID for our pending request `token`, signed over `handshakeHash`; nil once it is not pending.
- (nullable SZFriendsFrame *)requestByIDFrameForToken:(NSData *)token handshakeHash:(NSData *)handshakeHash;
// The IK callback after Add by ID: the token names our request; the person it was for gets this key.
- (nullable NSString *)conversationForCallbackLink:(SZFriendsPeerLink *)link;
- (void)callbackLinkWentLive:(SZFriendsPeerLink *)link;
// The callback secrets to advertise now: requests nobody answered yet, with today's secret and its last broadcast.
- (NSArray<SZFriendsPendingCallback *> *)advertisedCallbacksAtDate:(NSDate *)now;
@end

// Host attestations on Add by ID answers (ADR 0004, Review amendments, 9; SZFriendsNearbyService+Attestation.m).
typedef NS_ENUM(NSInteger, SZFriendsAnswerAttestation) {
    // None, or one that proves nothing about the ID asked for: unreadable, from a host our list does not name, too old,
    // or this key's own for another ID (a holder renamed since). The answer takes one of the unattested slots.
    SZFriendsAnswerUnattested = 0,
    // The host says the ID asked for is reserved for this key: the answer is the holder's, and confirmed.
    SZFriendsAnswerAttested = 1,
    // It names another identity key: someone showing a holder's attestation as their own. Refused outright.
    SZFriendsAnswerRefused = 2,
};

// Pure: what `presented` (an answer's Attestation field) says about `identityKey` holding `requestedID` according to
// `list`, at `now`. `attestation` gets the parsed attestation when the answer is attested, nil otherwise.
SZFriendsAnswerAttestation SZFriendsJudgeAnswerAttestation(NSData *_Nullable presented,
                                                           SZFriendsHostList *_Nullable list,
                                                           NSString *_Nullable requestedID, NSData *identityKey,
                                                           NSDate *now,
                                                           SZFriendsHostAttestation *_Nullable *_Nullable attestation);

@interface SZFriendsNearbyService (Attestation)
// Holder: what our IK callback carries, our attestation for the ID we hold now; nil when we have none to show.
- (nullable NSData *)attestationForOurAnswer;
// Requester: the judgement on an answer presenting our token `token`, against the ID that request asked for and the
// verified host list. Reads only, so the key policy may ask.
- (SZFriendsAnswerAttestation)judgeAnswerWithToken:(NSData *)token
                                       identityKey:(NSData *)identityKey
                                         presented:(nullable NSData *)presented
                                               now:(NSDate *)now
                                       attestation:(SZFriendsHostAttestation *_Nullable *_Nullable)attestation;
// Requester, once the store gave the answer its conversation: an attested answer confirms the ID; an unattested one
// from a key we did not know keeps no Friends ID we typed, so only their own PROFILE can name one, unconfirmed.
- (void)recordAnswerInConversation:(NSString *)conversationID
                       attestation:(nullable SZFriendsHostAttestation *)attestation
                       requestedID:(nullable NSString *)requestedID
                          keyKnown:(BOOL)keyKnown;
@end

NS_ASSUME_NONNULL_END
