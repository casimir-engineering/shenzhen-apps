// friends-avatars-check: the animal set, its fixtures, and the picture pipeline.
//
// Usage: SZFriendsAvatarsTests <animals/manifest.json> <fixtures dir>
// Prints "SZFriendsAvatarsTests passed" and exits 0 only when every check holds. Everything it writes goes to a
// fresh temporary directory (also used as SZFRIENDS_STATE_DIR), which it removes at exit. It needs no network,
// no Keychain and no rsvg-convert, and it finishes in a few seconds; a watchdog fails it after 10 s instead of
// letting a hung decode stall the suite.

#import <signal.h>
#import <unistd.h>

#import "SZFriendsAvatarsTestSupport.h"

int SZTestFailures = 0;
int SZTestChecks = 0;

static void SZTestWatchdog(int signal) {
    (void)signal;
    static const char message[] = "SZFriendsAvatarsTests: timed out after 10 s\n";
    write(STDERR_FILENO, message, sizeof message - 1);
    _exit(1);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "usage: %s <manifest.json> <fixtures dir>\n", argv[0]);
            return 2;
        }
        signal(SIGALRM, SZTestWatchdog);
        alarm(10);

        NSString *template = [NSTemporaryDirectory() stringByAppendingPathComponent:@"szfriends-avatars.XXXXXX"];
        char *buffer = strdup(template.fileSystemRepresentation);
        if (!mkdtemp(buffer)) {
            fprintf(stderr, "SZFriendsAvatarsTests: cannot create a temporary directory\n");
            return 1;
        }
        NSString *scratch = [NSFileManager.defaultManager stringWithFileSystemRepresentation:buffer
                                                                                       length:strlen(buffer)];
        free(buffer);
        setenv("SZFRIENDS_STATE_DIR", scratch.fileSystemRepresentation, 1);

        NSString *cwd = NSFileManager.defaultManager.currentDirectoryPath;
        NSString *manifest = @(argv[1]), *fixtures = @(argv[2]);
        if (!manifest.isAbsolutePath) manifest = [cwd stringByAppendingPathComponent:manifest];
        if (!fixtures.isAbsolutePath) fixtures = [cwd stringByAppendingPathComponent:fixtures];
        SZTestContext context = {manifest.stringByStandardizingPath, fixtures.stringByStandardizingPath, scratch};

        SZRunAnimalSetTests(context);
        SZRunFixtureReferenceTests(context);
        SZRunPictureTests(context);
        SZRunJPEGTests(context);
        SZRunPipelineTests(context);
        SZRunReceivedImageTests(context);
        SZRunIntentTests(context);

        [NSFileManager.defaultManager removeItemAtPath:scratch error:NULL];
        if (SZTestFailures > 0) {
            fprintf(stderr, "SZFriendsAvatarsTests: %d check(s) failed\n", SZTestFailures);
            return 1;
        }
        // The count guards against a suite that silently stopped running its checks.
        if (SZTestChecks < 400) {
            fprintf(stderr, "SZFriendsAvatarsTests: only %d checks ran\n", SZTestChecks);
            return 1;
        }
        printf("%d checks\nSZFriendsAvatarsTests passed\n", SZTestChecks);
    }
    return 0;
}
