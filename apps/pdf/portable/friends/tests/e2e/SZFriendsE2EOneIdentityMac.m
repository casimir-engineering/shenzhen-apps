// friends-one-identity-check, one computer: Ana's Mac, its three apps and their helpers (SZFriendsE2EOneIdentityMac.h).

#import "SZFriendsE2EOneIdentityMac.h"

#import <libproc.h>
#import <signal.h>
#import <sys/stat.h>

NSString *const SZFOPDF = @"ShenzhenPDF", *const SZFOFiles = @"Shenzhen Files", *const SZFO3D = @"Shenzhen 3D";
const uint64_t SZFOBuild = 26101301;

NSArray<NSString *> *SZFOApps(void) {
    return @[ SZFOPDF, SZFOFiles, SZFO3D ];
}

NSArray<NSArray<NSString *> *> *SZFOOrders(void) {
    return @[
        @[ SZFOPDF, SZFOFiles, SZFO3D ], @[ SZFOPDF, SZFO3D, SZFOFiles ], @[ SZFOFiles, SZFOPDF, SZFO3D ],
        @[ SZFOFiles, SZFO3D, SZFOPDF ], @[ SZFO3D, SZFOPDF, SZFOFiles ], @[ SZFO3D, SZFOFiles, SZFOPDF ]
    ];
}

static NSString *SZFOEnv(NSString *name) {
    return NSProcessInfo.processInfo.environment[name];
}

#pragma mark - Ana's Mac

@implementation SZFOMac
@end

// Ana's Friends home: where the shipped apps put it for a person whose home is `home`.
NSString *SZFOStateDirectory(NSString *home) {
    return [home stringByAppendingPathComponent:@"Library/Application Support/Shenzhen Friends"];
}

static BOOL SZFORun(NSArray<NSString *> *arguments, NSString *_Nullable *output) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:arguments[0]];
    task.arguments = [arguments subarrayWithRange:NSMakeRange(1, arguments.count - 1)];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    if (![task launchAndReturnError:NULL]) return NO;
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (output) *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return task.terminationStatus == 0;
}

// The three app bundles, each embedding the oneid helper saying the build given for it.
static BOOL SZFOMakeApps(SZFE2EWorld *world, SZFOMac *mac, NSDictionary<NSString *, NSNumber *> *builds) {
    NSString *helper = NSProcessInfo.processInfo.arguments[1];
    NSString *appkit = SZFOEnv(@"SZFRIENDS_E2E_APPKIT_APP"), *gtk = SZFOEnv(@"SZFRIENDS_E2E_GTK_APP");
    NSString *quiet = SZFOEnv(@"SZFRIENDS_E2E_GTK_QUIET"), *threeD = SZFOEnv(@"SZFRIENDS_E2E_3D");
    NSString *node = SZFOEnv(@"SZFRIENDS_E2E_NODE");
    CHECK(appkit && gtk && quiet && threeD && node, "oneid.mk names every app program");
    mac.appsDirectory = [world.scenarioDirectory stringByAppendingPathComponent:@"apps"];
    mac.executables = [NSMutableDictionary dictionary];
    mac.helpers = [NSMutableDictionary dictionary];
    mac.executables[SZFOPDF] = SZFE2EMakeAppBundle(mac.appsDirectory, SZFOPDF, appkit, helper,
                                                   builds[SZFOPDF].unsignedLongLongValue);
    mac.executables[SZFOFiles] = SZFE2EMakeAppBundle(mac.appsDirectory, SZFOFiles, gtk, helper,
                                                     builds[SZFOFiles].unsignedLongLongValue);
    CHECK(mac.executables[SZFOPDF] && mac.executables[SZFOFiles], "the AppKit and GTK app bundles");
    for (NSString *app in @[ SZFOPDF, SZFOFiles ]) mac.helpers[app] = SZFE2EAppHelperExecutable(mac.executables[app]);
    // The GTK app finds the quiet interposer beside it (@executable_path), as the views' probes do.
    NSString *beside = [mac.executables[SZFOFiles].stringByDeletingLastPathComponent
        stringByAppendingPathComponent:quiet.lastPathComponent];
    CHECK([[NSFileManager defaultManager] copyItemAtPath:quiet toPath:beside error:NULL], "the quiet interposer");

    // Shenzhen 3D: the packaged shell, built by its own script, with the same helper embedded.
    NSString *driver = [threeD stringByAppendingPathComponent:@"electron/friends-one-identity-app.mjs"];
    NSString *bundle = [mac.appsDirectory stringByAppendingPathComponent:@"Shenzhen 3D.app"];
    NSString *animals = [NSProcessInfo.processInfo.arguments[2] stringByDeletingLastPathComponent];
    NSString *made = nil;
    CHECK(SZFORun(@[ node, driver, @"--make-app", bundle, helper,
                     [NSString stringWithFormat:@"%llu", builds[SZFO3D].unsignedLongLongValue], animals ],
                  &made),
          "Shenzhen 3D's app bundle: %@", made);
    mac.helpers[SZFO3D] = [bundle stringByAppendingPathComponent:
                                      @"Contents/Helpers/Shenzhen Friends.app/Contents/MacOS/Shenzhen Friends"];
    // What the runner launches for Shenzhen 3D: the driver, which runs the bundle hidden.
    NSString *wrapper = [mac.appsDirectory stringByAppendingPathComponent:@"shenzhen-3d-driver"];
    NSString *script = [NSString stringWithFormat:@"#!/bin/sh\nexec '%@' '%@' \"$@\"\n", node, driver];
    CHECK([script writeToFile:wrapper atomically:YES encoding:NSUTF8StringEncoding error:NULL] &&
              chmod(wrapper.fileSystemRepresentation, 0755) == 0,
          "the driver's wrapper");
    mac.executables[SZFO3D] = wrapper;
    return YES;
}

// Changes the build an app's embedded helper says (the app updated to a newer or older one).
BOOL SZFOSetBuild(SZFOMac *mac, NSString *app, uint64_t build) {
    // SZFE2ESetAppHelperBuild finds the helper from an executable in Contents/MacOS; any name there will do.
    NSString *contents = mac.helpers[app];
    for (int i = 0; i < 5; i++) contents = contents.stringByDeletingLastPathComponent; // <App>.app/Contents
    return SZFE2ESetAppHelperBuild([contents stringByAppendingPathComponent:@"MacOS/app"], build);
}

// Ana befriends Ben with a harness helper on her Friends home; Ben's message waits unread; with `laptop`, a second
// computer of hers (a harness helper) joins her profile, so You exists. Her helper stops, so her apps start their own
// on the same home. Then the bundles.
SZFOMac *SZFOPrepareWith(SZFE2EWorld *world, NSDictionary<NSString *, NSNumber *> *builds, BOOL laptop) {
    SZFOMac *mac = [SZFOMac new];
    mac.home = [world.scenarioDirectory stringByAppendingPathComponent:@"ana"];
    mac.running = [NSMutableDictionary dictionary];
    mac.helperPIDs = [NSMutableSet set];
    NSString *relative = [@"ana" stringByAppendingPathComponent:@"Library/Application Support/Shenzhen Friends"];
    SZFE2EComputer *ana = SZFE2EStartComputer(world, relative, @"Ana", nil, NO);
    SZFE2EComputer *ben = SZFE2EStartComputer(world, @"ben", @"Ben", nil, NO);
    if (ana == nil || ben == nil) return nil;
    NSString *benAtAna = nil, *anaAtBen = nil;
    if (!SZFE2EBefriendNearby(ana, ben, &benAtAna, &anaAtBen)) return nil;
    if (!SZFE2ESay(ben, anaAtBen, @"Pages 3–5 are ready")) {
        SZFE2EFail(__FILE__, __LINE__, "Ben writes", @"");
        return nil;
    }
    if (!SZFE2EWaitUntil(15, ^BOOL { return [SZFE2EListRow(ana, @"Ben")[@"unread"] boolValue]; })) {
        SZFE2EFail(__FILE__, __LINE__, "Ben's message unread at Ana", [SZFE2EListRow(ana, @"Ben") description]);
        return nil;
    }
    mac.friendsID = SZFE2EFriendsID(ana);
    if (laptop) {
        mac.laptop = SZFE2EStartComputer(world, @"laptop", @"Ana", nil, YES);
        if (mac.laptop == nil || !SZFE2EJoin(ana, mac.laptop, 25)) return nil;
    }
    if (!SZFE2EStopComputer(ana)) return nil;
    mac.ben = ben;
    mac.benAtAna = benAtAna;
    mac.anaAtBen = anaAtBen;
    NSString *bin = SZFOEnv(@"SZFRIENDS_E2E_NODE").stringByDeletingLastPathComponent;
    // A home of her own and nothing that says where Friends lives: the apps find it as the shipped ones do. The
    // file key store and the loopback Bonjour type are the harness's, as for every helper it runs.
    mac.environment = @{
        @"HOME" : mac.home,
        @"CFFIXED_USER_HOME" : mac.home,
        @"SZFRIENDS_E2E_TEST_HOME" : mac.home,
        @"SZFRIENDS_KEY_STORE" : @"file",
        @"SZFRIENDS_TEST_SERVICE_TYPE" : world.serviceType,
        @"SZFRIENDS_AVATARS_MANIFEST" : NSProcessInfo.processInfo.arguments[2],
        @"XDG_CACHE_HOME" : [world.scenarioDirectory.stringByDeletingLastPathComponent
            stringByAppendingPathComponent:@"cache"],
        @"PATH" : [NSString stringWithFormat:@"%@:/usr/bin:/bin", bin],
        @"TMPDIR" : NSTemporaryDirectory(),
        @"LANG" : @"en_US.UTF-8",
    };
    return SZFOMakeApps(world, mac, builds) ? mac : nil;
}

SZFOMac *SZFOPrepare(SZFE2EWorld *world, NSDictionary<NSString *, NSNumber *> *builds) {
    return SZFOPrepareWith(world, builds, NO);
}

NSDictionary<NSString *, NSNumber *> *SZFOSameBuild(void) {
    return @{SZFOPDF : @(SZFOBuild), SZFOFiles : @(SZFOBuild), SZFO3D : @(SZFOBuild)};
}

// Every Friends helper process running from one of this Mac's app bundles.
NSArray<NSNumber *> *SZFOHelperProcesses(SZFOMac *mac) {
    char resolved[PATH_MAX];
    NSString *root = realpath(mac.appsDirectory.fileSystemRepresentation, resolved) ? @(resolved) : mac.appsDirectory;
    int capacity = proc_listallpids(NULL, 0) + 64;
    pid_t *pids = calloc((size_t)capacity, sizeof(pid_t));
    int count = proc_listallpids(pids, capacity * (int)sizeof(pid_t));
    NSMutableArray<NSNumber *> *found = [NSMutableArray array];
    for (int i = 0; i < count; i++) {
        NSString *path = SZFE2EProcessPath(pids[i]);
        if ([path hasPrefix:[root stringByAppendingString:@"/"]] &&
            [path.lastPathComponent isEqualToString:@"Shenzhen Friends"])
            [found addObject:@(pids[i])];
    }
    free(pids);
    [mac.helperPIDs addObjectsFromArray:found];
    return [found sortedArrayUsingSelector:@selector(compare:)];
}

SZFE2EApp *SZFOLaunch(SZFOMac *mac, NSString *app, uint64_t build) {
    SZFE2EApp *running = [SZFE2EApp launch:mac.executables[app] helper:mac.helpers[app] build:build
                               environment:mac.environment];
    if (running) mac.running[app] = running;
    return running;
}

void SZFOQuitAll(SZFOMac *mac) {
    for (NSString *app in mac.running) {
        SZFE2EApp *running = mac.running[app];
        [mac.helperPIDs addObjectsFromArray:running.helperPIDs];
        [running quitWithin:5];
    }
    [mac.running removeAllObjects];
}

// Quits the apps and stops every helper of this Mac, as a scenario's end or a fresh round needs.
void SZFOShutDown(SZFOMac *mac, BOOL printLogs) {
    if (printLogs) {
        for (NSString *app in mac.running) {
            NSArray<NSString *> *lines = [mac.running[app].log componentsSeparatedByString:@"\n"];
            NSUInteger keep = MIN(lines.count, (NSUInteger)40);
            fprintf(stderr, "--- %s log\n%s\n", app.UTF8String,
                    [[lines subarrayWithRange:NSMakeRange(lines.count - keep, keep)] componentsJoinedByString:@"\n"]
                        .UTF8String);
        }
        NSString *log = [SZFOStateDirectory(mac.home) stringByAppendingPathComponent:@"helper.log"];
        NSString *text = [NSString stringWithContentsOfFile:log encoding:NSUTF8StringEncoding error:NULL] ?: @"";
        NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
        NSUInteger keep = MIN(lines.count, (NSUInteger)40);
        fprintf(stderr, "--- Ana's helper log\n%s\n",
                [[lines subarrayWithRange:NSMakeRange(lines.count - keep, keep)] componentsJoinedByString:@"\n"]
                    .UTF8String);
    }
    SZFOQuitAll(mac);
    [mac.helperPIDs addObjectsFromArray:SZFOHelperProcesses(mac)];
    SZFE2EKillHelpersUnder(mac.helperPIDs.allObjects, mac.appsDirectory);
}

void SZFODrain(SZFOMac *mac) {
    for (SZFE2EApp *app in mac.running.allValues) [app drain];
}

// The pid every running app is ready on, when they all agree; 0 otherwise.
pid_t SZFOSharedHelper(SZFOMac *mac) {
    SZFODrain(mac);
    pid_t shared = 0;
    for (SZFE2EApp *app in mac.running.allValues) {
        if (![app.state isEqual:@"ready"] || app.helperPID <= 0) return 0;
        if (shared != 0 && app.helperPID != shared) return 0;
        shared = app.helperPID;
    }
    return shared;
}

BOOL SZFOAllReady(SZFOMac *mac, NSTimeInterval timeout) {
    return SZFE2EWaitUntil(timeout, ^BOOL { return SZFOSharedHelper(mac) > 0; });
}

NSString *SZFOStates(SZFOMac *mac) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *app in mac.running)
        [parts addObject:[NSString stringWithFormat:@"%@ %@ on %d (was on %@)", app, mac.running[app].state,
                                                    mac.running[app].helperPID,
                                                    [mac.running[app].helperPIDs componentsJoinedByString:@","]]];
    return [parts componentsJoinedByString:@"; "];
}

// A command whose reply is tagged; the reply, or nil after `timeout`.
NSDictionary *SZFOAsk(SZFE2EApp *app, NSDictionary *command, NSTimeInterval timeout) {
    static unsigned counter;
    NSString *tag = [NSString stringWithFormat:@"t%u", ++counter];
    NSMutableDictionary *line = [command mutableCopy];
    line[@"tag"] = tag;
    [app send:line];
    __block NSDictionary *reply = nil;
    SZFE2EWaitUntil(timeout, ^BOOL {
        [app drain];
        reply = [app replyTagged:tag];
        return reply != nil;
    });
    return reply;
}

// What the app's real conversation view shows for the conversation (`title` is its row's, for Shenzhen 3D's panel).
NSArray<NSString *> *SZFOShownTexts(SZFE2EApp *app, NSString *conversationID, NSString *title) {
    NSDictionary *reply = SZFOAsk(app, @{@"cmd" : @"ui_texts", @"conversation_id" : conversationID, @"title" : title},
                                  20);
    id texts = reply[@"result"][@"texts"];
    return [reply[@"ok"] boolValue] && [texts isKindOfClass:NSArray.class] ? texts : nil;
}

BOOL SZFOShows(NSArray<NSString *> *texts, NSString *text) {
    for (NSString *shown in texts)
        if ([shown isKindOfClass:NSString.class] && [shown containsString:text]) return YES;
    return NO;
}

// Waits until the real view of every app in `apps` shows `text` in the conversation (or, with `shown` NO, no longer
// shows it).
BOOL SZFOViewsShow(SZFOMac *mac, NSArray<NSString *> *apps, NSString *conversationID, NSString *title,
                          NSString *text, BOOL shown, NSTimeInterval timeout) {
    for (NSString *app in apps) {
        __block NSArray *last = nil;
        BOOL ok = SZFE2EWaitUntil(timeout, ^BOOL {
            last = SZFOShownTexts(mac.running[app], conversationID, title);
            return last != nil && SZFOShows(last, text) == shown;
        });
        if (!ok) {
            // What the helper says, beside what the view shows.
            [mac.running[app] send:@{@"cmd" : @"open", @"conversation_id" : conversationID}];
            SZFE2EWaitUntil(2, ^BOOL {
                [mac.running[app] drain];
                return [mac.running[app] conversation:conversationID] != nil;
            });
        }
        CHECK(ok, "%@'s view %@ \"%@\": %@ (the helper's: %@)", app, shown ? @"shows" : @"no longer shows", text, last,
              [SZFE2EKindItems([mac.running[app] conversation:conversationID], @"message") valueForKey:@"text"]);
    }
    return YES;
}

NSDictionary *SZFORow(SZFE2EApp *app, NSString *conversationID) {
    for (NSDictionary *row in app.list[@"rows"])
        if ([row[@"conversation_id"] isEqual:conversationID]) return row;
    return nil;
}

// Every app subscribed to its list and profile; waits until each one's profile says this identity and name.
BOOL SZFOSameIdentity(SZFOMac *mac, NSString *name) {
    for (SZFE2EApp *app in mac.running.allValues) {
        [app send:@{@"cmd" : @"list"}];
        [app send:@{@"cmd" : @"profile"}];
    }
    __block NSString *seen = @"";
    BOOL same = SZFE2EWaitUntil(20, ^BOOL {
        SZFODrain(mac);
        NSMutableArray *parts = [NSMutableArray array];
        BOOL all = YES;
        for (NSString *app in mac.running) {
            NSDictionary *profile = [mac.running[app] view:@"profile"];
            NSString *id = profile[@"id"][@"friends_id"], *shownName = profile[@"name"][@"value"];
            [parts addObject:[NSString stringWithFormat:@"%@: %@ %@", app, id, shownName]];
            all = all && [id isEqual:mac.friendsID] && [shownName isEqual:name];
        }
        seen = [parts componentsJoinedByString:@", "];
        return all;
    });
    CHECK(same, "every app shows Ana's one identity (%@, %@): %@", mac.friendsID, name, seen);
    return YES;
}

// Exactly one helper process, `helper`, through `seconds` of looking.
BOOL SZFOOnlyHelper(SZFOMac *mac, pid_t helper, NSTimeInterval seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (until.timeIntervalSinceNow > 0) {
        NSArray<NSNumber *> *helpers = SZFOHelperProcesses(mac);
        CHECK(helpers.count == 1 && helpers[0].intValue == helper, "one helper process, %d: %@ (%@)", helper, helpers,
              SZFOStates(mac));
        CHECK(SZFOSharedHelper(mac) == helper, "every app stays on it: %@", SZFOStates(mac));
        SZFE2EPump(0.1);
    }
    return YES;
}

