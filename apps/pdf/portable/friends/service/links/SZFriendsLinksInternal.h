// The links area's pieces, shared by its sources and tests. Not a public header: the helper uses SZFriendsLinks.h.
//
//   SZFriendsLinkSource.m    what a download link serves: an APFS clone, or the original while it is unchanged
//   SZFriendsLinkSetup       one opening of a download link over a host sid, for either end: the hello, the challenge,
//                            the proof, then offers, answers and candidates, and the peer connections they make
//   SZFriendsLinkUpload      the sender's records over an open data channel
//   SZFriendsLinkDownload    the opener's side of them, into a sink
//
// Pre-authentication (lead decision 6; SZFriendsOnlineTransport.h rule 3): the sender creates no peer connection and
// says nothing about the file until the opener has proved the link's secret over the sender's fresh challenge. Every
// offer, answer and candidate travels sealed under the session key, so the host can neither read nor swap the DTLS
// fingerprints inside the descriptions; each is also handed to the transport on its own, as the rule requires.

#import <Foundation/Foundation.h>

#import "service/links/SZFriendsLinkWire.h"
#import "service/links/SZFriendsLinks.h"
#import "service/online/driver/SZFriendsOnlineDriverInternal.h"
#import "service/store/SZFriendsStoreLinks.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - The file a link serves

// Tests only: every new link holds the original, as on a volume without clones.
extern BOOL SZFriendsLinkClonesRefused;

// Holds the file at `path` for a new link: an APFS clone at `clonePath` (0600) when the volume makes one, otherwise
// the original's size, dates, inode and device; then its size, SHA-256 and BLAKE2b, from what will be served. Nil with
// an SZFriendsStoreErrorDomain error: FileMissing, FolderNotSupported, or SourceChanged for an original that changed
// while it was read.
SZFriendsDownloadLinkRecord *_Nullable SZFriendsLinkHoldFile(NSString *path, NSString *clonePath, NSError **error);
NSString *_Nullable SZFriendsLinkServedPath(SZFriendsDownloadLinkRecord *link);
// The clone is there at its size; or the original still has its size and modification date, and either its inode
// and change time too, or its SHA-256. Reads the whole file in the last case only.
BOOL SZFriendsLinkSourceUnchanged(SZFriendsDownloadLinkRecord *link);
// Deletes the link's clone, if it is one this helper made in `linksDirectory`.
void SZFriendsLinkReleaseFile(SZFriendsDownloadLinkRecord *link, NSString *linksDirectory);

#pragma mark - Setup

// The page's end reasons, which the sender's end message and End record carry.
extern NSString *const SZFriendsLinkEndRevoked;   // "revoked"
extern NSString *const SZFriendsLinkEndExpired;   // "expired"
extern NSString *const SZFriendsLinkEndChanged;   // "changed"

// One connection attempt of a setup: 1 direct, 2 through the relay.
@interface SZFriendsLinkAttempt : NSObject
@property(nonatomic) uint8_t number;
@property(nonatomic) BOOL relay;
@property(nonatomic, strong, nullable) id<SZFriendsOnlineConnection> connection;
@property(nonatomic, copy) NSString *mid;
@property(nonatomic) BOOL described;    // our description went out
@property(nonatomic) BOOL remoteReady;  // the other side's description is applied
@property(nonatomic) BOOL localEnded, endSent, streamOpen;
@property(nonatomic, strong) NSMutableArray<NSArray<NSString *> *> *outgoing; // [candidate, mid] not sent yet
@property(nonatomic, strong) NSMutableArray<id> *held;                        // remote ones not applied yet
@end

NSData *SZFriendsLinkRandomNonce(void);
// An attempt number from a setup message ("a"): 1 or 2, else 0.
NSInteger SZFriendsLinkAttemptNumber(id _Nullable value);
// What a remote candidate line's type says, for the technique log.
SZFriendsOnlineTechnique SZFriendsLinkRemoteTechnique(NSString *line);
// The outcome an end message's reason means to the opener.
SZFriendsLinkOutcome SZFriendsLinkOutcomeForReason(id _Nullable reason);

@class SZFriendsLinkSetup;

@protocol SZFriendsLinkSetupDelegate <NSObject>
// A data channel opened for `attempt` (1 direct, 2 relayed): the records go over it, under that attempt's key.
- (void)linkSetup:(SZFriendsLinkSetup *)setup didOpenStream:(id<SZFriendsByteStream>)stream attempt:(uint8_t)attempt;
// The setup ended without a channel; nothing more arrives.
- (void)linkSetup:(SZFriendsLinkSetup *)setup didFail:(SZFriendsLinkOutcome)outcome;
@optional
// Sender: the opener proved the secret. Nil serves the link; an end reason refuses it, and the opener hears why.
- (nullable NSString *)linkSetupOpenerProved:(SZFriendsLinkSetup *)setup;
@end

@interface SZFriendsLinkSetup : NSObject <SZFriendsOnlineConnectionDelegate>
- (instancetype)initOpenerWithKeys:(SZFriendsLinkKeys *)keys environment:(SZFriendsLinkEnvironment *)environment;
- (instancetype)initSenderWithKeys:(SZFriendsLinkKeys *)keys
                           channel:(id<SZFriendsOnlineSignalChannel>)channel
                       environment:(SZFriendsLinkEnvironment *)environment;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, weak, nullable) id<SZFriendsLinkSetupDelegate> delegate;
@property(nonatomic, readonly) SZFriendsLinkKeys *keys;
@property(nonatomic, readonly) BOOL isSender;
// Opener: seals the hello and opens the sid with it through `open`, which gives back the sid (or nil) and whether the
// sender's helper is connected (`owner_online`). Not connected, or no answer in SZFriendsOnlineAnswerTimeout, is
// Unavailable: an app does not wait for a Mac that is off.
- (void)startWithOpen:(void (^)(NSData *hello, void (^done)(id<SZFriendsOnlineSignalChannel> _Nullable channel,
                                                             BOOL ownerOnline)))open;
// Sender: the hello from sig_incoming. NO (send nothing, close the sid) unless it opens under this link's keys.
- (BOOL)receiveHello:(NSData *)payload;
// The same for a link no longer served (revoked or expired, `reason`): it answers only the end, then closes.
- (BOOL)receiveHello:(NSData *)payload refusing:(nullable NSString *)reason;
// Ends the sid and every connection that carries no open stream. Idempotent.
- (void)close;
@end

#pragma mark - Upload and download

@interface SZFriendsLinkUpload : NSObject
// The metadata, then, from the opener's start, chunks while its credit lasts, reading `link`'s file; the final chunk
// goes only when the bytes sent hash to the link's SHA-256, otherwise an End record "changed". A start with "from"
// (a download carrying on after a drop) begins at that chunk, once the bytes before it are hashed again.
- (instancetype)initWithStream:(id<SZFriendsByteStream>)stream
                          link:(SZFriendsDownloadLinkRecord *)link
                      metadata:(SZFriendsLinkMetadata *)metadata
                    contentKey:(NSData *)contentKey
                         queue:(dispatch_queue_t)queue NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// Once: YES when the opener confirmed the whole file ("done", "ok"), NO when the stream ended otherwise.
@property(nonatomic, copy, nullable) void (^onFinish)(BOOL downloaded);
// How long a channel whose page never asks for the file ("start") is kept: 15 minutes, for the person to decide.
@property(nonatomic) NSTimeInterval startTimeout;
- (void)start;
- (void)close;
@end

@interface SZFriendsLinkDownload : NSObject
// `previous`, when given, is a download whose connection dropped: this one carries on from its first chunk not yet
// written, with its hash so far, once the new connection's metadata describes the same file; the sink hears the
// metadata only once.
- (instancetype)initWithStream:(id<SZFriendsByteStream>)stream
                    contentKey:(NSData *)contentKey
                          sink:(id<SZFriendsLinkSink>)sink
                         queue:(dispatch_queue_t)queue
                  resumingFrom:(nullable SZFriendsLinkDownload *)previous NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, copy, nullable) void (^onFinish)(SZFriendsLinkOutcome outcome);
// Failed because the connection dropped (or went quiet for stallTimeout) mid-file. The sink has not been told: the
// caller either carries on with a new download resuming from this one, or tells the sink it stopped.
@property(nonatomic, readonly) BOOL lost;
@property(nonatomic, readonly) uint64_t nextChunk; // the first chunk not yet written
@property(nonatomic) NSTimeInterval stallTimeout;  // 30 s
- (void)start;
- (void)close;
@end

NS_ASSUME_NONNULL_END
