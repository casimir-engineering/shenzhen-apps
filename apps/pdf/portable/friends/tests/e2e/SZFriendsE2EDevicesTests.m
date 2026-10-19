// friends-e2e-devices-check: the runner (SZFriendsE2EDevices.h).
//
// Usage: SZFriendsE2EDevicesTests <online e2e helper> <animal manifest> [scenario numbers, e.g. 1,4]

#import "SZFriendsE2EDevices.h"

#import <sodium.h>

// The brief's budget for one whole scenario.
static const NSTimeInterval kScenarioBudget = 60;

typedef BOOL (*SZFE2EDevicesScenario)(SZFE2EWorld *world);

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3 || sodium_init() < 0) {
            fprintf(stderr, "usage: SZFriendsE2EDevicesTests <online e2e helper> <animal manifest>\n");
            return 2;
        }
        NSString *executable = @(argv[1]), *manifest = @(argv[2]);
        // Private and per run, short enough for the scripted Bluetooth sockets the harness also makes.
        char template[1024];
        NSString *pattern = [NSTemporaryDirectory() stringByAppendingPathComponent:@"szfd.XXXXXX"];
        strlcpy(template, pattern.fileSystemRepresentation, sizeof(template));
        NSString *root = mkdtemp(template) ? @(template) : nil;
        if (root == nil || ![[NSFileManager defaultManager] isExecutableFileAtPath:executable]) {
            fprintf(stderr, "SZFriendsE2EDevicesTests: no scratch directory or no helper at %s\n", argv[1]);
            return 2;
        }
        SZFE2EWorld *world = [[SZFE2EWorld alloc] initWithExecutable:executable manifest:manifest root:root];
        struct {
            const char *name;
            SZFE2EDevicesScenario run;
        } scenarios[] = {
            {"devices: a computer joins nearby, then history goes both ways", SZFE2EDevicesScenarioJoinNearby},
            {"devices: a computer joins online with no nearby route, then syncs online",
             SZFE2EDevicesScenarioJoinOnline},
            {"devices: three computers, a partition and concurrent edits converge", SZFE2EDevicesScenarioPartition},
            {"devices: a removal reaches a sibling and a friend, and the removed computer stops",
             SZFE2EDevicesScenarioRevoke},
            {"devices: deleting one chat, then all history, reaches every computer", SZFE2EDevicesScenarioErase},
            {"devices: You carries a file everywhere; a large file waits on its computer until Get",
             SZFE2EDevicesScenarioYou},
            {"devices: a friend reaches one computer; a queued message leaves once, from either",
             SZFE2EDevicesScenarioFriendReachesOne},
            {"devices: a computer removed while away learns it once back nearby",
             SZFE2EDevicesScenarioRemovedWhileAway},
        };
        // While working on one scenario, only it runs; make always runs them all.
        NSArray<NSString *> *only = argc > 3 ? [@(argv[3]) componentsSeparatedByString:@","] : nil;
        int failed = 0;
        for (size_t i = 0; i < sizeof(scenarios) / sizeof(scenarios[0]); i++) {
            if (only != nil && ![only containsObject:[NSString stringWithFormat:@"%zu", i + 1]]) continue;
            int before = SZFE2EFailures;
            [world beginScenario:[NSString stringWithFormat:@"d%02zu", i + 1]];
            NSDate *start = [NSDate date];
            BOOL ok = scenarios[i].run(world) && SZFE2EFailures == before;
            NSTimeInterval took = -start.timeIntervalSinceNow;
            if (ok && took > kScenarioBudget) {
                SZFE2EFail(__FILE__, __LINE__, "took <= 60 s", [NSString stringWithFormat:@"%.1f s", took]);
                ok = NO;
            }
            printf("%s %s (%.1f s)\n", ok ? "ok  " : "FAIL", scenarios[i].name, took);
            fflush(stdout);
            if (!ok) {
                failed++;
                [world printLogs];
            }
            [world endScenario];
        }
        if (getenv("SZFRIENDS_E2E_KEEP_LOGS") == NULL) {
            [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
        } else fprintf(stderr, "SZFriendsE2EDevicesTests: helper logs kept under %s\n", root.UTF8String);
        if (failed > 0 || SZFE2EFailures > 0) {
            fprintf(stderr, "SZFriendsE2EDevicesTests: %d scenario(s) failed\n", failed);
            return 1;
        }
        printf("SZFriendsE2EDevicesTests passed\n");
        return 0;
    }
}
