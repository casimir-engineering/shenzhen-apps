// Shenzhen Friends helper link: the transport seam beneath SZFriendsHelperLink (internal; not a public header).
//
// The link owns everything the views rely on (subscriptions that survive reconnects, reply matching, the static
// strings); a transport only moves frames. Production uses the C client library (SZFriendsClientTransport); the
// views' tests use an in-process transport that replays the golden fixtures, so the link's routing is exercised
// by every view test without a socket.

#import <Foundation/Foundation.h>

#import "mac/SZFriendsHelperLink.h"

NS_ASSUME_NONNULL_BEGIN

@protocol SZFriendsLinkTransportDelegate <NSObject>
// Every helper frame, parsed (welcome, reply, snapshot, goodbye). Main thread.
- (void)transportDidReceiveFrame:(NSDictionary<NSString *, id> *)frame;
// `statusText` is the client library's line for non-Ready states, nil when Ready.
- (void)transportDidChangeState:(SZFriendsLinkState)state statusText:(nullable NSString *)statusText;
@end

@protocol SZFriendsLinkTransport <NSObject>
@property(nonatomic, weak, nullable) id<SZFriendsLinkTransportDelegate> delegate;
- (void)start;
- (void)stopDisablingFriends:(BOOL)disabling;
// Sends one intent; returns the frame id the reply will carry, or nil with a client-side error code
// ("not_ready", "frame_too_large", "internal") when nothing was sent.
- (nullable NSString *)sendIntent:(NSString *)type
                           fields:(NSDictionary<NSString *, id> *)fields
                        errorCode:(NSString *_Nullable *_Nonnull)errorCode;
@end

@interface SZFriendsHelperLink () <SZFriendsLinkTransportDelegate>
// Tests and probes: a link over any transport. -initWithHost: uses the C client library.
- (instancetype)initWithHost:(nullable id<SZFriendsHost>)host
                   transport:(id<SZFriendsLinkTransport>)transport NS_DESIGNATED_INITIALIZER;
@end

// The production transport over client/szfriends_client.h, driven from the main run loop.
@interface SZFriendsClientTransport : NSObject <SZFriendsLinkTransport>
- (instancetype)initWithHost:(id<SZFriendsHost>)host;
// Client capability strings this host earns (PROTOCOL.md § Capabilities), derived from what it implements.
+ (NSArray<NSString *> *)capabilitiesForHost:(id<SZFriendsHost>)host;
@end

NS_ASSUME_NONNULL_END
