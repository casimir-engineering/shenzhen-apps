// friends-ui-e2e's flows for one person (SPDFMacFriendsUIE2E.h): the Nearby permission cards and Settings' Allow, with
// the radio's states simulated by a script file the helper reads.

#import "SPDFMacFriendsUIFlowsInternal.h"

#import "mac/SZFriendsListPage.h"
#import "mac/SZFriendsSettingsSection.h"

// Visible buttons titled `title` under `root`: one card, one button (the Nearby cards).
static NSUInteger UICountButtons(NSView* root, NSString* title) {
    NSUInteger count = 0;
    for (NSView* view in UIAllViews(root))
        if ([view isKindOfClass:NSButton.class] && [((NSButton*)view).title isEqualToString:title] && UIVisible(view))
            count++;
    return count;
}

#pragma mark - Nearby permission cards (simulated states)

static BOOL UIWriteState(NSString* path, NSString* word) {
    return [word writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static NSUInteger UIStarts(NSString* path) {
    NSString* text = [NSString stringWithContentsOfFile:[path stringByAppendingString:@".starts"]
                                               encoding:NSUTF8StringEncoding error:nil];
    return text.length ? [text componentsSeparatedByString:@"start"].count - 1 : 0;
}

static BOOL UIPermissionCards(UIRig* rig, NSString* script) {
    UIBeginFlow(rig, @"permission");
    // Never asked, and Friends never opened: nothing has started, and Settings offers Allow.
    SZFriendsSettingsSection* section = [[SZFriendsSettingsSection alloc] initWithHost:rig.host link:rig.link];
    NSWindow* settings = UISettingsWindow(rig, section);
    NSView* view = section.view;
    EXPECT(rig, UIWait(5, ^BOOL { return UIFindText(view, @"to find people nearby") != nil; }),
           "Settings says Nearby waits to be allowed:\n%@", UIDescribe(view));
    NSButton* allow = UIFindButton(view, @"Allow");
    EXPECT(rig, allow && allow.enabled, "with Allow");
    EXPECT(rig, UIStarts(script) == 0, "nothing started before the person allowed it");
    UIShotWindow(rig, settings, @"settings-not-asked");
    CLICK(rig, allow, @"Allow");
    EXPECT(rig, UIWait(5, ^BOOL { return UIStarts(script) == 1; }), "Allow starts Nearby (%lu starts)",
           (unsigned long)UIStarts(script));
    EXPECT(rig, UIWait(5, ^BOOL { return !UIFindButton(view, @"Allow"); }), "Allow goes once it has started");
    UIWriteState(script, @"working");
    UISpin(0.5);
    UIShotWindow(rig, settings, @"settings-allowed");
    [section sectionDidDisappear];
    [settings orderOut:nil];
    [settings close];

    EXPECT(rig, UIOpenDropdown(rig), "the dropdown opens");
    SZFriendsListPage* list = rig.listPage;
    CLICK(rig, list.nearbyTab, @"the Nearby tab");
    EXPECT(rig, UIWait(5, ^BOOL {
               return UIReveal(rig.content, @"Looking for people nearby") || UIReveal(rig.content, @"Nobody visible");
           }), "allowed, Nearby looks:\n%@", UIDescribe(rig.content));
    UIShot(rig, @"working");
    // Local Network off: the card says so and opens Privacy settings (recorded, never opened).
    UIWriteState(script, @"denied");
    EXPECT(rig, UIWait(5, ^BOOL { return UIFindButton(rig.content, @"Open Privacy Settings") != nil; }),
           "Local Network off shows the way to turn it on");
    EXPECT(rig, UIReveal(rig.content, @"can’t find people on your network"), "and says what is wrong");
    // One card, one button, nothing under it saying more or the opposite (the owner's report of 2026-10-20: two
    // Open Privacy Settings, "Bluetooth isn't working either" and "Nearby isn't working right now" under the card).
    EXPECT(rig, UICountButtons(rig.content, @"Open Privacy Settings") == 1, "one Open Privacy Settings, not %lu",
           (unsigned long)UICountButtons(rig.content, @"Open Privacy Settings"));
    EXPECT(rig, UICountButtons(rig.content, @"Try Again") == 0 && !UIReveal(rig.content, @"either") &&
                    !UIReveal(rig.content, @"isn’t working right now") && !UIReveal(rig.content, @"People nearby") &&
                    !UIReveal(rig.content, @"to be visible to people nearby"),
           "nothing under the card:\n%@", UIDescribe(rig.content));
    UIShot(rig, @"denied");
    CLICK(rig, UIFindButton(rig.content, @"Open Privacy Settings"), @"Open Privacy Settings");
    EXPECT(rig, UIWait(3, ^BOOL { return rig.openedURLs.count > 0; }) &&
                    [rig.openedURLs.lastObject.absoluteString containsString:@"Privacy"],
           "the button opens Privacy & Security: %@", rig.openedURLs);
    // Wi-Fi off.
    UIWriteState(script, @"radio_off");
    EXPECT(rig, UIWait(5, ^BOOL { return UIFindButton(rig.content, @"Open Wi-Fi Settings") != nil; }),
           "Wi-Fi off offers Wi-Fi settings");
    EXPECT(rig, UIReveal(rig.content, @"Wi-Fi is off"), "and says Wi-Fi is off");
    EXPECT(rig, UICountButtons(rig.content, @"Open Wi-Fi Settings") == 1 &&
                    UICountButtons(rig.content, @"Open Privacy Settings") == 0 &&
                    UICountButtons(rig.content, @"Try Again") == 0 && !UIReveal(rig.content, @"People nearby"),
           "one card, one button:\n%@", UIDescribe(rig.content));
    UIShot(rig, @"radio-off");
    // Not working: Try Again starts it again.
    UIWriteState(script, @"unavailable");
    __block NSView* card = nil;
    EXPECT(rig, UIWait(5, ^BOOL {
               NSView* title = UIReveal(rig.content, @"can’t find people on your network right now");
               card = title.superview;
               return card && UIFindButton(card, @"Try Again") != nil;
           }), "a failing Nearby says so, with Try Again");
    EXPECT(rig, UICountButtons(rig.content, @"Try Again") == 1 && !UIReveal(rig.content, @"either") &&
                    !UIReveal(rig.content, @"People nearby can’t see you") && !UIReveal(rig.content, @"People nearby"),
           "one Try Again, nothing under the card:\n%@", UIDescribe(rig.content));
    UIShot(rig, @"unavailable");
    NSUInteger starts = UIStarts(script);
    NSButton* again = UIFindButton(card, @"Try Again");
    CLICK(rig, again, @"Try Again");
    EXPECT(rig, UIWait(5, ^BOOL { return UIStarts(script) > starts; }), "Try Again starts Nearby again");
    UIWriteState(script, @"working");
    EXPECT(rig, UIWait(5, ^BOOL { return !UIReveal(rig.content, @"can’t find people on your network"); }),
           "working again, the card goes");
    UIShot(rig, @"working-again");
    return YES;
}

BOOL UIFlowPermission(SZFE2EWorld* world, UIVariant* variant) {
    [world beginScenario:[@"permission-" stringByAppendingString:variant.name]];
    NSString* script = [world.scenarioDirectory stringByAppendingPathComponent:@"nearby-state"];
    UIWriteState(script, @"not_asked");
    // No loopback method: the scripted one alone, so its state is Nearby's whole story.
    UIRig* rig = UIStartRig(world, variant, @"perm",
                            @{@"SZFRIENDS_E2E_NEARBY_SCRIPT" : script, @"SZFRIENDS_TEST_SERVICE_TYPE" : @""});
    BOOL passed = NO;
    if (rig) {
        int failuresBefore = UIFailures;
        passed = UIPermissionCards(rig, script) && UIFailures == failuresBefore;
        if (!passed) [world printLogs];
        UIStopRig(rig);
    }
    UIRecord(variant, @"Allow and the Nearby permission cards", passed);
    [world endScenario];
    return passed;
}
