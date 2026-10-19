// SZFriendsConversationPage: one friend's history and composer, or the request card while a request is pending.
//
// The open_conversation subscription marks the conversation read while it exists, so it is held only while this
// page is on screen (brief § Interface; PROTOCOL.md open_conversation) and released when the dropdown closes.

#import "mac/SZFriendsConversationPage.h"

#import "mac/SZFriendsArming.h"
#import "mac/SZFriendsMentionViews.h"
#import "mac/SZFriendsPromiseCopies.h"

@interface SZFriendsConversationPage () <NSSearchFieldDelegate>
@end

static NSString *SZFItemKey(NSString *kind, NSString *itemID) {
    return [NSString stringWithFormat:@"%@:%@", kind ?: @"", itemID ?: @""];
}

@implementation SZFriendsConversationPage {
    NSString *_messageID;
    NSString *_token;
    NSDictionary *_data;
    SZFriendsFlippedView *_searchBar;
    SZFriendsFlippedView *_itemsView;
    NSMutableArray<SZFriendsItemView *> *_items;
    NSScrollView *_requestScroll;
    NSString *_scrolledHighlight;
    BOOL _hasRendered;
    BOOL _loadingEarlier;
    CGFloat _heightBeforeEarlier;
    NSString *_lastSearch;
    CGFloat _laidOutWidth;          // the item width of the last layout
    BOOL _resizing;                 // this page set context.reusesMarkdownRenders and clears it once settled
    NSUInteger _resizeGeneration;
}

// How long the width must stay the same before the host renders the history at it.
static const NSTimeInterval SZFResizeSettleDelay = 0.3;

- (instancetype)initWithContext:(SZFriendsContext *)context conversationID:(NSString *)conversationID
               highlightMessage:(NSString *)messageID {
    if (!(self = [super initWithContext:context])) return nil;
    _conversationID = [conversationID copy];
    _messageID = [messageID copy];
    SZFriendsAppearance *appearance = context.appearance;
    __weak SZFriendsConversationPage *weakSelf = self;

    _header = [[SZFriendsHeaderView alloc] initWithAppearance:appearance];
    _header.backButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        [weakSelf.context.navigator goBack];
    };
    _header.titleButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        SZFriendsConversationPage *page = weakSelf;
        if (page) [page.context.navigator openDetails:page.conversationID];
    };
    [self addSubview:_header];

    _searchBar = [SZFriendsFlippedView new];
    _searchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(10, 8, 380, 28)];
    _searchField.bezelStyle = NSTextFieldRoundedBezel;
    _searchField.font = appearance.secondaryFont;
    _searchField.delegate = self;
    _searchField.sendsWholeSearchString = NO;
    [_searchBar addSubview:_searchField];
    [self addSubview:_searchBar];

    _messageList = [[SZFriendsMessageList alloc] initWithContext:context];
    _itemsView = [[SZFriendsFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 400, 100)];
    _messageList.documentView = _itemsView;
    _messageList.contentView.postsBoundsChangedNotifications = YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(listScrolled:)
                                               name:NSViewBoundsDidChangeNotification
                                             object:_messageList.contentView];
    _messageList.onDropItems = ^(NSArray<SZFriendsAttachableItem *> *items) { [weakSelf sendDroppedItems:items]; };
    [self addSubview:_messageList];
    _items = [NSMutableArray array];
    // A visible way to older history besides scrolling to the top, which not everyone discovers (or can do).
    _loadEarlierButton = [SZFriendsButton buttonWithTitle:@"" style:SZFriendsButtonStyleLink appearance:appearance];
    _loadEarlierButton.hidden = YES;
    _loadEarlierButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        [weakSelf loadEarlier];
    };
    [_itemsView addSubview:_loadEarlierButton];

    _requestCard = [[SZFriendsRequestCardView alloc] initWithContext:context];
    _requestScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 400, 400)];
    _requestScroll.drawsBackground = NO;
    _requestScroll.hasVerticalScroller = YES;
    _requestScroll.autohidesScrollers = YES;
    _requestScroll.documentView = _requestCard;
    _requestScroll.hidden = YES;
    [self addSubview:_requestScroll];

    _composer = [[SZFriendsComposerView alloc] initWithContext:context conversationID:conversationID];
    _composer.onOpenAttachPicker = ^{ [weakSelf openAttachPicker]; };
    _composer.onOpenMentionPicker = ^{ [weakSelf openMentionPicker]; };
    _composer.onHeightChange = ^{ [weakSelf composerResized]; };
    [self addSubview:_composer];
    _searchField.placeholderString = [context string:@"conversation_search_placeholder"];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_resizing) self.context.reusesMarkdownRenders = NO; // the context outlives the page
}

- (SZFriendsDropdownView)kind {
    return SZFriendsDropdownViewConversation;
}

- (NSArray<SZFriendsItemView *> *)itemViews {
    return [_items copy];
}

- (BOOL)holdsSubscription {
    return _token != nil;
}

- (NSView *)preferredFirstResponder {
    return _composer.hidden ? nil : _composer.textView;
}

#pragma mark - Subscription

- (void)pageWillAppear {
    [super pageWillAppear];
    [self subscribe];
}

- (void)pageDidDisappear {
    [super pageDidDisappear];
    if (_token) [self.context.link unsubscribe:_token];
    _token = nil;
    [self closeAttachPicker];
    [self closeMentionPicker]; // its own `list` subscription goes with it
    [self closeMentionCard];
    [self closeSearchResults];
    [self endResizing];
}

- (void)subscribe {
    if (_token) [self.context.link unsubscribe:_token];
    __weak SZFriendsConversationPage *weakSelf = self;
    _token = [self.context.link openConversation:_conversationID messageID:_messageID
                                         handler:^(NSDictionary *data, NSInteger rev) {
                                             (void)rev;
                                             [weakSelf applySnapshot:data];
                                         }];
    // The highlight belongs to the moment it was asked for; reopening the dropdown later must not jump again.
    _messageID = nil;
}

- (void)highlightMessage:(NSString *)messageID {
    _messageID = [messageID copy];
    _scrolledHighlight = nil;
    if (self.onScreen) [self subscribe];
}

#pragma mark - Snapshot

- (void)applySnapshot:(NSDictionary *)data {
    SZFriendsAppearance *appearance = self.context.appearance;
    BOOL wasAtBottom = !_hasRendered || [self isScrolledToBottom];
    CGFloat previousOrigin = _messageList.contentView.bounds.origin.y;
    CGFloat previousHeight = NSHeight(_itemsView.frame);
    _data = [data copy];

    NSDictionary *header = SZFDict(data, @"header");
    NSDictionary *route = SZFDict(header, @"route");
    [_header setTitle:SZFStr(header, @"title") subtitle:SZFStr(header, @"subtitle")
          subtitleColor:SZFriendsRouteColor(appearance, SZFStr(route, @"kind"))
              clickable:SZFBool(header, @"details_available")
     accessibilityLabel:SZFStr(header, @"accessibility_label")];
    [_header setRoute:route];
    [_header setBack:SZFDict(data, @"back") fallbackLabel:[self.context string:@"back"]];
    if (self.onBackBadgeChange) self.onBackBadgeChange();
    _searchField.placeholderString = SZFStr(data,
            @"search_placeholder") ?: [self.context string:@"conversation_search_placeholder"];

    NSDictionary *request = SZFDict(data, @"request");
    _requestScroll.hidden = request == nil;
    _messageList.hidden = request != nil;
    _searchBar.hidden = request != nil;
    if (request) [_requestCard applyRequest:request conversationID:_conversationID];

    NSDictionary *composer = SZFDict(data, @"composer");
    _composer.hidden = !SZFBool(composer, @"visible");
    [_composer applyComposer:composer];
    _messageList.acceptsDrops = SZFBool(composer, @"accepts_drops") && SZFBool(composer, @"enabled");

    [self applyItems:SZFArr(data, @"items")];
    [self refreshMentionCard];
    // Shown only with the helper's words for it (PROTOCOL.md § Static strings: never invent text).
    NSString *earlierTitle = [self.context string:@"load_earlier"];
    _loadEarlierButton.hidden = !SZFBool(data, @"has_earlier") || request != nil || earlierTitle.length == 0;
    _loadEarlierButton.title = earlierTitle;
    [self layout];
    if (_loadingEarlier && NSHeight(_itemsView.frame) > previousHeight) {
        // Earlier items were added above: keep the message under the pointer where it was.
        [self scrollListTo:previousOrigin + NSHeight(_itemsView.frame) - previousHeight];
        _loadingEarlier = NO;
    } else if (wasAtBottom) {
        [self scrollListTo:CGFLOAT_MAX];
    } else {
        [self scrollListTo:previousOrigin];
    }
    if (!SZFBool(data, @"has_earlier")) _loadingEarlier = NO; // nothing more to wait for
    _loadEarlierButton.enabled = !_loadingEarlier;
    NSString *highlight = SZFStr(data, @"highlight_item_id");
    if (highlight && ![highlight isEqualToString:_scrolledHighlight]) {
        _scrolledHighlight = highlight;
        for (SZFriendsItemView *view in _items)
            if ([view.itemID isEqualToString:highlight])
                [self scrollListTo:NSMidY(view.frame) - NSHeight(_messageList.contentView.bounds) / 2];
    }
    _hasRendered = YES;
}

- (void)applyItems:(NSArray *)items {
    // Reuse views by item id and kind, so a progress tick does not rebuild the whole history.
    NSMutableDictionary<NSString *, SZFriendsItemView *> *existing = [NSMutableDictionary dictionary];
    for (SZFriendsItemView *view in _items) existing[SZFItemKey(view.itemKind, view.itemID)] = view;
    NSMutableArray *next = [NSMutableArray array];
    for (NSDictionary *item in items) {
        NSString *key = SZFItemKey(SZFStr(item, @"kind"), SZFStr(item, @"item_id"));
        SZFriendsItemView *view = existing[key];
        if (view) {
            [existing removeObjectForKey:key];
            [view applyItem:item];
        } else {
            view = [SZFriendsItemView viewForItem:item context:self.context];
            [_itemsView addSubview:view];
        }
        [next addObject:view];
    }
    for (SZFriendsItemView *gone in existing.allValues) [gone removeFromSuperview];
    _items = next;
}

#pragma mark - Scrolling

// A chip or a second line grows the composer; the newest message must stay in view above it.
- (void)composerResized {
    BOOL atBottom = [self isScrolledToBottom];
    [self layout];
    if (atBottom) [self scrollListTo:CGFLOAT_MAX];
}

- (BOOL)isScrolledToBottom {
    NSRect visible = _messageList.contentView.bounds;
    return NSMaxY(visible) >= NSHeight(_itemsView.frame) - 4;
}

- (void)scrollListTo:(CGFloat)y {
    CGFloat maxY = MAX(0, NSHeight(_itemsView.frame) - NSHeight(_messageList.contentView.bounds));
    [_messageList.contentView scrollToPoint:NSMakePoint(0, MAX(0, MIN(maxY, y)))];
    [_messageList reflectScrolledClipView:_messageList.contentView];
}

- (void)listScrolled:(NSNotification *)notification {
    (void)notification;
    // Near the top with more history on the helper: the same as pressing Show earlier messages.
    if (_messageList.contentView.bounds.origin.y > 40) return;
    [self loadEarlier];
}

// Asks for the next 200 items once; the button stays disabled until they arrive.
- (void)loadEarlier {
    if (!_token || _loadingEarlier || !SZFBool(_data, @"has_earlier")) return;
    _loadingEarlier = YES;
    _loadEarlierButton.enabled = NO;
    [self.context.link loadEarlierForSubscription:_token];
}

#pragma mark - Drops, `#`, search

- (void)sendDroppedItems:(NSArray<SZFriendsAttachableItem *> *)items {
    NSMutableArray *files = [NSMutableArray array];
    for (SZFriendsAttachableItem *item in items) [files addObject:[SZFriendsContext fileObjectForItem:item]];
    // The helper has copied promised files by the time it answers: their copies can go now, not an hour later.
    [self.context.link sendIntent:@"send_files"
                           fields:@{@"conversation_id" : _conversationID, @"files" : files,
                                    @"client_token" : [SZFriendsContext clientToken]}
                            reply:^(NSDictionary *result, SZFriendsLinkError *error) {
                                (void)result;
                                if (!error) [SZFriendsPromiseCopies discardCopiesForItems:items after:0];
                            }];
}

- (void)openAttachPicker {
    if (_attachPicker || !self.context.host) return;
    [self closeMentionPicker];
    _attachPicker = [[SZFriendsAttachPicker alloc] initWithContext:self.context];
    __weak SZFriendsConversationPage *weakSelf = self;
    _attachPicker.onChoose = ^(SZFriendsAttachableItem *item) {
        SZFriendsConversationPage *page = weakSelf;
        if (!page) return;
        // The `#` typed to open the picker becomes the chip.
        NSTextView *text = page.composer.textView;
        NSRange selection = text.selectedRange;
        if (selection.location > 0 && [[text.string substringWithRange:NSMakeRange(selection.location - 1, 1)]
                                          isEqualToString:@"#"])
            [text insertText:@"" replacementRange:NSMakeRange(selection.location - 1, 1)];
        [page.composer addAttachments:@[ item ]];
        [page closeAttachPicker];
    };
    [self addSubview:_attachPicker];
    [_attachPicker reloadForQuery:@""];
    [self layout];
    [self.window makeFirstResponder:_attachPicker.searchField];
}

- (void)closeAttachPicker {
    if (!_attachPicker) return;
    [_attachPicker removeFromSuperview];
    _attachPicker = nil;
    if (self.window && !_composer.hidden) [self.window makeFirstResponder:_composer.textView];
}

- (void)closeSearchResults {
    [_searchResults removeFromSuperview];
    _searchResults = nil;
}

- (BOOL)dismissInnermostPicker {
    // An armed "Block?" on the request card or a transfer is the innermost thing open (SZFriendsArming.h).
    if (SZFriendsDisarmActionButtons(self)) return YES;
    if ([self dismissMentionOverlay]) return YES; // a stranger's card, then the `@` picker
    if (_attachPicker) {
        [self closeAttachPicker];
        return YES;
    }
    if ([_composer leaveCommand]) return YES; // the `/` field, before the dropdown
    if (_searchResults) {
        [self closeSearchResults];
        return YES;
    }
    return NO;
}

- (void)runSearch {
    NSString *query = _searchField.stringValue ?: @"";
    if (!query.length) {
        [self closeSearchResults];
        return;
    }
    _lastSearch = query;
    __weak SZFriendsConversationPage *weakSelf = self;
    [self.context.link sendIntent:@"search_messages" fields:@{@"query" : query, @"conversation_id" : _conversationID}
                            reply:^(NSDictionary *result, SZFriendsLinkError *error) {
                                SZFriendsConversationPage *page = weakSelf;
                                if (!page || error || ![query isEqualToString:page->_lastSearch]) return;
                                [page showSearchResult:result];
                            }];
}

- (void)showSearchResult:(NSDictionary *)result {
    if (!_searchResults) {
        _searchResults = [[SZFriendsSearchResultsView alloc] initWithContext:self.context];
        __weak SZFriendsConversationPage *weakSelf = self;
        _searchResults.onChoose = ^(NSString *conversationID, NSString *messageID) {
            SZFriendsConversationPage *page = weakSelf;
            [page closeSearchResults];
            if ([conversationID isEqualToString:page.conversationID]) [page highlightMessage:messageID];
            else [page.context.navigator openConversation:conversationID highlightMessage:messageID];
        };
        [self addSubview:_searchResults];
    }
    [_searchResults applyResult:result];
    [self layout];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    (void)notification;
    // Local search costs nothing on the network; a short pause keeps it from running on every keystroke.
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(runSearch) object:nil];
    [self performSelector:@selector(runSearch) withObject:nil afterDelay:0.25];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command {
    (void)control, (void)textView;
    if (command == @selector(insertNewline:)) {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(runSearch) object:nil];
        [self runSearch];
        return YES;
    }
    if (command == @selector(cancelOperation:)) {
        SZFriendsForwardEscape(self);
        return YES;
    }
    return NO;
}

#pragma mark - Layout

- (void)widthIsChanging {
    _resizing = YES;
    self.context.reusesMarkdownRenders = YES;
    NSUInteger generation = ++_resizeGeneration;
    __weak SZFriendsConversationPage *weakSelf = self;
    if (self.context.scheduleAfter)
        self.context.scheduleAfter(SZFResizeSettleDelay, ^{ [weakSelf widthSettled:generation]; });
}

// The width stayed the same for a moment: one pass at it. A live resize waits for its end instead, since a pause
// while the person still holds the window edge is not the width it ends at.
- (void)widthSettled:(NSUInteger)generation {
    if (generation != _resizeGeneration || self.inLiveResize) return;
    [self endResizing];
}

- (void)viewDidEndLiveResize {
    [super viewDidEndLiveResize];
    [self endResizing];
}

- (void)endResizing {
    if (!_resizing) return;
    _resizing = NO;
    _resizeGeneration++;
    self.context.reusesMarkdownRenders = NO;
    self.needsLayout = YES;
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds), height = NSHeight(self.bounds);
    _header.frame = NSMakeRect(0, 0, width, SZFriendsHeaderHeight);
    CGFloat y = SZFriendsHeaderHeight;
    if (!_searchBar.hidden) {
        _searchBar.frame = NSMakeRect(0, y, width, 44);
        _searchField.frame = NSMakeRect(10, 8, width - 20, 28);
        y += 44;
    }
    CGFloat composerHeight = _composer.hidden ? 0 : [_composer heightForWidth:width];
    _composer.frame = NSMakeRect(0, height - composerHeight, width, composerHeight);
    NSRect body = NSMakeRect(0, y, width, MAX(0, height - composerHeight - y));
    _requestScroll.frame = NSMakeRect(0, SZFriendsHeaderHeight, width, height - SZFriendsHeaderHeight);
    CGFloat cardHeight = [_requestCard heightForWidth:width];
    _requestCard.frame = NSMakeRect(0, 0, width, MAX(cardHeight, NSHeight(_requestScroll.frame)));
    _messageList.frame = body;

    CGFloat itemWidth = width - 28, itemsHeight = 12;
    CGFloat earlierHeight = _loadEarlierButton.hidden ? 0 : 28;
    if (earlierHeight) itemsHeight += earlierHeight + 10;
    NSMutableArray *heights = [NSMutableArray arrayWithCapacity:_items.count];
    for (NSUInteger index = 0; index < _items.count; index++) [heights addObject:@0];
    NSArray<SZFriendsItemView *> *items = _items;
    // While the width keeps changing (a live resize, a dropdown growing), each width used to be a whole render pass:
    // about 1.5 s of the main thread per point with a hostile history. Bubbles lay their last rendering out again
    // instead, and the host renders the history once, at the width it settles on.
    if (_laidOutWidth > 0 && itemWidth != _laidOutWidth && items.count) [self widthIsChanging];
    _laidOutWidth = itemWidth;
    // Measuring lays Markdown out: one render pass for the whole history, so the host can bound it as a whole. Newest
    // first: when a hostile history spends the allowance, what stays plain text is the oldest, out of sight above.
    [self.context markdownPass:^{
        for (NSUInteger index = items.count; index > 0; index--)
            heights[index - 1] = @([items[index - 1] heightForWidth:itemWidth]);
    }];
    for (NSNumber *itemHeight in heights) itemsHeight += itemHeight.doubleValue + 10;
    itemsHeight += 2;
    // Short histories sit at the bottom, next to the composer, as chat histories do.
    CGFloat top = MAX(12, NSHeight(body) - itemsHeight + 12);
    if (earlierHeight) {
        CGFloat earlierWidth = MIN([_loadEarlierButton fittingWidth], itemWidth);
        _loadEarlierButton.frame = NSMakeRect(floor((width - earlierWidth) / 2), top, earlierWidth, earlierHeight);
        top += earlierHeight + 10;
    }
    for (NSUInteger index = 0; index < _items.count; index++) {
        CGFloat itemHeight = [heights[index] doubleValue];
        _items[index].frame = NSMakeRect(14, top, itemWidth, itemHeight);
        top += itemHeight + 10;
    }
    _itemsView.frame = NSMakeRect(0, 0, width, MAX(NSHeight(body), top + 2));

    if (_attachPicker) {
        CGFloat pickerHeight = MIN([_attachPicker preferredHeight], MAX(120, height - composerHeight - y - 8));
        _attachPicker.frame = NSMakeRect(10, height - composerHeight - pickerHeight - 6, width - 20, pickerHeight);
    }
    if (_searchResults) {
        CGFloat resultsHeight = MIN([_searchResults preferredHeight], MAX(60, NSHeight(body) - 10));
        _searchResults.frame = NSMakeRect(10, y - 4, width - 20, resultsHeight);
    }
    [self layoutMentionOverlaysAbove:height - composerHeight];
}

@end
