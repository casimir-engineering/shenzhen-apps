// Opening without taking the focus (SPDFMacBackgroundOpening.h).
#import "SPDFMacBackgroundOpening.h"
#import "SPDFMacSupport.h"

#include <stdlib.h>

// Read once, at the first window, and taken out of the environment then: restored sibling windows spawned earlier in
// the launch inherit it and open behind too, but a tab detached hours later must not.
static BOOL BackgroundLaunch(void) {
    static BOOL background, read;
    if (!read) {
        read = YES;
        const char* value = getenv("SPDF_BACKGROUND_LAUNCH");
        background = value && value[0] == '1';
        unsetenv("SPDF_BACKGROUND_LAUNCH");
    }
    return background;
}

static void RequestActivation(void) {
    if (@available(macOS 14.0, *)) [NSApp activate];
    else [NSApp activateIgnoringOtherApps:YES];
}

static void OrderFront(NSWindow* window) {
    [window orderFrontRegardless];
    [window makeKeyAndOrderFront:nil];
    [window makeMainWindow];
}

void spdf_mac_show_window_in_background(NSWindow* window) {
    if (!window || window.visible || window.miniaturized) return;
    [window orderBack:nil];
}

void spdf_mac_order_launch_window(NSWindow* window) {
    if (BackgroundLaunch()) spdf_mac_show_window_in_background(window);
    else [window makeKeyAndOrderFront:nil];
}

void spdf_mac_show_launch_window(NSWindow* window, BOOL activate) {
    if (BackgroundLaunch()) {
        spdf_mac_show_window_in_background(window);
        return;
    }
    [window makeKeyAndOrderFront:nil];
    if (activate && !spdf_launch_activation_suppressed()) RequestActivation();
}

void spdf_mac_bring_window_to_front(NSWindow* window) {
    if (!window) return;
    [NSApp activateIgnoringOtherApps:YES];
    OrderFront(window);
}

void spdf_mac_show_window_for_external_open(NSWindow* window) {
    if (!window) return;
    if (NSApp.isActive) {
        OrderFront(window);
        return;
    }
    if (@available(macOS 14.0, *)) {
        // Granted or not is known only when the app becomes active, if it does: the window follows it forward
        // then. Until that, a window that was not on screen waits behind the others rather than nowhere.
        spdf_mac_show_window_in_background(window);
        __block id observer = [NSNotificationCenter.defaultCenter
            addObserverForName:NSApplicationDidBecomeActiveNotification object:NSApp queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification* note) {
                      (void)note;
                      [NSNotificationCenter.defaultCenter removeObserver:observer];
                      observer = nil;
                      OrderFront(window);
                    }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
          if (observer) [NSNotificationCenter.defaultCenter removeObserver:observer];
          observer = nil;
        });
        [NSApp activate];
        return;
    }
    [NSApp activateIgnoringOtherApps:YES];
    OrderFront(window);
}
