// The online transport suite (friends-online-check): the pure rules first, then peer connections over 127.0.0.1,
// then the relay through a local coturn when one is available. Exits non-zero on any failure.

#import "SZFOnlineTestSupport.h"

#include <stdio.h>
#include <stdlib.h>

int main(void) {
    @autoreleasepool {
        SZFORunCandidateTests();
        SZFORunDescriptionTests();
        SZFORunTimerTests();
        SZFORunGatingTests();
        SZFORunLoopbackTests();
        SZFORunCancellationTests();
        SZFORunSidePathTests();
        SZFORunRelayTests();
    }
    if (SZFOFailures != 0) {
        fprintf(stderr, "SZFriendsOnlineTransportTests: %d failure(s)\n", SZFOFailures);
        return EXIT_FAILURE;
    }
    printf("SZFriendsOnlineTransportTests passed\n");
    return EXIT_SUCCESS;
}
