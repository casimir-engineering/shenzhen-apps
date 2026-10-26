// The end of a conversation (SZFriendsHistoryFollow.h): sending takes the history to its end from wherever it was
// scrolled; scrolled up, the friend's new messages leave it where it is and a pill counts them; the pill scrolls to
// the first of them and goes once it is in view. Renders the pill in light and dark.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsConversationPage.h"

static NSMutableArray *SZFFollowItems(NSUInteger count) {
    NSDictionary *base = SZFTestSnapshot(@"conversation-mei");
    NSMutableArray *items = [base[@"items"] mutableCopy];
    NSDictionary *template = items[3]; // Mei's "Thanks. Here is my markup…"
    for (NSUInteger index = 0; index < count; index++) {
        NSMutableDictionary *item = [template mutableCopy];
        NSString *text = [NSString stringWithFormat:@"Older message %lu, long enough to wrap onto a second line in the "
                                                    @"dropdown.", (unsigned long)index];
        item[@"item_id"] = [NSString stringWithFormat:@"m_old_%lu", (unsigned long)index];
        item[@"text"] = text;
        item[@"segments"] = @[ @{@"text" : text} ];
        item[@"accessibility_label"] = [@"Mei Lin: " stringByAppendingString:text];
        [items insertObject:item atIndex:1];
    }
    return items;
}

static NSDictionary *SZFFollowItem(NSString *itemID, NSString *direction, NSString *text) {
    NSMutableDictionary *item = [SZFTestSnapshot(@"conversation-mei")[@"items"][3] mutableCopy];
    item[@"item_id"] = itemID;
    item[@"direction"] = direction;
    item[@"text"] = text;
    item[@"segments"] = @[ @{@"text" : text} ];
    item[@"accessibility_label"] = text;
    return item;
}

static void SZFFollowApply(SZFriendsConversationPage *page, NSArray *items) {
    NSMutableDictionary *data = [SZFTestSnapshot(@"conversation-mei") mutableCopy];
    data[@"items"] = items;
    [page applySnapshot:data];
    [page.window.contentView layoutSubtreeIfNeeded];
}

static BOOL SZFFollowAtEnd(SZFriendsConversationPage *page) {
    NSScrollView *list = page.messageList;
    return NSMaxY(list.contentView.bounds) >= NSHeight(list.documentView.frame) - 4;
}

static void SZFFollowScrollTo(SZFriendsConversationPage *page, CGFloat y) {
    [page.messageList.contentView scrollToPoint:NSMakePoint(0, y)];
    [page.messageList reflectScrolledClipView:page.messageList.contentView];
}

static SZFriendsButton *SZFFollowPill(SZFriendsConversationPage *page) {
    for (SZFriendsButton *button in SZFTestSubviews(page, SZFriendsButton.class))
        if ([button.identifier isEqual:@"newMessagesPill"]) return button;
    return nil;
}

void SZFTestHistoryFollow(void) {
    for (NSAppearanceName appearance in @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]) {
        SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(NULL));
        SZFriendsConversationPage *page = [[SZFriendsConversationPage alloc] initWithContext:context
                                                                              conversationID:@"c_mei"
                                                                            highlightMessage:nil];
        NSWindow *window = SZFTestHostWindow(page, NSMakeSize(400, 520), appearance);
        NSMutableArray *items = SZFFollowItems(24);
        SZFFollowApply(page, items);
        SZFriendsButton *pill = SZFFollowPill(page);
        SZFExpect(SZFFollowAtEnd(page) && pill && pill.hidden, @"a long conversation opens at its end, no pill");

        // Scrolled to the top, Mei's messages arrive below: the history stays, the pill counts them.
        SZFFollowScrollTo(page, 60);
        [items addObject:SZFFollowItem(@"m_new_1", @"in", @"First new message from Mei.")];
        SZFFollowApply(page, items);
        SZFExpect(!pill.hidden && [pill.title isEqual:@"New message ↓"] &&
                      fabs(page.messageList.contentView.bounds.origin.y - 60) < 2,
                  @"one new message below: the pill says so and nothing moves (%@)", pill.title);
        [items addObject:SZFFollowItem(@"m_new_2", @"in", @"Second.")];
        [items addObject:SZFFollowItem(@"m_new_3", @"in", @"Third.")];
        SZFFollowApply(page, items);
        SZFExpect(!pill.hidden && [pill.title isEqual:@"3 new messages ↓"], @"several are counted (%@)", pill.title);
        NSString *render = SZFTestRender(window.contentView, appearance == NSAppearanceNameAqua ?
            @"conversation-new-messages-light" : @"conversation-new-messages-dark", 2);
        SZFExpect(render != nil, @"the pill renders");

        // The pill scrolls to the first of them and goes.
        [pill performClick:nil];
        SZFTestSpin(0.6);
        NSView *first = nil;
        for (NSView *view in page.itemViews) if ([[view valueForKey:@"itemID"] isEqual:@"m_new_1"]) first = view;
        NSRect visible = page.messageList.contentView.bounds;
        SZFExpect(first && NSMinY(first.frame) >= NSMinY(visible) - 1 && NSMinY(first.frame) < NSMaxY(visible) &&
                      pill.hidden, @"the pill scrolls to the first new message and goes");

        // Sending from the top: to the end.
        SZFFollowScrollTo(page, 0);
        [items addObject:SZFFollowItem(@"m_sent", @"out", @"A reply sent from the top of the conversation.")];
        SZFFollowApply(page, items);
        SZFExpect(SZFFollowAtEnd(page) && pill.hidden, @"sending takes the conversation to its end");
        (void)window;
    }
}
