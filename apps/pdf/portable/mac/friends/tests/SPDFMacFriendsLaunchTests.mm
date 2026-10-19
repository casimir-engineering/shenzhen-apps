// Launch laziness, instrumented (ADR 0002 § Verification): disabled makes no queue hop, spawn, attach or socket;
// enabled makes exactly one background hop, spawns off the main thread, never blocks the caller, and attaches only
// after first paint. A signed app's signing policy is prepared before the first spawn and before every attach.

#import <Foundation/Foundation.h>
#import <pthread.h>
#include <mach/mach.h>
#include <sys/stat.h>
#import "SPDFMacFriendsLaunch.h"
#import "SPDFMacFriendsSettings.h"
#import "SPDFMacFriendsSigning.h"
#import "SPDFMacFriendsTestSupport.h"

@interface Probe : NSObject
@property(atomic) NSInteger dispatches, spawns, helperPathCalls, attaches, detaches, signings;
@property(atomic) BOOL spawnOnMain, helperPathOnMain, lastDetachDisabling, signedBeforeSpawn, signedBeforeAttach;
@property(atomic, copy) NSString* spawnedPath;
@property(nonatomic) dispatch_semaphore_t spawned;
@property(atomic) useconds_t spawnDelay;
@end
@implementation Probe
@end

static NSInteger OpenSockets(void) {
    NSInteger count = 0;
    for (int fd = 0; fd < getdtablesize(); fd++) {
        struct stat st = {};
        if (fstat(fd, &st) == 0 && S_ISSOCK(st.st_mode)) count++;
    }
    return count;
}

static SPDFMacFriendsLifecycle* Lifecycle(Probe* probe, SPDFMacFriendsSettingsState* state, NSString* helper) {
    probe.spawned = dispatch_semaphore_create(0);
    SPDFMacFriendsLaunchEnvironment* environment = [[SPDFMacFriendsLaunchEnvironment alloc]
        initWithSpawn:^int(NSString* path, NSString* stateDirectory, pid_t* pid) {
            (void)stateDirectory;
            if (probe.spawnDelay) usleep(probe.spawnDelay);
            probe.signedBeforeSpawn = probe.signings > 0;
            probe.spawns++;
            probe.spawnOnMain = pthread_main_np() != 0;
            probe.spawnedPath = path;
            *pid = 4242;
            dispatch_semaphore_signal(probe.spawned);
            return 0;
        }];
    void (^realDispatch)(dispatch_block_t) = environment.dispatchBackground;
    environment.dispatchBackground = ^(dispatch_block_t block) { probe.dispatches++; realDispatch(block); };
    environment.prepareSigning = ^{ probe.signings++; };
    return [[SPDFMacFriendsLifecycle alloc] initWithSettings:state environment:environment
        helperPath:^NSString* {
            probe.helperPathCalls++;
            probe.helperPathOnMain = pthread_main_np() != 0;
            return helper;
        }
        attach:^{ probe.signedBeforeAttach = probe.signings > 0; probe.attaches++; }
        detach:^(BOOL disabling) { probe.detaches++; probe.lastDetachDisabling = disabling; }];
}

static void TestSettingsParsing(void) {
    Expect(SPDFMacFriendsEnabledInSettings(nil), @"a missing settings.yaml must leave Friends on (on by default)");
    Expect(SPDFMacFriendsEnabledInSettings(@{@"fitMode" : @1}), @"a settings.yaml without friends must leave it on");
    Expect(!SPDFMacFriendsEnabledInSettings(@{@"friends" : @{@"enabled" : @NO}}), @"explicit false must turn it off");
    Expect(SPDFMacFriendsEnabledInSettings(@{@"friends" : @{@"enabled" : @"no"}}),
           @"a hand-edited string is not a boolean and must not silently stop reception");
    Expect(SPDFMacFriendsEnabledInSettings(@{@"friends" : @"off"}), @"a malformed friends entry must leave it on");
}

static void TestDisabledLaunchDoesNothing(void) {
    Probe* probe = [Probe new];
    SPDFMacFriendsSettingsState* state = [SPDFMacFriendsSettingsState new];
    SPDFMacFriendsLifecycle* lifecycle = Lifecycle(probe, state, @"/Applications/X.app/helper");
    NSInteger socketsBefore = OpenSockets();
    [lifecycle launchWithSettings:@{@"friends" : @{@"enabled" : @NO}}];
    [lifecycle firstPaintDidHappen];
    SPDFMacFriendsTestRunUntil(0.2, ^BOOL { return NO; });
    Expect(probe.dispatches == 0, @"disabled launch hopped to a queue %ld times", (long)probe.dispatches);
    Expect(probe.spawns == 0 && probe.helperPathCalls == 0, @"disabled launch looked for or spawned the helper");
    Expect(probe.signings == 0, @"disabled launch read the app's signature");
    Expect(probe.attaches == 0 && !lifecycle.attached, @"disabled launch attached (link, sockets, timers)");
    Expect(OpenSockets() == socketsBefore, @"disabled launch opened a socket");
}

static void TestEnabledLaunchSpawnsOffMainWithoutBlocking(void) {
    Probe* probe = [Probe new];
    probe.spawnDelay = 300 * 1000;  // a slow spawn must not slow the caller
    SPDFMacFriendsSettingsState* state = [SPDFMacFriendsSettingsState new];
    SPDFMacFriendsLifecycle* lifecycle = Lifecycle(probe, state, @"/Applications/ShenzhenPDF.app/helper");
    NSDate* start = NSDate.date;
    [lifecycle launchWithSettings:@{}];
    NSTimeInterval elapsed = -start.timeIntervalSinceNow;
    Expect(elapsed < 0.05, @"the launch hook blocked the main thread for %.0f ms", elapsed * 1000);
    Expect(probe.dispatches == 1, @"enabled launch must hop to the background exactly once, made %ld",
           (long)probe.dispatches);
    Expect(probe.attaches == 0, @"attached before first paint: Friends work ran before the first frame");
    Expect(dispatch_semaphore_wait(probe.spawned, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0,
           @"the background spawn never ran");
    Expect(probe.spawns == 1 && !probe.spawnOnMain, @"spawn ran on the main thread or more than once");
    Expect(probe.signedBeforeSpawn, @"the helper was spawned before the signing policy was set");
    Expect(probe.helperPathCalls == 1 && !probe.helperPathOnMain, @"bundle lookup ran on the main thread");
    Expect([probe.spawnedPath isEqual:@"/Applications/ShenzhenPDF.app/helper"], @"spawned %@", probe.spawnedPath);
    [lifecycle firstPaintDidHappen];
    [lifecycle firstPaintDidHappen];
    Expect(probe.attaches == 1 && lifecycle.attached, @"first paint must attach exactly once, attached %ld",
           (long)probe.attaches);
    Expect(probe.signedBeforeAttach && probe.signings == 2,
           @"the link must not connect before the signing policy is set (prepared %ld times)", (long)probe.signings);
}

// Enabled in Settings without a launch spawn (it was off at launch): attaching still prepares the policy first.
static void TestAttachWithoutLaunchSpawnSignsFirst(void) {
    Probe* probe = [Probe new];
    SPDFMacFriendsLifecycle* lifecycle = Lifecycle(probe, [SPDFMacFriendsSettingsState new], @"/h");
    [lifecycle launchWithSettings:@{@"friends" : @{@"enabled" : @NO}}];
    [lifecycle firstPaintDidHappen];
    [lifecycle setEnabled:YES];
    Expect(probe.attaches == 1 && probe.signedBeforeAttach && probe.signings == 1,
           @"turning Friends on attached without the signing policy");
}

static audit_token_t OwnAuditToken(void) {
    audit_token_t token = {};
    mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
    task_info(mach_task_self(), TASK_AUDIT_TOKEN, (task_info_t)&token, &count);
    return token;
}

// The policy the app hands the client library: set only with a Team ID, with the Security.framework verifier.
static void TestSigningPolicy(void) {
    __block NSInteger calls = 0;
    __block NSString* team = nil;
    __block SPDFMacFriendsPeerVerifier verifier = NULL;
    SPDFMacFriendsSetSigningPolicy record = ^int(const char* value, SPDFMacFriendsPeerVerifier check) {
        calls++;
        team = @(value);
        verifier = check;
        return 0;
    };
    Expect(!SPDFMacFriendsApplySigningPolicy(^NSString* { return nil; }, record) && calls == 0,
           @"an unsigned build must leave the library's default (uid check, SZFRIENDS_STATE_DIR honoured)");
    Expect(SPDFMacFriendsApplySigningPolicy(^NSString* { return @"ABCDE12345"; }, record) && calls == 1 &&
           [team isEqual:@"ABCDE12345"] && verifier == SPDFMacFriendsVerifyPeer,
           @"a signed build must pass its team and the Security verifier: %@", team);
    // The test binary is ad-hoc signed by the linker: no team, so a development build sets nothing.
    Expect(SPDFMacFriendsOwnTeamIdentifier() == nil, @"an ad-hoc build reported a team: %@",
           SPDFMacFriendsOwnTeamIdentifier());

    audit_token_t me = OwnAuditToken();
    const char* teamRequirement = "anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\"";
    Expect(SPDFMacFriendsVerifyPeer(NULL, &me, sizeof me, "always"),
           @"the verifier refused a process that meets its requirement");
    Expect(!SPDFMacFriendsVerifyPeer(NULL, &me, sizeof me, teamRequirement),
           @"an ad-hoc process passed as signed by the team");
    Expect(!SPDFMacFriendsVerifyPeer(NULL, &me, sizeof me - 4, "always") &&
           !SPDFMacFriendsVerifyPeer(NULL, NULL, sizeof me, "always") &&
           !SPDFMacFriendsVerifyPeer(NULL, &me, sizeof me, "") &&
           !SPDFMacFriendsVerifyPeer(NULL, &me, sizeof me, "not a requirement ("),
           @"a short token, no token or a malformed requirement must be refused");
    audit_token_t gone = me;
    gone.val[5] = 0x7ffffff0; // a pid no process has
    Expect(!SPDFMacFriendsVerifyPeer(NULL, &gone, sizeof gone, "always"), @"a token naming no process passed");
}

static void TestMissingHelperSpawnsNothing(void) {
    Probe* probe = [Probe new];
    SPDFMacFriendsLifecycle* lifecycle = Lifecycle(probe, [SPDFMacFriendsSettingsState new], nil);
    [lifecycle launchWithSettings:nil];
    SPDFMacFriendsTestRunUntil(1.0, ^BOOL { return probe.helperPathCalls == 1; });
    usleep(50 * 1000);
    Expect(probe.helperPathCalls == 1 && probe.spawns == 0, @"a build without an embedded helper tried to spawn");
}

static void TestToggling(void) {
    Probe* probe = [Probe new];
    SPDFMacFriendsSettingsState* state = [SPDFMacFriendsSettingsState new];
    SPDFMacFriendsLifecycle* lifecycle = Lifecycle(probe, state, @"/h");
    [lifecycle launchWithSettings:nil];
    [lifecycle firstPaintDidHappen];
    [lifecycle setEnabled:NO];
    Expect(probe.detaches == 1 && probe.lastDetachDisabling && !state.enabled,
           @"turning Friends off in this window must detach and send disable");
    Expect([[state settingsByAddingFriends:@{}][@"friends"][@"enabled"] isEqual:@NO],
           @"the choice must reach the settings.yaml dictionary the coordinator saves");
    [lifecycle setEnabled:YES];
    Expect(probe.attaches == 2 && lifecycle.attached, @"turning it back on must attach again");
    [lifecycle settingsDidChange:@{@"friends" : @{@"enabled" : @NO}}];
    Expect(probe.detaches == 2 && !probe.lastDetachDisabling,
           @"another window's disable must detach here without sending a second disable");

    // A window that is still disabled at launch and enabled later attaches only once it has painted.
    Probe* late = [Probe new];
    SPDFMacFriendsLifecycle* other = Lifecycle(late, [SPDFMacFriendsSettingsState new], @"/h");
    [other launchWithSettings:@{@"friends" : @{@"enabled" : @NO}}];
    [other settingsDidChange:@{@"friends" : @{@"enabled" : @YES}}];
    Expect(late.attaches == 0, @"attached before first paint after a settings change");
    [other firstPaintDidHappen];
    Expect(late.attaches == 1, @"did not attach at first paint after being enabled elsewhere");
}

static void TestHelperPath(void) {
    NSString* root = SPDFMacFriendsTestTemporaryDirectory(@"bundle");
    NSString* app = [root stringByAppendingPathComponent:@"ShenzhenPDF.app"];
    [NSFileManager.defaultManager createDirectoryAtPath:[app stringByAppendingPathComponent:@"Contents/MacOS"]
                            withIntermediateDirectories:YES attributes:nil error:nil];
    Expect(SPDFMacFriendsHelperExecutablePath([NSBundle bundleWithPath:app]) == nil,
           @"a bundle without the helper must report none");
    NSString* macos = [app stringByAppendingPathComponent:@"Contents/Helpers/Shenzhen Friends.app/Contents/MacOS"];
    [NSFileManager.defaultManager createDirectoryAtPath:macos withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* executable = [macos stringByAppendingPathComponent:@"Shenzhen Friends"];
    [[NSData dataWithBytes:"#!/bin/sh\n" length:10] writeToFile:executable atomically:YES];
    chmod(executable.fileSystemRepresentation, 0755);
    NSString* found = SPDFMacFriendsHelperExecutablePath([NSBundle bundleWithPath:app]);
    Expect([found.stringByResolvingSymlinksInPath isEqual:executable.stringByResolvingSymlinksInPath],
           @"helper path %@", found);
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
}

// The probes that run the whole reader (mac/tests/workspace-probe.mk) launch with Friends on by default, so after first
// paint they attach and the helper link would use the real Friends state. Each points SZFRIENDS_STATE_DIR at its own
// temporary root before the application object exists.
static void TestProbesUseTheirOwnFriendsState(void) {
    for (NSString* probe in @[@"mac/tests/SPDFMacWorkspaceProbe.mm", @"mac/tests/SPDFMacReadmeProbe.mm",
                              @"mac/tests/SPDFMacAIReadmeProbe.mm"]) {
        NSString* source = [NSString stringWithContentsOfFile:probe encoding:NSUTF8StringEncoding error:nil];
        NSRange state = [source rangeOfString:@"setenv(\"SZFRIENDS_STATE_DIR\",root.UTF8String,1);"];
        NSRange reader = [source rangeOfString:@"setenv(\"SPDF_STATE_DIR\",root.UTF8String,1);"];
        NSRange application = [source rangeOfString:@"[NSApplication sharedApplication];"];
        Expect(source && state.location != NSNotFound && reader.location != NSNotFound &&
               application.location != NSNotFound && state.location < application.location,
               @"%@ must set SZFRIENDS_STATE_DIR to its temporary root before the reader starts", probe);
    }
}

int main(void) {
    @autoreleasepool {
        TestProbesUseTheirOwnFriendsState();
        TestSettingsParsing();
        TestDisabledLaunchDoesNothing();
        TestEnabledLaunchSpawnsOffMainWithoutBlocking();
        TestMissingHelperSpawnsNothing();
        TestToggling();
        TestAttachWithoutLaunchSpawnSignsFirst();
        TestSigningPolicy();
        TestHelperPath();
    }
    puts("SPDFMacFriendsLaunchTests passed");
    return 0;
}
