// Internal to service/online/transport/: one libdatachannel peer connection as an SZFriendsOnlineConnection, the
// data channel as an SZFriendsByteStream, and the bridge from libdatachannel's threads. Identifiers are
// libdatachannel's integer handles, so this header needs no rtc.h.

#import <Foundation/Foundation.h>

#import "service/online/transport/SZFriendsOnlineTransportInternal.h"

NS_ASSUME_NONNULL_BEGIN

// libdatachannel's states, as plain integers (rtcState, rtcIceState, rtcGatheringState).
typedef NS_ENUM(NSInteger, SZFriendsOnlinePCState) {
    SZFriendsOnlinePCStateConnected = 2,
    SZFriendsOnlinePCStateDisconnected = 3,
    SZFriendsOnlinePCStateFailed = 4,
    SZFriendsOnlinePCStateClosed = 5,
};

#pragma mark - The data channel as a byte stream

// Write completions are held while more than this is buffered in the channel, and released below the low mark. Small
// enough that a message queued behind a file waits well under a second on the 5 Mbit/s relay, large enough to keep
// SCTP's window full on a fast path.
extern const NSUInteger SZFriendsOnlineChannelHighWater;
extern const NSUInteger SZFriendsOnlineChannelLowWater;
// Bytes a stream keeps for its owner before -startWithQueue:; a peer sending more before the session starts is
// closed (nothing above ADR 0001's first handshake message is legitimate then).
extern const NSUInteger SZFriendsOnlineUnstartedBufferMax;

@interface SZFriendsOnlineDataChannelStream : NSObject <SZFriendsByteStream>
// `connectionQueue` is where every channel event and every state change runs; callbacks go to the start queue.
- (instancetype)initWithChannel:(int)channel
                connectionQueue:(dispatch_queue_t)connectionQueue
                     messageMax:(NSUInteger)messageMax NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) int channel;
// Connection queue only.
- (void)channelDidReceive:(NSData *)data;
- (void)channelBufferedAmountLow;
// The path ended under the stream: onClose(error) once, unless the owner closed it first.
- (void)endWithError:(nullable NSError *)error;
@property(nonatomic, readonly) BOOL ended;
// Called on the connection queue when the owner closes the stream.
@property(nonatomic, copy, nullable) void (^onOwnerClose)(void);
@end

#pragma mark - The peer connection

@interface SZFriendsOnlinePeerConnection : NSObject <SZFriendsOnlineConnectionExtras>
- (instancetype)initWithRequest:(id<SZFriendsOnlineConnectionRequest>)request
                      transport:(SZFriendsOnlineDataChannelTransport *)transport
                       delegate:(id<SZFriendsOnlineConnectionDelegate>)delegate
                          queue:(dispatch_queue_t)queue NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// Creates the peer connection: an offerer opens its data channel (which creates the offer), an answerer applies
// `offer` (which creates the answer). NO with SZFriendsOnlineErrorUnavailable or the offer's error.
- (BOOL)startWithServerURL:(nullable NSString *)serverURL
                     offer:(nullable SZFriendsOnlineDescription *)offer
                  sidePath:(nullable id<SZFriendsOnlineSidePath>)sidePath
                     error:(NSError *_Nullable *_Nullable)error;
@end

// SZFriendsOnlinePeerConnection+Events.m: what the stack and the side path report.
@interface SZFriendsOnlinePeerConnection (Events) <SZFriendsOnlineSidePathEvents>
// From libdatachannel's threads (SZFriendsOnlineCallbacks.m). Each copies what it needs and continues on the queue.
- (void)stackDidCreateDescription:(NSString *)sdp;
- (void)stackDidGatherCandidate:(NSString *)line;
- (void)stackGatheringDidComplete;
- (void)stackStateDidChange:(SZFriendsOnlinePCState)state;
- (void)stackICEDidConnect;
- (void)stackChannelDidOpen:(int)channel;
- (void)stackChannel:(int)channel didReceive:(NSData *)data;
- (void)stackChannelDidReceiveText:(int)channel;
- (void)stackChannelBufferedAmountLow:(int)channel;
- (void)stackChannelDidClose:(int)channel;
@end

#pragma mark - Bridge (SZFriendsOnlineCallbacks.m)

// Routes libdatachannel's callbacks for `handle` (a peer connection or a channel) to `connection`, held weakly.
void SZFriendsOnlineRegisterHandle(int handle, SZFriendsOnlinePeerConnection *connection);
void SZFriendsOnlineUnregisterHandle(int handle);
void SZFriendsOnlineInstallPeerCallbacks(int peerConnection);
void SZFriendsOnlineInstallChannelCallbacks(int channel);

NS_ASSUME_NONNULL_END
