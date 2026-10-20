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

// Visible buttons titled `title` under `root`: one card, one button (the Nearby cards).
static NSUInteger UICountButtons(NSView* root, NSString* title) {
    NSUInteger count = 0;
    for (NSView* view in UIAllViews(root))
        if ([view isKindOfClass:NSButton.class] && [((NSButton*)view).title isEqualToString:title] && UIVisible(view))
            count++;
    return count;
}

static NSString* UISavedText(NSString* name) {
    return [NSString stringWithFormat:@"Saved — friends now see %@", name];
}

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
    // Friends is a beta: the title's tag shows, whole and inside the dropdown; the first-run card and the button's
    // tooltip say so too.
    NSView* beta = list.betaTagView;
    EXPECT(rig, beta && UIVisible(beta) && UIFindText(beta, @"Beta"), "the title shows the Beta tag: %@", beta);
    NSRect tag = [beta convertRect:beta.bounds toView:rig.content];
    EXPECT(rig, NSWidth(tag) >= 20 && NSHeight(tag) >= 10 && NSContainsRect(rig.content.bounds, tag),
           "the Beta tag lies inside the dropdown: %@ in %@", NSStringFromRect(tag),
           NSStringFromRect(rig.content.bounds));
    EXPECT(rig, UIFindText(rig.content, @"Friends is in beta, so things may still change."),
           "the first-run card says Friends is a beta");
    EXPECT(rig, [rig.dropdown.button.toolTip hasPrefix:@"Friends (Beta)"], "the button's tooltip says Beta: %@",
           rig.dropdown.button.toolTip);
    EXPECT(rig, UIFindText(rig.content, @"No friends yet"), "the empty list says so");
    // No note about the ID that raises a question without helping (the owner's report of 2026-10-20).
    EXPECT(rig, !UIFindText(rig.content, @"already taken") && !UIFindText(rig.content, @"works nearby now"),
           "no note about the ID in the list");
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
    // It worked, said where the person typed it, before the card goes (the owner's report of 2026-10-20: nothing
    // said the name was saved). The field is gone, so the typing goes to search.
    NSString* savedText = UISavedText(name);
    EXPECT(rig, UIWait(3, ^BOOL { return UIFindText(rig.content, savedText) != nil; }) && list.showingNameSaved,
           "the card says \"%@\"", savedText);
    EXPECT(rig, list.searchField.currentEditor != nil, "the focus moves to search (first responder %@)",
           popover.firstResponder);
    UIShot(rig, @"saved-confirmation");
    EXPECT(rig, UIWait(5, ^BOOL { return !list.showingNameSaved && !UIFindText(rig.content, savedText); }),
           "then the card goes");
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
    EXPECT(rig, UIFindButton(footer, @"Cancel") && editor.cancelButton.enabled, "Cancel shows beside Save");
    UIShot(rig, @"editing");
    // Cancel leaves it: the name stays and nothing is sent.
    NSInteger sent = UISnapshotCount(rig, @"list");
    UIClearField(popover);
    UIType(popover, @"Someone else");
    CLICK(rig, UIFindButton(footer, @"Cancel"), @"Cancel");
    EXPECT(rig, !footer.editingName && UIFindText(footer, from), "Cancel leaves the rename and the name stays");
    // A click anywhere else in the list leaves it too: on a tab (which takes no focus), and in the search field.
    CLICK(rig, footer.nameButton, @"the name in the footer");
    UIClearField(popover);
    UIType(popover, @"Someone else");
    CLICK(rig, rig.listPage.friendsTab, @"the Friends tab");
    EXPECT(rig, UIWait(2, ^BOOL { return !footer.editingName; }), "a click on a tab leaves the rename");
    CLICK(rig, footer.nameButton, @"the name in the footer");
    UIClearField(popover);
    UIType(popover, @"Someone else");
    CLICK(rig, rig.listPage.searchField, @"the search field");
    EXPECT(rig, UIWait(2, ^BOOL { return !footer.editingName; }) && rig.listPage.searchField.currentEditor != nil,
           "a click in the search field leaves the rename, and the typing goes there");
    UISpin(0.3);
    EXPECT(rig, UISnapshotCount(rig, @"list") == sent && [UISavedName(rig) isEqualToString:from] &&
                    UIFindText(footer, from),
           "neither Cancel nor a click elsewhere saved anything: %@", UIFooter(rig));
    CLICK(rig, footer.nameButton, @"the name in the footer");
    editor = footer.nameEditor;
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
    UIPressReturn(popover);
    EXPECT(rig, UIWaitNextSnapshot(rig, @"list", before, 5) && [UISavedName(rig) isEqualToString:to],
           "Return saves the new name: %@", UIFooter(rig));
    EXPECT(rig, UIWait(3, ^BOOL { return !footer.editingName && UIFindText(footer, to) != nil; }),
           "the footer shows %@", to);
    // It worked, said on the name itself: a check where the pencil was, and the words as its tooltip.
    EXPECT(rig, footer.showingNameSaved && [footer.nameButton.toolTip isEqualToString:UISavedText(to)],
           "the name shows its check (tooltip %@)", footer.nameButton.toolTip);
    UIShot(rig, @"renamed");
    EXPECT(rig, UIWait(5, ^BOOL { return !footer.showingNameSaved; }), "then the pencil again");
    return YES;
}

#pragma mark - Tabs and being visible

// The selected tab against the track it sits on, sampled beside its title in both tabs (the other tab shows the
// track there): drawn by cacheDisplayInRect: and as the window's own layers hold it. The owner's report of
// 2026-10-20: in light mode the selected tab could not be seen. Its white fill was blended into the track by the
// popover's vibrancy (1.00:1 measured), and white on the old track #f4f4f5 would still be only 1.10:1.
static BOOL UISelectedTabStandsOut(UIRig* rig, NSView* selected, NSView* other) {
    NSPoint spot = NSMakePoint(5, NSMidY(selected.bounds));
    double pill[3], track[3], pillLayers[3], trackLayers[3];
    NSString* saved = UIShotPathFor(rig, @"tabs-window-layers");
    EXPECT(rig, UISampleCached(rig, selected, spot, pill) && UISampleCached(rig, other, spot, track),
           "the tabs can be sampled as drawn");
    EXPECT(rig, UISampleWindowLayers(rig, selected, spot, pillLayers, saved) &&
                    UISampleWindowLayers(rig, other, spot, trackLayers, nil),
           "the tabs can be sampled from the window's layers");
    double drawn = UIContrast(pill, track), composited = UIContrast(pillLayers, trackLayers);
    EXPECT(rig, drawn >= 1.2 && composited >= 1.2,
           "the selected tab stands out from the track: %.2f:1 as drawn (%.3f %.3f %.3f on %.3f %.3f %.3f), %.2f:1 in "
           "the window's layers (%.3f %.3f %.3f on %.3f %.3f %.3f)",
           drawn, pill[0], pill[1], pill[2], track[0], track[1], track[2], composited, pillLayers[0], pillLayers[1],
           pillLayers[2], trackLayers[0], trackLayers[1], trackLayers[2]);
    return YES;
}

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
    EXPECT(rig, UISelectedTabStandsOut(rig, list.nearbyTab, list.friendsTab), "the selected tab stands out");
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
    EXPECT(rig, !UIReveal(page, @"already taken") && !UIReveal(page, @"works nearby now"),
           "no note about the ID on the profile either");
    NSWindow* popover = rig.popoverWindow;
    CLICK(rig, page.addField, @"the ID field");
    // Send request rests until something is typed, as Save does (the owner's report of 2026-10-20).
    EXPECT(rig, !page.addButton.enabled, "Send request rests with nothing typed");
    UIType(popover, @"  ");
    EXPECT(rig, !page.addButton.enabled, "and for spaces");
    UIClearField(popover);
    UIType(popover, @"not an id");
    EXPECT(rig, page.addButton.enabled, "Send request wakes once something is typed");
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

#pragma mark - The name saved elsewhere, seen on Nearby

// The root cause of the owner's stuck card (2026-10-20): the list page dropped its `list` subscription while Nearby
// showed, and the card comes from it. Here the name is saved by another client of the same helper (another app),
// so nothing in the card's editor runs: only the subscription can take the card away. Reverting the subscription
// fix fails this step even though the editor hides the card after its own Save.
static BOOL UINameSavedElsewhere(UIRig* rig) {
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
        {@"a name saved elsewhere takes the card away on Nearby", ^BOOL { return UINameSavedElsewhere(rig); }},
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
