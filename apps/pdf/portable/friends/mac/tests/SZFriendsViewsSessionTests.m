// Shenzhen Friends views tests: a whole dropdown session against the fake helper, through the real link and client
// library: badge, activate, subscriptions held only on screen, navigation, keyboard, drafts.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsConversationPage.h"
#import "mac/SZFriendsDetailsPage.h"

static NSUInteger SZFCount(SZFTestFakeHelper *fake, NSString *type, BOOL (^match)(NSDictionary *frame)) {
    NSUInteger count = 0;
    for (NSDictionary *frame in [fake framesOfType:type])
        if (!match || match(frame)) count++;
    return count;
}

static BOOL SZFOpenConversation(NSDictionary *frame, NSString *conversationID) {
    return [frame[@"conversation_id"] isEqualToString:conversationID];
}

void SZFTestDropdownSession(NSString *stateDirectory) {
    setenv("SZFRIENDS_STATE_DIR", stateDirectory.fileSystemRepresentation, 1);
    SZFTestFakeHelper *fake = [[SZFTestFakeHelper alloc] initWithStateDirectory:stateDirectory];
    SZFExpect(fake != nil, @"fake helper started");
    if (!fake) return;
    SZFTestHost *host = [SZFTestHost new];
    SZFriendsHelperLink *link = [[SZFriendsHelperLink alloc] initWithHost:host];
    SZFTestPresenter *presenter = [SZFTestPresenter new];
    SZFriendsDropdownController *controller = [[SZFriendsDropdownController alloc] initWithHost:host link:link
                                                                                      presenter:presenter];
    [controller install];
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return link.state == SZFriendsLinkStateReady; }), @"link ready");
    SZFriendsButton *button = (SZFriendsButton *)controller.button;
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return [button.badgeLabel isEqualToString:@"2"]; }), @"badge from helper");
    SZFExpect([button.accessibilityLabel isEqualToString:@"Friends, 2 waiting for you"], @"badge accessibility");
    SZFExpect(host.services != nil, @"services offered once connected (search.export)");
    NSDictionary *hello = [fake framesOfType:@"hello"].firstObject;
    SZFExpect([hello[@"capabilities"] containsObject:@"drop.tabs"]
            && [hello[@"capabilities"] containsObject:@"search.export"],
              @"hello capabilities from the host: %@", hello[@"capabilities"]);
    SZFExpect(SZFCount(fake, @"subscribe",
            ^BOOL(NSDictionary *f) { return [f[@"view"] isEqualToString:@"list"]; }) == 0,
              @"nothing but the badge before the dropdown opens");

    // Opening: activate, then the list.
    [controller toggle];
    SZFExpect(controller.shown && presenter.presentCount == 1, @"dropdown shown");
    SZFExpect(presenter.lastSize.width == 400 && presenter.lastSize.height == 640, @"400 x 640 without a window");
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return SZFCount(fake, @"activate", nil) == 1; }), @"activate on open");
    SZFriendsDropdownContent *content = controller.content;
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return content.listPage.rows.count == 7; }), @"list rows from the helper");

    // Into Mei's conversation.
    [content.listPage.rows[1] performClick:nil];
    SZFExpect(controller.currentView == SZFriendsDropdownViewConversation, @"conversation view");
    SZFriendsConversationPage *mei = (SZFriendsConversationPage *)content.topPage;
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return mei.itemViews.count == 6; }), @"conversation items");
    SZFExpect(SZFCount(fake, @"open_conversation", ^BOOL(NSDictionary *f) { return SZFOpenConversation(f,
            @"c_mei"); }) == 1,
              @"open_conversation once");
    SZFExpect(mei.holdsSubscription, @"held while on screen");

    // Escape: the `#` picker first, then the dropdown; never back.
    host.attachableItems = @[ [SZFriendsAttachableItem new] ];
    [mei openAttachPicker];
    SZFExpect(mei.attachPicker != nil, @"picker open");
    [content friendsHandleEscape];
    SZFExpect(mei.attachPicker == nil && controller.shown, @"Escape closed only the picker");
    SZFExpect(controller.currentView == SZFriendsDropdownViewConversation, @"Escape did not navigate back");
    [content friendsHandleEscape];
    SZFExpect(!controller.shown, @"second Escape closed the dropdown");
    SZFExpect(!mei.holdsSubscription, @"open_conversation released when the dropdown closed");
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return SZFCount(fake, @"unsubscribe", nil) >= 1; }),
              @"unsubscribe reached the helper");

    // Reopening returns to the conversation, subscribing again; the draft survives.
    [mei.composer.textView insertText:@"draft text" replacementRange:NSMakeRange(0, 0)];
    [controller toggle];
    SZFExpect(controller.currentView == SZFriendsDropdownViewConversation && content.topPage == mei,
              @"reopened where it was left");
    SZFExpect(SZFTestWaitUntil(10, ^BOOL {
                  return SZFCount(fake, @"open_conversation", ^BOOL(NSDictionary *f) { return SZFOpenConversation(f,
                          @"c_mei"); }) == 2;
              }), @"open_conversation again on reopen");
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return SZFCount(fake, @"activate", nil) == 2; }), @"activate on every open");
    SZFExpect([mei.composer.textView.string isEqualToString:@"draft text"], @"draft kept across close and reopen");

    // Cmd+[ goes back; the draft comes back with the conversation.
    [content performKeyEquivalent:SZFTestKeyEvent(@"[", 33, NSEventModifierFlagCommand)];
    SZFExpect(controller.currentView == SZFriendsDropdownViewList, @"Cmd+[ went back to the list");
    [content.listPage.rows[1] performClick:nil];
    mei = (SZFriendsConversationPage *)content.topPage;
    SZFExpect([mei.composer.textView.string isEqualToString:@"draft text"], @"draft restored for the conversation");
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return mei.itemViews.count == 6; }), @"conversation items again");

    // Shift+Return inserts a line; Return sends, once, with a client token.
    NSUInteger sentBefore = SZFCount(fake, @"send_message", nil);
    [mei.composer.textView setSelectedRange:NSMakeRange(mei.composer.textView.string.length, 0)];
    [mei.composer.textView keyDown:SZFTestKeyEvent(@"\r", 36, NSEventModifierFlagShift)];
    SZFExpect([mei.composer.textView.string isEqualToString:@"draft text\n"], @"Shift+Return inserted a line: %@",
              mei.composer.textView.string);
    SZFTestSpin(0.05);
    SZFExpect(SZFCount(fake, @"send_message", nil) == sentBefore, @"Shift+Return did not send");
    [mei.composer.textView insertText:@"more" replacementRange:mei.composer.textView.selectedRange];
    [mei.composer.textView keyDown:SZFTestKeyEvent(@"\r", 36, 0)];
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return SZFCount(fake, @"send_message", nil) == sentBefore + 1; }),
              @"Return sent");
    NSDictionary *sent = [fake framesOfType:@"send_message"].lastObject;
    SZFExpect([sent[@"text"] isEqualToString:@"draft text\nmore"]
            && [sent[@"conversation_id"] isEqualToString:@"c_mei"] &&
                  [sent[@"client_token"] length] >= 16,
              @"send_message fields: %@", sent);
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return mei.composer.textView.string.length == 0; }),
              @"composer cleared after the reply");
    SZFExpect(controller.content.context.drafts[@"c_mei"] == nil, @"draft dropped once sent");

    // Details from the header name; the details subscription carries the conversation.
    [mei.header.titleButton performClick:nil];
    SZFExpect(controller.currentView == SZFriendsDropdownViewDetails, @"details view");
    SZFExpect(SZFTestWaitUntil(10, ^BOOL {
                  return SZFCount(fake, @"subscribe", ^BOOL(NSDictionary *f) {
                             return [f[@"view"] isEqualToString:@"details"] &&
                                    [f[@"params"][@"conversation_id"] isEqualToString:@"c_mei"];
                         }) == 1;
              }), @"details subscription");
    SZFriendsDetailsPage *details = (SZFriendsDetailsPage *)content.topPage;
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return details.actionButtons.count == 3; }), @"details rendered");
    [details.autoAcceptSwitch performClick:nil];
    SZFExpect(SZFTestWaitUntil(10, ^BOOL {
                  return SZFCount(fake, @"set_auto_accept", ^BOOL(NSDictionary *f) {
                             return [f[@"conversation_id"] isEqualToString:@"c_mei"] && ![f[@"enabled"] boolValue];
                         }) == 1;
              }), @"automatic acceptance switch sends set_auto_accept");
    [content performKeyEquivalent:SZFTestKeyEvent(@"[", 33, NSEventModifierFlagCommand)];
    SZFExpect(controller.currentView == SZFriendsDropdownViewConversation, @"back to the conversation");
    [content performKeyEquivalent:SZFTestKeyEvent(@"[", 33, NSEventModifierFlagCommand)];
    SZFExpect(controller.currentView == SZFriendsDropdownViewList, @"back to the list");
    [content performKeyEquivalent:SZFTestKeyEvent(@"[", 33, NSEventModifierFlagCommand)];
    SZFExpect(controller.currentView == SZFriendsDropdownViewList && controller.shown,
            @"Cmd+[ at the list does nothing");

    // Add by ID opens the profile; Escape there closes the dropdown and leaves the profile for next time.
    [content.listPage.footer.addButton performClick:nil];
    SZFExpect(controller.currentView == SZFriendsDropdownViewProfile, @"profile from Add by ID");
    SZFriendsProfilePage *profile = (SZFriendsProfilePage *)content.topPage;
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return [profile.addButton.title isEqualToString:@"Send request"]; }),
              @"profile rendered");
    profile.addField.stringValue = @"willow-breeze";
    [profile sendAddRequest];
    SZFExpect(SZFTestWaitUntil(10, ^BOOL {
                  return SZFCount(fake, @"add_by_id", ^BOOL(NSDictionary *f) {
                             return [f[@"friends_id"] isEqualToString:@"willow-breeze"];
                         }) == 1;
              }), @"add_by_id sent");
    [content friendsHandleEscape];
    SZFExpect(!controller.shown && controller.currentView == SZFriendsDropdownViewProfile, @"Escape closed, view kept");

    // Nearby: subscribed only while its tab shows; the visibility action sends start_visibility.
    [controller toggle];
    [content popToList];
    [content.listPage.nearbyTab performClick:nil];
    SZFExpect(controller.currentView == SZFriendsDropdownViewNearby, @"Nearby tab");
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return content.listPage.nearbyPane.personRows.count == 4; }),
            @"nearby people");
    [content.listPage.nearbyPane.personRows[1].accessoryButton performClick:nil];
    SZFExpect(SZFTestWaitUntil(10, ^BOOL {
                  return SZFCount(fake, @"send_request", ^BOOL(NSDictionary *f) {
                             return [f[@"nearby_id"] isEqualToString:@"n_7c1e"];
                         }) == 1;
              }), @"Request sends send_request with the nearby id");
    [content.listPage.nearbyPane.visibilityButton performClick:nil];
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return SZFCount(fake, @"stop_visibility", nil) == 1; }), @"Stop");
    [content.listPage.friendsTab performClick:nil];
    [controller close];

    // A confirm on any action is asked inline first; Escape cancels it and nothing is sent.
    [controller toggle];
    NSDictionary *action = @{@"action" : @"delete_history", @"label" : @"Delete", @"style" : @"destructive",
                             @"confirm" : @{@"title" : @"Delete?", @"body" : @"Gone.", @"confirm_label" : @"Delete",
                                            @"cancel_label" : @"Cancel"}};
    [content.context performAction:action ids:@{@"conversation_id" : @"c_tulip"} done:nil];
    SZFExpect(content.confirmation != nil, @"confirmation shown");
    [content friendsHandleEscape];
    SZFExpect(content.confirmation == nil && controller.shown, @"Escape cancelled only the confirmation");
    [content.context performAction:action ids:@{@"conversation_id" : @"c_tulip"} done:nil];
    [content.confirmation.confirmButton performClick:nil];
    SZFExpect(SZFTestWaitUntil(10, ^BOOL {
                  return SZFCount(fake, @"delete_history", ^BOOL(NSDictionary *f) {
                             return [f[@"conversation_id"] isEqualToString:@"c_tulip"];
                         }) == 1;
              }), @"confirmed action sent once");

    // The helper goes away: pages keep their last snapshot and the status line says why; when a helper is back,
    // every subscription is re-sent by the link and the views update again without being rebuilt.
    [content popToList];
    NSUInteger badgeSubscriptions = SZFCount(fake, @"subscribe", ^BOOL(NSDictionary *f) {
        return [f[@"view"] isEqualToString:@"badge"];
    });
    SZFExpect(badgeSubscriptions == 1, @"one badge subscription so far: %lu", (unsigned long)badgeSubscriptions);
    [fake stop];
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return content.statusText.length > 0; }), @"status line while disconnected");
    SZFExpect(content.listPage.rows.count == 7, @"last snapshot kept while disconnected");
    SZFExpect([button.badgeLabel isEqualToString:@"2"], @"badge kept while disconnected");
    fake = [[SZFTestFakeHelper alloc] initWithStateDirectory:stateDirectory];
    SZFExpect(fake != nil, @"fake helper restarted");
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return link.state == SZFriendsLinkStateReady; }), @"reconnected");
    SZFExpect(SZFTestWaitUntil(10, ^BOOL {
                  return SZFCount(fake, @"subscribe", ^BOOL(NSDictionary *f) {
                             return [f[@"view"] isEqualToString:@"badge"];
                         }) == 1 &&
                         SZFCount(fake, @"subscribe", ^BOOL(NSDictionary *f) {
                             return [f[@"view"] isEqualToString:@"list"];
                         }) == 1;
              }), @"badge and list re-subscribed on the new connection");
    SZFExpect(SZFTestWaitUntil(10, ^BOOL { return content.statusText == nil; }), @"status line gone once connected");

    [controller uninstall];
    SZFExpect(host.installedButton == nil && host.services == nil, @"uninstall removed the button and the services");
    [link stopDisablingFriends:NO];
    [fake stop];
}
