// A paced Unix-socket byte stream for the harness's scripted Bluetooth adapter (SZFriendsE2EBluetooth.h).

#import <Foundation/Foundation.h>

#import "service/session/SZFriendsSession.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFE2ESocketStream : NSObject <SZFriendsByteStream>
// Takes ownership of `fd`. `queue` serves completions until -startWithQueue: names the session's queue.
- (instancetype)initWithDescriptor:(int)fd bytesPerSecond:(double)rate queue:(dispatch_queue_t)queue;
@end

NS_ASSUME_NONNULL_END
