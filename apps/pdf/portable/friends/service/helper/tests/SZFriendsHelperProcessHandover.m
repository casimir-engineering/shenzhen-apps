// Process tests of the version handover (ADR 0002 § Version handover, PROTOCOL.md § Handover request), and of the
// claims a helper no longer believes (review: handover denial of service).
//
// A handover now needs an app that carries the successor: the asking client must be an app's main executable whose
// bundle embeds that build in Contents/Helpers/. The tests build such an app around a copy of this test binary, which
// runs as a one-hello client when started with --hello (SZFHHelloClientMain).

#import <Foundation/Foundation.h>

#import <signal.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>

#import "SZFriendsHelperProcessHarness.h"

extern char **environ;

// The client mode: one hello naming `build` as the embedded helper. Exit 0 when the helper scheduled a handover, 3
// when it did not, 2 when no welcome came.
int SZFHHelloClientMain(const char *socket, const char *build) {
    @autoreleasepool {
        SZFHClient *client = [SZFHClient connectToSocket:@(socket) timeout:5];
        NSDictionary *welcome = [client helloWithEmbeddedBuild:strtoull(build, NULL, 10)];
        if (![welcome[@"type"] isEqual:@"welcome"]) return 2;
        return [welcome[@"handover"] isEqual:@"scheduled"] ? 0 : 3;
    }
}

// Reader.app/Contents/MacOS/Reader (this test binary) beside Contents/Helpers/Shenzhen Friends.app saying `build`:
// an app that really carries that helper. Returns the app's executable.
static NSString *_Nullable SZFHAppCarryingBuild(SZFHHarness *harness, uint64_t build) {
    NSString *app = [[harness makeDirectory] stringByAppendingPathComponent:@"Reader.app"];
    NSString *executable = [app stringByAppendingPathComponent:@"Contents/MacOS/Reader"];
    NSFileManager *files = [NSFileManager defaultManager];
    if (![files createDirectoryAtPath:executable.stringByDeletingLastPathComponent withIntermediateDirectories:YES
                           attributes:nil error:NULL] ||
        ![files copyItemAtPath:NSBundle.mainBundle.executablePath toPath:executable error:NULL]) {
        return nil;
    }
    NSString *helper = [app stringByAppendingPathComponent:@"Contents/Helpers/Shenzhen Friends.app"];
    return [harness copyOfAppAtPath:helper buildNumber:build] != nil ? executable : nil;
}

// Runs `executable` as a hello client against `socket`; its exit code, or -1 when it did not finish in 10 s.
static int SZFHRunHelloClient(SZFHHarness *harness, NSString *executable, NSString *socket, uint64_t build) {
    NSString *buildText = [NSString stringWithFormat:@"%llu", build];
    const char *argv[] = {executable.fileSystemRepresentation, "--hello", socket.fileSystemRepresentation,
                          buildText.UTF8String, NULL};
    pid_t pid = 0;
    if (posix_spawn(&pid, argv[0], NULL, NULL, (char **)argv, environ) != 0) return -1;
    int status = 0;
    if (![harness waitForExit:pid timeout:10 status:&status]) {
        kill(pid, SIGKILL);
        [harness waitForExit:pid timeout:2 status:NULL];
        return -1;
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

// Builds N and N+1: equal builds never hand over; an app carrying N+1 makes N say goodbye with its successor and
// exit within the 5 s deadline, after which N+1 serves.
BOOL SZFHTestHandover(SZFHHarness *harness) {
    NSString *older = [harness copyOfAppWithBuildNumber:100];
    NSString *reader = SZFHAppCarryingBuild(harness, 101);
    CHECK(older != nil && reader != nil, "bundle copies with build numbers");
    NSString *newer = [reader.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent
        stringByAppendingPathComponent:@"Helpers/Shenzhen Friends.app/Contents/MacOS/Shenzhen Friends"];
    NSString *state = [harness makeDirectory];
    pid_t oldPID = [harness spawnExecutable:older stateDirectory:state timeScale:1];
    NSString *socket = [harness socketPathForStateDirectory:state];
    SZFHClient *same = [SZFHClient connectToSocket:socket timeout:5];
    NSDictionary *welcome = [same helloWithEmbeddedBuild:100];
    CHECK([welcome[@"handover"] isEqual:@"none"] && [welcome[@"helper"][@"build_number"] intValue] == 100,
          "equal builds never hand over: %@", welcome);
    usleep(300000);
    CHECK([harness isRunning:oldPID]);
    NSDate *asked = [NSDate date];
    int verdict = SZFHRunHelloClient(harness, reader, socket, 101);
    CHECK(verdict == 0, "the app carrying build 101 is granted the handover (client exit %d)", verdict);
    NSDictionary *goodbye = [same nextFrameOfType:@"goodbye" timeout:6];
    CHECK([goodbye[@"reason"] isEqual:@"handover"] && [goodbye[@"successor"][@"build_number"] intValue] == 101, "%@",
          goodbye);
    CHECK([same waitForEOFWithTimeout:3]);
    int status = 0;
    CHECK([harness waitForExit:oldPID timeout:6 status:&status] && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    CHECK(-asked.timeIntervalSinceNow < 5.5, "handed over within 5 s");
    pid_t newPID = [harness spawnExecutable:newer stateDirectory:state timeScale:1];
    SZFHClient *after = [SZFHClient connectToSocket:socket timeout:5];
    welcome = [after helloWithEmbeddedBuild:101];
    CHECK([welcome[@"helper"][@"build_number"] intValue] == 101 && [welcome[@"handover"] isEqual:@"none"], "%@",
          welcome);
    kill(newPID, SIGTERM);
    CHECK([harness waitForExit:newPID timeout:3 status:NULL]);
    return YES;
}

// Review (handover denial of service): any client could name a newer build, 2^53 - 1 at worst, and every helper
// stepped aside for a successor that never came. Now a forged hello changes nothing: a newer build named by a client
// that carries none, an absurd build, or a build further than a year ahead even when an app carries it.
BOOL SZFHTestForgedHandover(SZFHHarness *harness) {
    NSString *older = [harness copyOfAppWithBuildNumber:100];
    NSString *farAhead = SZFHAppCarryingBuild(harness, 2000000000);
    CHECK(older != nil && farAhead != nil);
    NSString *state = [harness makeDirectory];
    pid_t pid = [harness spawnExecutable:older stateDirectory:state timeScale:1];
    NSString *socket = [harness socketPathForStateDirectory:state];
    for (NSNumber *build in @[ @101, @9007199254740991ULL ]) {
        SZFHClient *forger = [SZFHClient connectToSocket:socket timeout:5];
        NSDictionary *welcome = [forger helloWithEmbeddedBuild:build.unsignedLongLongValue];
        CHECK([welcome[@"type"] isEqual:@"welcome"] && [welcome[@"handover"] isEqual:@"none"],
              "a client outside any app naming build %@: %@", build, welcome);
    }
    int verdict = SZFHRunHelloClient(harness, farAhead, socket, 2000000000);
    CHECK(verdict == 3, "an app carrying a build years ahead is refused too (client exit %d)", verdict);
    usleep(500000);
    CHECK([harness isRunning:pid], "the helper stayed");
    SZFHClient *later = [SZFHClient connectToSocket:socket timeout:5];
    NSDictionary *welcome = [later helloWithEmbeddedBuild:0];
    CHECK([welcome[@"type"] isEqual:@"welcome"] && [welcome[@"helper"][@"build_number"] intValue] == 100,
          "and still serves: %@", welcome);
    kill(pid, SIGTERM);
    CHECK([harness waitForExit:pid timeout:3 status:NULL]);
    return YES;
}
