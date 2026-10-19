// The helper the online scenarios run (SZFriendsE2EOnlineTests.m): the production helper objects with this main in
// place of main.m. It sets the online driver's test hooks (SZFriendsOnlineDriver.h) and hands over to the real
// SZFriendsHelperMain; the shipped main never sets them. Refuses to start without SZFRIENDS_STATE_DIR, so a stray run
// can never touch the real Friends state or the Keychain.
//   - Peer connections bind to 127.0.0.1 and accept loopback candidates; no router is asked for a port mapping.
//   - While <state dir>/online-block-direct exists, no direct candidate is sent or applied: only the relay connects.
//   - SIGUSR1 stands for a network change (what the system's change notification would say).

#import <Foundation/Foundation.h>

#include <signal.h>

#import "service/helper/SZFriendsHelper.h"
#import "service/online/driver/SZFriendsOnlineDriver.h"

static dispatch_source_t SZFE2EOnlineNetworkSignal;

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *state = [NSProcessInfo processInfo].environment[@"SZFRIENDS_STATE_DIR"];
        if (state.length == 0) {
            fprintf(stderr, "szfriends-e2e-online-helper: SZFRIENDS_STATE_DIR must be set\n");
            return 2;
        }
        SZFriendsOnlineDriverTestHooks.loopbackOnly = YES;
        NSString *block = [state stringByAppendingPathComponent:@"online-block-direct"];
        SZFriendsOnlineDriverTestHooks.directPathsBlocked = ^BOOL {
            return [[NSFileManager defaultManager] fileExistsAtPath:block];
        };
        signal(SIGUSR1, SIG_IGN);
        SZFE2EOnlineNetworkSignal =
            dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR1, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(SZFE2EOnlineNetworkSignal, ^{
            [SZFriendsOnlineDriverTestHooks simulateNetworkChange];
        });
        dispatch_resume(SZFE2EOnlineNetworkSignal);
    }
    return SZFriendsHelperMain(argc, argv);
}
