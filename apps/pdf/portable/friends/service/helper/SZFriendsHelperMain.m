// The helper's entry point: start in the order ADR 0002 fixes, serve, and exit by the lifecycle policy.
//
// Order matters: (1) the lock, before touching anything else, so a duplicate spawn costs nothing and never
// disturbs the running helper's files; (2) sodium_init(), which keeps /dev/urandom open from then on; (3) every
// bundle resource, because the updater may replace the bundle while the helper runs; (4) identity and store;
// (5) bind and serve; (6) Nearby and the host check-in, which never wait for each other. Everything after start runs
// on the main queue, one serial queue for IPC, dispatch, sessions and the store's single writer, so no state needs
// a lock.

#import "service/helper/SZFriendsHelper.h"

#import <errno.h>
#import <fcntl.h>
#import <signal.h>
#import <unistd.h>
#import <sodium.h>

#import "service/helper/SZFriendsHelperInternal.h"
#import "service/helper/SZFriendsHelperServices.h"
#import "service/helper/SZFriendsHelperTesting.h"
#import "service/helper/SZFriendsHostCheckIn.h"
#import "service/helper/SZFriendsIntentRouter.h"
#import "service/helper/nearby/SZFriendsNearbyService.h"

// Held for the life of the process: dispatch_main() never returns, and ARC may otherwise release a local after
// its last use.
static NSArray *SZFriendsHelperRoots;
static NSArray<dispatch_source_t> *SZFriendsHelperSignalSources;

// The spawner gives a helper /dev/null for stderr, so it never holds an app's pipe open (ADR 0002); the helper then
// writes its own log, <state>/helper.log, owned by whoever holds the lock. Kept under 1 MiB by moving the previous
// one aside, since a helper runs for as long as any app is open.
static void SZFriendsOpenHelperLog(SZFriendsStatePaths *paths) {
    NSString *log = [paths.stateDirectory stringByAppendingPathComponent:@"helper.log"];
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:log error:NULL];
    if (attributes.fileSize > 1024 * 1024) {
        NSString *previous = [log stringByAppendingString:@".1"];
        rename(log.fileSystemRepresentation, previous.fileSystemRepresentation);
    }
    int fd = open(log.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return;
    dup2(fd, STDERR_FILENO);
    close(fd);
}

static void SZFriendsInstallSignalHandlers(SZFriendsHelperLifecycle *lifecycle, dispatch_queue_t queue) {
    NSMutableArray *sources = [NSMutableArray array];
    int signals[] = {SIGTERM, SIGINT, SIGHUP};
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
        int signalNumber = signals[i];
        // Ignored at the C level so the dispatch source alone sees it and the exit can say goodbye.
        signal(signalNumber, SIG_IGN);
        dispatch_source_t source =
            dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, (uintptr_t)signalNumber, 0, queue);
        __weak SZFriendsHelperLifecycle *weakLifecycle = lifecycle;
        dispatch_source_set_event_handler(source, ^{ [weakLifecycle shutdownForSignal:signalNumber]; });
        dispatch_resume(source);
        [sources addObject:source];
    }
    SZFriendsHelperSignalSources = sources;
}

int SZFriendsHelperMain(int argc, const char *_Nonnull argv[_Nonnull]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        // A client that disappears mid-write must cost a write error, not the process.
        signal(SIGPIPE, SIG_IGN);
        // Before anything reads it: a team-signed helper drops every SZFRIENDS_* override from its own process
        // environment too, so no area that reads the environment directly (the animal set's manifest) still sees one.
        NSArray<NSString *> *ignored = nil;
        NSDictionary<NSString *, NSString *> *environment = SZFriendsHelperTrustedEnvironment(
            [NSProcessInfo processInfo].environment, SZFriendsEnvironmentOverridesAllowed(), &ignored);
        for (NSString *name in ignored) unsetenv(name.UTF8String);
        NSString *stateDirectory = [SZFriendsStatePaths defaultStateDirectoryWithEnvironment:environment];
        SZFriendsStatePaths *paths = [[SZFriendsStatePaths alloc] initWithStateDirectory:stateDirectory];

        // (1) The lock. The state directory must exist to hold helper.lock, and nothing else is touched first.
        NSError *error = nil;
        if (![paths prepareStateDirectoryWithError:&error]) {
            SZFriendsHelperLog(@"cannot use the state directory: %@", error.localizedDescription);
            return 1;
        }
        SZFriendsInstanceLock *lock = [SZFriendsInstanceLock acquireAtPath:paths.lockPath error:&error];
        if (lock == nil) {
            if ([error.domain isEqualToString:NSPOSIXErrorDomain] && error.code == EWOULDBLOCK) return 0;
            SZFriendsHelperLog(@"cannot take helper.lock: %@", error.localizedDescription);
            return 1;
        }

        SZFriendsOpenHelperLog(paths);
        if (ignored.count > 0) {
            SZFriendsHelperLog(@"signed build: ignoring %@", [ignored componentsJoinedByString:@", "]);
        }

        // (2) libsodium.
        if (sodium_init() < 0) {
            SZFriendsHelperLog(@"libsodium failed to initialise");
            return 1;
        }

        // (3) Bundle resources, (4) identity and store.
        SZFriendsHelperResources *resources = [SZFriendsHelperResources loadFromBundle:[NSBundle mainBundle]];
        SZFriendsHelperServices *services = [[SZFriendsHelperServices alloc] initWithPaths:paths
                                                                               environment:environment
                                                                                 resources:resources];
        [services open];

        // (5) Bind and serve.
        if (![paths prepareDirectoriesWithError:&error]) {
            SZFriendsHelperLog(@"refusing to bind: %@", error.localizedDescription);
            [services close];
            return 1;
        }
        dispatch_queue_t queue = dispatch_get_main_queue();
        SZFriendsIPCServer *server = [[SZFriendsIPCServer alloc] initWithPaths:paths queue:queue];
        SZFriendsPublisher *publisher = [[SZFriendsPublisher alloc] initWithServices:services
                                                                              server:server
                                                                               queue:queue];
        SZFriendsIntentRouter *router = [[SZFriendsIntentRouter alloc] initWithServices:services publisher:publisher];
        SZFriendsLifecyclePolicy *policy = [[SZFriendsLifecyclePolicy alloc] init];
        double scale = SZFriendsHelperTimeScale(environment);
        policy.gracePeriod *= scale;
        policy.firstClientDeadline *= scale;
        policy.handoverDeadline *= scale;
        SZFriendsHelperLifecycle *lifecycle = [[SZFriendsHelperLifecycle alloc] initWithPolicy:policy
                                                                                        server:server
                                                                                         queue:queue];
        __weak SZFriendsIntentRouter *weakRouter = router;
        __weak SZFriendsIPCServer *weakServer = server;
        __weak SZFriendsHelperLifecycle *weakLifecycle = lifecycle;
        server.intentHandler = router;
        server.welcomeBuilder = ^NSDictionary *(SZFriendsClientContext *client) {
            return [weakRouter welcomeForClient:client] ?: @{};
        };
        server.onConnectionsChanged = ^(SZFriendsIPCConnection *closed) { [weakLifecycle connectionsChanged:closed]; };
        // Nearby and the host check-in exist only with an identity and a store: an identity-unavailable helper
        // shows its reset path and contacts nobody.
        SZFriendsNearbyService *nearby = nil;
        if (services.store != nil && services.identity != nil) {
            nearby = [[SZFriendsNearbyService alloc] initWithServices:services
                                                             adapters:SZFriendsHelperMakeAdapters(queue, environment)
                                                                queue:queue];
            nearby.onChange = ^{ [publisher publishAllCoalesced]; };
            services.nearby = nearby;
            if (services.checkInSetup != nil && services.hostListCache != nil) {
                services.checkIn = [[SZFriendsHelperCheckIn alloc] initWithServices:services
                                                                              setup:services.checkInSetup
                                                                              cache:services.hostListCache
                                                                              queue:queue];
                services.checkIn.onChange = ^{ [publisher publishAllCoalesced]; };
            }
        }
        server.onHandoverRequested = ^(NSDictionary *embedded) {
            // No new chunk starts; what is in flight drains, and the successor resumes from the durable offsets.
            [nearby beginHandover];
            [weakLifecycle requestHandoverWithSuccessor:embedded];
        };
        router.onDisable = ^(SZFriendsIPCConnection *connection) { [weakLifecycle connectionSentDisable:connection]; };
        router.onReset = ^{ [weakServer broadcastGoodbyeWithReason:@"reset" successor:nil]; };
        // A handover waits (5 s at most) while a chunk is unacknowledged or received bytes are not yet durable.
        lifecycle.workInFlight = ^BOOL { return nearby.workInFlight; };
        lifecycle.onExit = ^(SZFriendsExitReason reason) {
            SZFriendsHelperLog(@"exiting (reason %ld)", (long)reason);
            [services.checkIn stop];
            void (^finish)(void) = ^{
                [publisher stop];
                [server stop];
                [services close];
                // Released last, after the socket is gone, so a successor never binds beside a live socket.
                [lock releaseLock];
                exit(0);
            };
            // Progress durable and CLOSE on every session, so friends resume from where we stopped (ADR 0002).
            if (nearby != nil) [nearby shutdownWithCompletion:finish];
            else finish();
        };
        if (![server startWithError:&error]) {
            SZFriendsHelperLog(@"cannot listen: %@", error.localizedDescription);
            [services close];
            return 1;
        }
        SZFriendsInstallSignalHandlers(lifecycle, queue);
        SZFriendsHelperRoots = @[ lock, services, server, publisher, router, lifecycle ];
        SZFriendsHelperLog(@"serving build %llu", SZFriendsHelperBuildNumber());
        [lifecycle start];
        [nearby startAtLaunch];
        [services.checkIn start];
        [publisher publishAllCoalesced]; // arms the visibility and midnight timers
    }
    dispatch_main();
}
