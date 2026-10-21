// Process tests of the helper's lifecycle: real helper processes on temporary state directories (ADR 0002
// § Verification). Frames and dispatch are in the sibling SZFriendsHelperProcess*.m files.
//
// Usage: SZFriendsHelperProcessTests <path to Shenzhen Friends.app> <fixtures dir>

#import <Foundation/Foundation.h>

#import <signal.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>

#import "SZFriendsHelperProcessHarness.h"

BOOL SZFHTestFrames(SZFHHarness *harness);
BOOL SZFHTestHandshakeErrors(SZFHHarness *harness);
BOOL SZFHTestSocketFallback(SZFHHarness *harness);
BOOL SZFHTestUnsafeDirectories(SZFHHarness *harness);
BOOL SZFHTestSameBadge(SZFHHarness *harness);
BOOL SZFHTestDispatch(SZFHHarness *harness);
BOOL SZFHTestLongConversation(SZFHHarness *harness);
BOOL SZFHTestEveryIntent(SZFHHarness *harness, NSString *fixtures);
BOOL SZFHTestHandover(SZFHHarness *harness);
BOOL SZFHTestForgedHandover(SZFHHarness *harness);
BOOL SZFHTestAddByIDKeepsKeyedRows(SZFHHarness *harness);
BOOL SZFHTestAddByIDBroadcastsPastClaims(SZFHHarness *harness);
BOOL SZFHTestMessageStatus(SZFHHarness *harness);
BOOL SZFHTestMentionsWritten(SZFHHarness *harness);
BOOL SZFHTestAddFromMention(SZFHHarness *harness);
BOOL SZFHTestBlockAndRemoveDropPreviews(SZFHHarness *harness);
BOOL SZFHTestListRowsDescribeNewestItem(SZFHHarness *harness);
BOOL SZFHTestJoinIntents(SZFHHarness *harness);
BOOL SZFHTestDevicesIntents(SZFHHarness *harness);
BOOL SZFHTestYouIntents(SZFHHarness *harness);
BOOL SZFHTestResetUnreadableIdentity(SZFHHarness *harness);
BOOL SZFHTestIdentityReadableAgain(SZFHHarness *harness);
BOOL SZFHTestRemoveFromList(SZFHHarness *harness);
BOOL SZFHTestRemoveMenu(SZFHHarness *harness);
BOOL SZFHTestLeftoverYouIsNoRow(SZFHHarness *harness);
int SZFHHelloClientMain(const char *socket, const char *build);

static NSString *SZFHFixtures;
static BOOL TestEveryIntent(SZFHHarness *harness) {
    return SZFHTestEveryIntent(harness, SZFHFixtures);
}

static BOOL SZFHExitedCleanly(int status) {
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

// Twenty spawns at once on one state directory: one helper holds the lock, the rest exit 0 at once, and twenty
// clients all reach the same helper.
static BOOL TestSpawnRace(SZFHHarness *harness) {
    NSString *state = [harness makeDirectory];
    NSMutableArray<NSNumber *> *pids = [NSMutableArray array];
    NSDate *start = [NSDate date];
    for (int i = 0; i < 20; i++) {
        pid_t pid = [harness spawnHelperWithStateDirectory:state timeScale:1];
        CHECK(pid > 0, "spawn %d", i);
        [pids addObject:@(pid)];
    }
    // Polled together, so the time reported is when the last duplicate left, not a sum of waits.
    NSMutableArray<NSNumber *> *running = [pids mutableCopy];
    NSTimeInterval slowestDuplicate = 0;
    while (running.count > 1 && -start.timeIntervalSinceNow < 3) {
        for (NSNumber *pid in [running copy]) {
            int status = 0;
            if (![harness reap:pid.intValue status:&status]) continue;
            CHECK(SZFHExitedCleanly(status), "a duplicate exits with status 0, got %d", status);
            slowestDuplicate = -start.timeIntervalSinceNow;
            [running removeObject:pid];
        }
        usleep(2000);
    }
    CHECK(running.count == 1, "exactly one helper keeps running, not %lu", (unsigned long)running.count);
    NSString *socket = [harness socketPathForStateDirectory:state];
    NSMutableArray<SZFHClient *> *clients = [NSMutableArray array];
    for (int i = 0; i < 20; i++) {
        SZFHClient *client = [SZFHClient connectToSocket:socket timeout:5];
        CHECK(client != nil, "client %d connects", i);
        [clients addObject:client];
    }
    for (SZFHClient *client in clients) {
        NSDictionary *welcome = [client helloWithEmbeddedBuild:0];
        CHECK([welcome[@"type"] isEqual:@"welcome"], "%@", welcome);
        CHECK([welcome[@"helper"][@"pid"] intValue] == running.firstObject.intValue, "every client sees one helper");
    }
    printf("  spawn race: 19 duplicates exited within %.0f ms\n", slowestDuplicate * 1000);
    kill(running.firstObject.intValue, SIGTERM);
    int status = 0;
    CHECK([harness waitForExit:running.firstObject.intValue timeout:3 status:&status] && SZFHExitedCleanly(status));
    return YES;
}

// SIGKILL leaves no stale lock or socket behind: the next spawn serves at once.
static BOOL TestRestartAfterKill(SZFHHarness *harness) {
    NSString *state = [harness makeDirectory];
    pid_t first = [harness spawnHelperWithStateDirectory:state timeScale:1];
    NSString *socket = [harness socketPathForStateDirectory:state];
    SZFHClient *client = [SZFHClient connectToSocket:socket timeout:5];
    CHECK(client != nil && [[client helloWithEmbeddedBuild:0][@"type"] isEqual:@"welcome"]);
    kill(first, SIGKILL);
    CHECK([harness waitForExit:first timeout:3 status:NULL]);
    CHECK([client waitForEOFWithTimeout:3], "a crash closes without goodbye");
    pid_t second = [harness spawnHelperWithStateDirectory:state timeScale:1];
    SZFHClient *again = [SZFHClient connectToSocket:socket timeout:5];
    NSDictionary *welcome = [again helloWithEmbeddedBuild:0];
    CHECK([welcome[@"helper"][@"pid"] intValue] == second, "%@", welcome);
    kill(second, SIGTERM);
    CHECK([harness waitForExit:second timeout:3 status:NULL]);
    return YES;
}

// Exit a grace period after the last client (here 2 s at time scale 0.2); a client returning within it keeps the
// helper.
static BOOL TestGraceExit(SZFHHarness *harness) {
    NSString *state = [harness makeDirectory];
    pid_t pid = [harness spawnHelperWithStateDirectory:state timeScale:0.2];
    NSString *socket = [harness socketPathForStateDirectory:state];
    SZFHClient *first = [SZFHClient connectToSocket:socket timeout:5];
    CHECK([[first helloWithEmbeddedBuild:0][@"type"] isEqual:@"welcome"]);
    [first close];
    usleep(1000000);
    CHECK([harness isRunning:pid], "still inside the grace period");
    SZFHClient *second = [SZFHClient connectToSocket:socket timeout:2];
    CHECK([[second helloWithEmbeddedBuild:0][@"type"] isEqual:@"welcome"], "a returning client keeps the helper");
    usleep(1500000);
    CHECK([harness isRunning:pid], "the grace restarts only when the last client leaves");
    NSDate *left = [NSDate date];
    [second close];
    int status = 0;
    CHECK([harness waitForExit:pid timeout:4 status:&status], "exits after the grace period");
    NSTimeInterval waited = -left.timeIntervalSinceNow;
    CHECK(waited > 1.6 && waited < 3.0, "exited %.2f s after the last client, expected 2 s", waited);
    CHECK(SZFHExitedCleanly(status));
    struct stat st;
    CHECK(lstat(socket.fileSystemRepresentation, &st) != 0, "the socket file is gone after exit");
    return YES;
}

// No client ever connects (the spawning app died): exit after the first-client deadline (3 s at scale 0.1).
static BOOL TestNoClientExit(SZFHHarness *harness) {
    NSString *state = [harness makeDirectory];
    NSDate *start = [NSDate date];
    pid_t pid = [harness spawnHelperWithStateDirectory:state timeScale:0.1];
    int status = 0;
    CHECK([harness waitForExit:pid timeout:6 status:&status], "exits when nobody connects");
    NSTimeInterval waited = -start.timeIntervalSinceNow;
    CHECK(waited > 2.5 && waited < 4.5, "exited after %.2f s, expected 3 s", waited);
    CHECK(SZFHExitedCleanly(status));
    return YES;
}

// `disable` from the last client with Friends on: exit at once, no grace. With another client on, keep serving.
static BOOL TestDisable(SZFHHarness *harness) {
    NSString *state = [harness makeDirectory];
    pid_t pid = [harness spawnHelperWithStateDirectory:state timeScale:1];
    NSString *socket = [harness socketPathForStateDirectory:state];
    SZFHClient *a = [SZFHClient connectToSocket:socket timeout:5];
    SZFHClient *b = [SZFHClient connectToSocket:socket timeout:5];
    CHECK([[a helloWithEmbeddedBuild:0][@"type"] isEqual:@"welcome"]);
    CHECK([[b helloWithEmbeddedBuild:0][@"type"] isEqual:@"welcome"]);
    CHECK([[a intent:@"disable" fields:nil][@"ok"] boolValue]);
    [a close];
    usleep(500000);
    CHECK([harness isRunning:pid], "another app still has Friends on");
    NSDate *disabled = [NSDate date];
    CHECK([[b intent:@"disable" fields:nil][@"ok"] boolValue], "the reply arrives before the helper leaves");
    int status = 0;
    CHECK([harness waitForExit:pid timeout:3 status:&status], "the last app turned Friends off");
    CHECK(-disabled.timeIntervalSinceNow < 2.0 && SZFHExitedCleanly(status), "without the 10 s grace");
    return YES;
}

// SIGTERM says goodbye (shutdown) to every client and exits 0.
static BOOL TestTerminate(SZFHHarness *harness) {
    NSString *state = [harness makeDirectory];
    pid_t pid = [harness spawnHelperWithStateDirectory:state timeScale:1];
    SZFHClient *client = [SZFHClient connectToSocket:[harness socketPathForStateDirectory:state] timeout:5];
    CHECK([[client helloWithEmbeddedBuild:0][@"type"] isEqual:@"welcome"]);
    kill(pid, SIGTERM);
    NSDictionary *goodbye = [client nextFrameOfType:@"goodbye" timeout:3];
    CHECK([goodbye[@"reason"] isEqual:@"shutdown"], "%@", goodbye);
    int status = 0;
    CHECK([harness waitForExit:pid timeout:3 status:&status] && SZFHExitedCleanly(status));
    return YES;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // A copy of this binary inside a test app is the client that asks for a handover (Handover.m).
        if (argc == 4 && strcmp(argv[1], "--hello") == 0) return SZFHHelloClientMain(argv[2], argv[3]);
        if (argc < 3) {
            fprintf(stderr, "usage: %s <Shenzhen Friends.app> <fixtures dir>\n", argv[0]);
            return 2;
        }
        SZFHFixtures = @(argv[2]);
        signal(SIGPIPE, SIG_IGN);
        alarm(240); // a backstop only: every wait below has its own timeout of at most 10 s
        SZFHHarness *harness = [[SZFHHarness alloc] initWithApp:@(argv[1])];
        if (![[NSFileManager defaultManager] isExecutableFileAtPath:harness.executablePath] ||
            ![harness switchToAdHocCopy]) {
            fprintf(stderr, "no helper executable at %s\n", harness.executablePath.UTF8String);
            return 2;
        }
        struct {
            const char *name;
            BOOL (*run)(SZFHHarness *);
        } tests[] = {
            {"spawn race", TestSpawnRace},
            {"restart after kill", TestRestartAfterKill},
            {"grace exit", TestGraceExit},
            {"no-client exit", TestNoClientExit},
            {"disable", TestDisable},
            {"terminate", TestTerminate},
            {"handover", SZFHTestHandover},
            {"forged handover", SZFHTestForgedHandover},
            {"frames", SZFHTestFrames},
            {"handshake errors", SZFHTestHandshakeErrors},
            {"sun_path fallback", SZFHTestSocketFallback},
            {"unsafe directories", SZFHTestUnsafeDirectories},
            {"same badge", SZFHTestSameBadge},
            {"dispatch", SZFHTestDispatch},
            {"long conversation", SZFHTestLongConversation},
            {"every intent", TestEveryIntent},
            {"add by ID keeps keyed rows", SZFHTestAddByIDKeepsKeyedRows},
            {"add by ID broadcasts past claimed IDs", SZFHTestAddByIDBroadcastsPastClaims},
            {"message status reads nothing", SZFHTestMessageStatus},
            {"mentions written by the helper", SZFHTestMentionsWritten},
            {"add from a mention: refusals, then bound to the key", SZFHTestAddFromMention},
            {"block and remove drop their previews", SZFHTestBlockAndRemoveDropPreviews},
            {"remove anyone from the list, each the way the intent says", SZFHTestRemoveFromList},
            {"list rows carry Remove for a client with list.menu", SZFHTestRemoveMenu},
            {"a leftover You conversation on one computer is nobody's row", SZFHTestLeftoverYouIsNoRow},
            {"list rows describe the newest item", SZFHTestListRowsDescribeNewestItem},
            {"joining: the view and its intents", SZFHTestJoinIntents},
            {"computers: the profile's list and its intents", SZFHTestDevicesIntents},
            {"You: a message to yourself through the helper", SZFHTestYouIntents},
            {"Reset Friends from an identity it cannot read", SZFHTestResetUnreadableIdentity},
            {"an identity readable again starts what needs it", SZFHTestIdentityReadableAgain},
        };
        int failed = 0;
        for (size_t i = 0; i < sizeof(tests) / sizeof(tests[0]); i++) {
            SZFHLastStateDirectory = nil;
            NSDate *start = [NSDate date];
            BOOL passed = tests[i].run(harness);
            printf("%s %s (%.1f s)\n", passed ? "ok  " : "FAIL", tests[i].name, -start.timeIntervalSinceNow);
            if (!passed) {
                failed++;
                if (SZFHLastStateDirectory) {
                    NSString *log = [harness logForStateDirectory:SZFHLastStateDirectory];
                    fprintf(stderr, "helper log:\n%s\n", log.UTF8String);
                }
            }
        }
        // Every directory goes, a failing run's too: its helper's log was printed above.
        [harness cleanUp];
        if (failed > 0 || SZFHFailures > 0) {
            fprintf(stderr, "SZFriendsHelperProcessTests: %d test(s) failed\n", failed);
            return 1;
        }
        printf("SZFriendsHelperProcessTests passed\n");
    }
    return 0;
}
