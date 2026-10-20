// friends-ui-e2e's flows for one person (SPDFMacFriendsUIE2E.h): the first open, choosing the name, renaming it,
// the tabs, being visible, Add by ID, Settings with Reset Friends, Escape, and the Nearby permission cards.

#import "SPDFMacFriendsUIE2E.h"

#import "mac/SZFriendsDetailsPage.h"
#import "mac/SZFriendsListPage.h"
#import "mac/SZFriendsSettingsSection.h"

static NSString* const UITooLong = @"Abcdefghij Abcdefghij Abcdefghij Abcdefghij"; // 43 characters: over 40

static NSDictionary* UIFooter(UIRig* rig) {
    return rig.snapshots[@"list"][@"footer"];
}

static NSString* UISavedName(UIRig* rig) {
    id name = UIFooter(rig)[@"name"];
    return [name isKindOfClass:NSString.class] ? name : nil;
}

static BOOL UIClickOrFail(UIRig* rig, NSView* _Nullable view, NSString* what, const char* file, int line) {
    NSString* why = nil;
    if (view && UIClick(view, &why)) return YES;
    UIFail(rig, file, line, "a click reaches it", [NSString stringWithFormat:@"%@: %@", what, why ?: @"not found"]);
    return NO;
}
#define CLICK(rig, view, what)                                                                                     \
    do {                                                                                                           \
        if (!UIClickOrFail(rig, view, what, __FILE__, __LINE__)) return NO;                                       \
    } while (0)

#pragma mark - First open

static BOOL UIFirstOpen(UIRig* rig) {
    UIBeginFlow(rig, @"first-open");
    EXPECT(rig, UIOpenDropdown(rig), "the dropdown opens from the title-bar button");
    SZFriendsListPage* list = rig.listPage;
    NSDictionary* footer = UIFooter(rig);
    NSString* idLabel = footer[@"id_label"];
    EXPECT(rig, idLabel.length > 0, "the helper names an ID: %@", rig.snapshots[@"list"]);
    EXPECT(rig, UIWait(5, ^BOOL { return UIFindText(rig.content, @"Choose the name friends see") != nil; }),
           "the card asks for a name on first open");
    NSString* friendsID = [footer[@"friends_id"] description];
    EXPECT(rig, UIFindText(rig.content, @"Until you choose one, friends see your ID"),
           "the card says what friends see meanwhile");
    EXPECT(rig, list.namePromptEditor && UIVisible(list.namePromptEditor.field), "the card has a field");
    NSButton* save = UIFindButton(rig.content, @"Save");
    EXPECT(rig, save && !save.enabled, "Save shows, and rests until a name is typed: %@", save);
    EXPECT(rig, UIFindText(list.footer, @"Choose your name") && UIFindText(list.footer, idLabel),
           "the footer shows the placeholder and %@ (%@)", idLabel, friendsID);
    EXPECT(rig, UIFindButton(rig.content, @"Friends") && UIFindButton(rig.content, @"Nearby"), "both tabs");
    EXPECT(rig, UIFindText(rig.content, @"No friends yet"), "the empty list says so");
    EXPECT(rig, UIShot(rig, @"first-open"), "the first open lays out inside the popover");
    return YES;
}

#pragma mark - Choosing the name (on the Nearby tab, where the owner found the card stuck)

static BOOL UISetName(UIRig* rig, NSString* name, BOOL onNearby, BOOL withReturn) {
    UIBeginFlow(rig, onNearby ? @"set-name-nearby" : @"set-name");
    EXPECT(rig, UIOpenDropdown(rig), "the dropdown opens");
    SZFriendsListPage* list = rig.listPage;
    if (onNearby) {
        CLICK(rig, list.nearbyTab, @"the Nearby tab");
        EXPECT(rig, UIWait(5, ^BOOL { return list.showingNearby; }), "Nearby shows");
    }
    SZFriendsNameEditor* editor = list.namePromptEditor;
    EXPECT(rig, editor != nil, "the card is there with its field");
    CLICK(rig, editor.field, @"the name field");
    NSWindow* popover = rig.popoverWindow;
    EXPECT(rig, editor.field.currentEditor != nil, "the field takes the typing (first responder %@)",
           popover.firstResponder);

    // Nothing typed: Return says what to do, and nothing reaches the helper.
    NSInteger before = UISnapshotCount(rig, @"list");
    UIPressReturn(popover);
    EXPECT(rig, UIWait(3, ^BOOL { return UIFindText(rig.content, @"Type the name friends should see.") != nil; }),
           "Return with nothing typed says to type a name");
    EXPECT(rig, rig.dropdown.shown && UIFindText(rig.content, @"Choose the name friends see"), "the card stays");
    UIShot(rig, @"empty-refused");
    // Only spaces: the same, and Save stays resting.
    EXPECT(rig, UIType(popover, @"   "), "typing reaches the field");
    EXPECT(rig, !editor.saveButton.enabled, "Save rests for spaces");
    UIPressReturn(popover);
    EXPECT(rig, UIFindText(rig.content, @"Type the name friends should see."), "spaces are refused the same way");
    EXPECT(rig, UISnapshotCount(rig, @"list") == before && !UISavedName(rig), "nothing was saved");

    // Too long: the helper refuses it, and says why under the field.
    UIClearField(popover);
    UIType(popover, UITooLong);
    EXPECT(rig, editor.saveButton.enabled && !UIFindText(rig.content, @"Type the name friends should see."),
           "typing clears the message and wakes Save");
    UIShot(rig, @"typed-too-long");
    CLICK(rig, editor.saveButton, @"Save");
    EXPECT(rig, UIWait(5, ^BOOL { return UIFindText(rig.content, @"Names can be 1 to 40 characters") != nil; }),
           "a name over 40 characters is refused with the helper's reason");
    EXPECT(rig, !UISavedName(rig) && UIFindText(rig.content, @"Choose the name friends see"), "nothing was saved");
    UIShot(rig, @"too-long-refused");

    // Escape drops what was typed and keeps the dropdown open.
    UIPressEscape(popover);
    EXPECT(rig, rig.dropdown.shown && editor.field.stringValue.length == 0 && !editor.hasTyping,
           "Escape empties the field first (shown %d, field \"%@\")", rig.dropdown.shown, editor.field.stringValue);
    EXPECT(rig, !UIFindText(rig.content, @"Names can be 1 to 40 characters"), "Escape takes the message away too");

    // The name: Save (or Return) shows it working at once, then the card goes and the footer shows the name.
    CLICK(rig, editor.field, @"the name field");
    UIType(popover, name);
    EXPECT(rig, editor.saveButton.enabled, "Save wakes for a name");
    UIShot(rig, @"typed");
    before = UISnapshotCount(rig, @"list");
    if (withReturn) UIPressReturn(popover);
    else CLICK(rig, editor.saveButton, @"Save");
    EXPECT(rig, UIWaitNextSnapshot(rig, @"list", before, 5), "the helper sends the list again");
    EXPECT(rig, [UISavedName(rig) isEqualToString:name], "the helper saved the name: %@", UIFooter(rig));
    EXPECT(rig, UIWait(5, ^BOOL { return list.namePromptEditor == nil; }),
           "the card goes once the helper has the name (Nearby %d)", list.showingNearby);
    EXPECT(rig, !UIFindText(rig.content, @"Choose the name friends see"), "nothing asks for a name any more");
    EXPECT(rig, UIWait(3, ^BOOL { return UIFindText(list.footer, name) != nil; }), "the footer shows %@", name);
    EXPECT(rig, rig.dropdown.shown, "the dropdown stays open");
    UIShot(rig, @"saved");
    // Reopened, the dropdown remembers: no card.
    EXPECT(rig, UICloseDropdown(rig) && UIOpenDropdown(rig), "closes and reopens");
    EXPECT(rig, !UIFindText(rig.content, @"Choose the name friends see") && UIFindText(list.footer, name),
           "after reopening, the name and no card");
    UIShot(rig, @"reopened");
    if (onNearby) CLICK(rig, list.friendsTab, @"the Friends tab");
    return YES;
}

#pragma mark - Renaming from the footer

static BOOL UIRename(UIRig* rig, NSString* from, NSString* to) {
    UIBeginFlow(rig, @"rename");
    EXPECT(rig, UIOpenDropdown(rig), "the dropdown opens");
    SZFriendsFooterView* footer = rig.listPage.footer;
    CLICK(rig, footer.nameButton, @"the name in the footer");
    SZFriendsNameEditor* editor = footer.nameEditor;
    NSWindow* popover = rig.popoverWindow;
    EXPECT(rig, editor && UIVisible(editor.field) && [editor.field.stringValue isEqualToString:from],
           "the pencil opens a field holding the name: %@", editor.field.stringValue);
    EXPECT(rig, editor.field.currentEditor != nil, "the field takes the typing");
    NSButton* save = UIFindButton(footer, @"Save");
    EXPECT(rig, save && !save.enabled, "Save shows and rests while the name is unchanged");
    UIShot(rig, @"editing");
    // Escape cancels: the name stays.
    UIClearField(popover);
    UIType(popover, @"Someone else");
    UIPressEscape(popover);
    EXPECT(rig, !footer.editingName && rig.dropdown.shown && UIFindText(footer, from),
           "Escape cancels the rename and keeps the dropdown");
    EXPECT(rig, [UISavedName(rig) isEqualToString:from], "nothing was saved: %@", UIFooter(rig));
    // Again, refusing nothing and too long.
    CLICK(rig, footer.nameButton, @"the name in the footer");
    editor = footer.nameEditor;
    UIClearField(popover);
    UIPressReturn(popover);
    EXPECT(rig, UIWait(3, ^BOOL { return UIFindText(footer, @"Type the name friends should see.") != nil; }),
           "an empty rename is refused");
    UIShot(rig, @"empty-refused");
    UIType(popover, UITooLong);
    CLICK(rig, editor.saveButton, @"Save");
    EXPECT(rig, UIWait(5, ^BOOL { return UIFindText(footer, @"Names can be 1 to 40 characters") != nil; }),
           "a long rename is refused with the reason");
    UIShot(rig, @"too-long-refused");
    UIClearField(popover);
    UIType(popover, to);
    NSInteger before = UISnapshotCount(rig, @"list");
    CLICK(rig, editor.saveButton, @"Save");
    EXPECT(rig, UIWaitNextSnapshot(rig, @"list", before, 5) && [UISavedName(rig) isEqualToString:to],
           "the helper has the new name: %@", UIFooter(rig));
    EXPECT(rig, UIWait(3, ^BOOL { return !footer.editingName && UIFindText(footer, to) != nil; }),
           "the footer shows %@", to);
    UIShot(rig, @"renamed");
    return YES;
}

#pragma mark - Tabs and being visible

static BOOL UITabs(UIRig* rig) {
    UIBeginFlow(rig, @"tabs");
    EXPECT(rig, UIOpenDropdown(rig), "the dropdown opens");
    SZFriendsListPage* list = rig.listPage;
    CLICK(rig, list.nearbyTab, @"the Nearby tab");
    EXPECT(rig, UIWait(5, ^BOOL { return UIFindButton(rig.content, @"Make myself visible for 5 minutes") != nil; }),
           "Nearby offers to make me visible");
    EXPECT(rig, [list.nearbyTab.accessibilityValue isEqual:@YES] && [list.friendsTab.accessibilityValue isEqual:@NO],
           "Nearby reads as the selected tab");
    UIShot(rig, @"nearby");
    CLICK(rig, list.friendsTab, @"the Friends tab");
    EXPECT(rig, UIWait(5, ^BOOL { return !list.showingNearby && UIFindText(rig.content, @"No friends yet") != nil; }),
           "Friends shows the list again");
    EXPECT(rig, !UIFindButton(rig.content, @"Make myself visible for 5 minutes"), "and not Nearby's card");
    UIShot(rig, @"friends");
    return YES;
}

// The visible "4:59" on the visibility card, or nil.
static NSString* UICountdown(UIRig* rig) {
    for (NSView* view in UIAllViews(rig.content)) {
        if (![view isKindOfClass:NSTextField.class] || !UIVisible(view)) continue;
        NSString* text = ((NSTextField*)view).stringValue;
        if ([text rangeOfString:@"^[0-9]:[0-5][0-9]$" options:NSRegularExpressionSearch].location == 0) return text;
    }
    return nil;
}

static BOOL UIVisibility(UIRig* rig) {
    UIBeginFlow(rig, @"visible");
    EXPECT(rig, UIOpenDropdown(rig), "the dropdown opens");
    SZFriendsListPage* list = rig.listPage;
    CLICK(rig, list.nearbyTab, @"the Nearby tab");
    NSButton* start = nil;
    EXPECT(rig, UIWait(5, ^BOOL { return UIFindButton(rig.content, @"Make myself visible for 5 minutes") != nil; }),
           "the offer to be visible");
    start = UIFindButton(rig.content, @"Make myself visible for 5 minutes");
    CLICK(rig, start, @"Make myself visible for 5 minutes");
    EXPECT(rig, UIWait(5, ^BOOL { return UIFindText(rig.content, @"You’re visible to people nearby") != nil; }),
           "the card says I am visible");
    EXPECT(rig, UIFindButton(rig.content, @"Stop"), "with Stop");
    __block NSString* first = nil;
    EXPECT(rig, UIWait(3, ^BOOL { return (first = UICountdown(rig)) != nil; }), "a countdown shows");
    EXPECT(rig, [first hasPrefix:@"4:"] || [first isEqualToString:@"5:00"], "it starts near five minutes: %@", first);
    UIShot(rig, @"visible");
    __block NSString* later = nil;
    EXPECT(rig, UIWait(4, ^BOOL {
               later = UICountdown(rig);
               return later && ![later isEqualToString:first];
           }), "the countdown counts down (%@, then %@)", first, later);
    CLICK(rig, UIFindButton(rig.content, @"Stop"), @"Stop");
    EXPECT(rig, UIWait(5, ^BOOL { return UIFindButton(rig.content, @"Make myself visible for 5 minutes") != nil; }),
           "Stop ends it, and the offer is back");
    UIShot(rig, @"stopped");
    CLICK(rig, list.friendsTab, @"the Friends tab");
    return YES;
}

#pragma mark - Add by ID

static BOOL UIAddByID(UIRig* rig) {
    UIBeginFlow(rig, @"add-by-id");
    EXPECT(rig, UIOpenDropdown(rig), "the dropdown opens");
    CLICK(rig, rig.listPage.footer.addButton, @"Add by ID");
    EXPECT(rig, UIWait(5, ^BOOL { return rig.dropdown.currentView == SZFriendsDropdownViewProfile; }),
           "Add by ID opens the profile page");
    SZFriendsProfilePage* page = (SZFriendsProfilePage*)rig.content.topPage;
    EXPECT(rig, UIWait(5, ^BOOL { return UIFindText(page, @"Add someone by ID") != nil; }), "the Add by ID section");
    // Opened for adding: the ID field is in sight and has the focus, however short the dropdown.
    EXPECT(rig, UIWait(3, ^BOOL { return UIVisible(page.addField) && page.addField.currentEditor != nil; }),
           "the ID field is in sight with the focus");
    NSString* saved = UISavedName(rig);
    EXPECT(rig, [page.nameField.stringValue isEqualToString:saved ?: @""], "the page shows the name %@: %@", saved,
           page.nameField.stringValue);
    UIShot(rig, @"profile");
    // Your computers names this computer as the test helper calls it, never this Mac's own name or macOS version.
    EXPECT(rig, UIReveal(page, @"Test computer me") && UIReveal(page, @"Test system 1.0"),
           "Your computers shows the test computer:\n%@", UIDescribe(page));
    EXPECT(rig, !UIRealComputerShown(page), "this Mac's own name or system shows: %@", UIRealComputerShown(page));
    UIShot(rig, @"your-computers");
    NSWindow* popover = rig.popoverWindow;
    CLICK(rig, page.addField, @"the ID field");
    UIType(popover, @"not an id");
    CLICK(rig, page.addButton, @"Send request");
    EXPECT(rig, UIWait(5, ^BOOL { return UIFindText(page, @"That isn’t a Friends ID") != nil; }),
           "a wrong ID is refused, saying what an ID looks like");
    UIShot(rig, @"invalid");
    CLICK(rig, page.addField, @"the ID field");
    UIClearField(popover);
    UIType(popover, @"amber-falcon");
    UIPressReturn(popover);
    EXPECT(rig, UIWait(5, ^BOOL { return UIFindText(page, @"Request sent to") != nil; }),
           "a well-formed ID is sent, and the page says so");
    EXPECT(rig, page.addField.stringValue.length == 0, "the field empties for the next one");
    UIShot(rig, @"sent");
    CLICK(rig, page.header.backButton, @"Back");
    EXPECT(rig, UIWait(5, ^BOOL { return rig.dropdown.currentView == SZFriendsDropdownViewList; }), "back to the list");
    UIShot(rig, @"list-after");
    return YES;
}

#pragma mark - Settings, Reset Friends

// Settings in a window of its own, as the reader's Settings shows the section; the caller closes it.
static NSWindow* UISettingsWindow(UIRig* rig, SZFriendsSettingsSection* section) {
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

// The sheet once it is up and still (the same frame for a few turns in a row), as a person sees it before clicking.
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
    return sheet;
}

static BOOL UISettingsAndReset(UIRig* rig) {
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

#pragma mark - Escape

static BOOL UIEscape(UIRig* rig) {
    UIBeginFlow(rig, @"escape");
    EXPECT(rig, UIOpenDropdown(rig), "the dropdown opens");
    NSWindow* popover = rig.popoverWindow;
    SZFriendsNameEditor* editor = rig.listPage.namePromptEditor;
    if (editor) {
        CLICK(rig, editor.field, @"the name field");
        UIType(popover, @"Half a na");
        UIPressEscape(popover);
        EXPECT(rig, rig.dropdown.shown && !editor.hasTyping, "the first Escape only drops what was typed");
    }
    UIPressEscape(popover);
    EXPECT(rig, UIWait(3, ^BOOL { return !rig.dropdown.shown; }), "Escape closes the dropdown");
    // From the search field, too.
    EXPECT(rig, UIOpenDropdown(rig), "reopens");
    CLICK(rig, rig.listPage.searchField, @"the search field");
    UIPressEscape(rig.popoverWindow);
    EXPECT(rig, UIWait(3, ^BOOL { return !rig.dropdown.shown; }), "Escape in the search field closes it");
    return YES;
}

#pragma mark - The one-person run

void UIRecord(UIVariant* variant, NSString* flow, BOOL passed) {
    [UIFlowResults addObject:[NSString stringWithFormat:@"%@\t%@\t%@", passed ? @"PASS" : @"FAIL", variant.name, flow]];
    printf("  %s %s\n", passed ? "ok  " : "FAIL", flow.UTF8String);
}

BOOL UIFlowSolo(SZFE2EWorld* world, UIVariant* variant) {
    [world beginScenario:[@"solo-" stringByAppendingString:variant.name]];
    UIRig* rig = UIStartRig(world, variant, @"me", nil);
    if (!rig) {
        UIRecord(variant, @"start", NO);
        return NO;
    }
    BOOL all = YES;
    // Each step ends with the dropdown in a known place (open on the list, or closed) for the next one.
    struct {
        NSString* name;
        BOOL (^run)(void);
    } steps[] = {
        {@"first open with no name", ^BOOL { return UIFirstOpen(rig); }},
        {@"choose the name on the Nearby tab (Return)", ^BOOL { return UISetName(rig, @"WAF!", YES, YES); }},
        {@"rename from the footer pencil", ^BOOL { return UIRename(rig, @"WAF!", @"Raph"); }},
        {@"switch Friends / Nearby", ^BOOL { return UITabs(rig); }},
        {@"Make myself visible for 5 minutes", ^BOOL { return UIVisibility(rig); }},
        {@"Add by ID", ^BOOL { return UIAddByID(rig); }},
        {@"Settings: Reset Friends… cancel and confirm", ^BOOL { return UISettingsAndReset(rig); }},
        {@"choose the name on the Friends tab (Save)", ^BOOL { return UISetName(rig, @"Ana", NO, NO); }},
        {@"Escape closes the dropdown", ^BOOL { return UIEscape(rig); }},
    };
    for (auto& step : steps) {
        int failuresBefore = UIFailures;
        BOOL passed = step.run() && UIFailures == failuresBefore;
        UIRecord(variant, step.name, passed);
        all = all && passed;
        if (!passed) {
            // Back to a known place before the next flow.
            if (rig.dropdown.shown) [rig.content popToList];
            UICloseDropdown(rig);
        }
    }
    if (!all) [world printLogs];
    UIStopRig(rig);
    [world endScenario];
    return all;
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
    UIShot(rig, @"radio-off");
    // Not working: Try Again starts it again.
    UIWriteState(script, @"unavailable");
    __block NSView* card = nil;
    EXPECT(rig, UIWait(5, ^BOOL {
               NSView* title = UIReveal(rig.content, @"can’t find people on your network right now");
               card = title.superview;
               return card && UIFindButton(card, @"Try Again") != nil;
           }), "a failing Nearby says so, with Try Again");
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
