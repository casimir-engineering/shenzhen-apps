// The NAT techniques' suite (ADR 0011 § Verification: each technique with a unit test and a loopback test).
// Usage: SZFriendsNATTests [<server/friends directory>]; with it, and Node.js 22.16 or later on PATH, the classifier
// also runs against the host's own STUN responder.

#import "SZFriendsNATTestSupport.h"

#include <signal.h>
#include <stdio.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        NSString *serverDirectory = argc > 1 ? @(argv[1]) : nil;
        struct {
            const char *name;
            void (^run)(void);
        } suites[] = {
            {"codecs", ^{ SZFTestCodecs(); }},
            {"classifier", ^{ SZFTestClassifier(serverDirectory); }},
            {"port mapping", ^{ SZFTestPortMapping(); }},
            {"UPnP", ^{ SZFTestUPnP(); }},
            {"prober", ^{ SZFTestProber(); }},
            {"TCP path", ^{ SZFTestTCPPath(); }},
        };
        for (size_t i = 0; i < sizeof suites / sizeof suites[0]; i++) {
            int before = SZFTestFailures;
            NSDate *start = [NSDate date];
            @autoreleasepool {
                suites[i].run();
            }
            fprintf(stderr, "  %-13s %s (%.2f s)\n", suites[i].name, SZFTestFailures == before ? "ok" : "FAILED",
                    MAX(0.0, -start.timeIntervalSinceNow));
        }
        if (SZFTestFailures > 0) {
            fprintf(stderr, "SZFriendsNATTests: %d failure(s)\n", SZFTestFailures);
            return 1;
        }
        printf("SZFriendsNATTests passed\n");
        return 0;
    }
}
