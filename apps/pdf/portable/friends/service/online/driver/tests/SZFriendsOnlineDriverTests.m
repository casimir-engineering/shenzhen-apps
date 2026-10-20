// friends-driver-check: the online driver joining the host's protocol 2, the signalling, the route order, the transport
// and the NAT techniques (SZFriendsOnlineDriver.h). Two drivers meet through in-memory sids; the transport binds to
// 127.0.0.1 only. The relay scenario needs FRIENDS_TEST_COTURN and skips, saying so, without it.

#import "SZFODriverTestSupport.h"

#import <sodium.h>

int main(void) {
    @autoreleasepool {
        if (sodium_init() < 0) return 1;
        // Before any context exists: every one this binary makes is loopback-only.
        SZFriendsOnlineDriverTestHooks.loopbackOnly = YES;
        struct {
            const char *name;
            void (*run)(void);
        } tests[] = {
            {"helpers", SZFODTestHelpers},
            {"gating", SZFODTestGating},
            {"backoff and lookups", SZFODTestBackoffLookups},
            {"side path", SZFODTestSidePath},
            {"direct", SZFODTestDirect},
            {"simultaneous", SZFODTestSimultaneous},
            {"back while we wait", SZFODTestBackWhileWeWait},
            {"relay and leave", SZFODTestRelayAndLeave},
            {"probing", SZFODTestProbing},
            {"network change", SZFODTestNetworkChange},
            {"reach", SZFODTestReach},
            {"add by ID online", SZFODTestByID},
            {"joining a profile", SZFODTestJoin},
        };
        for (size_t i = 0; i < sizeof tests / sizeof tests[0]; i++) {
            int before = SZFODFailures;
            NSDate *start = [NSDate date];
            tests[i].run();
            fprintf(stderr, "%s %s (%.1f s)\n", SZFODFailures == before ? "ok  " : "FAIL", tests[i].name,
                    -start.timeIntervalSinceNow);
        }
        if (SZFODFailures > 0) {
            fprintf(stderr, "friends-driver-check: %d failure(s)\n", SZFODFailures);
            return 1;
        }
        fprintf(stderr, "friends-driver-check: all passed\n");
    }
    return 0;
}
