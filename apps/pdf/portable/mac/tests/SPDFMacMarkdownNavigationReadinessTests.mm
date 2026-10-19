#import "../SPDFMacMarkdownSession.h"
#import "../markdown/SPDFMarkdown.h"
#include <assert.h>

static BOOL spin(BOOL (^condition)(void)) {
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!condition() && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return condition();
}
static void activate(SPDFMacMarkdownSession* session, NSView* host, dispatch_queue_t queue) {
    [session activateInHostView:host workQueue:queue scrollOrigin:NSZeroPoint selectedRange:NSMakeRange(0, 0)
        pageIndex:0 zoom:1 fitMode:SPDFMacMarkdownPageFitPage anchor:nil completion:^(BOOL success, NSError* error) {
            assert(success && !error);
            // The state can already be Ready, but the viewport restore is queued.
            assert(session.state == SPDFMacMarkdownSessionReady && !session.isNavigationReady);
        }];
}
int main(void) {
    @autoreleasepool {
        (void)NSApplication.sharedApplication;
        NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"md"]];
        NSString* source = @"# First\n\nOne.\n\n<!-- pagebreak -->\n\n# Second\n\nTwo.\n";
        assert([source writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        SPDFMacMarkdownSession* session = [[SPDFMacMarkdownSession alloc] initWithDocumentURL:[NSURL fileURLWithPath:path]];
        NSView* host = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)];
        dispatch_queue_t queue = dispatch_queue_create("markdown.navigation.ready.test", DISPATCH_QUEUE_SERIAL);
        assert(!session.isNavigationReady);
        activate(session, host, queue);
        assert(!session.isNavigationReady);
        assert(spin(^BOOL { return session.isNavigationReady; }));
        [session deactivate];
        assert(!session.isNavigationReady);
        // Cached activation is synchronous until its queued viewport restore.
        activate(session, host, queue);
        assert(!session.isNavigationReady);
        assert(spin(^BOOL { return session.isNavigationReady; }));
        [session goToPageAtIndex:1];
        assert(session.currentPageIndex == 1);
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        assert(session.currentPageIndex == 1);
        dispatch_suspend(queue);
        [session applyFontScale:1.25];
        assert(session.state == SPDFMacMarkdownSessionReady && !session.isNavigationReady);
        [session cancelAllOperations];
        assert(!session.isNavigationReady); // stale preferences require the self-heal rerender
        dispatch_resume(queue);
        assert(spin(^BOOL { return session.isNavigationReady; }));
        dispatch_suspend(queue);
        [session reloadFromDiskWithStatus:nil];
        assert(!session.isNavigationReady);
        dispatch_resume(queue);
        assert(spin(^BOOL { return session.isNavigationReady; }));
        // A failed source reload keeps the usable old document, and does not
        // leave readiness stuck behind a work flag whose callback was dropped.
        assert([@"---\npaper-size: Invalid\n---\nBroken.\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        [session reloadFromDiskWithStatus:nil];
        assert(!session.isNavigationReady);
        assert(spin(^BOOL { return session.isNavigationReady; }));
        assert([session.renderedDocument.attributedString.string containsString:@"Two."]);
        [session deactivate];
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        puts("SPDFMacMarkdownNavigationReadinessTests passed");
    }
}
