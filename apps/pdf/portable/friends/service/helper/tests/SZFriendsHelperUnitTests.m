// Unit tests of the helper's pure decisions and file-system rules: negotiation, handover order, the lifecycle
// policy, peer checks with injected credentials, hello parsing, state paths, the socket directory check, the
// sun_path fallback and the instance lock. No helper process, no network.
//
// Usage: SZFriendsHelperUnitTests <fixtures dir>

#import <Foundation/Foundation.h>

#import <errno.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <unistd.h>

#import "client/szfriends_client.h"
#import "service/helper/SZFriendsHelperInternal.h"

static int failures = 0;
#define EXPECT(cond, ...)                                                                                          \
    do {                                                                                                           \
        if (!(cond)) {                                                                                             \
            failures++;                                                                                            \
            fprintf(stderr, "%s:%d: expected %s: %s\n", __FILE__, __LINE__, #cond,                                 \
                    [[NSString stringWithFormat:@"" __VA_ARGS__] UTF8String]);                                     \
        }                                                                                                          \
    } while (0)

static SZFriendsProtocolVersion V(NSInteger major, NSInteger minor) {
    return (SZFriendsProtocolVersion){.major = major, .minor = minor};
}

static void TestNegotiation(void) {
    SZFriendsProtocolVersion out = V(0, 0);
    EXPECT(SZFriendsNegotiateProtocol(V(1, 0), 1, V(1, 0), 1, &out) && out.major == 1 && out.minor == 0);
    EXPECT(SZFriendsNegotiateProtocol(V(1, 2), 1, V(1, 0), 1, &out) && out.minor == 0, "lower minor wins");
    EXPECT(SZFriendsNegotiateProtocol(V(1, 0), 1, V(1, 3), 1, &out) && out.minor == 0, "lower minor wins");
    // A helper one major ahead still serves an older client in the client's major and minor.
    EXPECT(SZFriendsNegotiateProtocol(V(2, 1), 1, V(1, 3), 1, &out) && out.major == 1 && out.minor == 3);
    EXPECT(SZFriendsNegotiateProtocol(V(1, 4), 1, V(2, 0), 1, &out) && out.major == 1 && out.minor == 4);
    EXPECT(SZFriendsNegotiateProtocol(V(2, 0), 1, V(3, 2), 2, &out) && out.major == 2 && out.minor == 0);
    EXPECT(!SZFriendsNegotiateProtocol(V(1, 0), 1, V(2, 0), 2, &out), "no common major");
    EXPECT(!SZFriendsNegotiateProtocol(V(3, 0), 3, V(1, 0), 1, &out), "no common major");
    EXPECT(!SZFriendsNegotiateProtocol(V(1, 0), 1, V(0, 5), 0, &out), "major 0 is not a version");
    EXPECT(!SZFriendsNegotiateProtocol(V(1, 0), 1, V(1, 0), 2, &out), "min_major above major is malformed");
    EXPECT(!SZFriendsNegotiateProtocol(V(1, 0), 1, V(1, -1), 1, &out), "negative minor is malformed");
}

static void TestHandoverOrder(void) {
    EXPECT(SZFriendsEmbeddedHelperIsNewer(V(1, 0), 26101201, V(1, 0), 26101202), "higher build");
    EXPECT(!SZFriendsEmbeddedHelperIsNewer(V(1, 0), 26101201, V(1, 0), 26101201), "equal never hands over");
    EXPECT(!SZFriendsEmbeddedHelperIsNewer(V(1, 0), 26101202, V(1, 0), 26101201), "older build");
    EXPECT(SZFriendsEmbeddedHelperIsNewer(V(1, 0), 99999999, V(1, 1), 1), "minor before build");
    EXPECT(!SZFriendsEmbeddedHelperIsNewer(V(1, 1), 1, V(1, 0), 99999999), "minor before build");
    EXPECT(SZFriendsEmbeddedHelperIsNewer(V(1, 9), 999, V(2, 0), 0), "major first");
}

// Review (handover denial of service): any client could name build 2^53 - 1 in its hello and make the helper step
// aside for a successor that never came. A claim must now be within a year of our build, and carried by the asking
// app's own bundle.
static NSString *MakeTemporaryDirectory(void);

static void TestHandoverClaims(void) {
    uint64_t ours = 26101301;
    EXPECT(SZFriendsHandoverBuildIsPlausible(ours, 26101302) && SZFriendsHandoverBuildIsPlausible(ours, 27101399),
           "up to the same day next year");
    EXPECT(!SZFriendsHandoverBuildIsPlausible(ours, 27101401), "nothing further ahead");
    EXPECT(!SZFriendsHandoverBuildIsPlausible(ours, 9007199254740991ULL), "the largest JSON integer");
    EXPECT(SZFriendsHandoverBuildIsPlausible(100, 101) && !SZFriendsHandoverBuildIsPlausible(0, 100000000),
           "test builds, and a helper outside a bundle, are bounded the same way");

    NSString *root = MakeTemporaryDirectory();
    NSString *app = [root stringByAppendingPathComponent:@"Reader.app"];
    NSString *executable = [app stringByAppendingPathComponent:@"Contents/MacOS/Reader"];
    NSString *helper = [app stringByAppendingPathComponent:@"Contents/Helpers/Shenzhen Friends.app/Contents"];
    NSFileManager *files = [NSFileManager defaultManager];
    [files createDirectoryAtPath:executable.stringByDeletingLastPathComponent withIntermediateDirectories:YES
                      attributes:nil error:NULL];
    [files createDirectoryAtPath:helper withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *plist = [helper stringByAppendingPathComponent:@"Info.plist"];
    [@{@"SZFriendsBuildNumber" : @"26101302", @"CFBundleVersion" : @"26101302"} writeToFile:plist atomically:YES];
    EXPECT([SZFriendsEmbeddedHelperBuildsOfApp(executable) isEqualToSet:[NSSet setWithObject:@26101302]],
           "%@", SZFriendsEmbeddedHelperBuildsOfApp(executable));
    EXPECT(SZFriendsEmbeddedHelperBuildsOfApp([root stringByAppendingPathComponent:@"tool"]).count == 0,
           "a tool outside an app carries nothing");
    EXPECT(SZFriendsEmbeddedHelperBuildsOfApp(nil).count == 0);
    // In place of the Info.plist: a pipe must not stall the helper, a symlink is not followed, a huge file not read.
    [files removeItemAtPath:plist error:NULL];
    EXPECT(mkfifo(plist.fileSystemRepresentation, 0600) == 0);
    EXPECT(SZFriendsEmbeddedHelperBuildsOfApp(executable).count == 0, "a pipe reads as nothing, at once");
    [files removeItemAtPath:plist error:NULL];
    NSString *elsewhere = [root stringByAppendingPathComponent:@"other.plist"];
    [@{@"SZFriendsBuildNumber" : @"26101302"} writeToFile:elsewhere atomically:YES];
    EXPECT(symlink(elsewhere.fileSystemRepresentation, plist.fileSystemRepresentation) == 0);
    EXPECT(SZFriendsEmbeddedHelperBuildsOfApp(executable).count == 0, "a symlinked Info.plist is not followed");
    [files removeItemAtPath:plist error:NULL];
    [[NSMutableData dataWithLength:70000] writeToFile:plist atomically:YES];
    EXPECT(SZFriendsEmbeddedHelperBuildsOfApp(executable).count == 0, "a huge Info.plist is not read");
    SZFriendsPeerCredentials own = {.pid = getpid()};
    EXPECT([SZFriendsPeerExecutablePath(&own) isEqualToString:NSProcessInfo.processInfo.arguments.firstObject] ||
               [SZFriendsPeerExecutablePath(&own).lastPathComponent isEqualToString:@"SZFriendsHelperUnitTests"],
           "%@", SZFriendsPeerExecutablePath(&own));
    [files removeItemAtPath:root error:NULL];
}

static void TestLifecyclePolicy(void) {
    SZFriendsLifecyclePolicy *policy = [[SZFriendsLifecyclePolicy alloc] init];
    EXPECT(policy.gracePeriod == 10 && policy.firstClientDeadline == 30 && policy.handoverDeadline == 5,
           "ADR 0002 defaults");
    NSDate *start = [NSDate dateWithTimeIntervalSince1970:1000];
    NSDate *(^at)(NSTimeInterval) = ^NSDate *(NSTimeInterval t) { return [start dateByAddingTimeInterval:t]; };
    SZFriendsExitReason (^reason)(NSUInteger, BOOL, NSDate *, BOOL, NSDate *, BOOL, NSDate *) =
        ^SZFriendsExitReason(NSUInteger clients, BOOL ever, NSDate *left, BOOL disabled, NSDate *handover, BOOL busy,
                             NSDate *now) {
            return [policy exitReasonWithClientCount:clients startedAt:start everHadClient:ever lastClientLeft:left
                                   disabledByLastApp:disabled handoverRequestedAt:handover workInFlight:busy now:now];
        };
    EXPECT(reason(2, YES, nil, NO, nil, NO, at(500)) == SZFriendsExitReasonNone, "clients keep it alive");
    EXPECT(reason(0, YES, at(100), NO, nil, NO, at(109.9)) == SZFriendsExitReasonNone, "inside the grace");
    EXPECT(reason(0, YES, at(100), NO, nil, NO, at(110)) == SZFriendsExitReasonIdle, "grace over");
    EXPECT(reason(0, YES, at(100), YES, nil, NO, at(100)) == SZFriendsExitReasonDisabled, "disable skips grace");
    EXPECT(reason(0, NO, nil, NO, nil, NO, at(29.9)) == SZFriendsExitReasonNone, "waiting for the first client");
    EXPECT(reason(0, NO, nil, NO, nil, NO, at(30)) == SZFriendsExitReasonNoClient, "spawner died");
    EXPECT(reason(3, YES, nil, NO, at(200), YES, at(204.9)) == SZFriendsExitReasonNone, "handover waits for work");
    EXPECT(reason(3, YES, nil, NO, at(200), YES, at(205)) == SZFriendsExitReasonHandover, "never past 5 s");
    EXPECT(reason(3, YES, nil, NO, at(200), NO, at(200)) == SZFriendsExitReasonHandover, "idle hands over at once");
}

static void TestPeerChecks(void) {
    SZFriendsPeerCredentials credentials;
    memset(&credentials, 0, sizeof(credentials));
    credentials.hasUID = YES;
    credentials.uid = 501;
    EXPECT(SZFriendsPeerUIDAllowed(&credentials, 501));
    EXPECT(!SZFriendsPeerUIDAllowed(&credentials, 502), "another user");
    credentials.hasUID = NO;
    EXPECT(!SZFriendsPeerUIDAllowed(&credentials, 501), "unknown uid is refused");

    credentials.hasUID = YES;
    __block NSUInteger calls = 0;
    __block NSString *seenRequirement = nil;
    SZFriendsRequirementChecker yes = ^BOOL(audit_token_t token, NSString *requirement) {
        (void)token;
        calls++;
        seenRequirement = requirement;
        return YES;
    };
    SZFriendsRequirementChecker no = ^BOOL(audit_token_t token, NSString *requirement) {
        (void)token, (void)requirement;
        calls++;
        return NO;
    };
    EXPECT(SZFriendsPeerAllowed(&credentials, 501, nil, nil), "ad-hoc builds check the uid only");
    EXPECT(!SZFriendsPeerAllowed(&credentials, 502, nil, yes) && calls == 0, "uid first, checker never asked");
    EXPECT(!SZFriendsPeerAllowed(&credentials, 501, @"ABCDE12345", yes) && calls == 0, "team build needs a token");
    credentials.hasAuditToken = YES;
    EXPECT(SZFriendsPeerAllowed(&credentials, 501, @"ABCDE12345", yes) && calls == 1);
    EXPECT([seenRequirement isEqualToString:
                                @"anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\""],
           "requirement %@", seenRequirement);
    EXPECT(!SZFriendsPeerAllowed(&credentials, 501, @"ABCDE12345", no), "other team or unsigned peer");
    EXPECT(!SZFriendsPeerAllowed(&credentials, 501, @"ABCDE12345", nil), "team build without a checker");
    calls = 0;
    EXPECT(!SZFriendsPeerAllowed(&credentials, 501, @"AB\" or true", yes) && calls == 0, "never a crafted team");
    EXPECT(SZFriendsTeamIdentifierIsValid(@"66LJ4BV7Q3") && !SZFriendsTeamIdentifierIsValid(@"66lj4bv7q3"));
    EXPECT(!SZFriendsTeamIdentifierIsValid(@"66LJ4BV7Q") && !SZFriendsTeamIdentifierIsValid(nil));

    // The kernel's answer for a real socket: our own uid and pid, and an audit token.
    int pair[2];
    EXPECT(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
    SZFriendsPeerCredentials real;
    EXPECT(SZFriendsReadPeerCredentials(pair[0], &real) && real.uid == geteuid() && real.pid == getpid(),
           "uid %u pid %d", real.uid, real.pid);
    EXPECT(real.hasAuditToken, "LOCAL_PEERTOKEN");
    EXPECT(SZFriendsPeerAllowed(&real, geteuid(), nil, nil));
    close(pair[0]);
    close(pair[1]);
}

static void TestClientContext(NSString *fixtures) {
    NSData *data = [NSData dataWithContentsOfFile:[fixtures stringByAppendingPathComponent:@"frames/hello.json"]];
    NSDictionary *hello = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    EXPECT(hello != nil, "fixture hello.json");
    NSError *error = nil;
    SZFriendsClientContext *context = [SZFriendsClientContext contextFromHello:hello negotiatedVersion:V(1, 0)
                                                                         error:&error];
    EXPECT([context.appName isEqualToString:@"ShenzhenPDF"] && [context.revealIn isEqualToString:@"Finder"]);
    EXPECT([context.openFormats containsObject:@"pdf"] && [context.capabilities containsObject:@"drop.files"]);
    NSMutableDictionary *bad = [hello mutableCopy];
    [bad removeObjectForKey:@"client"];
    EXPECT([SZFriendsClientContext contextFromHello:bad negotiatedVersion:V(1, 0) error:&error] == nil &&
           [error.userInfo[@"field"] isEqual:@"client"]);
    NSMutableDictionary *client = [hello[@"client"] mutableCopy];
    client[@"app_name"] = @42;
    bad = [hello mutableCopy];
    bad[@"client"] = client;
    EXPECT([SZFriendsClientContext contextFromHello:bad negotiatedVersion:V(1, 0) error:&error] == nil &&
           [error.userInfo[@"field"] isEqual:@"client.app_name"], "field %@", error.userInfo[@"field"]);
    bad = [hello mutableCopy];
    bad[@"capabilities"] = @"drop.files";
    EXPECT([SZFriendsClientContext contextFromHello:bad negotiatedVersion:V(1, 0) error:&error] == nil &&
           [error.userInfo[@"field"] isEqual:@"capabilities"]);
    bad = [hello mutableCopy];
    bad[@"open_formats"] = @[ @"PDF", @"Md" ];
    bad[@"locale"] = [NSNull null];
    context = [SZFriendsClientContext contextFromHello:bad negotiatedVersion:V(1, 0) error:&error];
    NSSet *lowercased = [NSSet setWithArray:@[ @"pdf", @"md" ]];
    EXPECT([context.openFormats isEqualToSet:lowercased], "formats are lowercased");
    EXPECT([context.locale isEqualToString:@"en"], "missing locale answers in English");
    // A reader lists every extension it opens in place: ShenzhenPDF's documents and source files are about 130,
    // and a hello refused over them left it retrying every 2 s without ever connecting.
    NSMutableArray *formats = [NSMutableArray array];
    for (NSUInteger i = 0; i <= SZFRIENDS_MAX_OPEN_FORMATS; i++)
        [formats addObject:[NSString stringWithFormat:@"x%lu", (unsigned long)i]];
    bad = [hello mutableCopy];
    bad[@"open_formats"] = [formats subarrayWithRange:NSMakeRange(0, 130)];
    context = [SZFriendsClientContext contextFromHello:bad negotiatedVersion:V(1, 0) error:&error];
    EXPECT(context.openFormats.count == 130, "a reader's 130 formats: %@", error.userInfo[@"field"]);
    bad[@"open_formats"] = [formats subarrayWithRange:NSMakeRange(0, SZFRIENDS_MAX_OPEN_FORMATS)];
    EXPECT([SZFriendsClientContext contextFromHello:bad negotiatedVersion:V(1, 0) error:&error] != nil,
           "formats up to the limit");
    bad[@"open_formats"] = formats;
    EXPECT([SZFriendsClientContext contextFromHello:bad negotiatedVersion:V(1, 0) error:&error] == nil &&
           [error.userInfo[@"field"] isEqual:@"open_formats"], "formats over the limit");
    client = [hello[@"client"] mutableCopy];
    client[@"toolkit"] = @"win32";
    bad = [hello mutableCopy];
    bad[@"client"] = client;
    EXPECT([SZFriendsClientContext contextFromHello:bad negotiatedVersion:V(1, 0) error:&error] != nil,
           "a later toolkit must not fail hello");
}

static NSString *MakeTemporaryDirectory(void) {
    NSString *template = [NSTemporaryDirectory() stringByAppendingPathComponent:@"szfh-unit.XXXXXX"];
    char buffer[PATH_MAX];
    strlcpy(buffer, template.fileSystemRepresentation, sizeof(buffer));
    return mkdtemp(buffer) ? [NSString stringWithUTF8String:buffer] : @"";
}

static void TestStatePaths(void) {
    NSString *dir = [SZFriendsStatePaths defaultStateDirectoryWithEnvironment:@{@"SZFRIENDS_STATE_DIR" : @"/x/y"}];
    EXPECT([dir isEqualToString:@"/x/y"]);
    NSDictionary *relative = @{@"SZFRIENDS_STATE_DIR" : @"rel", @"HOME" : @"/h"};
    dir = [SZFriendsStatePaths defaultStateDirectoryWithEnvironment:relative];
    EXPECT([dir isEqualToString:@"/h/Library/Application Support/Shenzhen Friends"], "relative is ignored: %@", dir);
    // The same rule as the client library's, for the process environment.
    setenv("SZFRIENDS_STATE_DIR", "/tmp/szfriends-unit-agree", 1);
    char cdir[SZFRIENDS_PATH_CAP];
    EXPECT(szfriends_default_state_dir(cdir, sizeof(cdir)) == SZFRIENDS_OK);
    dir = [SZFriendsStatePaths defaultStateDirectoryWithEnvironment:[NSProcessInfo processInfo].environment];
    EXPECT([dir isEqualToString:@(cdir)], "%@ vs %s", dir, cdir);
    unsetenv("SZFRIENDS_STATE_DIR");

    NSString *root = MakeTemporaryDirectory();
    NSString *state = [root stringByAppendingPathComponent:@"state"];
    SZFriendsStatePaths *paths = [[SZFriendsStatePaths alloc] initWithStateDirectory:state];
    char socketPath[SZFRIENDS_PATH_CAP];
    bool fallback = true;
    EXPECT(szfriends_socket_path(state.fileSystemRepresentation, socketPath, sizeof(socketPath), &fallback) ==
           SZFRIENDS_OK);
    EXPECT([paths.socketPath isEqualToString:@(socketPath)] && !fallback, "%@", paths.socketPath);
    EXPECT([paths.socketPath hasSuffix:@"/ipc/helper.sock"] && [paths.lockPath hasSuffix:@"/state/helper.lock"]);
    EXPECT([paths.partialDirectory hasSuffix:@"/received/.partial"]);
    NSError *error = nil;
    EXPECT([paths prepareDirectoriesWithError:&error], "%@", error);
    struct stat st;
    EXPECT(lstat(paths.socketDirectory.fileSystemRepresentation, &st) == 0 && (st.st_mode & 0777) == 0700);
    EXPECT(lstat(state.fileSystemRepresentation, &st) == 0 && (st.st_mode & 0777) == 0700);

    // An existing socket directory with group or world access, or a symlink, is refused, never repaired.
    NSString *loose = [root stringByAppendingPathComponent:@"loose"];
    mkdir(loose.fileSystemRepresentation, 0700);
    mkdir([loose stringByAppendingPathComponent:@"ipc"].fileSystemRepresentation, 0755);
    chmod([loose stringByAppendingPathComponent:@"ipc"].fileSystemRepresentation, 0755);
    EXPECT(![[[SZFriendsStatePaths alloc] initWithStateDirectory:loose] prepareDirectoriesWithError:&error]);
    EXPECT(lstat([loose stringByAppendingPathComponent:@"ipc"].fileSystemRepresentation, &st) == 0 &&
           (st.st_mode & 0777) == 0755, "left as found");
    NSString *linked = [root stringByAppendingPathComponent:@"linked"];
    mkdir(linked.fileSystemRepresentation, 0700);
    NSString *link = [linked stringByAppendingPathComponent:@"ipc"];
    symlink(paths.socketDirectory.fileSystemRepresentation, link.fileSystemRepresentation);
    EXPECT(![[[SZFriendsStatePaths alloc] initWithStateDirectory:linked] prepareDirectoriesWithError:&error],
           "symlinked socket directory");

    // A state directory too deep for sun_path gets the short per-user fallback, created 0700.
    NSString *deepName = [@"" stringByPaddingToLength:90 withString:@"d" startingAtIndex:0];
    NSString *deep = [root stringByAppendingPathComponent:deepName];
    SZFriendsStatePaths *deepPaths = [[SZFriendsStatePaths alloc] initWithStateDirectory:deep];
    EXPECT(deepPaths.socketPath.length > 0 && strlen(deepPaths.socketPath.fileSystemRepresentation) < 104 &&
           [deepPaths.socketPath.stringByDeletingLastPathComponent.lastPathComponent hasPrefix:@"szfriends-"],
           "%@", deepPaths.socketPath);
    EXPECT([deepPaths prepareDirectoriesWithError:&error], "%@", error);
    EXPECT(lstat(deepPaths.socketDirectory.fileSystemRepresentation, &st) == 0 && (st.st_mode & 0777) == 0700 &&
           st.st_uid == geteuid());
    [[NSFileManager defaultManager] removeItemAtPath:deepPaths.socketDirectory error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
}

static void TestInstanceLock(void) {
    NSString *root = MakeTemporaryDirectory();
    NSString *path = [root stringByAppendingPathComponent:@"helper.lock"];
    NSError *error = nil;
    SZFriendsInstanceLock *first = [SZFriendsInstanceLock acquireAtPath:path error:&error];
    EXPECT(first != nil, "%@", error);
    SZFriendsInstanceLock *second = [SZFriendsInstanceLock acquireAtPath:path error:&error];
    EXPECT(second == nil && [error.domain isEqual:NSPOSIXErrorDomain] && error.code == EWOULDBLOCK, "%@", error);
    [first releaseLock];
    SZFriendsInstanceLock *third = [SZFriendsInstanceLock acquireAtPath:path error:&error];
    EXPECT(third != nil, "released locks can be taken again");
    [third releaseLock];
    [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
}

static void TestSmallPieces(void) {
    EXPECT(SZFriendsJSONIsInteger(@3) && !SZFriendsJSONIsInteger(@YES) && !SZFriendsJSONIsInteger(@1.5));
    EXPECT(!SZFriendsJSONIsInteger(@"3") && SZFriendsJSONIsBool(@NO) && !SZFriendsJSONIsBool(@0));
    EXPECT(SZFriendsFrameIDIsValid(@"1") && SZFriendsFrameIDIsValid([@"" stringByPaddingToLength:32 withString:@"x"
                                                                                  startingAtIndex:0]));
    EXPECT(!SZFriendsFrameIDIsValid(@"") && !SZFriendsFrameIDIsValid(@7) && !SZFriendsFrameIDIsValid(@"a\nb"));
    EXPECT(!SZFriendsFrameIDIsValid([@"" stringByPaddingToLength:33 withString:@"x" startingAtIndex:0]));
    NSString *stamp = SZFriendsRFC3339([NSDate dateWithTimeIntervalSince1970:1791787870]);
    EXPECT([stamp isEqualToString:@"2026-10-12T06:51:10Z"], "%@", stamp);
    EXPECT(SZFriendsHelperTimeScale(@{@"SZFRIENDS_HELPER_TIME_SCALE" : @"0.1"}) == 1.0, "production ignores it");
    NSDictionary *test = @{@"SZFRIENDS_STATE_DIR" : @"/t", @"SZFRIENDS_HELPER_TIME_SCALE" : @"0.1"};
    EXPECT(SZFriendsHelperTimeScale(test) == 0.1);
    test = @{@"SZFRIENDS_STATE_DIR" : @"/t", @"SZFRIENDS_HELPER_TIME_SCALE" : @"5"};
    EXPECT(SZFriendsHelperTimeScale(test) == 1.0, "it can only shorten");
    test = @{@"SZFRIENDS_STATE_DIR" : @"/t", @"SZFRIENDS_HELPER_TIME_SCALE" : @"0.0001"};
    EXPECT(SZFriendsHelperTimeScale(test) == 0.01);
}

// Security review (environment overrides): a team-signed helper used to honour SZFRIENDS_STATE_DIR and
// SZFRIENDS_KEY_STORE from its environment, so any process running as the user could move it to a plaintext key
// store. A signed build now drops every SZFRIENDS_* variable; tests run unsigned builds and keep them.
static void TestTrustedEnvironment(void) {
    NSDictionary *env = @{@"SZFRIENDS_STATE_DIR" : @"/tmp/x", @"SZFRIENDS_KEY_STORE" : @"file",
                          @"SZFRIENDS_TEST_HOST_LIST" : @"/tmp/l", @"SZFRIENDS_AVATARS_MANIFEST" : @"/tmp/m",
                          @"HOME" : @"/Users/someone", @"SZFRIENDSX" : @"kept"};
    NSArray<NSString *> *ignored = nil;
    NSDictionary *signedEnv = SZFriendsHelperTrustedEnvironment(env, NO, &ignored);
    EXPECT(signedEnv[@"SZFRIENDS_STATE_DIR"] == nil && signedEnv[@"SZFRIENDS_KEY_STORE"] == nil &&
           signedEnv[@"SZFRIENDS_TEST_HOST_LIST"] == nil && signedEnv[@"SZFRIENDS_AVATARS_MANIFEST"] == nil,
           "a signed build drops every override: %@", signedEnv);
    EXPECT([signedEnv[@"HOME"] isEqual:@"/Users/someone"] && [signedEnv[@"SZFRIENDSX"] isEqual:@"kept"],
           "and nothing else");
    EXPECT(ignored.count == 4 && [ignored.firstObject isEqual:@"SZFRIENDS_AVATARS_MANIFEST"], "%@", ignored);
    // The state directory then falls back to the real one, which is what a signed build must use.
    EXPECT(![[SZFriendsStatePaths defaultStateDirectoryWithEnvironment:signedEnv] isEqual:@"/tmp/x"]);
    NSDictionary *testEnv = SZFriendsHelperTrustedEnvironment(env, YES, &ignored);
    EXPECT([testEnv isEqual:env] && ignored.count == 0, "unsigned builds keep them");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: %s <fixtures dir>\n", argv[0]);
            return 2;
        }
        TestNegotiation();
        TestHandoverOrder();
        TestHandoverClaims();
        TestLifecyclePolicy();
        TestPeerChecks();
        TestClientContext(@(argv[1]));
        TestStatePaths();
        TestInstanceLock();
        TestSmallPieces();
        TestTrustedEnvironment();
        if (failures > 0) {
            fprintf(stderr, "SZFriendsHelperUnitTests: %d failure(s)\n", failures);
            return 1;
        }
        printf("SZFriendsHelperUnitTests passed\n");
    }
    return 0;
}
