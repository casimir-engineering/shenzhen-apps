// Internal to SZFriendsOnlinePeerConnection*.m: the connection's state, shared by the file that handles the owner's
// calls and the file that handles libdatachannel's events. Every property is read and written on the connection's
// queue, except the immutable request fields (set in -init) and the stack handles (set in -start before any event).

#import "service/online/transport/SZFriendsOnlinePeerConnection.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFriendsOnlinePeerConnection ()
@property(nonatomic, readonly) dispatch_queue_t queue;
@property(nonatomic, readonly) BOOL allowsLoopback;
@property(nonatomic, readonly, copy, nullable) NSString *bindAddress; // tests only
@property(nonatomic, strong, nullable) id<SZFriendsOnlineConnectionDelegate> delegate; // nil once closed
// A failure found inside one of the owner's calls, told on the next turn of the queue unless the owner closes first.
@property(nonatomic, strong, nullable) id<SZFriendsOnlineConnectionDelegate> pendingFailureDelegate;
@property(nonatomic) int peerConnection;  // -1 until created
@property(nonatomic) int offererChannel; // -1 for an answerer
@property(nonatomic) uint16_t boundPort;

@property(nonatomic) BOOL closed; // closed or failed: the delegate hears nothing more
@property(nonatomic) BOOL descriptionSent;
@property(nonatomic) BOOL answerApplied;
@property(nonatomic) BOOL gatheringFinished, gatheringReported;
@property(nonatomic) BOOL iceConnected;
@property(nonatomic) BOOL streamEverOpened;
@property(nonatomic) BOOL channelPathDone, sidePathDone;
@property(nonatomic) NSUInteger relayCandidates;
@property(nonatomic) NSUInteger stackCandidates; // remote candidates given to libjuice, at most 30
@property(nonatomic, copy, nullable) NSString *remoteMid;
@property(nonatomic, copy, nullable) NSData *fingerprint;

@property(nonatomic, readonly) NSMutableArray<NSArray *> *heldLocalCandidates; // [line, technique] before the SDP
// Every candidate sent or applied, by endpoint ("UDP address port"), with the technique it travelled with: a
// selected pair is read back through these, because libjuice reports a pair it learnt from checks as peer-reflexive
// even when the same endpoint was signalled a moment later as host or server-reflexive.
@property(nonatomic, readonly) NSMutableDictionary<NSString *, SZFriendsOnlineCandidate *> *localCandidates;
@property(nonatomic, readonly) NSMutableDictionary<NSString *, NSNumber *> *localTechniques;
@property(nonatomic, readonly) NSMutableDictionary<NSString *, SZFriendsOnlineCandidate *> *remoteCandidates;
@property(nonatomic, readonly) NSMutableDictionary<NSString *, NSNumber *> *remoteTechniques;
// Remote TCP candidates that arrived before the side path started.
@property(nonatomic, readonly) NSMutableArray<NSString *> *heldSideCandidates;
@property(nonatomic) BOOL sidePathStarted;
@property(nonatomic, readonly) NSMutableSet<NSNumber *> *channels; // every channel handle registered

@property(nonatomic, strong, nullable) SZFriendsOnlineDataChannelStream *channelStream;
@property(nonatomic) SZFriendsOnlineRoute channelRoute;
@property(nonatomic, strong, nullable) dispatch_source_t routeTimer;
@property(nonatomic, strong, nullable) id<SZFriendsOnlineSidePath> sidePath;
@property(nonatomic, strong, nullable) id<SZFriendsByteStream> sideStream;
@property(nonatomic) SZFriendsOnlineRoute sideRoute;
@property(nonatomic, strong, nullable) NSError *channelError; // why the data channel's path ended

// SZFriendsOnlinePeerConnection.m
- (void)offerLocalCandidate:(SZFriendsOnlineCandidate *)candidate technique:(SZFriendsOnlineTechnique)technique;
- (void)bothDescriptionsApplied;
- (void)failWithError:(NSError *)error;
@end

@interface SZFriendsOnlinePeerConnection (EventsInternal)
- (void)reportGatheringIfDue;
- (void)stopRouteTimer;
@end

NS_ASSUME_NONNULL_END
