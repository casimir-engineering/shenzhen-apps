// friends-ui-e2e's flow for Friends that does not start (SPDFMacFriendsUIE2E.h): the owner's report of 2026-11-01. A
// leftover helper of a test copy held the socket and never let ShenzhenPDF in, and the dropdown said "Starting
// Friends…" for good over an empty search field, a tab bar without labels and an empty list.
//
// Here the reader is a copy of the app with its own embedded helper (the run's helper under the shipped name), in a
// home of its own:
// 1. A helper of another copy holds the socket and is frozen (SIGSTOP): it takes connections and never answers. The
//    dropdown shows that Friends is starting and nothing else, then the reader ends that helper, starts its own and
//    shows the list, before it would say that Friends did not start.
// 2. A listener nothing may end (this process's own) holds the socket. The dropdown says "Friends couldn’t start."
//    with Try Again, and once the listener is gone, Try Again brings the list.

#import "SPDFMacFriendsUIE2E.h"

#import "mac/SZFriendsListPage.h"
#include "client/szfriends_client.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

static NSString* const UIStarting = @"Starting Friends";
static NSString* const UIDidNotStart = @"Friends couldn’t start.";
static NSString* const UITryAgain = @"Try Again";

// <folder>/<name>.app with the run's helper inside it where ShenzhenPDF embeds its own.
static NSString* UIAppCopy(NSString* folder, NSString* name) {
    NSString* app = [folder stringByAppendingPathComponent:[name stringByAppendingString:@".app"]];
    NSString* macos = [app stringByAppendingPathComponent:@"Contents/Helpers/Shenzhen Friends.app/Contents/MacOS"];
    NSFileManager* files = NSFileManager.defaultManager;
    [files createDirectoryAtPath:macos withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* helper = [macos stringByAppendingPathComponent:@"Shenzhen Friends"];
    if (![files fileExistsAtPath:helper]) [files copyItemAtPath:UIHelperExecutable toPath:helper error:nil];
    return app;
}

static NSString* UIEmbeddedHelper(NSString* app) {
    return [app stringByAppendingPathComponent:@"Contents/Helpers/Shenzhen Friends.app/Contents/MacOS/Shenzhen Friends"];
}

// What a helper the reader starts needs to find in its environment, as the harness gives its own helpers: it
// inherits this process's. Returns what was there before, for UIRestoreEnvironment.
static NSDictionary* UISetHelperEnvironment(SZFE2EWorld* world, NSString* name) {
    SZFE2EHelper* model = [world helperNamed:name];
    NSMutableDictionary* values = [[model valueForKey:@"baseEnvironment"] mutableCopy];
    [values addEntriesFromDictionary:UIDeviceEnvironment(name)];
    values[@"HOME"] = [model.stateDirectory stringByAppendingString:@"-home"];
    [values removeObjectsForKeys:@[ @"PATH", @"TMPDIR" ]];
    NSMutableDictionary* previous = [NSMutableDictionary dictionary];
    for (NSString* key in values) {
        const char* old = getenv(key.UTF8String);
        previous[key] = old ? @(old) : (id)NSNull.null;
        setenv(key.UTF8String, [values[key] UTF8String], 1);
    }
    return previous;
}

static void UIRestoreEnvironment(NSDictionary* previous) {
    for (NSString* key in previous) {
        if (previous[key] == NSNull.null) unsetenv(key.UTF8String);
        else setenv(key.UTF8String, [previous[key] UTF8String], 1);
    }
}

static BOOL UISocketPath(NSString* state, char* path, size_t size) {
    return szfriends_socket_path(state.fileSystemRepresentation, path, size, NULL) == SZFRIENDS_OK;
}

// The process listening on `state`'s socket, or 0.
static pid_t UIListenerOf(NSString* state) {
    char path[1024];
    struct sockaddr_un address = {};
    if (!UISocketPath(state, path, sizeof path) || strlen(path) >= sizeof address.sun_path) return 0;
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, path, sizeof address.sun_path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    pid_t pid = 0;
    socklen_t length = sizeof pid;
    if (fd >= 0 && connect(fd, (struct sockaddr*)&address, sizeof address) == 0)
        getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length);
    if (fd >= 0) close(fd);
    return pid;
}

// Ends the helper the reader started (`pid`, found on the socket before UIStopRig removes the socket's folder), as
// quitting the app's last window would; never this process. Gone, not only off the socket: nothing of the run may
// outlive it.
static void UIEndStartedHelper(pid_t pid) {
    if (pid <= 1 || pid == getpid()) return;
    kill(pid, SIGTERM);
    if (!UIWait(8, ^BOOL { return kill(pid, 0) != 0; })) kill(pid, SIGKILL);
}

static BOOL UIListShows(UIRig* rig) {
    SZFriendsListPage* page = rig.listPage;
    return rig.link.state == SZFriendsLinkStateReady && UIVisible(page.searchField) && page.friendsTab.title.length &&
           UIVisible(page.friendsTab) && !UIFindText(rig.content, UIStarting);
}

// Nothing but the start: no search field, no tabs, no list.
static BOOL UIOnlyStarting(UIRig* rig) {
    return UIFindText(rig.content, UIStarting) && !UIVisible(rig.listPage.searchField) &&
           !UIVisible(rig.listPage.friendsTab) && !UIVisible(rig.listPage.scrollView);
}

static BOOL UIFrozenHelperOfAnotherCopy(UIRig* rig, SZFE2EHelper* stray) {
    UIBeginFlow(rig, @"starting");
    EXPECT(rig, UIOpenDropdown(rig), "the dropdown opens");
    UISpin(0.5);
    UIShot(rig, @"starting");
    EXPECT(rig, UIOnlyStarting(rig), "only says Friends is starting:\n%@", UIDescribe(rig.content));
    // The reader ends the frozen helper and starts its own well before it would give up (15 s).
    BOOL recovered = UIWait(13, ^BOOL { return UIListShows(rig); });
    UISpin(0.5);
    UIShot(rig, recovered ? @"recovered" : @"still-starting");
    EXPECT(rig, recovered, "the list shows within 13 s:\n%@", UIDescribe(rig.content));
    EXPECT(rig, UIWait(3, ^BOOL { return !stray.isRunning; }), "the frozen helper of the other copy is gone");
    return YES;
}

// This process listens on `state`'s socket and holds its lock: a helper that takes connections, never answers, and
// that the reader may never end (it is the reader's own process).
static BOOL UISquat(NSString* state, int* listener, int* lock) {
    char path[1024];
    struct sockaddr_un address = {};
    *listener = *lock = -1;
    mkdir(state.fileSystemRepresentation, 0700);
    if (!UISocketPath(state, path, sizeof path) || strlen(path) >= sizeof address.sun_path) return NO;
    mkdir([@(path) stringByDeletingLastPathComponent].fileSystemRepresentation, 0700);
    *lock = open([state stringByAppendingPathComponent:@"helper.lock"].fileSystemRepresentation,
                 O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (*lock < 0 || flock(*lock, LOCK_EX | LOCK_NB) != 0) return NO;
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, path, sizeof address.sun_path);
    unlink(path);
    *listener = socket(AF_UNIX, SOCK_STREAM, 0);
    return *listener >= 0 && bind(*listener, (struct sockaddr*)&address, sizeof address) == 0 && listen(*listener, 64) == 0;
}

static void UIStopSquatting(NSString* state, int listener, int lock) {
    char path[1024];
    if (listener >= 0) close(listener);
    if (UISocketPath(state, path, sizeof path)) unlink(path);
    if (lock >= 0) close(lock);
}

static BOOL UINothingCanEnd(UIRig* rig, NSString* state, int* listener, int* lock) {
    UIBeginFlow(rig, @"couldnt-start");
    EXPECT(rig, UIOpenDropdown(rig), "the dropdown opens");
    UISpin(0.5);
    UIShot(rig, @"starting");
    EXPECT(rig, UIOnlyStarting(rig), "only says Friends is starting:\n%@", UIDescribe(rig.content));
    BOOL said = UIWait(20, ^BOOL { return UIFindText(rig.content, UIDidNotStart) != nil; });
    UISpin(0.3);
    UIShot(rig, said ? @"did-not-start" : @"still-starting");
    EXPECT(rig, said, "says Friends couldn’t start within 20 s:\n%@", UIDescribe(rig.content));
    NSButton* again = UIFindButton(rig.content, UITryAgain);
    EXPECT(rig, again, "Try Again is offered:\n%@", UIDescribe(rig.content));
    EXPECT(rig, !UIVisible(rig.listPage.searchField) && !UIVisible(rig.listPage.friendsTab),
           "no search field or tabs beside it:\n%@", UIDescribe(rig.content));
    // Whatever held the socket goes away; Try Again starts the reader's own helper at once.
    UIStopSquatting(state, *listener, *lock);
    *listener = *lock = -1;
    NSString* why = nil;
    EXPECT(rig, UIClick(again, &why), "Try Again takes the click: %@", why);
    BOOL shown = UIWait(10, ^BOOL { return UIListShows(rig); });
    UISpin(0.5);
    UIShot(rig, @"after-try-again");
    EXPECT(rig, shown, "the list shows after Try Again:\n%@", UIDescribe(rig.content));
    return YES;
}

BOOL UIFlowStarting(SZFE2EWorld* world, UIVariant* variant) {
    [world beginScenario:[@"starting-" stringByAppendingString:variant.name]];
    NSString* folder = [world.scenarioDirectory stringByAppendingPathComponent:@"apps"];
    NSString* app = UIAppCopy(folder, @"ShenzhenPDF Test");
    int failuresBefore = UIFailures;
    BOOL passed = NO;

    // 1. A frozen helper of another copy on the socket.
    NSDictionary* previous = UISetHelperEnvironment(world, @"ana");
    SZFE2EHelper* stray = [world helperNamed:@"ana"];
    [stray setValue:UIEmbeddedHelper(UIAppCopy(folder, @"Other Copy")) forKey:@"executable"];
    NSMutableDictionary* strayEnvironment = [UIDeviceEnvironment(@"ana") mutableCopy];
    strayEnvironment[@"HOME"] = [stray.stateDirectory stringByAppendingString:@"-home"];
    stray.extraEnvironment = strayEnvironment;
    SZFE2EClient* probe = [stray start] ? [SZFE2EClient clientForHelper:stray] : nil;
    [probe close];
    UIRig* rig = nil;
    if (probe && kill(stray.pid, SIGSTOP) == 0) rig = UIStartRigInApp(world, variant, @"ana", nil, app);
    if (rig) {
        passed = UIFrozenHelperOfAnotherCopy(rig, stray);
        pid_t started = UIListenerOf(rig.helper.stateDirectory);
        UIStopRig(rig);
        UIEndStartedHelper(started);
    } else {
        UIFail(nil, __FILE__, __LINE__, "the other copy's helper starts and freezes", stray.log);
    }
    [stray kill9];
    UIRestoreEnvironment(previous);

    // 2. A listener nothing may end.
    if (passed) {
        previous = UISetHelperEnvironment(world, @"bo");
        NSString* state = [world helperNamed:@"bo"].stateDirectory;
        int listener = -1, lock = -1;
        passed = NO;
        rig = nil;
        if (UISquat(state, &listener, &lock)) rig = UIStartRigInApp(world, variant, @"bo", nil, app);
        else UIFail(nil, __FILE__, __LINE__, "this process holds Bo's socket", @(strerror(errno)));
        pid_t started = 0;
        if (rig && listener >= 0) {
            passed = UINothingCanEnd(rig, state, &listener, &lock);
            started = UIListenerOf(state);
            UIStopRig(rig);
        }
        UIStopSquatting(state, listener, lock);
        UIEndStartedHelper(started);
        UIRestoreEnvironment(previous);
    }

    passed = passed && UIFailures == failuresBefore;
    UIRecord(variant, @"Friends that does not start: a frozen helper is replaced, else Try Again", passed);
    if (!passed) [world printLogs];
    [world endScenario];
    return passed;
}
