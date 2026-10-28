// Also loads one framework AppKit would otherwise load on the main thread during launch (below).
//
// The launch reads documents.yaml, bookmarks.yaml and session.yaml in loadPersistentState, on the main thread before
// the first frame. On a profile of 100 restored tabs they are 420, 430 and 120 KB and took about 7 ms to read and
// parse there. main() starts this prefetch before NSApplication exists (about 35 ms of AppKit start), so the parse is
// done by the time loadPersistentState asks. The stat check makes a file changed in between (another window's
// process saving) fall back to a fresh read, so the launch never restores older state than it would have read.
#import "SPDFMacStatePrefetch.h"
#import "SPDFMacStateDirectory.h"
#import "SPDFMacLifecycleSignposts.h"
#include <dlfcn.h>
#include <sys/stat.h>

id spdf_state_object_from_yaml_data(NSData* data); // ShenzhenPDFMac.mm

@interface SPDFMacPrefetchedState : NSObject
@property(nonatomic, strong) id object;
@property(nonatomic) struct stat info;
@end
@implementation SPDFMacPrefetchedState
@end

static dispatch_group_t gGroup;
static NSMutableDictionary<NSString*, SPDFMacPrefetchedState*>* gPrefetched;

static BOOL SameFile(const struct stat* a, const struct stat* b) {
    return a->st_ino == b->st_ino && a->st_dev == b->st_dev && a->st_size == b->st_size &&
           a->st_mtimespec.tv_sec == b->st_mtimespec.tv_sec && a->st_mtimespec.tv_nsec == b->st_mtimespec.tv_nsec;
}

void spdf_mac_prefetch_launch_state(void) {
    if (gGroup) return;
    SPDF_LIFECYCLE_BEGIN("Launch"); // ends after the first paint (spdf_mac_first_paint_done)
    // Setting the main menu makes AppKit add Writing Tools to the Edit menu, which loads WritingToolsUI on the main
    // thread before the first frame (about 4 ms of main-thread CPU, measured A/B on the 100-tab profile).
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        dlopen("/System/Library/PrivateFrameworks/WritingToolsUI.framework/WritingToolsUI", RTLD_LAZY | RTLD_LOCAL);
    });
    gGroup = dispatch_group_create();
    gPrefetched = [NSMutableDictionary dictionary];
    NSString* directory = SPDFMacStateDirectoryPath();
    for (NSString* name in @[ @"documents.yaml", @"bookmarks.yaml", @"session.yaml" ]) {
        NSString* path = [directory stringByAppendingPathComponent:name];
        dispatch_group_async(gGroup, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            @autoreleasepool {
                struct stat before, after;
                if (stat(path.fileSystemRepresentation, &before) != 0) return;
                NSData* data = [NSData dataWithContentsOfFile:path];
                // Written while being read: leave it to the main thread.
                if (!data || stat(path.fileSystemRepresentation, &after) != 0 || !SameFile(&before, &after)) return;
                SPDFMacPrefetchedState* state = [SPDFMacPrefetchedState new];
                state.object = spdf_state_object_from_yaml_data(data);
                state.info = after;
                if (!state.object) return;
                @synchronized(gPrefetched) { gPrefetched[path] = state; }
            }
        });
    }
}

id spdf_mac_take_prefetched_state(NSString* path) {
    if (!gGroup || !path.length) return nil;
    dispatch_group_wait(gGroup, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));
    SPDFMacPrefetchedState* state;
    @synchronized(gPrefetched) {
        state = gPrefetched[path];
        [gPrefetched removeObjectForKey:path];
    }
    struct stat now, then;
    if (!state) return nil;
    then = state.info;
    return stat(path.fileSystemRepresentation, &now) == 0 && SameFile(&now, &then) ? state.object : nil;
}
