// A network method whose permission and state a test writes to a file, for the harnesses only: the Nearby cards
// (Allow, Local Network off, Wi-Fi off, not working) come from the real helper's real snapshots, while the test plays
// the part of macOS and the radios.
//
// The file holds one word, re-read four times a second: not_asked (permission never asked; nothing starts at
// launch, and once started it reports Starting, as while the system's question is up), starting, working, denied,
// radio_off or unavailable. Every -start (which is what `activate`, Allow and Try Again lead to) adds a line to
// "<file>.starts", so a test sees the helper ask. It finds nobody and accepts nobody: a person cannot be met
// through it.

#import <Foundation/Foundation.h>

#import "service/discovery/SZFriendsDiscovery.h"

NS_ASSUME_NONNULL_BEGIN

id<SZFriendsDiscoveryAdapter> SZFriendsE2EMakeScriptedNearbyAdapter(dispatch_queue_t queue, NSString *scriptPath);

NS_ASSUME_NONNULL_END
