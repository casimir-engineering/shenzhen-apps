// A connected TCP socket as an SZFriendsByteStream, for the TCP simultaneous-open path (ADR 0011): the stream ADR
// 0001 runs on directly, with no DTLS, Noise authenticating as on the LAN.
//
// Behaves like the LAN's Network.framework streams: onClose runs once when the peer ends the connection (nil for an
// orderly FIN, an error otherwise), never after -close; -close sends a FIN after everything already written and lets
// go within 2 s; a write's completion runs once its bytes are in the kernel. TCP keepalive starts after 60 s idle,
// probes every 10 s and gives up after 3 (ADR 0011 § Keepalive, provisional); Nagle is off, because ADR 0001 frames
// are written whole.

#import "service/online/nat/SZFriendsNAT.h"
#import "service/session/SZFriendsSession.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFriendsNATSocketStream : NSObject <SZFriendsByteStream>
// Takes ownership of `descriptor`, a connected TCP socket; it is closed by -close, an error or dealloc.
- (instancetype)initWithConnectedSocket:(int)descriptor NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly, nullable) SZFriendsNATEndpoint *remoteEndpoint;
@property(nonatomic, readonly, nullable) SZFriendsNATEndpoint *localEndpoint;
// For whoever handed the stream over (the TCP path's owner), not the session: runs once, on the stream's queue,
// when the stream ends for any reason (the peer, an error, or -close), after onClose if that runs.
@property(nonatomic, copy, nullable) void (^onEnd)(void);
@end

// A descriptor several dispatch sources watch: closed when the last of them lets go, from its cancel handler, as
// libdispatch requires (closing it while another source still watches it is undefined).
@interface SZFriendsNATSharedDescriptor : NSObject
- (instancetype)initWithDescriptor:(int)descriptor holders:(int)holders NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)letGo;
@end

NS_ASSUME_NONNULL_END
