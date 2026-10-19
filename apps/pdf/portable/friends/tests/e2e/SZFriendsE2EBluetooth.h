// A scripted stand-in for the Bluetooth adapter, for the two-helper harness only (brief § Testing strategy: one Mac
// cannot discover itself over Bluetooth).
//
// Helpers meet in a shared directory instead of over the air: each writes what it advertises to a file and listens
// on Unix sockets beside it, and every helper polls the directory for the others. Streams are slow and small on
// purpose (4 KiB writes, about 200 KB/s), like an L2CAP channel, so a transfer over this "Bluetooth" lasts long
// enough to move to the faster loopback network mid-file. Its permission reads Allowed, so it starts at launch
// without `activate`, as real Bluetooth does once the person has allowed it.

#import <Foundation/Foundation.h>

#import "service/discovery/SZFriendsDiscovery.h"

NS_ASSUME_NONNULL_BEGIN

extern const double SZFriendsE2EBluetoothBytesPerSecond;

id<SZFriendsDiscoveryAdapter> SZFriendsE2EMakeScriptedBluetoothAdapter(dispatch_queue_t queue, NSString *directory);

NS_ASSUME_NONNULL_END
