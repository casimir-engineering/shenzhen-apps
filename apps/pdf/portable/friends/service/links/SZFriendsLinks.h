// Shenzhen Friends links in the helper: download links this person makes and serves, the friend link's invite, and
// download links opened in this Mac's apps (portable/docs/plans/friends-links.md; PROTOCOL.md § Links).
//
// Helper-only. Owns:
//   - making a download link: the file held at once (an APFS clone, or the original's size, dates and hashes), no size
//     limit, an expiry of 1, 7 or 30 days, registered with the host (link_register; the host keeps only a keyed hash
//     of the id) while the helper is connected, and unregistered on Revoke;
//   - serving it: an open from the page or another Mac's helper arrives as a host sid (via link); the opener proves the
//     secret before anything else happens, then gets the metadata and the file over a WebRTC data channel, direct or
//     through the relay (SZFriendsLinksInternal.h); a finished download is counted;
//   - opening one in an app: the same exchange from the opener's end, through this helper's own host connection, the
//     file stored as a received transfer in the sender's conversation;
//   - the friend link's invite tokens, through the store (SZFriendsStoreLinks.h).
// Nothing here runs at launch: the service is made on first use, and serving starts only once the online driver says
// the host takes online messages.
//
// Threading: every method on the queue given at init (the helper's), and every callback arrives there.

#import <Foundation/Foundation.h>

#import "service/discovery/SZFriendsDiscovery.h"
#import "service/online/SZFriendsOnlineTransport.h"

NS_ASSUME_NONNULL_BEGIN

@class SZFriendsDownloadLinkPayload;
@class SZFriendsDownloadLinkRecord;
@class SZFriendsHostOnline;
@class SZFriendsIdentity;
@class SZFriendsLinkMetadata;
@class SZFriendsStore;
@class SZFriendsTransfers;

// How a download link's opening ended, on either end.
typedef NS_ENUM(NSInteger, SZFriendsLinkOutcome) {
    SZFriendsLinkOutcomeDone = 0,        // the whole file arrived and its SHA-256 matched
    SZFriendsLinkOutcomeUnavailable = 1, // nobody answered: the sender's Mac is not connected, or nobody holds the link
    SZFriendsLinkOutcomeEnded = 2,       // the sender said the link was revoked or has expired
    SZFriendsLinkOutcomeChanged = 3,     // the sender's file changed after the link was made
    SZFriendsLinkOutcomeFailed = 4,      // no path opened, or what arrived did not check
};

// What a link's peer connections need, from the online driver's context.
@interface SZFriendsLinkEnvironment : NSObject
@property(nonatomic, strong) id<SZFriendsOnlineTransport> transport;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy, nullable) NSString *stunURI; // the connected host's, numeric; nil gathers no srflx
// Tests: while this answers YES only relay candidates are sent or applied (the driver's scripted direct failure).
@property(nonatomic, copy, nullable) BOOL (^directPathsBlocked)(void);
@property(nonatomic) NSTimeInterval answerTimeout; // 15 s: opener, from the open to the sender's challenge
@property(nonatomic) NSTimeInterval directTimeout; // 12 s: opener, the direct attempt before the relay (the page's)
@property(nonatomic) NSTimeInterval relayTimeout;  // 25 s: opener, the relayed attempt
@property(nonatomic) NSTimeInterval setupTimeout;  // 60 s: sender, from the hello to an open channel
@property(nonatomic) NSTimeInterval startTimeout;  // 15 min: sender, until the page asks for the file
// 30 s: opener, a download that receives nothing this long counts as dropped and carries on over a new connection
// (not every relay drop closes the channel at once).
@property(nonatomic) NSTimeInterval stallTimeout;
// Tests: the direct timeout every new environment starts with (12 s unless set).
@property(class, nonatomic) NSTimeInterval defaultDirectTimeout;
@end

// Where an opened link's file goes, in order: the metadata, then every byte at its offset, then the end. Returning
// NO stops the download (Failed).
@protocol SZFriendsLinkSink <NSObject>
- (BOOL)linkDidReceiveMetadata:(SZFriendsLinkMetadata *)metadata;
- (BOOL)linkDidReceiveBytes:(NSData *)bytes atOffset:(uint64_t)offset;
// Every byte arrived and the file's SHA-256 matched the metadata's.
- (BOOL)linkDidFinish;
// The download stopped before that (whatever arrived is to be thrown away).
- (void)linkDidStop:(SZFriendsLinkOutcome)outcome;
@end

// One opening of a download link, from the opener's end: the setup, then the download into `sink`. The browser
// stand-in of the tests and an app's receive_link both use it.
@interface SZFriendsLinkOpening : NSObject
- (nullable instancetype)initWithLinkID:(NSData *)linkID
                                 secret:(NSData *)secret
                            environment:(SZFriendsLinkEnvironment *)environment
                                   sink:(id<SZFriendsLinkSink>)sink;
- (instancetype)init NS_UNAVAILABLE;
// `open` sends the hello as the open's payload (link_open for a guest, sig_open to.link_id for a helper) and gives back
// the sid. `completion` runs once with how it ended; the sink has heard everything by then.
- (void)startWithOpen:(void (^)(NSData *hello, void (^done)(id _Nullable channel, BOOL ownerOnline)))open
           completion:(void (^)(SZFriendsLinkOutcome outcome))completion;
@property(nonatomic, readonly) uint8_t attempt; // the attempt whose channel carried the file: 1 direct, 2 relayed
// Before `open`'s done(nil, NO): the host said the link ended (sig_opened's link_ended), so the opening ends Ended
// rather than Unavailable.
- (void)noteLinkEnded;
- (void)cancel;
@end

@interface SZFriendsLinkService : NSObject
- (instancetype)initWithStore:(SZFriendsStore *)store
                    transfers:(SZFriendsTransfers *)transfers
                     identity:(SZFriendsIdentity *)identity
               stateDirectory:(NSString *)stateDirectory
                        queue:(dispatch_queue_t)queue NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// The page origin links are made for ("https://friends.meerkat.orgabots.com"); nil makes no link.
@property(nonatomic, copy, nullable) NSString *_Nullable (^linkOrigin)(void);
// The online driver's transport and STUN, or nil while online Friends is unavailable.
@property(nonatomic, copy, nullable) SZFriendsLinkEnvironment *_Nullable (^environment)(void);
// The check-in client's online side: registers links, and opens sids for receive_link.
@property(nonatomic, weak, nullable) SZFriendsHostOnline *hostOnline;
// Something the snapshots show changed: a link expired, a download was counted, a received file arrived.
@property(nonatomic, copy, nullable) void (^onChange)(void);
// The person's own name and Friends ID, for the metadata's sender.
@property(nonatomic, copy, nullable) NSString *_Nullable (^profileName)(void);

// The host takes online messages now: every live link is registered again, and expired ones go.
- (void)hostBecameAvailable;
// An open toward this helper via a link id (sig_incoming via link). NO when it is not ours to answer: the caller
// closes the sid without a word.
- (BOOL)receiveOpenOfLinkID:(NSData *)linkID channel:(id)channel payload:(NSData *)payload;

// make_download_link: holds the file (off the queue: hashing a large file takes a while) and stores the link; the
// completion has the link and its URL, or a store-domain error (FileMissing, FolderNotSupported, SourceChanged when a
// revision's size or SHA-256 does not match, Constraint for too many links, DiskFull).
- (void)makeDownloadLinkForPath:(NSString *)path
                    displayName:(nullable NSString *)displayName
                 revisionSHA256:(nullable NSData *)revisionSHA256
                   revisionSize:(nullable NSNumber *)revisionSize
                    expiresDays:(NSInteger)days
                     completion:(void (^)(SZFriendsDownloadLinkRecord *_Nullable link, NSString *_Nullable url,
                                          NSError *_Nullable error))completion;
// revoke_link: the link stops at once (unregistered, its clone deleted). NotFound for an unknown id.
- (BOOL)revokeLinkID:(NSData *)linkID error:(NSError **)error;
// Links expire on their own; the helper calls this hourly and when the host comes back.
- (void)expireLinks;
// The live download links, newest first.
- (NSArray<SZFriendsDownloadLinkRecord *> *)liveLinks;

// The friend link: its URL (made with the standing invite, created on first use), and reset_friend_link.
- (nullable NSString *)friendLinkURLWithFriendsID:(NSString *)friendsID name:(nullable NSString *)name;
- (BOOL)resetFriendLinkWithError:(NSError **)error;

// receive_link: opens the link through this helper's host connection. `started` runs once: with the conversation the
// file goes to and the metadata, once the sender's metadata arrived and the transfer is recorded; or with an outcome
// and error code when it ends before (Unavailable, Ended, Changed, Failed). The file then arrives in the background.
- (void)receiveLink:(SZFriendsDownloadLinkPayload *)payload
            started:(void (^)(NSString *_Nullable conversationID, SZFriendsLinkMetadata *_Nullable metadata,
                              SZFriendsLinkOutcome outcome))started;

// Tests: the number of openings being served now, and the clock expiry reads (the wall clock while nil).
@property(nonatomic, readonly) NSUInteger servingCount;
@property(class, nonatomic, copy, nullable) NSDate * (^testClock)(void);
@end

NS_ASSUME_NONNULL_END
