// Nearby Friends inside the helper: discovery, sessions and delivery wired together.
//
// Internal to the helper. Everything here runs on the helper queue. The pieces are other areas' public headers:
//   adapters -> SZFriendsDiscoveryCoordinator (merger, racer) -> SZFriendsSecureChannel per device
//   -> outbox entries become frames, acknowledged only after the recipient's durable commit
//   -> SZFriendsChunkSender / SZFriendsChunkReceiver move accepted files, resuming from the durable offset.
// ADR 0001 (sessions), ADR 0003 (store) and ADR 0004 (nearby) are the decisions; this layer adds no protocol of its
// own. The intent router tells it what changed; the publisher learns from `onChange` that snapshots may differ.

#import <Foundation/Foundation.h>

#import "service/discovery/SZFriendsDiscovery.h"
#import "service/helper/SZFriendsHelperServices.h"

NS_ASSUME_NONNULL_BEGIN

// A stranger seen through a public entry, as a browse handshake described them (send_request takes it).
@interface SZFriendsNearbyStranger : NSObject
@property(nonatomic, copy) NSString *nearbyID;
@property(nonatomic, copy) NSData *identityKey;
@property(nonatomic, copy, nullable) NSData *staticKey;
@property(nonatomic, copy, nullable) NSString *name;
@property(nonatomic, copy, nullable) NSString *friendsID;
@property(nonatomic, copy) SZFriendsPicture *picture;
@end

// What a live transfer looks like right now, beyond what the store has made durable.
typedef struct SZFriendsLiveTransfer {
    uint64_t bytes;             // received (incoming) or acknowledged by the recipient (outgoing)
    double bytesPerSecond;      // measured on the current link; 0 until a second has passed
    SZFriendsRouteMethod route; // the link carrying it
} SZFriendsLiveTransfer;

@interface SZFriendsNearbyService : NSObject
- (instancetype)initWithServices:(SZFriendsHelperServices *)services
                        adapters:(NSArray<id<SZFriendsDiscoveryAdapter>> *)adapters
                           queue:(dispatch_queue_t)queue NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Something a snapshot shows may have changed (people nearby, a route, a message arriving, progress).
@property(nonatomic, copy, nullable) void (^onChange)(void);

#pragma mark Lifecycle

// After the socket is bound: adapters ADR 0004 allows at launch (only once the store records that the person was
// asked), the first advertisement, the window and wake timers.
- (void)startAtLaunch;
// The person opened Friends: record that permission was asked, start every adapter (this may prompt).
- (void)activate;
// Exit, disable or handover: progress made durable, CLOSE on every session, adapters stopped. The completion runs
// once the CLOSE frames are written, or after a second at most.
- (void)shutdownWithCompletion:(void (^)(void))completion;
// A newer helper takes over: no new chunks start, so what is in flight drains and resumes in the successor.
- (void)beginHandover;
// A chunk is sent but not yet acknowledged, or received but not yet durable (handover waits for NO).
@property(nonatomic, readonly) BOOL workInFlight;
// Reset Friends is starting: every session closes and nothing is advertised or dialed until -identityDidReset,
// so the old identity's tags never go out beside the new one, even when the reset fails part-way.
- (void)suspendForReset;
// Reset Friends replaced the identity: advertising resumes with the new one.
- (void)identityDidReset;

#pragma mark Intents

// start_visibility / stop_visibility: the deadline (never extended) or nil, stored and advertised at once.
- (NSDate *)startVisibility;
- (void)stopVisibility;
// Relations, secrets or Add by ID requests changed (accept, decline, cancel, block, unblock, remove, add by ID).
- (void)peopleChanged;
// New outbox entries for this conversation (messages, offers, answers, presence secrets).
- (void)outboxChangedForConversation:(NSString *)conversationID;
// The name or picture friends see changed.
- (void)profileChanged;
// This person accepted, declined, cancelled or retried a transfer.
- (void)transferChanged:(NSString *)transferID;
// History was deleted: transfers it held stop.
- (void)historyDeleted;
// accept_key_change: the store made the static key the friend presented the one we dial.
- (void)keyChangeAccepted:(NSString *)conversationID;
@end

// Erase chat history (delete_history): with another device of ours in the profile, on every one of them (a deletion
// sync carries; SZFriendsNearbyService+Sync.m), otherwise here only. NO when the store failed.
@interface SZFriendsNearbyService (SyncHistory)
- (BOOL)eraseHistoryInConversation:(nullable NSString *)conversationID;
@end

// Friends over the Internet (SZFriendsNearbyService+Online.m, SZFriendsOnlineDriver.h).
@class SZFriendsHostOnline;
@interface SZFriendsNearbyService (OnlineHost)
// The check-in client's online side: the driver is made on the first call and does nothing until the host's welcome
// says it takes online messages.
- (void)attachOnlineHost:(SZFriendsHostOnline *)online;
// Check-in stopped, Reset Friends, exit: every attempt ends and nothing more is published or answered.
- (void)stopOnline;
// The host has said it takes online messages since the driver was made (a later drop of the host connection does not
// change it until -stopOnline): the helper announces `online` and its words say "online or nearby".
@property(nonatomic, readonly) BOOL reachesFriendsOnline;
// open_conversation: the person is looking at this friend now, so an attempt already running shows as Connecting.
- (void)conversationOpened:(NSString *)conversationID;
// What the words say about this friend while no session is up (SZFriendsOnlineReach), by the rule: Connecting only
// while an attempt runs and, within the last 45 s, a message or file was queued for them or the person opened the
// conversation; Unreachable only while a message or file waits and an attempt failed everywhere (the friend
// answered, and no path worked, the relay included), through the retries after it, until a stream opens, something
// new is queued, the conversation is opened or the network changes; otherwise Unknown, which reads "Not connected
// right now".
// Unknown for anyone the driver may not reach.
- (SZFriendsOnlineReach)onlineReachForPerson:(SZFriendsPersonRecord *)person now:(NSDate *)now;
@end

// File previews (SZFriendsNearbyService+Thumbnails.m).
@interface SZFriendsNearbyService (Thumbnails)
// Files were just offered (send_files, send_message): their previews are made off this queue and follow the offers.
- (void)makeThumbnailsForTransfers:(NSArray<NSString *> *)transferIDs;
@end

// What snapshots show, read from live discovery and sessions (SZFriendsNearbyService+Facts.m).
@interface SZFriendsNearbyService (Facts)
// send_request: the stranger behind a Nearby row, or nil when that row is gone or was never a stranger.
- (nullable SZFriendsNearbyStranger *)strangerWithNearbyID:(NSString *)nearbyID;
- (BOOL)hasAdapterForMethod:(SZFriendsDiscoveryMethod)method;
- (SZFriendsAdapterState)stateOfMethod:(SZFriendsDiscoveryMethod)method;
// The route of the session carrying this conversation, or None.
- (SZFriendsRouteMethod)liveRouteForConversation:(NSString *)conversationID;
// Nearby's people, from the merger's identified candidates: friends matched by tag, strangers whose public entry
// told us who they are. Never unmatched devices or unidentified entries.
- (NSArray<SZFriendsNearbyPersonFacts *> *)nearbyPeople;
// For each conversation seen nearby now, every discovery method that sees them (SZFriendsRouteMethod numbers in the
// order LAN, peer-to-peer Wi-Fi, Bluetooth), across all of that person's devices.
- (NSDictionary<NSString *, NSArray<NSNumber *> *> *)foundMethodsByConversation;
- (BOOL)liveTransfer:(NSString *)transferID state:(SZFriendsLiveTransfer *)state;
@end

// Mentions (SZFriendsNearbyService+Mentions.m, ADR 0007). An Add from a mention is an Add by ID that only the mentioned
// identity key may answer: its request token is this keyed hash of that key under the request's own callback secret,
// so the binding lives in what the store already keeps, and anyone else presenting the token is refused.
NSData *SZFriendsMentionRequestToken(NSData *callbackSecret, NSData *identityKey);

@interface SZFriendsNearbyService (Mentions)
// An arriving message's text with every Friends link that is not a well-formed mention of a word-list ID, and every
// mention past the twentieth, made plain text (PROTOCOL.md § Mentions, Arriving).
- (NSString *)textWithCheckedMentions:(NSString *)text;
// YES when `token` names an Add from a mention of ours bound to another identity key than `identityKey`. A pure read,
// for the listener's key policy as much as for the callback.
- (BOOL)requestToken:(NSData *)token refusesIdentityKey:(NSData *)identityKey atDate:(NSDate *)now;
// Whether `token` is our request from a mention or a friend link, made for exactly `identityKey`: that key is who the
// person asked for, so its answer needs no host's word.
- (BOOL)requestToken:(NSData *)token isBoundToIdentityKey:(NSData *)identityKey atDate:(NSDate *)now;
@end

NS_ASSUME_NONNULL_END
