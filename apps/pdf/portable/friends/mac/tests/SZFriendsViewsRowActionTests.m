// Shenzhen Friends views tests: a friend request answered from the list. Accept, Decline and Block are full-bounds
// icon buttons named after the person; Block sends only on a second click within the snapshot's seconds, and its
// armed pill turns back on the timer, on Escape and when the pointer leaves the row, never on a stale timer or a
// list refresh, and never onto the person who takes the row's place.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsArming.h"

@interface SZFRequestList : NSObject
@property(nonatomic, strong) SZFriendsDropdownContent *content;
@property(nonatomic, strong) SZFTestTransport *transport;
@property(nonatomic, strong) SZFTestClock *clock;
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic) NSInteger closes;
@end

@implementation SZFRequestList
@end

static SZFRequestList *SZFMakeRequestList(NSAppearanceName appearance) {
    SZFRequestList *list = [SZFRequestList new];
    SZFTestTransport *transport = nil;
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(&transport));
    SZFTestClock *clock = [SZFTestClock new];
    SZFTestInstallClock(context, clock);
    list.transport = transport;
    list.clock = clock;
    list.content = [[SZFriendsDropdownContent alloc] initWithContext:context];
    __weak SZFRequestList *weakList = list;
    list.content.onClose = ^{ weakList.closes++; };
    list.window = SZFTestHostWindow(list.content, NSMakeSize(400, 640), appearance);
    [list.content.listPage applySnapshot:SZFTestSnapshot(@"list")];
    [list.content layoutSubtreeIfNeeded];
    return list;
}

static void SZFClick(SZFRequestList *list, NSButton *button) {
    SZFTestClickAfter(list.clock, button, NSEvent.doubleClickInterval + 1, 1);
}

static SZFriendsRowView *SZFLena(SZFRequestList *list) {
    return list.content.listPage.rows.firstObject;
}

static SZFriendsRowActionButton *SZFButton(SZFRequestList *list, NSString *icon) {
    for (SZFriendsRowActionButton *button in SZFLena(list).actionsView.buttons)
        if ([button.rowAction[@"icon"] isEqualToString:icon]) return button;
    return nil;
}

// The answers sent so far, as "type conversation_id".
static NSArray<NSString *> *SZFAnswers(SZFRequestList *list) {
    NSMutableArray *answers = [NSMutableArray array];
    for (NSDictionary *sent in list.transport.sent) {
        NSString *type = sent[@"type"];
        if ([@[ @"accept_request", @"decline_request", @"block" ] containsObject:type])
            [answers addObject:[NSString stringWithFormat:@"%@ %@", type, sent[@"fields"][@"conversation_id"]]];
    }
    return answers;
}

static void SZFReplyToLast(SZFRequestList *list, BOOL ok) {
    NSDictionary *last = list.transport.sent.lastObject;
    NSDictionary *reply = ok ? @{@"type" : @"reply", @"re" : last[@"id"], @"ok" : @YES, @"result" : @{}}
                             : @{@"type" : @"reply", @"re" : last[@"id"], @"ok" : @NO,
                                 @"error" : @{@"code" : @"stale", @"message" : [NSNull null], @"retryable" : @NO,
                                              @"details" : @{}}};
    [list.transport deliver:reply];
}

static NSEvent *SZFExitEvent(NSWindow *window) {
    return [NSEvent enterExitEventWithType:NSEventTypeMouseExited location:NSZeroPoint modifierFlags:0 timestamp:0
                              windowNumber:window.windowNumber context:nil eventNumber:0 trackingNumber:0
                                  userData:NULL];
}

static void SZFTestRequestRowFromFixture(void) {
    SZFRequestList *list = SZFMakeRequestList(NSAppearanceNameDarkAqua);
    SZFriendsRowView *lena = SZFLena(list);
    NSArray *expected = SZFTestSnapshot(@"list")[@"rows"][0][@"actions"];
    NSArray<SZFriendsRowActionButton *> *buttons = lena.actionsView.buttons;
    SZFExpect(buttons.count == 3 && !lena.actionsView.hidden, @"Accept, Decline and Block on Lena's row: %lu",
              (unsigned long)buttons.count);
    for (NSUInteger i = 0; i < MIN(buttons.count, expected.count); i++) {
        SZFriendsRowActionButton *button = buttons[i];
        NSString *label = expected[i][@"label"];
        // Accept and Decline show their word, so a first-time reader tells Decline from Block; Block its icon.
        id word = expected[i][@"title"];
        BOOL worded = [word isKindOfClass:NSString.class];
        SZFExpect([button.rowAction isEqual:expected[i]] && [button.title isEqualToString:worded ? word : @""],
                  @"the button's word: %@", button.title);
        SZFExpect([button.accessibilityLabel isEqualToString:label] && [button.toolTip isEqualToString:label],
                  @"tooltip and accessible name name the person: %@ / %@", button.accessibilityLabel, button.toolTip);
        SZFExpect(worded ? NSHeight(button.frame) == 28 && NSWidth(button.frame) >= [button fittingWidth]
                         : NSEqualSizes(button.frame.size, NSMakeSize(28, 28)),
                  @"a 28 pt pill that fits its word, or a 28 pt round button: %@", NSStringFromSize(button.frame.size));
    }
    SZFExpect([buttons.firstObject.accessibilityLabel isEqualToString:@"Accept Lena Weber’s request"],
              @"Accept's name: %@", buttons.firstObject.accessibilityLabel);
    // In place of the time: the buttons end where the time label would, 8 pt from the row's edge.
    SZFExpect(fabs(NSMaxX(lena.actionsView.frame) - (NSWidth(lena.bounds) - 8)) < 0.5, @"right column: %@",
              NSStringFromRect(lena.actionsView.frame));
    NSArray *children = lena.accessibilityChildren;
    for (SZFriendsRowActionButton *button in buttons)
        SZFExpect([children containsObject:button], @"VoiceOver reaches %@", button.accessibilityLabel);
    for (NSUInteger i = 1; i < list.content.listPage.rows.count; i++) {
        SZFriendsRowView *row = list.content.listPage.rows[i];
        SZFExpect(!row.actionsView || row.actionsView.hidden, @"%@ has no buttons of its own", row.conversationID);
    }

    // Full-bounds hits for every button, idle and with Block armed (the pill is wider and moves its neighbours).
    for (int armed = 0; armed < 2; armed++) {
        if (armed) SZFClick(list, SZFButton(list, @"block"));
        [list.content layoutSubtreeIfNeeded];
        for (SZFriendsRowActionButton *button in lena.actionsView.buttons) {
            NSUInteger missed = SZFTestMissedHits(button, list.window.contentView);
            SZFExpect(missed == 0, @"%@ (armed %d) missed %lu hit points", button.accessibilityLabel, armed,
                      (unsigned long)missed);
        }
        SZFExpect(SZFTestMissedHits(lena, list.window.contentView) == 0, @"the row keeps its own full bounds");
    }
    SZFExpect(SZFAnswers(list).count == 0, @"arming sends nothing: %@", SZFAnswers(list));

    // An action or icon this view does not know is hidden, and the row falls back to its time.
    NSMutableDictionary *row = [SZFTestSnapshot(@"list")[@"rows"][0] mutableCopy];
    row[@"actions"] = @[
        @{@"action" : @"poke", @"icon" : @"accept", @"label" : @"Poke", @"arm" : [NSNull null]},
        @{@"action" : @"accept_request", @"icon" : @"sparkle", @"label" : @"Accept", @"arm" : [NSNull null]}
    ];
    [lena configureWithListRow:row];
    SZFExpect(lena.actionsView.hidden && lena.actionsView.buttons.count == 0, @"unknown actions and icons hidden");
}

static void SZFTestAnswers(void) {
    SZFRequestList *list = SZFMakeRequestList(NSAppearanceNameAqua);
    SZFriendsRowActionButton *accept = SZFButton(list, @"accept");
    SZFClick(list, accept);
    SZFExpect([SZFAnswers(list) isEqual:@[ @"accept_request c_lena" ]], @"Accept answers at once: %@",
              SZFAnswers(list));
    SZFClick(list, accept);
    SZFExpect(SZFAnswers(list).count == 1 && !accept.enabled, @"one answer until the reply: %@", SZFAnswers(list));
    SZFReplyToLast(list, NO);
    SZFExpect(accept.enabled, @"a failed answer leaves the buttons to try again");
    SZFClick(list, SZFButton(list, @"decline"));
    SZFExpect([SZFAnswers(list).lastObject isEqualToString:@"decline_request c_lena"], @"Decline: %@",
              SZFAnswers(list));
    SZFReplyToLast(list, YES);
    // The rest of the row still opens the request.
    [SZFLena(list) performClick:nil];
    SZFExpect(list.content.topPage.kind == SZFriendsDropdownViewConversation, @"the row opens the request card");
}

static void SZFTestTwoClickBlock(void) {
    SZFRequestList *list = SZFMakeRequestList(NSAppearanceNameAqua);
    SZFriendsRowActionButton *block = SZFButton(list, @"block");
    CGFloat idleWidth = NSWidth(SZFLena(list).actionsView.frame);
    SZFClick(list, block);
    [list.content layoutSubtreeIfNeeded];
    SZFExpect(SZFAnswers(list).count == 0 && block.armed, @"the first click arms and sends nothing: %@",
              SZFAnswers(list));
    SZFExpect([block.title isEqualToString:@"Block?"] &&
                  [block.accessibilityLabel isEqualToString:@"Click again to block Lena Weber"] &&
                  [block.toolTip isEqualToString:@"Click again to block Lena Weber"],
              @"the pill says what the next click does: %@ / %@", block.title, block.accessibilityLabel);
    SZFExpect(NSWidth(SZFLena(list).actionsView.frame) > idleWidth + 20, @"the pill is wider than the icon");
    SZFExpect([list.clock.delays isEqual:@[ @4 ]], @"armed for the snapshot's 4 seconds: %@", list.clock.delays);
    SZFClick(list, block);
    SZFExpect([SZFAnswers(list) isEqual:@[ @"block c_lena" ]] && !block.armed, @"the second click blocks: %@",
              SZFAnswers(list));

    // A list refresh keeps the pill; the same row showing someone else never inherits it.
    list = SZFMakeRequestList(NSAppearanceNameAqua);
    SZFClick(list, SZFButton(list, @"block"));
    [list.content.listPage applySnapshot:SZFTestSnapshot(@"list")];
    SZFExpect(SZFLena(list).actionsView.armed, @"an unchanged snapshot keeps the pill armed");
    NSMutableDictionary *data = [SZFTestSnapshot(@"list") mutableCopy];
    NSMutableArray *rows = [data[@"rows"] mutableCopy];
    [rows exchangeObjectAtIndex:0 withObjectAtIndex:2];
    data[@"rows"] = rows;
    [list.content.listPage applySnapshot:data];
    for (SZFriendsRowView *row in list.content.listPage.rows)
        SZFExpect(!row.actionsView.armed, @"%@ is not armed after the list reordered", row.conversationID);
    SZFExpect(SZFAnswers(list).count == 0, @"nothing sent");
}

static void SZFTestDisarming(void) {
    // The timer: after arm.seconds the pill turns back, and a later click arms again instead of blocking.
    SZFRequestList *list = SZFMakeRequestList(NSAppearanceNameAqua);
    SZFriendsRowActionButton *block = SZFButton(list, @"block");
    SZFClick(list, block);
    list.clock.blocks.lastObject();
    SZFExpect(!block.armed && block.title.length == 0 && [block.accessibilityLabel isEqualToString:@"Block Lena Weber"],
              @"the timer reverts the pill: %@", block.accessibilityLabel);
    SZFClick(list, block);
    SZFExpect(block.armed && SZFAnswers(list).count == 0, @"a click after the timeout arms again");

    // Escape: reverts the pill first and closes nothing; the next Escape closes the dropdown.
    [list.content friendsHandleEscape];
    SZFExpect(!block.armed && list.closes == 0, @"Escape turns the pill back without closing (closes %ld)",
              (long)list.closes);
    [list.content friendsHandleEscape];
    SZFExpect(list.closes == 1, @"then Escape closes the dropdown");

    // A stale timer from an earlier arming does nothing to the current pill.
    NSUInteger before = list.clock.blocks.count;
    SZFClick(list, block);
    dispatch_block_t first = list.clock.blocks.lastObject;
    [list.content friendsHandleEscape];
    SZFClick(list, block);
    dispatch_block_t second = list.clock.blocks.lastObject;
    SZFExpect(list.clock.blocks.count == before + 2, @"one timer per arming");
    first();
    SZFExpect(block.armed, @"the earlier arming's timer leaves the new pill alone");
    second();
    SZFExpect(!block.armed, @"the current arming's timer reverts it");

    // The pointer: moving between the buttons keeps the pill; leaving the row reverts it.
    SZFClick(list, block);
    [block mouseExited:SZFExitEvent(list.window)];
    SZFExpect(block.armed, @"leaving the pill for another button of the row keeps it armed");
    [SZFLena(list) mouseExited:SZFExitEvent(list.window)];
    SZFExpect(!block.armed, @"leaving the row reverts the pill");

    // The send picker fades requests: their buttons take no answer and drop an armed pill.
    SZFClick(list, block);
    [list.content.listPage setSendPickerTitle:@"Send 1 file to…"];
    SZFExpect(!block.armed && !block.enabled, @"a faded row's buttons are off");
    [list.content.listPage setSendPickerTitle:nil];
    SZFExpect(block.enabled, @"and back on when the picker ends");
    SZFExpect(SZFAnswers(list).count == 0, @"none of this sent anything: %@", SZFAnswers(list));

    // A snapshot without a usable time still times out.
    NSMutableDictionary *row = [SZFTestSnapshot(@"list")[@"rows"][0] mutableCopy];
    NSMutableArray *actions = [row[@"actions"] mutableCopy];
    NSMutableDictionary *blockAction = [actions[2] mutableCopy];
    blockAction[@"arm"] = @{@"label" : @"Block?", @"accessibility_label" : @"Click again", @"seconds" : @0};
    actions[2] = blockAction;
    row[@"actions"] = actions;
    [SZFLena(list) configureWithListRow:row];
    SZFClick(list, SZFButton(list, @"block"));
    SZFExpect([list.clock.delays.lastObject doubleValue] >= 1, @"never armed for good: %@",
              list.clock.delays.lastObject);
}

// A habitual double-click on the slash icon must not arm and block in one gesture: the confirming press is ignored
// when it is the second click of a run (clickCount 2) or lands within the double-click interval of arming.
static void SZFTestDoubleClickGuard(void) {
    SZFRequestList *list = SZFMakeRequestList(NSAppearanceNameAqua);
    SZFriendsRowActionButton *block = SZFButton(list, @"block");
    NSTimeInterval interval = NSEvent.doubleClickInterval;
    SZFClick(list, block);
    SZFTestClickAfter(list.clock, block, interval / 4, 2);
    SZFExpect(block.armed && SZFAnswers(list).count == 0, @"the double-click's second half blocks nothing: %@",
              SZFAnswers(list));
    SZFTestClickAfter(list.clock, block, interval / 4, 1);
    SZFExpect(block.armed && SZFAnswers(list).count == 0,
              @"a single click within the double-click interval of arming blocks nothing: %@", SZFAnswers(list));
    SZFTestClickAfter(list.clock, block, interval + 0.05, 3);
    SZFExpect(block.armed && SZFAnswers(list).count == 0, @"nor does a triple click's third press, however late");
    SZFTestClickAfter(list.clock, block, interval + 0.05, 1);
    SZFExpect([SZFAnswers(list) isEqual:@[ @"block c_lena" ]] && !block.armed,
              @"a separate click after the interval blocks: %@", SZFAnswers(list));

    // The decision itself, and how a press is read from an event (pure).
    SZFExpect(!SZFriendsArmAcceptsConfirm(10, 10.2, 1, 0.5) && SZFriendsArmAcceptsConfirm(10, 10.5, 1, 0.5) &&
                  !SZFriendsArmAcceptsConfirm(10, 12, 2, 0.5),
              @"interval and click count decide");
    NSEvent *second = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:NSZeroPoint modifierFlags:0
                                        timestamp:50.25 windowNumber:0 context:nil eventNumber:0 clickCount:2
                                         pressure:0];
    SZFriendsPress press = SZFriendsPressFromEvent(second, 50.3);
    SZFExpect(press.time == 50.25 && press.clickCount == 2, @"a mouse press: %f / %ld", press.time,
              (long)press.clickCount);
    press = SZFriendsPressFromEvent(second, 400);
    SZFExpect(press.time == 400 && press.clickCount == 1, @"a stale event (VoiceOver's press) reads as now, once");
    NSEvent *space = SZFTestKeyEvent(@" ", 49, 0);
    press = SZFriendsPressFromEvent(space, 0.5);
    SZFExpect(press.time == 0 && press.clickCount == 1, @"a key press has its time and one click");
    press = SZFriendsPressFromEvent(nil, 7);
    SZFExpect(press.time == 7 && press.clickCount == 1, @"no event: one press now");
}

// VoiceOver hears what the pill says: arming speaks its new label at once and marks the title changed; the timer
// turning it back marks the title changed again, silently.
static void SZFTestArmAnnouncements(void) {
    SZFRequestList *list = SZFMakeRequestList(NSAppearanceNameAqua);
    SZFriendsRowActionButton *block = SZFButton(list, @"block");
    SZFClick(list, block);
    NSString *expected = [NSString stringWithFormat:@"%@ (high): %@", NSAccessibilityAnnouncementRequestedNotification,
                                                    @"Click again to block Lena Weber"];
    SZFExpect([list.clock.spoken containsObject:expected], @"arming is announced: %@", list.clock.spoken);
    NSUInteger titleChange = [list.clock.spoken indexOfObject:NSAccessibilityTitleChangedNotification];
    SZFExpect(titleChange != NSNotFound && list.clock.notifiedElements[titleChange] == block,
              @"the armed button's title change is posted on it: %@", list.clock.spoken);
    [list.clock.spoken removeAllObjects];
    list.clock.blocks.lastObject();
    SZFExpect([list.clock.spoken isEqual:@[ NSAccessibilityTitleChangedNotification ]],
              @"turning back changes the title without speaking: %@", list.clock.spoken);
}

void SZFTestRowActions(void) {
    SZFTestRequestRowFromFixture();
    SZFTestAnswers();
    SZFTestTwoClickBlock();
    SZFTestDisarming();
    SZFTestDoubleClickGuard();
    SZFTestArmAnnouncements();
    // Offscreen renders of the armed pill, light and dark, for review beside the mockups.
    for (NSAppearanceName name in @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]) {
        SZFRequestList *list = SZFMakeRequestList(name);
        SZFClick(list, SZFButton(list, @"block"));
        [list.content layoutSubtreeIfNeeded];
        BOOL dark = [name isEqualToString:NSAppearanceNameDarkAqua];
        NSString *render = dark ? @"list-request-armed-dark" : @"list-request-armed-light";
        NSString *path = SZFTestRender(list.content, render, 2);
        SZFExpect(path != nil, @"armed render written");
    }
}
