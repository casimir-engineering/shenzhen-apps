// What must leave before the post-update helper swaps the bundle: the other instances of the app, and the Shenzhen
// Friends helper embedded in it (SPDFUpdaterProcesses.h).

#import "SPDFUpdaterProcesses.h"

#import <AppKit/AppKit.h>

#include <libproc.h>
#include <signal.h>
#include <unistd.h>

NSUInteger spdf_running_instance_count(NSString* bundleID) {
    NSUInteger count = 0;
    for (NSRunningApplication* app in [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID]) {
        if (app.processIdentifier != getpid()) ++count;
    }
    return count;
}

void spdf_helper_stop_embedded_friends(NSString* targetBundlePath) {
    NSString* executable = [targetBundlePath
        stringByAppendingPathComponent:@"Contents/Helpers/Shenzhen Friends.app/Contents/MacOS/Shenzhen Friends"];
    char wanted[PATH_MAX];
    if (!realpath(executable.fileSystemRepresentation, wanted)) return;
    int capacity = proc_listallpids(NULL, 0);
    if (capacity <= 0) return;
    NSMutableData* buffer = [NSMutableData dataWithLength:(NSUInteger)(capacity + 64) * sizeof(pid_t)];
    pid_t* pids = (pid_t*)buffer.mutableBytes;
    int count = proc_listallpids(pids, (int)buffer.length);
    NSMutableArray<NSNumber*>* asked = [NSMutableArray array];
    for (int i = 0; i < count; i++) {
        pid_t pid = pids[i];
        struct proc_bsdshortinfo info;
        char path[PROC_PIDPATHINFO_MAXSIZE];
        if (pid <= 1 || pid == getpid()) continue;
        if (proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, (int)sizeof info) != (int)sizeof info ||
            info.pbsi_uid != geteuid())
            continue;
        if (proc_pidpath(pid, path, sizeof path) <= 0 || strcmp(path, wanted) != 0) continue;
        if (kill(pid, SIGTERM) == 0) [asked addObject:@(pid)];
    }
    for (NSTimeInterval waited = 0; asked.count > 0 && waited < 5.0; waited += 0.1) {
        NSMutableArray<NSNumber*>* left = [NSMutableArray array];
        for (NSNumber* pid in asked) {
            if (kill(pid.intValue, 0) == 0) [left addObject:pid];
        }
        asked = left;
        if (asked.count > 0) [NSThread sleepForTimeInterval:0.1];
    }
}
