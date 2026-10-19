// Shenzhen Friends views tests: a stranger's mention card (PROTOCOL.md § Mentions, mention_card). It opens under the
// link with the name shown literally, "Friends ID …" and the status; Add sends add_from_mention with the action's own
// fields and shows the helper's answer; Accept, Decline and Block use the card's conversation_id, Block armed; the
// card follows new snapshots and closes on Escape, a click elsewhere or when its person is no longer a stranger. The
// name and the proposal run the shared invisible-character cases. Renders in light and dark.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsArming.h"
#import "mac/SZFriendsComposerInternal.h"
#import "mac/SZFriendsMentionViews.h"

static NSDictionary *SZFLastSent(SZFTestTransport *transport, NSString *type) {
    for (NSDictionary *frame in transport.sent.reverseObjectEnumerator)
        if ([frame[@"type"] isEqualToString:type]) return frame;
    return nil;
}

static NSArray<NSString *> *SZFTitles(NSArray<SZFriendsButton *> *buttons) {
    return [buttons valueForKey:@"title"] ?: @[];
}

// Daniel's conversation again, with message m_d0a2's first mention (Leo) given `card`.
static NSDictionary *SZFWithLeoCard(NSDictionary *card, NSString *kind) {
    NSMutableDictionary *data = [SZFTestSnapshot(@"conversation-daniel-mentions") mutableCopy];
    NSMutableArray *items = [data[@"items"] mutableCopy];
    NSMutableDictionary *item = [items[2] mutableCopy];
    NSMutableArray *mentions = [item[@"mentions"] mutableCopy];
    NSMutableDictionary *leo = [mentions[0] mutableCopy];
    leo[@"card"] = card ?: (id)NSNull.null;
    leo[@"kind"] = kind;
    if ([kind isEqualToString:@"friend"]) leo[@"conversation_id"] = @"c_leo";
    mentions[0] = leo;
    item[@"mentions"] = mentions;
    items[2] = item;
    data[@"items"] = items;
    return data;
}

static void SZFTestAddFromCard(void) {
    SZFTestTransport *transport = nil;
    NSWindow *window = nil;
    SZFriendsConversationPage *page = SZFTestMentionPage([SZFTestHost new], [SZFTestNavigator new], &transport,
                                                         &window, NSAppearanceNameAqua);
    SZFTestClock *clock = [SZFTestClock new];
    SZFTestInstallClock(page.context, clock);
    SZFTestClickWords(page, @"m_d0a2", @"@Leo Park", @"szfriends:mention?ref=0");
    SZFriendsMentionCardView *card = page.mentionCard;
    [window.contentView layoutSubtreeIfNeeded];
    SZFExpect([card.titleLabel.stringValue isEqualToString:@"Leo Park"] &&
                  [card.idLabel.stringValue isEqualToString:@"Friends ID bonfire‑otter"] && card.statusLabel.hidden,
              @"the card shows the name, the ID line and no status: %@ / %@", card.titleLabel.stringValue,
              card.idLabel.stringValue);
    SZFExpect([SZFTitles(card.actionButtons) isEqualToArray:@[ @"Add" ]], @"Add: %@", SZFTitles(card.actionButtons));
    SZFExpect(NSContainsRect(page.bounds, card.frame) && NSMinY(card.frame) > NSMinY(card.superview.bounds),
              @"inside the page: %@", NSStringFromRect(card.frame));
    SZFExpect(clock.notifiedElements.count && clock.notifiedElements.lastObject == card,
              @"VoiceOver hears the card appear");
    [card.actionButtons.firstObject performClick:nil];
    NSDictionary *sent = SZFLastSent(transport, @"add_from_mention");
    NSDictionary *example = [SZFTestFrame(@"replies/add_from_mention") mutableCopy];
    NSDictionary *expected = @{@"friends_id" : @"bonfire-otter", @"identity_key" :
                                   @"tN1JdICMMlIsgspydMWcnrWDAec9jXbspfRfygj7Q6o", @"name" : @"Leo Park"};
    SZFExpect([sent[@"fields"] isEqualToDictionary:expected], @"Add sends the action's own fields: %@", sent);
    NSMutableDictionary *reply = [example mutableCopy];
    reply[@"re"] = sent[@"id"] ?: @"";
    [transport deliver:reply];
    [window.contentView layoutSubtreeIfNeeded];
    NSString *message = example[@"result"][@"message"];
    SZFExpect([card.resultLabel.stringValue isEqualToString:message] && !card.resultLabel.hidden,
              @"the helper's answer shows on the card: %@", card.resultLabel.stringValue);
    SZFExpect([clock.spoken.lastObject hasSuffix:message], @"and is spoken: %@", clock.spoken.lastObject);
    // The next snapshot says a request waits: the card follows, keeping the answer.
    [page applySnapshot:SZFWithLeoCard(@{@"title" : @"Leo Park", @"id_label" : @"Friends ID bonfire‑otter",
                                         @"status_label" : @"Request sent", @"conversation_id" : @"c_leo",
                                         @"actions" : @[]}, @"stranger")];
    [page layoutSubtreeIfNeeded];
    SZFExpect(page.mentionCard == card && [card.statusLabel.stringValue isEqualToString:@"Request sent"] &&
                  !card.actionButtons.count && [card.resultLabel.stringValue isEqualToString:message],
              @"Request sent, nothing to press: %@", card.statusLabel.stringValue);
    // Leo accepted: the mention now opens a chat, and the card has nothing left to say.
    [page applySnapshot:SZFWithLeoCard(nil, @"friend")];
    SZFExpect(page.mentionCard == nil, @"a friend's mention has no card");
    [page pageDidDisappear];
}

static void SZFTestRequestCard(void) {
    SZFTestTransport *transport = nil;
    NSWindow *window = nil;
    SZFriendsConversationPage *page = SZFTestMentionPage([SZFTestHost new], [SZFTestNavigator new], &transport,
                                                         &window, NSAppearanceNameAqua);
    SZFTestClock *clock = [SZFTestClock new];
    SZFTestInstallClock(page.context, clock);
    SZFTestClickWords(page, @"m_d0a3", @"@Lena", @"szfriends:mention?ref=0");
    SZFriendsMentionCardView *card = page.mentionCard;
    NSArray *answers = @[ @"Accept", @"Decline", @"Block Lena" ];
    SZFExpect([SZFTitles(card.actionButtons) isEqualToArray:answers] &&
                  [card.statusLabel.stringValue isEqualToString:@"Wants to be friends"],
              @"a request from them: Accept, Decline and Block: %@", SZFTitles(card.actionButtons));
    [card.actionButtons[0] performClick:nil];
    SZFExpect([SZFLastSent(transport, @"accept_request")[@"fields"] isEqualToDictionary:@{@"conversation_id" :
                                                                                               @"c_lena"}],
              @"Accept uses the card's conversation_id");
    SZFriendsActionButton *block = (SZFriendsActionButton *)card.actionButtons[2];
    SZFTestClickAfter(clock, block, 10, 1);
    SZFExpect(block.armed && !SZFLastSent(transport, @"block"), @"the first click on Block only arms it");
    SZFExpect([page dismissInnermostPicker] && !block.armed && page.mentionCard == card,
              @"Escape turns the pill back first");
    SZFTestClickAfter(clock, block, 10, 1);
    SZFTestClickAfter(clock, block, 1, 1);
    SZFExpect([SZFLastSent(transport, @"block")[@"fields"] isEqualToDictionary:@{@"conversation_id" : @"c_lena"}],
              @"a second, separate click blocks Lena");
    SZFExpect([page dismissInnermostPicker] && page.mentionCard == nil, @"then Escape closes the card");
    // Someone the reader blocked: "Blocked", nothing to press.
    SZFTestClickWords(page, @"m_d0a3", @"@Jonas", @"szfriends:mention?ref=1");
    card = page.mentionCard;
    SZFExpect([card.statusLabel.stringValue isEqualToString:@"Blocked"] && card.actionButtons.count == 0,
              @"Blocked, no actions: %@", SZFTitles(card.actionButtons));
    // A click anywhere else in the page closes the card and does nothing else.
    NSPoint outside = [page convertPoint:NSMakePoint(5, NSHeight(page.bounds) - 5) toView:page.superview];
    NSView *hit = [page hitTest:outside];
    SZFExpect(hit == card.superview, @"a click outside the card lands on its layer: %@", hit);
    [hit mouseDown:[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSZeroPoint modifierFlags:0
                                     timestamp:0 windowNumber:0 context:nil eventNumber:0 clickCount:1 pressure:1]];
    SZFExpect(page.mentionCard == nil, @"and closes it");
    [page pageDidDisappear];
}

// The card's name and the proposal show text as the shared cases say: each marked character as its code point, and
// text without any exactly as written (friends/fixtures/text/invisible-cases.json, the new mark cases included).
static void SZFTestSharedCasesOnCards(void) {
    NSString *path = [SZFTestFixturesDir stringByAppendingPathComponent:@"text/invisible-cases.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSDictionary *file = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSArray *cases = [file isKindOfClass:NSDictionary.class] ? file[@"cases"] : nil;
    SZFExpect(cases.count >= 20, @"the shared cases load: %lu", (unsigned long)cases.count);
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(NULL));
    SZFriendsMentionCardView *card = [[SZFriendsMentionCardView alloc] initWithContext:context];
    SZFriendsProposalView *proposalView = [[SZFriendsProposalView alloc] initWithContext:context];
    for (NSDictionary *entry in cases) {
        NSString *name = entry[@"name"], *text = entry[@"text"];
        NSArray<NSString *> *marked = entry[@"marked"];
        if (![text isKindOfClass:NSString.class] || ![marked isKindOfClass:NSArray.class]) continue;
        [card applyMention:@{@"url" : @"szfriends:mention?ref=0", @"kind" : @"stranger", @"label" : @"@x",
                             @"card" : @{@"title" : text, @"id_label" : @"Friends ID bonfire‑otter",
                                         @"actions" : @[]}}];
        SZFriendsAssistantResult *result = [SZFriendsAssistantResult new];
        result.outcome = SZFriendsAssistantOutcomeProposed;
        result.text = text;
        proposalView.proposal = [[SZFriendsAssistantProposal alloc] initWithResult:result chipsWhenRun:@[]
                                                                     conversationID:@"c_mei"];
        for (NSString *shown in @[ card.titleLabel.stringValue, proposalView.textView.string ]) {
            if (!marked.count)
                SZFExpect([shown isEqualToString:text.precomposedStringWithCanonicalMapping],
                          @"%@: shown exactly as written, composed", name);
            for (NSString *mark in marked)
                SZFExpect([shown containsString:mark], @"%@: %@ shows: %@", name, mark, shown);
        }
    }
}

static void SZFTestMentionRenders(void) {
    for (NSAppearanceName appearance in @[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]) {
        NSString *suffix = [appearance isEqualToString:NSAppearanceNameAqua] ? @"light" : @"dark";
        SZFTestTransport *transport = nil;
        NSWindow *window = nil;
        SZFriendsConversationPage *page = SZFTestMentionPage([SZFTestHost new], [SZFTestNavigator new], &transport,
                                                             &window, appearance);
        NSString *conversation = SZFTestRender(window.contentView,
                                               [@"conversation-daniel-mentions-" stringByAppendingString:suffix], 2);
        SZFTestClickWords(page, @"m_d0a3", @"@Lena", @"szfriends:mention?ref=0");
        [window.contentView layoutSubtreeIfNeeded];
        NSString *card = SZFTestRender(window.contentView, [@"mention-card-lena-" stringByAppendingString:suffix], 2);
        [page closeMentionCard];
        [page.composer.textView insertText:@"@" replacementRange:page.composer.textView.selectedRange];
        NSDictionary *subscribe = SZFLastSent(transport, @"subscribe");
        [transport deliver:@{@"type" : @"reply", @"re" : subscribe[@"id"] ?: @"", @"ok" : @YES,
                             @"result" : @{@"subscription" : @"s_80"}}];
        [transport deliver:@{@"type" : @"snapshot", @"subscription" : @"s_80", @"view" : @"list", @"rev" : @1,
                             @"data" : SZFTestMentionList()}];
        [window.contentView layoutSubtreeIfNeeded];
        NSString *picker = SZFTestRender(window.contentView, [@"mention-picker-" stringByAppendingString:suffix], 2);
        SZFExpect(conversation && card && picker, @"mention renders written (%@)", suffix);
        [page pageDidDisappear];
    }
}

void SZFTestMentionCards(void) {
    SZFTestAddFromCard();
    SZFTestRequestCard();
    SZFTestSharedCasesOnCards();
    SZFTestMentionRenders();
}
