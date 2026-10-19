// The helper the links e2e runs (SZFriendsLinksE2ETests.m): the production helper objects with this main in place of
// main.m. It sets the online driver's and the links' test hooks, then hands over to the real SZFriendsHelperMain; the
// shipped main never sets them. Refuses to start without SZFRIENDS_STATE_DIR, so a stray run can never touch the real
// Friends state or the Keychain.
//   - Peer connections bind to 127.0.0.1 and accept loopback candidates, links' too; no router is asked for a port
//     mapping.
//   - While <state dir>/online-block-direct exists, no direct candidate is sent or applied: only the relay connects.
//   - SZFRIENDS_TEST_LINK_NO_CLONE=1: every link holds its original, as on a volume without clones.
//   - <state dir>/links-clock-offset holds seconds added to the clock link expiry reads.
//   - An app opening a link tries the relay after 3 s of direct attempts, not 12.

#import <Foundation/Foundation.h>

#import "service/helper/SZFriendsHelper.h"
#import "service/links/SZFriendsLinksInternal.h"
#import "service/online/driver/SZFriendsOnlineDriver.h"
#import "service/online/transport/SZFriendsOnlineTransportInternal.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSDictionary<NSString *, NSString *> *env = [NSProcessInfo processInfo].environment;
        NSString *state = env[@"SZFRIENDS_STATE_DIR"];
        if (state.length == 0) {
            fprintf(stderr, "szfriends-links-e2e-helper: SZFRIENDS_STATE_DIR must be set\n");
            return 2;
        }
        SZFriendsOnlineDriverTestHooks.loopbackOnly = YES;
        SZFriendsOnlineTestLinksUseLocalAddresses = YES; // links on loopback, and coturn relaying from en0
        NSString *block = [state stringByAppendingPathComponent:@"online-block-direct"];
        SZFriendsOnlineDriverTestHooks.directPathsBlocked = ^BOOL {
            return [[NSFileManager defaultManager] fileExistsAtPath:block];
        };
        SZFriendsLinkClonesRefused = [env[@"SZFRIENDS_TEST_LINK_NO_CLONE"] isEqualToString:@"1"];
        NSString *offset = [state stringByAppendingPathComponent:@"links-clock-offset"];
        SZFriendsLinkService.testClock = ^NSDate * {
            NSString *text = [NSString stringWithContentsOfFile:offset encoding:NSUTF8StringEncoding error:NULL];
            return [NSDate dateWithTimeIntervalSinceNow:text.doubleValue];
        };
        SZFriendsLinkEnvironment.defaultDirectTimeout = 3;
    }
    return SZFriendsHelperMain(argc, argv);
}
