// Shenzhen Friends views tests: taking someone off the list from their row (PROTOCOL.md list_row menu). Right-click,
// Control-click, Delete and VoiceOver open or run the row's menu; Remove asks first, with "Also delete chat history"
// unticked when there is history; the intent carries delete_history only when ticked; the row goes at once and comes
// back if the helper refuses. The list is the list fixture with each row's `menu` written here as the spec gives it.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsLinkTransport.h"

NSDictionary *SZFTestRemoveConfirm(NSString *first, BOOL history) {
    NSString *body = [NSString stringWithFormat:@"%@ leaves your list and isn’t told. Anything still waiting to go to "
                                                @"%@ won’t be sent.", first, first];
    if (history)
        body = [body stringByAppendingFormat:@" Your chat history with %@ is kept unless you also delete it.", first];
    NSMutableDictionary *confirm = [@{
        @"title" : [NSString stringWithFormat:@"Remove %@?", first], @"body" : body, @"confirm_label" : @"Remove",
        @"cancel_label" : @"Cancel", @"destructive" : @YES
    } mutableCopy];
    if (history) confirm[@"option"] = @{@"label" : @"Also delete chat history", @"field" : @"delete_history"};
    return confirm;
}

static NSDictionary *SZFRemove(NSString *label, NSDictionary *confirm) {
    return @{@"action" : @"remove_friend", @"label" : label, @"style" : @"destructive", @"note" : [NSNull null],
             @"arm" : [NSNull null], @"confirm" : confirm};
}

// The list fixture with menus: Lena (an incoming request) and Mei (a friend with history) offer Remove, Kenji only an
// action this view does not know, Daniel an empty menu, and the others none at all (an older helper).
static NSDictionary *SZFMenuList(void) {
    NSMutableDictionary *data = [SZFTestSnapshot(@"list") mutableCopy];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *source in data[@"rows"]) {
        NSMutableDictionary *row = [source mutableCopy];
        NSString *conversation = row[@"conversation_id"];
        if ([conversation isEqualToString:@"c_lena"]) {
            NSMutableDictionary *confirm = [SZFTestRemoveConfirm(@"Lena", YES) mutableCopy];
            confirm[@"body"] = @"Lena leaves your list. Either of you can send a new request later. Your chat history "
                               @"with Lena is kept unless you also delete it.";
            row[@"menu"] = @[ SZFRemove(@"Remove", confirm) ];
        } else if ([conversation isEqualToString:@"c_mei"]) {
            row[@"menu"] = @[ SZFRemove(@"Remove", SZFTestRemoveConfirm(@"Mei", YES)) ];
        } else if ([conversation isEqualToString:@"c_kenji"]) {
            row[@"menu"] = @[ @{@"action" : @"poke", @"label" : @"Poke", @"style" : @"secondary"} ];
        } else if ([conversation isEqualToString:@"c_daniel"]) {
            row[@"menu"] = @[];
        } else if ([conversation isEqualToString:@"c_priya"]) {
            row[@"menu"] = @[ SZFRemove(@"Remove", SZFTestRemoveConfirm(@"Priya", NO)) ];
        }
        [rows addObject:row];
    }
    data[@"rows"] = rows;
    return data;
}

static NSDictionary *SZFWithout(NSDictionary *data, NSString *conversationID) {
    NSMutableDictionary *copy = [data mutableCopy];
    copy[@"rows"] = [data[@"rows"] filteredArrayUsingPredicate:
                                       [NSPredicate predicateWithFormat:@"conversation_id != %@", conversationID]];
    return copy;
}

@interface SZFMenuRig : NSObject
@property(nonatomic, strong) SZFriendsDropdownContent *content;
@property(nonatomic, strong) SZFTestTransport *transport;
@property(nonatomic, strong) SZFTestClock *clock;
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSMutableArray<NSMenu *> *menus;
@property(nonatomic, strong) NSMutableArray<NSView *> *menuViews;
@end

@implementation SZFMenuRig
@end

static SZFMenuRig *SZFMakeMenuRig(void) {
    SZFMenuRig *rig = [SZFMenuRig new];
    SZFTestTransport *transport = nil;
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(&transport));
    rig.transport = transport;
    rig.clock = [SZFTestClock new];
    SZFTestInstallClock(context, rig.clock);
    rig.menus = [NSMutableArray array];
    rig.menuViews = [NSMutableArray array];
    __weak SZFMenuRig *weakRig = rig;
    // Recorded, never popped up: a real context menu would run its own loop on screen.
    context.presentMenu = ^(NSMenu *menu, NSView *view, NSPoint point) {
        (void)point;
        [weakRig.menus addObject:menu];
        [weakRig.menuViews addObject:view];
    };
    rig.content = [[SZFriendsDropdownContent alloc] initWithContext:context];
    rig.window = SZFTestHostWindow(rig.content, NSMakeSize(400, 640), NSAppearanceNameAqua);
    [rig.content.listPage applySnapshot:SZFMenuList()];
    [rig.content layoutSubtreeIfNeeded];
    return rig;
}

static SZFriendsRowView *SZFRowFor(SZFMenuRig *rig, NSString *conversationID) {
    for (SZFriendsRowView *row in rig.content.listPage.rows)
        if ([row.conversationID isEqualToString:conversationID]) return row;
    return nil;
}

static NSArray<NSDictionary *> *SZFRemovals(SZFMenuRig *rig) {
    NSMutableArray *sent = [NSMutableArray array];
    for (NSDictionary *frame in rig.transport.sent)
        if ([frame[@"type"] isEqualToString:@"remove_friend"]) [sent addObject:frame];
    return sent;
}

static void SZFReplyTo(SZFMenuRig *rig, NSDictionary *sent, BOOL ok) {
    NSDictionary *reply = ok ? @{@"type" : @"reply", @"re" : sent[@"id"], @"ok" : @YES, @"result" : @{}}
                             : @{@"type" : @"reply", @"re" : sent[@"id"], @"ok" : @NO,
                                 @"error" : @{@"code" : @"not_ready", @"message" : @"Friends isn’t running.",
                                              @"retryable" : @YES, @"details" : @{}}};
    [rig.transport deliver:reply];
}

static NSEvent *SZFMouse(NSEventType type, SZFriendsRowView *row, NSEventModifierFlags flags) {
    NSPoint point = [row convertPoint:NSMakePoint(NSMidX(row.bounds), NSMidY(row.bounds)) toView:nil];
    return [NSEvent mouseEventWithType:type location:point modifierFlags:flags timestamp:0
                          windowNumber:row.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
}

// Chooses the menu's first item as a click on it would.
static void SZFChooseFirst(NSMenu *menu) {
    if (menu.numberOfItems) [menu performActionForItemAtIndex:0];
}

static void SZFTestMenusFromSnapshot(void) {
    SZFMenuRig *rig = SZFMakeMenuRig();
    SZFriendsRowView *mei = SZFRowFor(rig, @"c_mei");
    SZFExpect(mei.menuActions.count == 1 && [mei.contextMenu.itemArray.firstObject.title isEqualToString:@"Remove"],
              @"Mei's row offers Remove: %@", mei.contextMenu.itemArray);
    SZFExpect(SZFRowFor(rig, @"c_kenji").menuActions.count == 0 && !SZFRowFor(rig, @"c_kenji").contextMenu,
              @"an action this view does not know is not offered");
    SZFExpect(!SZFRowFor(rig, @"c_daniel").contextMenu && !SZFRowFor(rig, @"c_tulip").contextMenu,
              @"an empty menu, or none at all, opens nothing");

    // Right-click opens the menu on the row, at the pointer; nothing is sent and nothing opens.
    [mei rightMouseDown:SZFMouse(NSEventTypeRightMouseDown, mei, 0)];
    SZFExpect(rig.menus.count == 1 && rig.menuViews.firstObject == mei, @"right-click opens Mei's menu");
    // Control-click is the same menu and never opens the conversation.
    [mei mouseDown:SZFMouse(NSEventTypeLeftMouseDown, mei, NSEventModifierFlagControl)];
    SZFExpect(rig.menus.count == 2 && [rig.menus.lastObject.itemArray.firstObject.title isEqualToString:@"Remove"],
              @"Control-click opens it too");
    SZFExpect(rig.content.stack.count == 1, @"neither opens the conversation: %lu pages",
              (unsigned long)rig.content.stack.count);
    // A row without a menu: right-click shows nothing of ours.
    SZFriendsRowView *daniel = SZFRowFor(rig, @"c_daniel");
    SZFExpect(![daniel showContextMenuAtPoint:NSZeroPoint] && rig.menus.count == 2, @"no menu on Daniel's row");
    SZFExpect(SZFRemovals(rig).count == 0, @"opening the menu sends nothing");
}

static void SZFTestRemoveAsksFirst(void) {
    SZFMenuRig *rig = SZFMakeMenuRig();
    SZFriendsRowView *mei = SZFRowFor(rig, @"c_mei");
    SZFChooseFirst(mei.contextMenu);
    SZFriendsConfirmView *confirm = rig.content.confirmation;
    SZFExpect(confirm != nil, @"Remove asks first");
    SZFExpect(SZFRemovals(rig).count == 0 && SZFRowFor(rig, @"c_mei"), @"nothing sent or hidden while it asks");
    SZFExpect([confirm.optionCheckbox.title isEqualToString:@"Also delete chat history"] &&
                  confirm.optionCheckbox.state == NSControlStateValueOff,
              @"the option is a checkbox, unticked: %@", confirm.optionCheckbox.title);
    [rig.content layoutSubtreeIfNeeded];
    NSRect box = [confirm convertRect:confirm.optionCheckbox.bounds fromView:confirm.optionCheckbox];
    NSRect button = [confirm convertRect:confirm.confirmButton.bounds fromView:confirm.confirmButton];
    SZFExpect(NSMaxY(box) <= NSMinY(button) && NSWidth(box) >= confirm.optionCheckbox.fittingSize.width - 0.5,
              @"the checkbox sits whole above the buttons: %@ / %@", NSStringFromRect(box), NSStringFromRect(button));
    SZFExpect(SZFTestMissedHits(confirm.optionCheckbox, rig.window.contentView) == 0, @"the whole checkbox takes clicks");
    SZFExpect(confirm.confirmButton.style == SZFriendsButtonStyleDestructiveBordered, @"Remove is drawn destructive");

    // Cancel: nothing sent, Mei stays.
    [confirm.cancelButton performClick:nil];
    SZFExpect(!rig.content.confirmation && SZFRemovals(rig).count == 0 && SZFRowFor(rig, @"c_mei"),
              @"Cancel sends nothing and keeps the row");

    // Confirmed unticked: remove_friend for Mei without delete_history, and the row goes at once.
    SZFChooseFirst(SZFRowFor(rig, @"c_mei").contextMenu);
    [rig.content.confirmation.confirmButton performClick:nil];
    NSDictionary *sent = SZFRemovals(rig).lastObject;
    SZFExpect([sent[@"fields"] isEqual:@{@"conversation_id" : @"c_mei"}], @"remove_friend for Mei only: %@",
              sent[@"fields"]);
    SZFExpect(!SZFRowFor(rig, @"c_mei") && rig.content.listPage.rows.count == 6, @"Mei's row goes at once");
    // A list from before the helper took her off cannot bring her back for a moment.
    [rig.content.listPage applySnapshot:SZFMenuList()];
    SZFExpect(!SZFRowFor(rig, @"c_mei"), @"an older list keeps her hidden");
    SZFReplyTo(rig, sent, YES);
    SZFExpect(SZFTestWaitUntil(2, ^BOOL { return SZFRemovals(rig).count == 1; }) && !SZFRowFor(rig, @"c_mei"),
              @"the helper's yes keeps her hidden");
    [rig.content.listPage applySnapshot:SZFWithout(SZFMenuList(), @"c_mei")];
    SZFExpect(!SZFRowFor(rig, @"c_mei"), @"the helper's list without her");
    // Later she asks again: the helper lists her, and so does the view.
    [rig.content.listPage applySnapshot:SZFMenuList()];
    SZFExpect(SZFRowFor(rig, @"c_mei") != nil, @"back on the list once the helper lists her again");

    // Ticked: delete_history true.
    SZFChooseFirst(SZFRowFor(rig, @"c_lena").contextMenu);
    rig.content.confirmation.optionCheckbox.state = NSControlStateValueOn;
    [rig.content.confirmation.confirmButton performClick:nil];
    sent = SZFRemovals(rig).lastObject;
    SZFExpect([sent[@"fields"] isEqual:(@{@"conversation_id" : @"c_lena", @"delete_history" : @YES})],
              @"ticked: the history goes too: %@", sent[@"fields"]);

    // No history: no checkbox, and nothing but the conversation.
    SZFChooseFirst(SZFRowFor(rig, @"c_priya").contextMenu);
    SZFExpect(rig.content.confirmation && !rig.content.confirmation.optionCheckbox, @"no history, no checkbox");
    [rig.content.confirmation.confirmButton performClick:nil];
    SZFExpect([SZFRemovals(rig).lastObject[@"fields"] isEqual:@{@"conversation_id" : @"c_priya"}],
              @"Priya: %@", SZFRemovals(rig).lastObject[@"fields"]);
}

static void SZFTestRefusedRemovalComesBack(void) {
    SZFMenuRig *rig = SZFMakeMenuRig();
    SZFChooseFirst(SZFRowFor(rig, @"c_mei").contextMenu);
    [rig.content.confirmation.confirmButton performClick:nil];
    SZFExpect(!SZFRowFor(rig, @"c_mei"), @"hidden while the helper answers");
    SZFReplyTo(rig, SZFRemovals(rig).lastObject, NO);
    SZFExpect(SZFTestWaitUntil(2, ^BOOL { return SZFRowFor(rig, @"c_mei") != nil; }), @"refused: Mei comes back");
    SZFExpect([rig.clock.spoken.lastObject containsString:@"Friends isn’t running."], @"and the reason is spoken: %@",
              rig.clock.spoken.lastObject);
    NSUInteger index = [rig.content.listPage.rows indexOfObjectPassingTest:^BOOL(SZFriendsRowView *row, NSUInteger i,
                                                                                 BOOL *stop) {
        (void)i, (void)stop;
        return [row.conversationID isEqualToString:@"c_mei"];
    }];
    SZFExpect(index == 1, @"in her place: %lu", (unsigned long)index);
}

static void SZFTestDeleteKeyAndVoiceOver(void) {
    SZFMenuRig *rig = SZFMakeMenuRig();
    SZFriendsRowView *mei = SZFRowFor(rig, @"c_mei");
    // Delete on the focused row: its first menu action, asking first.
    [mei keyDown:SZFTestKeyEvent(@"\x7f", 51, 0)];
    SZFExpect(rig.content.confirmation != nil && SZFRemovals(rig).count == 0, @"Delete asks to remove Mei");
    [rig.content.confirmation.cancelButton performClick:nil];
    [mei keyDown:SZFTestKeyEvent([NSString stringWithFormat:@"%C", (unichar)NSDeleteFunctionKey], 117,
                                 NSEventModifierFlagFunction)];
    SZFExpect(rig.content.confirmation != nil, @"Forward Delete asks too");
    [rig.content.confirmation.cancelButton performClick:nil];

    // VoiceOver: Show Menu opens it, and Remove is one of the row's actions by its label.
    SZFExpect([mei accessibilityPerformShowMenu] && rig.menuViews.lastObject == mei, @"VoiceOver's Show Menu");
    // What VoiceOver reads to list the row's actions (the old informal protocol, still how AppKit answers it).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // VoiceOver speaks to the button's cell.
    NSArray *actionNames = [mei.cell accessibilityActionNames];
    NSArray *danielNames = [SZFRowFor(rig, @"c_daniel").cell accessibilityActionNames];
#pragma clang diagnostic pop
    SZFExpect([actionNames containsObject:NSAccessibilityShowMenuAction] &&
                  [actionNames containsObject:NSAccessibilityPressAction],
              @"the row lists Show Menu beside Press: %@", actionNames);
    SZFExpect(![danielNames containsObject:NSAccessibilityShowMenuAction], @"not without a menu: %@", danielNames);
    NSUInteger menusBefore = rig.menus.count;
    SZFExpect([mei.cell accessibilityPerformShowMenu] && rig.menus.count == menusBefore + 1,
              @"Show Menu on the cell opens it");
    NSArray<NSAccessibilityCustomAction *> *custom = [mei.cell accessibilityCustomActions];
    SZFExpect(custom.count == 1 && [custom.firstObject.name isEqualToString:@"Remove"], @"custom action: %@",
              [custom valueForKey:@"name"]);
    if (custom.count) custom.firstObject.handler();
    SZFExpect(rig.content.confirmation != nil, @"the custom action asks first as well");
    [rig.content.confirmation.cancelButton performClick:nil];
    SZFExpect(![SZFRowFor(rig, @"c_daniel").cell accessibilityCustomActions].count, @"no menu, no custom actions");
}

// Rows are reused by position: a menu opened on Mei and chosen after a new list put someone else in that row does
// nothing, rather than removing whoever arrived.
static void SZFTestMenuFollowsPerson(void) {
    SZFMenuRig *rig = SZFMakeMenuRig();
    SZFriendsRowView *row = SZFRowFor(rig, @"c_mei");
    NSMenu *menu = row.contextMenu;
    [rig.content.listPage applySnapshot:SZFWithout(SZFMenuList(), @"c_lena")];
    SZFExpect([row.conversationID isEqualToString:@"c_kenji"] || ![row.conversationID isEqualToString:@"c_mei"],
              @"the row now shows someone else: %@", row.conversationID);
    SZFChooseFirst(menu);
    SZFExpect(!rig.content.confirmation && SZFRemovals(rig).count == 0, @"the stale menu does nothing");
}

static void SZFTestOptionElsewhere(void) {
    // Settings' sheet: the option is the alert's checkbox.
    NSAlert *alert = [SZFriendsSettingsSection alertForConfirm:SZFTestRemoveConfirm(@"Mei", YES)];
    SZFExpect(alert.showsSuppressionButton && [alert.suppressionButton.title isEqualToString:@"Also delete chat history"]
                  && alert.suppressionButton.state == NSControlStateValueOff,
              @"the sheet's checkbox: %@", alert.suppressionButton.title);
    SZFExpect(![SZFriendsSettingsSection alertForConfirm:SZFTestRemoveConfirm(@"Mei", NO)].showsSuppressionButton,
              @"none without an option");
    // An option for a field these views do not know is never shown.
    SZFMenuRig *rig = SZFMakeMenuRig();
    NSMutableDictionary *confirm = [SZFTestRemoveConfirm(@"Mei", YES) mutableCopy];
    confirm[@"option"] = @{@"label" : @"Also forget the key", @"field" : @"forget_key"};
    [rig.content.context performAction:SZFRemove(@"Remove", confirm) ids:@{@"conversation_id" : @"c_mei"} done:nil];
    SZFExpect(rig.content.confirmation && !rig.content.confirmation.optionCheckbox, @"unknown option hidden");
    [rig.content.confirmation.cancelButton performClick:nil];
    SZFExpect([[SZFriendsClientTransport capabilitiesForHost:[SZFTestHost new]] containsObject:@"list.menu"],
              @"the views ask for row menus");
}

void SZFTestRowMenus(void) {
    SZFTestMenusFromSnapshot();
    SZFTestRemoveAsksFirst();
    SZFTestRefusedRemovalComesBack();
    SZFTestDeleteKeyAndVoiceOver();
    SZFTestMenuFollowsPerson();
    SZFTestOptionElsewhere();
}
