// friends-one-identity-check: the runner (SZFriendsE2EOneIdentity.h).
//
// Usage: SZFriendsE2EOneIdentityTests <oneid helper> <animal manifest> [scenario numbers, e.g. 1,4]
// The environment names the app programs (oneid.mk): SZFRIENDS_E2E_APPKIT_APP, SZFRIENDS_E2E_GTK_APP and its
// SZFRIENDS_E2E_GTK_QUIET, SZFRIENDS_E2E_3D (Shenzhen 3D's tree) and SZFRIENDS_E2E_NODE.

#import "SZFriendsE2EOneIdentity.h"

#import <sodium.h>

// Each scenario starts the three apps several times; the Electron shell alone takes a few seconds to come up.
static const NSTimeInterval kScenarioBudget = 180;

typedef BOOL (*SZFE2EOneIDScenario)(SZFE2EWorld *world);

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3 || sodium_init() < 0) {
            fprintf(stderr, "usage: SZFriendsE2EOneIdentityTests <oneid helper> <animal manifest> [scenarios]\n");
            return 2;
        }
        NSString *executable = @(argv[1]), *manifest = @(argv[2]);
        char template[1024];
        NSString *pattern = [NSTemporaryDirectory() stringByAppendingPathComponent:@"szfo.XXXXXX"];
        strlcpy(template, pattern.fileSystemRepresentation, sizeof(template));
        NSString *root = mkdtemp(template) ? @(template) : nil;
        if (root == nil || ![[NSFileManager defaultManager] isExecutableFileAtPath:executable]) {
            fprintf(stderr, "SZFriendsE2EOneIdentityTests: no scratch directory or no helper at %s\n", argv[1]);
            return 2;
        }
        SZFE2EWorld *world = [[SZFE2EWorld alloc] initWithExecutable:executable manifest:manifest root:root];
        struct {
            const char *name;
            SZFE2EOneIDScenario run;
        } scenarios[] = {
            {"one computer: three apps, in every start order, share one helper and one identity",
             SZFE2EOneIDScenarioStartOrders},
            {"one computer: what one app's view sends, reads or deletes, the other two views show at once",
             SZFE2EOneIDScenarioRealViews},
            {"one computer: apps carrying older and newer helpers, in every start order, end on the newest, once",
             SZFE2EOneIDScenarioBuilds},
            {"one computer: a crashed helper is replaced once, whichever app notices first", SZFE2EOneIDScenarioCrash},
            {"one computer: every app finds the same Friends home and none makes its own", SZFE2EOneIDScenarioHome},
            {"two computers nearby: chats, friends, name, deletions and You stay the same both ways",
             SZFE2EOneIDScenarioComputersNearby},
            {"two computers online: the same through the host, and the relay", SZFE2EOneIDScenarioComputersOnline},
            {"two computers: one away while the other changes things, then back, nearby and online",
             SZFE2EOneIDScenarioComputersAway},
        };
        NSArray<NSString *> *only = argc > 3 ? [@(argv[3]) componentsSeparatedByString:@","] : nil;
        int failed = 0;
        for (size_t i = 0; i < sizeof(scenarios) / sizeof(scenarios[0]); i++) {
            if (only != nil && ![only containsObject:[NSString stringWithFormat:@"%zu", i + 1]]) continue;
            int before = SZFE2EFailures;
            [world beginScenario:[NSString stringWithFormat:@"o%02zu", i + 1]];
            NSDate *start = [NSDate date];
            BOOL ok = scenarios[i].run(world) && SZFE2EFailures == before;
            NSTimeInterval took = -start.timeIntervalSinceNow;
            if (ok && took > kScenarioBudget) {
                SZFE2EFail(__FILE__, __LINE__, "took <= 180 s", [NSString stringWithFormat:@"%.1f s", took]);
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
        } else fprintf(stderr, "SZFriendsE2EOneIdentityTests: logs kept under %s\n", root.UTF8String);
        if (failed > 0 || SZFE2EFailures > 0) {
            fprintf(stderr, "SZFriendsE2EOneIdentityTests: %d scenario(s) failed\n", failed);
            return 1;
        }
        printf("SZFriendsE2EOneIdentityTests passed\n");
        return 0;
    }
}
