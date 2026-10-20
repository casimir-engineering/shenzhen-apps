// friends-one-identity-check, one computer: ShenzhenPDF, Shenzhen Files and Shenzhen 3D in one home, in every start
// order, with older and newer helpers, after a crash, and where each finds Friends (SZFriendsE2EOneIdentity.h).

#import "SZFriendsE2EOneIdentityMac.h"

#import <signal.h>

BOOL SZFE2EOneIDScenarioStartOrders(SZFE2EWorld *world) {
    SZFOMac *mac = SZFOPrepare(world, SZFOSameBuild());
    if (mac == nil) return NO;
    BOOL ok = NO;
    @try {
        NSArray *orders = SZFOOrders();
        for (NSUInteger round = 0; round < orders.count; round++) {
            NSArray<NSString *> *order = orders[round];
            // Even rounds start each app once the one before is ready; odd rounds start all three at once, so their
            // spawns race for the lock.
            BOOL together = round % 2 == 1;
            for (NSString *app in order) {
                CHECK(SZFOLaunch(mac, app, SZFOBuild) != nil, "%@ launches", app);
                if (!together) CHECK([mac.running[app] waitReady:30] > 0, "%@ ready (%@)", app, SZFOStates(mac));
            }
            CHECK(SZFOAllReady(mac, 30), "round %lu (%@): all three ready on one helper: %@", (unsigned long)round,
                  [order componentsJoinedByString:@", "], SZFOStates(mac));
            pid_t helper = SZFOSharedHelper(mac);
            NSString *path = SZFE2EProcessPath(helper);
            if (!together) {
                CHECK([path isEqual:[mac.helpers[order[0]] stringByResolvingSymlinksInPath]] ||
                          [path hasSuffix:[mac.helpers[order[0]] substringFromIndex:mac.appsDirectory.length]],
                      "the first app's own helper serves all three: %@", path);
            }
            if (!SZFOOnlyHelper(mac, helper, 1.5) || !SZFOSameIdentity(mac, @"Ana")) return NO;
            CHECK(SZFE2EWaitUntil(10, ^BOOL {
                      SZFODrain(mac);
                      for (SZFE2EApp *app in mac.running.allValues)
                          if (![SZFORow(app, mac.benAtAna)[@"unread"] boolValue]) return NO;
                      return YES;
                  }),
                  "Ben's message waits unread in all three");
            SZFOQuitAll(mac);
            if (round == 0) {
                // The last app gone, the helper leaves by itself after its grace period.
                CHECK(SZFE2EWaitGone(helper, 20), "the helper exits after the last app quits");
            } else {
                kill(helper, SIGTERM);
                CHECK(SZFE2EWaitGone(helper, 10), "the helper stops");
            }
            CHECK(SZFOHelperProcesses(mac).count == 0, "no helper left between rounds");
        }
        ok = YES;
    } @finally {
        SZFOShutDown(mac, !ok);
    }
    return ok;
}

BOOL SZFE2EOneIDScenarioBuilds(SZFE2EWorld *world) {
    SZFOMac *mac = SZFOPrepare(world, SZFOSameBuild());
    if (mac == nil) return NO;
    BOOL ok = NO;
    @try {
        NSArray *orders = SZFOOrders();
        for (NSUInteger round = 0; round < orders.count; round++) {
            NSArray<NSString *> *order = orders[round];
            // Which app carries the newest helper turns with the round, so each start order meets it first, in the
            // middle and last across the rounds.
            NSArray<NSString *> *apps = SZFOApps();
            NSString *newest = apps[round % 3], *middle = apps[(round + 1) % 3], *oldest = apps[(round + 2) % 3];
            NSDictionary<NSString *, NSNumber *> *builds =
                @{newest : @(SZFOBuild + 2), middle : @(SZFOBuild + 1), oldest : @(SZFOBuild)};
            for (NSString *app in apps) CHECK(SZFOSetBuild(mac, app, builds[app].unsignedLongLongValue));
            for (NSString *app in order) {
                CHECK(SZFOLaunch(mac, app, builds[app].unsignedLongLongValue) != nil, "%@ launches", app);
                CHECK([mac.running[app] waitReady:30] > 0, "%@ ready: %@", app, SZFOStates(mac));
            }
            NSString *wanted = [mac.helpers[newest] substringFromIndex:mac.appsDirectory.length];
            __block pid_t helper = 0;
            CHECK(SZFE2EWaitUntil(30, ^BOOL {
                      helper = SZFOSharedHelper(mac);
                      return helper > 0 && [SZFE2EProcessPath(helper) hasSuffix:wanted];
                  }),
                  "round %lu (%@, newest %@): all three end on the newest helper: %@ %@", (unsigned long)round,
                  [order componentsJoinedByString:@", "], newest, SZFOStates(mac), SZFE2EProcessPath(helper));
            // The older helpers are gone and no app brings one back, even after its own wait for the successor.
            CHECK(SZFE2EWaitUntil(10, ^BOOL { return SZFOHelperProcesses(mac).count == 1; }),
                  "the older helpers exit: %@", SZFOHelperProcesses(mac));
            if (!SZFOOnlyHelper(mac, helper, 11) || !SZFOSameIdentity(mac, @"Ana")) return NO;
            CHECK(SZFE2EWaitUntil(10, ^BOOL {
                      SZFODrain(mac);
                      for (SZFE2EApp *app in mac.running.allValues)
                          if (![SZFORow(app, mac.benAtAna)[@"unread"] boolValue]) return NO;
                      return YES;
                  }),
                  "nothing lost on the way: Ben's message still waits unread in all three");
            SZFOQuitAll(mac);
            kill(helper, SIGTERM);
            CHECK(SZFE2EWaitGone(helper, 10), "the helper stops");
        }
        ok = YES;
    } @finally {
        SZFOShutDown(mac, !ok);
    }
    return ok;
}

BOOL SZFE2EOneIDScenarioCrash(SZFE2EWorld *world) {
    SZFOMac *mac = SZFOPrepare(world, SZFOSameBuild());
    if (mac == nil) return NO;
    BOOL ok = NO;
    @try {
        for (NSString *app in SZFOApps()) CHECK(SZFOLaunch(mac, app, SZFOBuild) != nil, "%@ launches", app);
        CHECK(SZFOAllReady(mac, 40), "all three ready: %@", SZFOStates(mac));
        for (int crash = 0; crash < 3; crash++) {
            pid_t before = SZFOSharedHelper(mac);
            kill(before, SIGKILL);
            CHECK(SZFE2EWaitGone(before, 5), "the helper is gone");
            // Its socket file and lock file stay behind, as after any crash.
            NSUInteger most = 0;
            NSDate *until = [NSDate dateWithTimeIntervalSinceNow:20];
            pid_t after = 0;
            while (until.timeIntervalSinceNow > 0) {
                most = MAX(most, SZFOHelperProcesses(mac).count);
                after = SZFOSharedHelper(mac);
                if (after > 0 && after != before) break;
                SZFE2EPump(0.05);
            }
            CHECK(after > 0 && after != before, "crash %d: all three back on one new helper: %@", crash,
                  SZFOStates(mac));
            if (!SZFOOnlyHelper(mac, after, 2)) return NO;
            if (!SZFOSameIdentity(mac, @"Ana")) return NO;
            // Ben's chat is the same in all three after the crash.
            NSDictionary *open = @{@"cmd" : @"open", @"conversation_id" : mac.benAtAna};
            for (SZFE2EApp *app in mac.running.allValues) [app send:open];
            CHECK(SZFE2EWaitUntil(10, ^BOOL {
                      SZFODrain(mac);
                      for (SZFE2EApp *app in mac.running.allValues) {
                          NSArray *messages = SZFE2EKindItems([app conversation:mac.benAtAna], @"message");
                          if (![[messages valueForKey:@"text"] containsObject:@"Pages 3–5 are ready"]) return NO;
                      }
                      return YES;
                  }),
                  "Ben's chat survives the crash in all three");
            if (crash == 2) {
                // The last crash with one app gone first: the two left recover the same way.
                [mac.running[SZFOPDF] quitWithin:5];
                [mac.running removeObjectForKey:SZFOPDF];
            }
            (void)most;
        }
        ok = YES;
    } @finally {
        SZFOShutDown(mac, !ok);
    }
    return ok;
}

// Every file a Friends helper writes in its home, by name, so a second home anywhere under $HOME shows.
static NSArray<NSString *> *SZFOFriendsHomesUnder(NSString *home) {
    NSMutableArray<NSString *> *found = [NSMutableArray array];
    NSDirectoryEnumerator *walk = [[NSFileManager defaultManager] enumeratorAtPath:home];
    for (NSString *relative in walk) {
        if ([relative.lastPathComponent isEqualToString:@"helper.lock"])
            [found addObject:relative.stringByDeletingLastPathComponent];
    }
    return found;
}

BOOL SZFE2EOneIDScenarioHome(SZFE2EWorld *world) {
    SZFOMac *mac = SZFOPrepare(world, SZFOSameBuild());
    if (mac == nil) return NO;
    BOOL ok = NO;
    @try {
        for (NSString *app in SZFOApps()) CHECK(SZFOLaunch(mac, app, SZFOBuild) != nil, "%@ launches", app);
        CHECK(SZFOAllReady(mac, 40), "all three ready: %@", SZFOStates(mac));
        // Each app's own client library (the addon's, in Shenzhen 3D's main process) names one Friends home and one
        // socket, the ones the helper uses.
        NSString *expected = SZFOStateDirectory(mac.home);
        NSString *socketPath = nil;
        for (NSString *app in SZFOApps()) {
            NSDictionary *paths = SZFOAsk(mac.running[app], @{@"cmd" : @"paths"}, 20)[@"result"];
            CHECK([paths[@"state_dir"] isEqual:expected], "%@ finds Ana's Friends home: %@", app, paths);
            socketPath = socketPath ?: paths[@"socket_path"];
            CHECK([paths[@"socket_path"] isEqual:socketPath] && socketPath.length > 0, "%@ uses the one socket: %@",
                  app, paths);
        }
        // Nothing made a Friends home of its own anywhere else in the person's home (Electron's profile, Files'
        // caches, a container): one helper.lock, in the shared home.
        NSArray<NSString *> *homes = SZFOFriendsHomesUnder(mac.home);
        CHECK(homes.count == 1 && [homes[0] isEqual:@"Library/Application Support/Shenzhen Friends"],
              "one Friends home in the person's home: %@", homes);
        ok = YES;
    } @finally {
        SZFOShutDown(mac, !ok);
    }
    return ok;
}
