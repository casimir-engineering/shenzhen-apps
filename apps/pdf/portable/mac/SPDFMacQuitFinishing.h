#pragma once
#import "SPDFMacDelegatePrivate.h"

// Quitting hides first, then finishes (SPDFMacQuitFinishing.mm). Every change is already saved when it is made, so a
// quit never asks anything: the windows leave the screen at once, and the last writes, the activity flush, an image
// copy still being written and the cleanup run after that while the process keeps running, then it exits.

// Posted once, on the main thread, when a quitting process has finished its writes and is about to exit -- also when
// AppKit's own NSApplicationWillTerminateNotification will not be posted (the quick exit below). Observers flush.
FOUNDATION_EXPORT NSNotificationName const SPDFMacQuitWillExitNotification;

// After the first paint: work that must wait for the first frame but not be lost when the launch ends sooner.
void spdf_mac_launch_began(void);            // applicationDidFinishLaunching starts
void spdf_mac_after_first_paint(dispatch_block_t block);
void spdf_mac_first_paint_done(void); // runs the queued blocks; later blocks run on the next main-queue pass

@interface ShenzhenMacDelegate (SPDFMacQuitFinishing)
// Takes every window of this process off the screen and passes the focus on, as a finished quit would (once).
- (void)hideWindowsForQuit;
// Starts a quit: hides, and returns NO when this process is already quitting.
- (BOOL)beginQuit;
// applicationShouldTerminate's reply once the windows are hidden: writes, then exits (NSTerminateLater).
- (NSApplicationTerminateReply)finishQuitAfterHiding;
// The end of applicationWillTerminate: a Dock click or document open that arrived while finishing starts a new launch.
- (void)quitRelaunchIfRequested;
// Whether applicationWillTerminate's writes and cleanup already ran (they run once).
- (BOOL)quitClaimFinalWrites;
@end
