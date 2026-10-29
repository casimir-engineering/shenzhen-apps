// Shenzhen Friends session suite: Noise vectors, the codec, the secure channel over in-memory streams with fault
// injection, comparison codes, chunk flow and resume, previews and device chains. Prints "SZFriendsSessionTests
// passed" and exits 0 only when every check passed. Usage: SZFriendsSessionTests <vector directory>

#import <Foundation/Foundation.h>

#import <sodium.h>

#import "SZFriendsSessionTestSupport.h"
#import "SZFriendsSessionTests.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: %s <vector directory>\n", argv[0]);
            return 2;
        }
        if (sodium_init() < 0) {
            fprintf(stderr, "libsodium failed to initialise\n");
            return 1;
        }
        // Tests never reach a real state directory, key store or network; these make an accident harmless.
        NSString *state = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
        setenv("SZFRIENDS_STATE_DIR", state.fileSystemRepresentation, 1);
        setenv("SZFRIENDS_KEY_STORE", "file", 1);

        NSString *vectors = @(argv[1]);
        NSArray *groups = @[
            @[ @"vectors", ^{ SZFRunNoiseVectorTests(vectors); } ],
            @[ @"noise", ^{ SZFRunNoiseUnitTests(); } ],
            @[ @"codec", ^{ SZFRunFrameCodecTests(); } ],
            @[ @"channel", ^{ SZFRunChannelTests(); } ],
            @[ @"policy", ^{ SZFRunChannelPolicyTests(); } ],
            @[ @"faults", ^{ SZFRunChannelFaultTests(); } ],
            @[ @"lifetime", ^{ SZFRunChannelLifetimeTests(); } ],
            @[ @"liveness", ^{ SZFRunChannelLivenessTests(); } ],
            @[ @"fast transfers", ^{ SZFRunFastTransferTests(); } ],
            @[ @"refusals", ^{ SZFRunChannelRefusalTests(); } ],
            @[ @"peer identity", ^{ SZFRunChannelIdentityTests(); } ],
            @[ @"scripted peer", ^{ SZFRunScriptedPeerTests(); } ],
            @[ @"codes", ^{ SZFRunCodeTests(); } ],
            @[ @"chunk flow", ^{ SZFRunChunkFlowTests(); } ],
            @[ @"resume", ^{ SZFRunTransferResumeTests(); } ],
            @[ @"domains", ^{ SZFRunSignatureDomainTests(vectors); } ],
            @[ @"thumbnails", ^{ SZFRunThumbnailFrameTests(); } ],
            @[ @"chain", ^{ SZFRunChainFrameTests(); } ],
            @[ @"join", ^{ SZFRunJoinFrameTests(); } ],
            @[ @"sync", ^{ SZFRunSyncFrameTests(); } ],
            @[ @"again", ^{ SZFRunAgainFrameTests(); } ],
        ];
        for (NSArray *group in groups) {
            NSDate *start = [NSDate date];
            int before = SZFTestFailures;
            ((void (^)(void))group[1])();
            printf("  %-14s %5.2f s%s\n", [group[0] UTF8String], -[start timeIntervalSinceNow],
                   SZFTestFailures == before ? "" : "  FAILED");
        }

        [[NSFileManager defaultManager] removeItemAtPath:state error:NULL];
        if (SZFTestFailures != 0) {
            fprintf(stderr, "SZFriendsSessionTests: %d check(s) failed\n", SZFTestFailures);
            return 1;
        }
        printf("SZFriendsSessionTests passed\n");
        return 0;
    }
}
