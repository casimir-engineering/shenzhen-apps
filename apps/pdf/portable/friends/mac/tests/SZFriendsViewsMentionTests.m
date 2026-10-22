// Shenzhen Friends views tests: mentions (PROTOCOL.md § Mentions). The views declare `mentions`; `@` opens a picker of
// mentionable friends only while the helper announces `mentions`; a chip goes out as U+FFFC with a `mentions` entry;
// and a bubble's mention links act by kind, matched by destination and words, with every other Friends link left as
// words.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsComposerInternal.h"
#import "mac/SZFriendsItemViewsInternal.h"
#import "mac/SZFriendsMentionViews.h"

@implementation SZFTestNavigator
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _opened = [NSMutableArray array];
    return self;
}
- (void)openConversation:(NSString *)conversationID highlightMessage:(NSString *)messageID {
    (void)messageID;
    [self.opened addObject:conversationID];
}
- (void)openDetails:(NSString *)conversationID {
    (void)conversationID;
}
- (void)openProfile {
}
- (void)openJoin {
    [self.opened addObject:@"join"];
}
- (void)goBack {
}
- (void)popToList {
}
- (void)closeDropdown {
}
- (NSArray<NSDictionary *> *)pendingSendFiles {
    return nil;
}
- (void)finishSendPicker {
}
@end

SZFriendsConversationPage *SZFTestMentionPage(SZFTestHost *host, SZFTestNavigator *navigator,
                                              SZFTestTransport **transportOut, NSWindow **windowOut,
                                              NSAppearanceName appearance) {
    SZFTestTransport *transport = nil;
    SZFriendsContext *context = SZFTestContext(host, SZFTestReadyLink(&transport));
    context.navigator = navigator;
    SZFriendsConversationPage *page = [[SZFriendsConversationPage alloc] initWithContext:context
                                                                          conversationID:@"c_daniel"
                                                                        highlightMessage:nil];
    *windowOut = SZFTestHostWindow(page, NSMakeSize(400, 640), appearance);
    [page pageWillAppear];
    [page applySnapshot:SZFTestSnapshot(@"conversation-daniel-mentions")];
    [page layoutSubtreeIfNeeded];
    if (transportOut) *transportOut = transport;
    return page;
}

NSDictionary *SZFTestMentionList(void) {
    NSMutableDictionary *data = [SZFTestSnapshot(@"list") mutableCopy];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *row in data[@"rows"]) {
        NSMutableDictionary *copy = [row mutableCopy];
        BOOL request = [SZFStr(SZFDict(row, @"waiting"), @"kind") isEqualToString:@"request"];
        copy[@"mentionable"] = @(!request && !SZFBool(row, @"blocked"));
        [rows addObject:copy];
    }
    data[@"rows"] = rows;
    return data;
}

static SZFriendsMessageBody *SZFBody(SZFriendsConversationPage *page, NSString *itemID) {
    for (SZFriendsItemView *view in page.itemViews)
        if ([view.itemID isEqualToString:itemID] && [view isKindOfClass:SZFriendsMessageItemView.class])
            return ((SZFriendsMessageItemView *)view).body;
    return nil;
}

static NSTextView *SZFShownText(SZFriendsMessageBody *body) {
    return body.showsMarkdown ? body.markdownView : body.plainText;
}

BOOL SZFTestClickWords(SZFriendsConversationPage *page, NSString *itemID, NSString *words, id link) {
    NSTextView *text = SZFShownText(SZFBody(page, itemID));
    NSRange range = [text.string rangeOfString:words];
    if (!text || range.location == NSNotFound) return NO;
    [text clickedOnLink:link atIndex:range.location];
    return YES;
}

static NSDictionary *SZFLastSent(SZFTestTransport *transport, NSString *type) {
    for (NSDictionary *frame in transport.sent.reverseObjectEnumerator)
        if ([frame[@"type"] isEqualToString:type]) return frame;
    return nil;
}

// The example of `type` in fixtures/intents.jsonl that carries `field`, without its type and id.
static NSDictionary *SZFFixtureIntent(NSString *type, NSString *field) {
    NSString *path = [SZFTestFixturesDir stringByAppendingPathComponent:@"intents.jsonl"];
    for (NSString *line in [[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil]
             componentsSeparatedByString:@"\n"]) {
        NSData *bytes = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *intent = line.length ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil] : nil;
        if (![intent isKindOfClass:NSDictionary.class] || ![intent[@"type"] isEqualToString:type] || !intent[field])
            continue;
        NSMutableDictionary *fields = [intent mutableCopy];
        [fields removeObjectsForKeys:@[ @"type", @"id" ]];
        return fields;
    }
    return nil;
}

static void SZFType(NSTextView *text, NSString *typed) {
    [text insertText:typed replacementRange:text.selectedRange];
}

// The welcome fixture, with or without the helper's `mentions`.
static void SZFWelcome(SZFTestTransport *transport, BOOL mentions) {
    NSMutableDictionary *welcome = [SZFTestFrame(@"frames/welcome") mutableCopy];
    NSMutableArray *capabilities = [welcome[@"capabilities"] mutableCopy];
    if (!mentions) [capabilities removeObject:@"mentions"];
    welcome[@"capabilities"] = capabilities;
    [transport deliver:welcome];
}

static void SZFTestCapabilityAndTrigger(void) {
    SZFExpect([[SZFriendsClientTransport capabilitiesForHost:[SZFTestHost new]] containsObject:@"mentions"],
              @"the views declare mentions: they show mention links and offer @");
    SZFTestNavigator *navigator = [SZFTestNavigator new];
    SZFTestTransport *transport = nil;
    NSWindow *window = nil;
    SZFriendsConversationPage *page = SZFTestMentionPage([SZFTestHost new], navigator, &transport, &window,
                                                         NSAppearanceNameAqua);
    NSTextView *input = page.composer.textView;
    [window makeFirstResponder:input];
    SZFType(input, @"mail raph");
    SZFType(input, @"@");
    SZFExpect(page.mentionPicker == nil, @"an @ inside a word (an email address) stays text");
    input.string = @"";
    SZFWelcome(transport, NO);
    SZFType(input, @"@");
    SZFExpect(page.mentionPicker == nil, @"a helper without mentions gets no @: it would send each chip as U+FFFC");
    input.string = @"";
    SZFWelcome(transport, YES);
    SZFType(input, @"@");
    SZFExpect(page.mentionPicker != nil && page.mentionPicker.subscribed, @"@ at a word's start opens the picker");
    NSDictionary *subscribe = SZFLastSent(transport, @"subscribe");
    SZFExpect([subscribe[@"fields"][@"view"] isEqualToString:@"list"], @"its own list subscription: %@", subscribe);
    SZFExpect([page.mentionPicker.noteLabel.stringValue
                  isEqualToString:SZFTestSnapshot(@"conversation-daniel-mentions")[@"composer"][@"mention_note"]],
              @"the composer's mention_note under it: %@", page.mentionPicker.noteLabel.stringValue);
    SZFExpect(window.firstResponder == page.mentionPicker.searchField.currentEditor ||
                  window.firstResponder == page.mentionPicker.searchField,
              @"typing goes to the picker's search: %@", window.firstResponder);
    [transport deliver:@{@"type" : @"reply", @"re" : subscribe[@"id"] ?: @"", @"ok" : @YES,
                         @"result" : @{@"subscription" : @"s_70"}}];
    [transport deliver:@{@"type" : @"snapshot", @"subscription" : @"s_70", @"view" : @"list", @"rev" : @1,
                         @"data" : SZFTestMentionList()}];
    NSArray *titles = [page.mentionPicker.rows valueForKey:@"title"];
    NSArray *friends = @[ @"Mei Lin", @"Kenji Sato", @"Daniel Ortiz", @"Priya Raman", @"tulip‑canyon" ];
    SZFExpect([titles isEqualToArray:friends], @"mentionable rows only, no request and no blocked person: %@", titles);
    SZFExpect(page.mentionPicker.rowButtons.count == titles.count, @"one row each");
    page.mentionPicker.searchField.stringValue = @"mei";
    [(id<NSSearchFieldDelegate>)page.mentionPicker controlTextDidChange:[NSNotification notificationWithName:@""
                                                                                                    object:nil]];
    NSDictionary *filter = SZFLastSent(transport, @"set_filter");
    NSDictionary *wanted = @{@"subscription" : @"s_70", @"query" : @"mei"};
    SZFExpect([filter[@"fields"] isEqualToDictionary:wanted], @"the filter follows the search field: %@", filter);
    // Escape closes the picker and only it; its subscription goes with it.
    SZFExpect([page dismissInnermostPicker] && page.mentionPicker == nil, @"Escape closes the picker");
    SZFExpect([SZFLastSent(transport, @"unsubscribe")[@"fields"][@"subscription"] isEqualToString:@"s_70"],
              @"its list subscription released");
    SZFExpect([input.string isEqualToString:@"@"], @"the @ typed stays when nothing was chosen: %@", input.string);
    [page pageDidDisappear];

    // Inside a `/` command `@` means something else to the assistant: no picker.
    SZFTestAssistantHost *host = [SZFTestAssistantHost new];
    host.assistant = [SZFTestAssistant new];
    page = SZFTestMentionPage(host, navigator, &transport, &window, NSAppearanceNameAqua);
    input = page.composer.textView;
    SZFType(input, @"/");
    SZFType(input, @"@");
    SZFExpect(page.composer.commandState == SZFriendsCommandStateEditing && page.mentionPicker == nil,
              @"no picker inside a command: %ld", (long)page.composer.commandState);
    // Edit on a proposal adds its message after what was typed meanwhile, and a chip typed there stays a chip.
    SZFType(input, @"tell Daniel I'm late");
    [page.composer.command run];
    host.assistant.completion(SZFTestProposalWithText(@"Running late, sorry!", @[]).result, nil);
    SZFType(input, @"Ask ");
    [page.composer insertMentionForConversation:@"c_mei" label:@"@Mei Lin"];
    [page.composer.command editProposal];
    SZFExpect([input.string isEqualToString:@"Ask \uFFFC \n\nRunning late, sorry!"] &&
                  [[input.textStorage attribute:NSAttachmentAttributeName atIndex:4 effectiveRange:NULL]
                      isKindOfClass:SZFriendsMentionChip.class],
              @"the chip survives Edit: %@", input.string);
    [page pageDidDisappear];
}

static void SZFTestChipsGoOut(void) {
    SZFTestTransport *transport = nil;
    NSWindow *window = nil;
    SZFTestHost *host = [SZFTestHost new];
    SZFriendsConversationPage *page = SZFTestMentionPage(host, [SZFTestNavigator new], &transport, &window,
                                                         NSAppearanceNameAqua);
    NSTextView *input = page.composer.textView;
    [window makeFirstResponder:input];
    SZFType(input, @"@");
    NSDictionary *subscribe = SZFLastSent(transport, @"subscribe");
    [transport deliver:@{@"type" : @"reply", @"re" : subscribe[@"id"] ?: @"", @"ok" : @YES,
                         @"result" : @{@"subscription" : @"s_71"}}];
    [transport deliver:@{@"type" : @"snapshot", @"subscription" : @"s_71", @"view" : @"list", @"rev" : @1,
                         @"data" : SZFTestMentionList()}];
    page.mentionPicker.selectedIndex = 0;
    [page.mentionPicker chooseSelected];
    SZFExpect(page.mentionPicker == nil, @"choosing closes the picker");
    id chip = input.textStorage.length ? [input.textStorage attribute:NSAttachmentAttributeName atIndex:0
                                                       effectiveRange:NULL] : nil;
    SZFExpect([chip isKindOfClass:SZFriendsMentionChip.class] &&
                  [((SZFriendsMentionChip *)chip).conversationID isEqualToString:@"c_mei"] &&
                  [((SZFriendsMentionChip *)chip).label isEqualToString:@"@Mei Lin"],
              @"the @ became Mei's chip: %@", chip);
    SZFExpect([input.string isEqualToString:@"￼ "], @"one attachment character and a space: %@", input.string);
    SZFType(input, @"has the bracket drawing. Ask her for rev B.");
    // The draft keeps the chip: a new composer for Daniel shows it again.
    SZFriendsComposerView *again = [[SZFriendsComposerView alloc] initWithContext:page.context
                                                                  conversationID:@"c_daniel"];
    SZFExpect([[again.textView.textStorage attribute:NSAttachmentAttributeName atIndex:0 effectiveRange:NULL]
                  isKindOfClass:SZFriendsMentionChip.class],
              @"the draft keeps its chip");
    [page.composer send];
    NSDictionary *sent = SZFLastSent(transport, @"send_message")[@"fields"];
    NSDictionary *example = SZFFixtureIntent(@"send_message", @"mentions");
    SZFExpect([sent[@"text"] isEqualToString:example[@"text"]] && [sent[@"mentions"] isEqual:example[@"mentions"]] &&
                  [sent[@"conversation_id"] isEqualToString:example[@"conversation_id"]],
              @"a chip goes out as U+FFFC with a mentions entry, as intents.jsonl: %@ vs %@", sent, example);
    [page pageDidDisappear];

    // What Send makes of other text: a pasted U+FFFC stays without chips and goes with them; an older helper gets
    // each chip as its label.
    NSArray *mentions = nil;
    NSAttributedString *pasted = [[NSAttributedString alloc] initWithString:@"a￼b"];
    SZFExpect([SZFriendsComposerMessage(pasted, YES, &mentions) isEqualToString:@"a￼b"] && mentions.count == 0,
              @"no chip: U+FFFC as typed");
    NSMutableAttributedString *mixed = [[SZFriendsMentionChip chipForConversation:@"c_mei" label:@"@Mei Lin"
                                                                       appearance:[SZFriendsAppearance new]]
        mutableCopy];
    [mixed appendAttributedString:[[NSAttributedString alloc] initWithString:@" and ￼"]];
    NSString *message = SZFriendsComposerMessage(mixed, YES, &mentions);
    SZFExpect([message isEqualToString:@"￼ and "] && mentions.count == 1,
              @"with a chip, a stray U+FFFC goes, since the helper counts them: %@", message);
    message = SZFriendsComposerMessage(mixed, NO, &mentions);
    SZFExpect([message isEqualToString:@"@Mei Lin and ￼"] && mentions.count == 0,
              @"an older helper gets the name the chip shows: %@", message);
}

// The link at `words` in an item's shown text, and its foreground.
static id SZFLinkAt(SZFriendsConversationPage *page, NSString *itemID, NSString *words, NSColor **color,
                    NSString **tooltip) {
    NSTextView *text = SZFShownText(SZFBody(page, itemID));
    NSRange range = [text.string rangeOfString:words];
    if (range.location == NSNotFound) return @"(words not shown)";
    NSDictionary *attributes = [text.textStorage attributesAtIndex:range.location effectiveRange:NULL];
    if (color) *color = attributes[NSForegroundColorAttributeName];
    if (tooltip) *tooltip = attributes[NSToolTipAttributeName];
    return attributes[NSLinkAttributeName];
}

static void SZFTestBubbleLinks(void) {
    SZFTestNavigator *navigator = [SZFTestNavigator new];
    NSWindow *window = nil;
    SZFTestHost *host = [SZFTestHost new];
    SZFriendsConversationPage *page = SZFTestMentionPage(host, navigator, NULL, &window, NSAppearanceNameAqua);
    __block NSUInteger menus = 0;
    page.context.presentMenu = ^(NSMenu *menu, NSView *view, NSPoint point) {
        (void)menu, (void)view, (void)point;
        menus++;
    };
    NSColor *color = nil;
    NSString *tooltip = nil;
    id link = SZFLinkAt(page, @"m_d0a1", @"@Mei Lin", &color, &tooltip);
    SZFExpect([link isEqual:@"szfriends:mention?ref=0"] && [color isEqual:page.context.appearance.accentColor] &&
                  [tooltip isEqualToString:@"Open your chat with Mei"],
              @"a friend's mention is a link in the accent colour with its tooltip: %@ %@", link, tooltip);
    SZFExpect([SZFLinkAt(page, @"m_d0a2", @"@Leo Park", NULL, NULL) isEqual:@"szfriends:mention?ref=0"],
              @"a stranger's mention is a link");
    NSTextView *leo = SZFShownText(SZFBody(page, @"m_d0a2"));
    NSDictionary *you = [leo.textStorage attributesAtIndex:[leo.string rangeOfString:@"@Raph"].location
                                            effectiveRange:NULL];
    SZFExpect(!you[NSLinkAttributeName] && you[NSBackgroundColorAttributeName],
              @"the reader's own name is highlighted, with nothing to click: %@", you);
    NSTextView *kenji = SZFShownText(SZFBody(page, @"m_d0a4"));
    __block BOOL linked = NO;
    [kenji.textStorage enumerateAttribute:NSLinkAttributeName inRange:NSMakeRange(0, kenji.textStorage.length)
                                  options:0 usingBlock:^(id value, NSRange range, BOOL *stop) {
                                      (void)range, (void)stop;
                                      linked = linked || value;
                                  }];
    SZFExpect(!linked, @"a mention the helper left as text stays text");

    SZFExpect(SZFTestClickWords(page, @"m_d0a1", @"@Mei Lin", @"szfriends:mention?ref=0") &&
                  [navigator.opened isEqualToArray:@[ @"c_mei" ]],
              @"a friend's mention opens your chat with them: %@", navigator.opened);
    SZFTestClickWords(page, @"m_d0a2", @"@Raph", @"szfriends:mention?ref=1");
    SZFExpect(navigator.opened.count == 1 && page.mentionCard == nil && menus == 0, @"your own mention does nothing");
    SZFExpect(SZFTestClickWords(page, @"m_d0a2", @"@Leo Park", @"szfriends:mention?ref=0") && page.mentionCard,
              @"a stranger's mention opens their card");
    [page closeMentionCard];
    // A Friends link that is not one of this message's mentions does nothing, and never reaches the link menu.
    SZFTestClickWords(page, @"m_d0a1", @"has the bracket", @"szfriends:mention?ref=0");
    SZFTestClickWords(page, @"m_d0a1", @"@Mei Lin", @"szfriends:mention?ref=7");
    SZFExpect(navigator.opened.count == 1 && page.mentionCard == nil && menus == 0,
              @"other words or another destination name nobody: %@", navigator.opened);
    [page pageDidDisappear];
}

// The host's Markdown path: a message that needs the engine, whose rendering keeps every link (the test renderer).
// The mention is styled from the rendering; a link to the same destination under other words, which an escaped
// scheme can produce in a real engine, and any other Friends link become words.
static void SZFTestMarkdownMentions(void) {
    SZFTestAssistantHost *host = [SZFTestAssistantHost new];
    SZFTestNavigator *navigator = [SZFTestNavigator new];
    NSWindow *window = nil;
    SZFriendsConversationPage *page = SZFTestMentionPage(host, navigator, NULL, &window, NSAppearanceNameDarkAqua);
    NSMutableDictionary *data = [SZFTestSnapshot(@"conversation-daniel-mentions") mutableCopy];
    NSMutableArray *items = [data[@"items"] mutableCopy];
    NSMutableDictionary *item = [items[1] mutableCopy];
    item[@"text"] = @"**Note:** [@Boss](szfriends:mention?ref=0), [@Mei Lin](szfriends:mention?ref=0) or "
                    @"[home](szfriends:open?x=1)";
    item[@"segments"] = @[ @{@"text" : @"**Note:** [@Boss](szfriends:mention?ref=0), "}, @{@"text" : @"@Mei Lin",
                                                                                          @"mention" : @0},
                           @{@"text" : @" or [home](szfriends:open?x=1)"} ];
    item[@"mentions"] = @[ SZFTestSnapshot(@"conversation-daniel-mentions")[@"items"][1][@"mentions"][0] ];
    items[1] = item;
    data[@"items"] = items;
    [page applySnapshot:data];
    [page layoutSubtreeIfNeeded];
    SZFriendsMessageBody *body = SZFBody(page, @"m_d0a1");
    SZFExpect(body.showsMarkdown, @"the host renders a message with Markdown beyond its mentions");
    SZFExpect([SZFLinkAt(page, @"m_d0a1", @"@Mei Lin", NULL, NULL) isEqual:@"szfriends:mention?ref=0"] ||
                  [[SZFLinkAt(page, @"m_d0a1", @"@Mei Lin", NULL, NULL) description]
                      isEqualToString:@"szfriends:mention?ref=0"],
              @"the mention stays a link in the rendering");
    SZFExpect(!SZFLinkAt(page, @"m_d0a1", @"@Boss", NULL, NULL) && !SZFLinkAt(page, @"m_d0a1", @"home", NULL, NULL),
              @"other words to the same destination, and another Friends link, are words");
    SZFTestClickWords(page, @"m_d0a1", @"@Boss", [NSURL URLWithString:@"szfriends:mention?ref=0"]);
    SZFExpect(navigator.opened.count == 0, @"and a click on them opens nothing: %@", navigator.opened);
    SZFTestClickWords(page, @"m_d0a1", @"@Mei Lin", [NSURL URLWithString:@"szfriends:mention?ref=0"]);
    SZFExpect([navigator.opened isEqualToArray:@[ @"c_mei" ]], @"the mention opens Mei's chat: %@", navigator.opened);
    // A message whose only link is its mention needs no engine: plain segments draw the mention as a link.
    SZFExpect(!SZFBody(page, @"m_d0a3").showsMarkdown, @"a mention alone is no reason to render Markdown");
    [page pageDidDisappear];
}

void SZFTestMentions(void) {
    SZFTestCapabilityAndTrigger();
    SZFTestChipsGoOut();
    SZFTestBubbleLinks();
    SZFTestMarkdownMentions();
}
