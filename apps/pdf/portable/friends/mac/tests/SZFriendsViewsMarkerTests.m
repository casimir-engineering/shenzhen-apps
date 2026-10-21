// Shenzhen Friends views tests: every Friends surface is marked "szfriends." so the host's assistant (ShenzhenPDF's
// app_controls) can skip it. The host skips a view whose identifier, or an ancestor's, has the prefix, so each test
// checks the mark itself and that every control a person could press sits under one.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsConversationPage.h"

static BOOL SZFMarked(NSView *view) {
    for (NSView *ancestor = view; ancestor; ancestor = ancestor.superview)
        if ([ancestor.identifier hasPrefix:@"szfriends."]) return YES;
    return NO;
}

// Every control under `root` (buttons, fields, switches, the search field) is inside a marked view.
static void SZFExpectAllControlsMarked(NSView *root, NSString *name) {
    NSArray *controls = SZFTestSubviews(root, NSControl.class);
    SZFExpect(controls.count > 0, @"%@ has controls", name);
    NSUInteger unmarked = 0;
    for (NSControl *control in controls) unmarked += !SZFMarked(control);
    SZFExpect(unmarked == 0, @"%@: %lu of %lu controls are not under a szfriends. mark", name,
              (unsigned long)unmarked, (unsigned long)controls.count);
}

void SZFTestAssistantMarkers(void) {
    SZFTestHost *host = [SZFTestHost new];
    SZFriendsDropdownController *controller =
        [[SZFriendsDropdownController alloc] initWithHost:host link:SZFTestReadyLink(NULL)
                                                presenter:[SZFTestPresenter new]];
    SZFExpect([controller.button.identifier isEqualToString:@"szfriends.title-button"],
              @"the title button is marked: %@", controller.button.identifier);

    // The dropdown: its content view, which holds every page, the confirmation over it and the list's own buttons.
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(NULL));
    SZFriendsDropdownContent *content = [[SZFriendsDropdownContent alloc] initWithContext:context];
    NSWindow *window = SZFTestHostWindow(content, NSMakeSize(400, 640), NSAppearanceNameAqua);
    SZFExpect([content.identifier isEqualToString:@"szfriends.dropdown"], @"the dropdown is marked: %@",
              content.identifier);
    [content.listPage applySnapshot:SZFTestSnapshot(@"list")];
    [content layoutSubtreeIfNeeded];
    SZFExpectAllControlsMarked(content, @"list");
    [content openConversation:@"c_mei" highlightMessage:nil];
    [content.topPage applySnapshot:SZFTestSnapshot(@"conversation-mei")];
    [content layoutSubtreeIfNeeded];
    SZFExpectAllControlsMarked(content, @"conversation");
    context.presentConfirmation(SZFTestSnapshot(@"settings")[@"reset"][@"confirm"], ^(BOOL ticked) { (void)ticked; });
    SZFExpect([content.confirmation.identifier isEqualToString:@"szfriends.confirmation"],
              @"the confirmation is marked: %@", content.confirmation.identifier);
    SZFExpectAllControlsMarked(content.confirmation, @"confirmation");

    // Settings: the section's view, and the alert its confirmations show, on the window and its content view.
    SZFriendsSettingsSection *settings = [[SZFriendsSettingsSection alloc] initWithHost:[SZFTestHost new]
                                                                                   link:SZFTestReadyLink(NULL)];
    NSWindow *settingsWindow = SZFTestHostWindow(settings.view, NSMakeSize(560, 640), NSAppearanceNameAqua);
    [settings applySnapshot:SZFTestSnapshot(@"settings")];
    [settings.buttons[2] performClick:nil]; // the per-friend switches too
    [settings.view layoutSubtreeIfNeeded];
    SZFExpect([settings.view.identifier isEqualToString:@"szfriends.settings"], @"the Settings section is marked: %@",
              settings.view.identifier);
    SZFExpectAllControlsMarked(settings.view, @"settings");
    for (NSString *part in @[ @"history", @"reset" ]) {
        NSAlert *alert = [SZFriendsSettingsSection alertForConfirm:SZFTestSnapshot(@"settings")[part][@"confirm"]];
        SZFExpect([alert.window.identifier isEqualToString:@"szfriends.alert"] &&
                      [alert.window.contentView.identifier isEqualToString:@"szfriends.alert"],
                  @"the %@ alert is marked: %@ / %@", part, alert.window.identifier,
                  alert.window.contentView.identifier);
        [alert layout];
        for (NSButton *button in alert.buttons)
            SZFExpect(SZFMarked(button), @"the alert's %@ button is under the mark", button.title);
    }
    (void)window, (void)settingsWindow;
}
