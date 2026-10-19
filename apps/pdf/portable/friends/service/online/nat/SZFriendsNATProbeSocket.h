// One UDP socket of a hard-NAT probe run (SZFriendsNATProber.h): non-blocking, read on the run's queue, its descriptor
// closed by its read source's cancel handler, as libdispatch requires.

#import "service/online/nat/SZFriendsNAT.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFriendsNATProbeSocket : NSObject
@property(nonatomic, readonly) int fd;
@property(nonatomic, readonly) uint16_t port;

// Bound to `port` (0: any) on the unspecified address of `family`, or on loopback when `loopbackOnly`; nil when the
// socket cannot be opened or bound (errno says why). `openDescriptors` holds one entry until the descriptor is
// closed; `readable` runs on `queue` whenever something waits to be read.
+ (nullable instancetype)socketWithFamily:(sa_family_t)family
                             loopbackOnly:(BOOL)loopbackOnly
                                     port:(uint16_t)port
                                    queue:(dispatch_queue_t)queue
                          openDescriptors:(dispatch_group_t)openDescriptors
                                 readable:(void (^)(SZFriendsNATProbeSocket *probeSocket))readable;
- (instancetype)init NS_UNAVAILABLE;

- (void)sendBytes:(const uint8_t *)bytes length:(size_t)length to:(SZFriendsNATEndpoint *)destination;
// Stops reading; the descriptor closes once the read source lets go of it.
- (void)close;

// 256 sockets need more descriptors than macOS's default soft limit of 256; the hard limit allows them.
+ (void)raiseFileLimit;
@end

NS_ASSUME_NONNULL_END
