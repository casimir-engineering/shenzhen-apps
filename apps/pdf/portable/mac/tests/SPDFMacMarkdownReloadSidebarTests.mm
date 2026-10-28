// A Markdown file that changes on disk is reread in place, and the chapter list
// must follow it. Production-linked: the real coordinator opens the file and
// reloads it the way the file watcher does; nothing is displayed and no state
// outside a temp dir is touched.
//
// The failure it guards (2026-10-28): a file that grew from 5 to 7 headings was
// reread in place, the footer read "Markdown headings · 7 chapters" (it asks the
// session's live sidebar model) but the list still showed the first 5 (its rows
// are copies taken from the model the session had replaced). Only a full reopen
// showed all 7.
#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacMarkdownSession.h"
#import "SPDFMacMarkdownSidebarModel.h"
#import "SPDFMacSidebarChapters.h"
#import "SPDFMacTabGroupIntegration.h"
#import "SPDFUpdater.h"
#import <objc/runtime.h>
#undef main

static NSUInteger failures;
static void Check(BOOL ok, NSString* what) {
    if (ok) return;
    failures++;
    fprintf(stderr, "FAIL: %s\n", what.UTF8String);
}

// The reader under test never reaches the screen.
static IMP gOriginalOrder;
static void RefuseOrder(id window, SEL sel, NSInteger place, NSInteger other) {
    if (place == NSWindowOut) ((void (*)(id, SEL, NSInteger, NSInteger))gOriginalOrder)(window, sel, place, other);
}
static void Inert(id self, SEL _cmd) { (void)self; (void)_cmd; }

@interface ShenzhenMacDelegate (ReloadSidebarAccess)
- (SPDFDocumentTab*)newTabForPath:(NSString*)path;
- (void)applicationDidFinishLaunching:(NSNotification*)notification;
@end

@interface ReloadSidebarReader : ShenzhenMacDelegate
@end

@implementation ReloadSidebarReader
// Launch side effects unrelated to the sidebar.
- (void)showUnifiedSettingsAfterFirstPaint {}
- (void)showUnifiedSettings:(id)sender { (void)sender; }
- (void)installWindowArrangementShortcutMonitor {}
- (void)spawnPendingRestoredWindowsIfNeeded {}
- (void)resumePersistentStateSavesAfterLaunch {}
- (void)collectionDidOpenPath:(NSString*)path { (void)path; }
- (void)aiDocumentDidOpen:(NSString*)path { (void)path; }

- (NSArray<NSString*>*)chapterRowTitles {
    NSMutableArray* titles = [NSMutableArray array];
    for (NSDictionary* item in _sidebarItems)
        if ([item[@"kind"] isEqual:@"chapter"]) [titles addObject:item[@"title"] ?: @""];
    return titles;
}
@end

static BOOL RunUntil(NSTimeInterval timeout, BOOL (^done)(void)) {
    NSDate* until = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!done()) {
        if (until.timeIntervalSinceNow <= 0) return NO;
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    return YES;
}

static NSString* Notes(NSArray<NSString*>* headings) {
    NSMutableString* text = [NSMutableString string];
    for (NSString* heading in headings) [text appendFormat:@"%@\n\nA paragraph under it.\n\n", heading];
    return text;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSString* state = [root stringByAppendingPathComponent:@"state"];
        [NSFileManager.defaultManager createDirectoryAtPath:state withIntermediateDirectories:YES attributes:nil
                                                      error:nil];
        setenv("SPDF_STATE_DIR", state.fileSystemRepresentation, 1);
        setenv("SPDF_NO_ACTIVATE", "1", 1);
        setenv("SPDF_NO_WINDOW_FIRST", "1", 1);
        setenv("SPDF_DISABLE_LAUNCH_PRERENDER", "1", 1);
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        gOriginalOrder = method_setImplementation(
            class_getInstanceMethod(NSWindow.class, @selector(orderWindow:relativeTo:)), (IMP)RefuseOrder);
        for (NSString* name in @[ @"consumePendingUpdateMarkerAndSweep", @"scheduleDailyUpdateCheckIfNeeded",
                                  @"armRecurringUpdateCheck" ]) {
            Method method = class_getInstanceMethod(SPDFUpdater.class, NSSelectorFromString(name));
            if (method) method_setImplementation(method, (IMP)Inert);
        }

        // The headings of the file the owner saw it on.
        NSArray* before = @[ @"# Camera flex bring-up notes", @"## Getting Started!", @"## Wiring", @"## Power rails",
                             @"## Usage" ];
        NSArray* after = [before arrayByAddingObjectsFromArray:@[ @"## FAQ", @"## Usage" ]];
        NSString* path = [root stringByAppendingPathComponent:@"notes.md"];
        [Notes(before) writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];

        ReloadSidebarReader* reader = [ReloadSidebarReader new];
        [reader applicationDidFinishLaunching:[NSNotification notificationWithName:@"ReloadSidebarTests" object:nil]];
        [reader selectTabAtIndex:[reader appendNewTabToActiveGroup:[reader newTabForPath:path]]];
        Check(RunUntil(10.0, ^{ return (BOOL)(reader.chapterRowTitles.count == 5); }),
              [NSString stringWithFormat:@"opened file lists its 5 headings (rows: %@)", reader.chapterRowTitles]);

        // What the file watcher does when the editor saves.
        [Notes(after) writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        SPDFMacMarkdownSession* session = reader.activeMarkdownSession;
        [reader reloadSelectedTabFromDiskChange];
        Check(RunUntil(10.0, ^{ return (BOOL)(session.sidebarModel.chapterItems.count == 7); }),
              @"the session rereads the file in place");
        Check(reader.activeMarkdownSession == session, @"the reload kept the session (in place, not a reopen)");
        BOOL listed = RunUntil(5.0, ^{ return (BOOL)(reader.chapterRowTitles.count == 7); });
        Check(listed, [NSString stringWithFormat:@"the chapter list shows the 7 headings the footer counts (rows: %@)",
                                                 reader.chapterRowTitles]);
        Check([reader.sidebarOutlineSummary hasSuffix:@"7 chapters"], reader.sidebarOutlineSummary);
        Check([reader.chapterRowTitles containsObject:@"FAQ"], @"the added FAQ heading is listed");

        [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    }
    if (failures) return 1;
    puts("SPDFMacMarkdownReloadSidebarTests passed");
    return 0;
}
