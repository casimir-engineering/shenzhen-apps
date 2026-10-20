// friends-ui-e2e's flows for one person (SPDFMacFriendsUIE2E.h): Settings with Reset Friends, and the name saved by
// another client of the same helper.

#import "SPDFMacFriendsUIFlowsInternal.h"

#import "mac/SZFriendsListPage.h"
#import "mac/SZFriendsSettingsSection.h"

#pragma mark - Settings, Reset Friends

// Settings in a window of its own, as the reader's Settings shows the section; the caller closes it.
NSWindow* UISettingsWindow(UIRig* rig, SZFriendsSettingsSection* section) {
    section.context.openURL = ^(NSURL* url) { [rig.openedURLs addObject:url]; };
    section.context.pasteboard = [NSPasteboard pasteboardWithUniqueName];
    NSWindow* settings = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 640)
                                                     styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                       backing:NSBackingStoreBuffered defer:NO];
    settings.releasedWhenClosed = NO;
    settings.title = @"Settings";
    settings.appearance = [NSAppearance appearanceNamed:rig.variant.appearance];
    NSView* view = section.view;
    view.frame = NSMakeRect(20, 20, 520, 600);
    [settings.contentView addSubview:view];
    [settings setFrameTopLeftPoint:NSMakePoint(NSMaxX(rig.window.frame) - 600, NSMaxY(rig.window.frame))];
    [settings orderFrontRegardless];
    [section sectionWillAppear];
    return settings;
}

// The sheet once it is up and still (the same frame for a few turns in a row) and a person has had a moment to read
// it. A press on "Reset Friends" within a tenth of a second of the sheet appearing was dropped about one try in
// twelve, and the same press repeated a second later went through; 0.6 s after the sheet appeared, 20 tries of 20
// went through. A person never clicks that fast, so the harness waits as they would.
static NSWindow* UISheet(NSWindow* window) {
    __block NSWindow* sheet = nil;
    if (!UIWait(5, ^BOOL { return (sheet = window.attachedSheet) != nil && sheet.isVisible; })) return nil;
    __block NSRect last = NSZeroRect;
    __block int steady = 0;
    UIWait(5, ^BOOL {
        NSRect frame = sheet.frame;
        steady = NSEqualRects(frame, last) ? steady + 1 : 0;
        last = frame;
        return steady >= 3;
    });
    UISpin(0.6);
    return sheet;
}

BOOL UISettingsAndReset(UIRig* rig) {
    UIBeginFlow(rig, @"settings-reset");
    UICloseDropdown(rig);
    NSString* idBefore = [UIFooter(rig)[@"friends_id"] description];
    SZFriendsSettingsSection* section = [[SZFriendsSettingsSection alloc] initWithHost:rig.host link:rig.link];
    NSWindow* settings = UISettingsWindow(rig, section);
    NSView* view = section.view;
    EXPECT(rig, UIWait(5, ^BOOL { return UIFindButton(view, @"Reset Friends…") != nil; }),
           "Settings shows Reset Friends…:\n%@", UIDescribe(view));
    NSString* name = UISavedName(rig);
    EXPECT(rig, name && [section.nameField.stringValue isEqualToString:name], "Settings shows the name %@: %@", name,
           section.nameField.stringValue);
    UIShotWindow(rig, settings, @"settings");
    // Cancel: the sheet goes and nothing changes.
    CLICK(rig, UIFindButton(view, @"Reset Friends…"), @"Reset Friends…");
    NSWindow* sheet = UISheet(settings);
    EXPECT(rig, sheet && UIFindText(sheet.contentView, @"Reset Friends?"), "the confirmation sheet asks");
    UIShotWindow(rig, sheet, @"confirm");
    CLICK(rig, UIFindButton(sheet.contentView, @"Cancel"), @"Cancel");
    EXPECT(rig, UIWait(5, ^BOOL { return settings.attachedSheet == nil; }), "Cancel closes the sheet");
    UISpin(0.3);
    EXPECT(rig, [[UIFooter(rig)[@"friends_id"] description] isEqualToString:idBefore] &&
                    [UISavedName(rig) isEqualToString:name],
           "Cancel changes nothing: %@", UIFooter(rig));
    // Confirm: a new ID, no name, and the dropdown asks for a name again.
    CLICK(rig, UIFindButton(view, @"Reset Friends…"), @"Reset Friends…");
    sheet = UISheet(settings);
    EXPECT(rig, sheet != nil, "the sheet again");
    NSInteger before = UISnapshotCount(rig, @"list");
    UIShotWindow(rig, sheet, @"confirm-again");
    CLICK(rig, UIFindButton(sheet.contentView, @"Reset Friends"), @"Reset Friends");
    EXPECT(rig, UIWait(5, ^BOOL { return settings.attachedSheet == nil; }), "the sheet closes");
    EXPECT(rig, UIWait(10, ^BOOL {
               return UISnapshotCount(rig, @"list") > before &&
                      ![[UIFooter(rig)[@"friends_id"] description] isEqualToString:idBefore];
           }), "Reset gives a new ID: %@ (was %@)", UIFooter(rig), idBefore);
    EXPECT(rig, !UISavedName(rig), "and no name");
    UIShotWindow(rig, settings, @"after-reset");
    [section sectionDidDisappear];
    [settings orderOut:nil];
    [settings close];
    EXPECT(rig, UIOpenDropdown(rig), "the dropdown opens");
    NSString* newID = UIFooter(rig)[@"id_label"];
    EXPECT(rig, UIWait(5, ^BOOL { return UIFindText(rig.content, @"Choose the name friends see") != nil; }) &&
                    UIFindText(rig.listPage.footer, newID),
           "after Reset the card asks for a name, and the footer shows %@", newID);
    UIShot(rig, @"dropdown-after-reset");
    return YES;
}

#pragma mark - The name saved elsewhere, seen on Nearby

// The root cause of the owner's stuck card (2026-10-20): the list page dropped its `list` subscription while Nearby
// showed, and the card comes from it. Here the name is saved by another client of the same helper (another app),
// so nothing in the card's editor runs: only the subscription can take the card away. Reverting the subscription
// fix fails this step even though the editor hides the card after its own Save.
BOOL UINameSavedElsewhere(UIRig* rig) {
    UIBeginFlow(rig, @"name-elsewhere");
    UICloseDropdown(rig);
    SZFE2EClient* other = [SZFE2EClient clientForHelper:rig.helper];
    EXPECT(rig, other != nil, "another app connects to the helper");
    NSDictionary* reply = [other intent:@"reset_friends" fields:@{@"confirm" : @"reset"}];
    EXPECT(rig, [reply[@"ok"] boolValue], "the other app resets Friends: %@", reply);
    EXPECT(rig, UIOpenDropdown(rig), "the dropdown opens");
    SZFriendsListPage* list = rig.listPage;
    CLICK(rig, list.nearbyTab, @"the Nearby tab");
    EXPECT(rig, UIWait(5, ^BOOL { return list.showingNearby && list.namePromptEditor != nil; }),
           "on Nearby, the card asks for a name");
    UIShot(rig, @"asks");
    reply = [other intent:@"set_name" fields:@{@"name" : @"Mika"}];
    EXPECT(rig, [reply[@"ok"] boolValue], "the other app saves a name: %@", reply);
    EXPECT(rig, UIWait(5, ^BOOL {
               return list.namePromptEditor == nil && !UIFindText(rig.content, @"Choose the name friends see");
           }), "the card goes on Nearby, though nothing was typed in it");
    EXPECT(rig, !list.showingNameSaved, "and claims no save of its own");
    EXPECT(rig, UIWait(3, ^BOOL { return UIFindText(list.footer, @"Mika") != nil; }), "the footer shows Mika");
    UIShot(rig, @"gone");
    CLICK(rig, list.friendsTab, @"the Friends tab");
    [other close];
    return YES;
}
