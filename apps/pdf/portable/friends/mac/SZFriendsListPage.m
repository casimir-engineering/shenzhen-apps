// SZFriendsListPage: the dropdown's root view. The title with its Beta tag, search, Friends / Nearby, rows sorted by
// the helper, the footer.

#import "mac/SZFriendsListPage.h"

#import "mac/SZFriendsDevices.h"
#import "mac/SZFriendsPromiseCopies.h"

@interface SZFriendsListPage () <NSSearchFieldDelegate, NSTextFieldDelegate>
@end

@implementation SZFriendsListPage {
    NSTextField *_titleLabel;
    SZFriendsFlippedView *_betaTag;
    NSTextField *_betaLabel;
    SZFriendsFlippedView *_tabTrack;
    SZFriendsNoticeView *_sendNotice;
    SZFriendsNoticeView *_banner;
    SZFriendsNoticeView *_namePrompt;
    SZFriendsFlippedView *_rowsView;
    NSScrollView *_nearbyScroll;
    NSTextField *_emptyTitle;
    NSTextField *_emptyBody;
    NSMutableArray<SZFriendsRowView *> *_rowViews;
    NSDictionary *_listData;
    NSDictionary *_nearbyData;
    NSString *_listToken;
    NSString *_nearbyToken;
    NSString *_sendTitle;
    NSString *_dropHint;
    BOOL _dropHintRefuses;
    BOOL _namePromptSaved;       // the card says the name was saved, and goes in a moment
    NSUInteger _namePromptRound; // which "saved" the pending hide belongs to
    // People taken off the list here (Remove): hidden at once, before the helper's next list. Sent and not yet
    // answered, and whether a list without them came meanwhile; answered yes, until a list without them comes.
    NSMutableSet<NSString *> *_leaving;
    NSMutableSet<NSString *> *_leavingSeenGone;
    NSMutableSet<NSString *> *_left;
}

- (instancetype)initWithContext:(SZFriendsContext *)context {
    if (!(self = [super initWithContext:context])) return nil;
    SZFriendsAppearance *appearance = context.appearance;
    // Friends is a beta: its title, with a small tag that says so (welcome.strings button_label and beta). Without
    // those strings (an older helper) neither shows and the search field moves up.
    _titleLabel = SZFriendsLabel(@"", appearance.headerFont, appearance.primaryTextColor);
    _titleLabel.maximumNumberOfLines = 1;
    [self addSubview:_titleLabel];
    _betaTag = [[SZFriendsFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 36, 16)];
    _betaTag.fillColor = [appearance.accentColor colorWithAlphaComponent:0.14];
    _betaTag.cornerRadius = 4;
    _betaLabel = SZFriendsLabel(@"", [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold], appearance.accentColor);
    _betaLabel.maximumNumberOfLines = 1;
    _betaLabel.alignment = NSTextAlignmentCenter;
    [_betaTag addSubview:_betaLabel];
    [self addSubview:_betaTag];
    _searchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(12, 12, 376, 28)];
    // The other panels' search field: a rounded native field at 13 pt that searches as you type.
    _searchField.bezelStyle = NSTextFieldRoundedBezel;
    _searchField.font = appearance.bodyFont;
    _searchField.sendsSearchStringImmediately = YES;
    _searchField.focusRingType = NSFocusRingTypeExterior;
    _searchField.delegate = self;
    [self addSubview:_searchField];

    _tabTrack = [[SZFriendsFlippedView alloc] initWithFrame:NSMakeRect(12, 48, 376, 30)];
    // A track a step darker than the cards in light mode, so the white selected tab stands out from it (white on
    // the field colour #f4f4f5 could not be told apart; the owner's report of 2026-10-20).
    _tabTrack.fillColor = SZFriendsDynamicColor(0xe4e4e7, 0x1f1f23);
    _tabTrack.cornerRadius = 8;
    [self addSubview:_tabTrack];
    __weak SZFriendsListPage *weakSelf = self;
    _friendsTab = [SZFriendsButton buttonWithTitle:@"" style:SZFriendsButtonStylePlain appearance:appearance];
    _friendsTab.onPress = ^(SZFriendsButton *button) {
        (void)button;
        [weakSelf showNearby:NO];
    };
    _nearbyTab = [SZFriendsButton buttonWithTitle:@"" style:SZFriendsButtonStylePlain appearance:appearance];
    _nearbyTab.onPress = ^(SZFriendsButton *button) {
        (void)button;
        [weakSelf showNearby:YES];
    };
    // The selected tab is raised and neutral, like a segmented control (blue already means "waiting for you"): a
    // lighter pill with an outline, and its title in semibold.
    for (SZFriendsButton *tab in @[ _friendsTab, _nearbyTab ]) {
        tab.selectedFillColor = SZFriendsDynamicColor(0xffffff, 0x3a3f4f);
        tab.selectedStrokeColor = SZFriendsDynamicColor(0xc4c6cc, 0x555a68);
        [_tabTrack addSubview:tab];
    }

    _sendNotice = [[SZFriendsNoticeView alloc] initWithContext:context];
    _sendNotice.strokeColor = [appearance.accentColor colorWithAlphaComponent:0.7];
    _sendNotice.dashedStroke = YES;
    _sendNotice.cornerRadius = 8;
    _sendNotice.padding = 10;
    _sendNotice.bodyLabel.textColor = appearance.primaryTextColor;
    _banner = [[SZFriendsNoticeView alloc] initWithContext:context];
    _banner.fillColor = [appearance.warningColor colorWithAlphaComponent:0.14];
    _banner.buttonTrailing = YES;
    _banner.padding = 10;
    _banner.bodyLabel.textColor = appearance.primaryTextColor;
    _namePrompt = [[SZFriendsNoticeView alloc] initWithContext:context];
    _namePrompt.fillColor = appearance.fieldBackgroundColor;
    _namePrompt.padding = 10;
    _devicesView = [[SZFriendsListDevicesView alloc] initWithContext:context];
    _devicesView.onJoin = ^{ [weakSelf.context.navigator openJoin]; };
    for (NSView *view in @[ _sendNotice, _banner, _devicesView, _namePrompt ]) {
        view.hidden = YES;
        [self addSubview:view];
    }

    _rowsView = [[SZFriendsFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 400, 100)];
    _scrollView = [self scrollViewWithDocument:_rowsView];
    _emptyTitle = SZFriendsLabel(@"", SZFriendsSemibold(appearance.bodyFont), appearance.primaryTextColor);
    _emptyBody = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    _emptyTitle.alignment = _emptyBody.alignment = NSTextAlignmentCenter;
    [_rowsView addSubview:_emptyTitle];
    [_rowsView addSubview:_emptyBody];
    _rowViews = [NSMutableArray array];

    _nearbyPane = [[SZFriendsNearbyPane alloc] initWithContext:context];
    _nearbyPane.onOpenConversation = ^(NSString *conversationID) {
        [weakSelf.context.navigator openConversation:conversationID highlightMessage:nil];
    };
    _nearbyScroll = [self scrollViewWithDocument:_nearbyPane];
    _nearbyScroll.hidden = YES;

    _footer = [[SZFriendsFooterView alloc] initWithContext:context];
    _footer.onAddByID = ^{ [weakSelf.context.navigator openProfile]; };
    [self addSubview:_footer];
    [self applyStaticStrings];
    return self;
}

- (NSScrollView *)scrollViewWithDocument:(NSView *)document {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 90, 400, 300)];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSNoBorder;
    scroll.scrollerStyle = NSScrollerStyleOverlay;
    scroll.documentView = document;
    [self addSubview:scroll];
    return scroll;
}

- (SZFriendsDropdownView)kind {
    return self.showingNearby ? SZFriendsDropdownViewNearby : SZFriendsDropdownViewList;
}

- (NSArray<SZFriendsRowView *> *)rows {
    return [_rowViews copy];
}

- (NSTextField *)namePromptField {
    return self.namePromptEditor.field;
}

- (SZFriendsNameEditor *)namePromptEditor {
    return _namePrompt.hidden || _namePromptSaved ? nil : _namePrompt.nameEditor;
}

- (SZFriendsButton *)bannerButton {
    return _banner.hidden ? nil : _banner.button;
}

- (NSView *)betaTagView {
    return _betaTag.hidden ? nil : _betaTag;
}

- (NSView *)preferredFirstResponder {
    return _searchField;
}

// The welcome's strings arrive after the page may already exist; re-read them whenever a snapshot lands.
- (void)applyStaticStrings {
    NSString *title = [self.context string:@"button_label"], *beta = [self.context string:@"beta"];
    _titleLabel.stringValue = title ?: @"";
    _titleLabel.hidden = !title.length;
    _betaLabel.stringValue = beta ?: @"";
    _betaTag.hidden = !title.length || !beta.length;
    _betaTag.accessibilityElement = NO;
    _titleLabel.accessibilityLabel = beta.length && title.length ? [NSString stringWithFormat:@"%@, %@", title, beta]
                                                                 : nil;
    _searchField.placeholderString = [self.context string:@"search_placeholder"];
    _friendsTab.title = [self.context string:@"tab_friends"];
    _nearbyTab.title = [self.context string:@"tab_nearby"];
    _friendsTab.selectedLook = !_showingNearby;
    _nearbyTab.selectedLook = _showingNearby;
    NSFont *plain = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    NSFont *bold = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    _friendsTab.font = _showingNearby ? plain : bold;
    _nearbyTab.font = _showingNearby ? bold : plain;
    // Tabs read as a radio group; the value is the selection state, so no word of ours is spoken.
    for (SZFriendsButton *tab in @[ _friendsTab, _nearbyTab ]) {
        tab.accessibilityRole = NSAccessibilityRadioButtonRole;
        tab.accessibilityValue = @(tab.selectedLook);
    }
}

#pragma mark - Subscriptions

- (void)pageWillAppear {
    [super pageWillAppear];
    [self subscribeVisibleTab];
}

- (void)pageDidDisappear {
    [super pageDidDisappear];
    if (_listToken) [self.context.link unsubscribe:_listToken];
    if (_nearbyToken) [self.context.link unsubscribe:_nearbyToken];
    _listToken = _nearbyToken = nil;
    [_footer cancelEditingName];
}

- (void)subscribeVisibleTab {
    if (!self.onScreen) return;
    __weak SZFriendsListPage *weakSelf = self;
    SZFriendsHelperLink *link = self.context.link;
    if (_showingNearby && !_nearbyToken) {
        _nearbyToken = [link subscribeToView:@"nearby" params:nil handler:^(NSDictionary *data, NSInteger rev) {
            (void)rev;
            [weakSelf applyNearbySnapshot:data];
        }];
        if (_searchField.stringValue.length) [link setFilter:_searchField.stringValue forSubscription:_nearbyToken];
    }
    // The list stays subscribed on both tabs: the name prompt and the banner above the tabs come from it, and a name
    // saved on the Nearby tab must take the prompt away there too (the owner's report of 2026-10-20: the card stayed
    // after Return, because Nearby had dropped the list and nothing told the card the name was saved).
    if (!_listToken) {
        _listToken = [link subscribeToView:@"list" params:nil handler:^(NSDictionary *data, NSInteger rev) {
            (void)rev;
            [weakSelf applySnapshot:data];
        }];
        if (_searchField.stringValue.length) [link setFilter:_searchField.stringValue forSubscription:_listToken];
    }
    // Nearby counts down every second; nothing should keep that running while the Friends tab shows.
    if (!_showingNearby && _nearbyToken) {
        [link unsubscribe:_nearbyToken];
        _nearbyToken = nil;
    }
}

- (void)showNearby:(BOOL)nearby {
    _showingNearby = nearby;
    _scrollView.hidden = nearby;
    _nearbyScroll.hidden = !nearby;
    [self applyStaticStrings];
    [self subscribeVisibleTab];
    NSDictionary *visible = nearby ? _nearbyData : _listData;
    [_footer applyFooter:SZFDict(visible ?: (_listData ?: _nearbyData), @"footer")];
    [self setNeedsLayout:YES];
}

#pragma mark - Snapshots

- (void)applySnapshot:(NSDictionary *)data {
    _listData = [data copy];
    [self applyStaticStrings];
    __weak SZFriendsListPage *weakSelf = self;

    NSDictionary *banner = SZFDict(data, @"banner");
    _banner.hidden = banner == nil;
    _banner.bodyLabel.stringValue = SZFStr(banner, @"text") ?: @"";
    NSString *bannerKind = SZFStr(banner, @"kind");
    [_banner setAction:SZFDict(banner, @"action") onPress:^(NSDictionary *action) {
        [weakSelf.context performAction:action ids:bannerKind ? @{@"kind" : bannerKind} : nil done:nil];
    }];

    NSDictionary *prompt = SZFDict(data, @"name_prompt");
    [self applyNamePrompt:prompt];
    [self applyDevices:data prompt:prompt];

    [self applyRows:SZFArr(data, @"rows")];
    NSDictionary *empty = SZFDict(data, @"empty");
    _emptyTitle.stringValue = SZFStr(empty, @"title") ?: @"";
    _emptyBody.stringValue = SZFStr(empty, @"body") ?: @"";
    if (!_showingNearby || !_nearbyData) [_footer applyFooter:SZFDict(data, @"footer")];
    [self setNeedsLayout:YES];
    self.needsDisplay = YES;
}

// The snapshot's rows, less anyone just removed here: a removal shows at once, and a list from before the helper
// took them off cannot bring them back for a moment.
- (void)applyRows:(NSArray *)snapshotRows {
    NSMutableSet<NSString *> *listed = [NSMutableSet set];
    for (NSDictionary *row in snapshotRows) {
        NSString *conversationID = SZFStr(row, @"conversation_id");
        if (conversationID) [listed addObject:conversationID];
    }
    for (NSString *conversationID in _leaving)
        if (![listed containsObject:conversationID]) [_leavingSeenGone addObject:conversationID];
    [_left intersectSet:listed]; // gone from the helper's list: from now on the helper's list decides
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *row in snapshotRows) {
        NSString *conversationID = SZFStr(row, @"conversation_id");
        if (conversationID && ([_leaving containsObject:conversationID] || [_left containsObject:conversationID]))
            continue;
        [rows addObject:row];
    }
    __weak SZFriendsListPage *weakSelf = self;
    while (_rowViews.count > rows.count) {
        [_rowViews.lastObject removeFromSuperview];
        [_rowViews removeLastObject];
    }
    while (_rowViews.count < rows.count) {
        SZFriendsRowView *row = [[SZFriendsRowView alloc] initWithContext:self.context];
        row.onPress = ^(SZFriendsButton *button) { [weakSelf rowPressed:(SZFriendsRowView *)button]; };
        row.onDropItems = ^(SZFriendsRowView *target, NSString *conversationID,
                            NSArray<SZFriendsAttachableItem *> *items) {
            (void)target;
            [weakSelf sendItems:items toConversation:conversationID];
        };
        row.onRowAction = ^(SZFriendsRowView *target, NSDictionary *action) {
            [weakSelf performRowAction:action onRow:target];
        };
        row.onMenuAction = ^(SZFriendsRowView *target, NSDictionary *action, NSString *conversationID) {
            (void)target;
            [weakSelf performMenuAction:action conversation:conversationID];
        };
        [_rowViews addObject:row];
        [_rowsView addSubview:row];
    }
    [rows enumerateObjectsUsingBlock:^(NSDictionary *row, NSUInteger index, BOOL *stop) {
        (void)stop;
        [self->_rowViews[index] configureWithListRow:row];
    }];
    [self dimRowsThatRefuseFiles];
    [self setNeedsLayout:YES];
}

// The card that asks for a name until one is saved. What is typed survives every snapshot. When the helper confirms
// the name, the card says so where the person typed it (welcome.strings name_saved, with a check) and goes a moment
// later; the helper's next snapshot (no name_prompt) does not cut that short.
- (void)applyNamePrompt:(NSDictionary *)prompt {
    if (_namePromptSaved) {
        if (!prompt) return;
        [self endNameSaved]; // asked again meanwhile (Reset Friends): the card asks
    }
    // The snapshot without the card can come before set_name's reply: the card waits for the reply to say "Saved".
    if (!prompt && !_namePrompt.hidden && _namePrompt.nameEditor.saving) return;
    BOOL wasHidden = _namePrompt.hidden;
    _namePrompt.hidden = prompt == nil;
    _namePrompt.titleLabel.stringValue = SZFStr(prompt, @"title") ?: @"";
    // The card shows on first run, so it also says Friends is a beta (welcome.strings beta_note), under its own note.
    NSString *note = SZFStr(prompt, @"note"), *betaNote = [self.context string:@"beta_note"];
    if (prompt && betaNote.length) note = note.length ? [NSString stringWithFormat:@"%@\n%@", note, betaNote] : betaNote;
    _namePrompt.noteLabel.stringValue = note ?: @"";
    if (prompt && !_namePrompt.nameEditor) {
        SZFriendsNameEditor *editor = [[SZFriendsNameEditor alloc] initWithContext:self.context
                                                                              font:self.context.appearance.bodyFont];
        __weak SZFriendsListPage *weakSelf = self;
        editor.onSaved = ^(NSString *name) { [weakSelf showNameSaved:name]; };
        editor.onLayoutChange = ^{ [weakSelf setNeedsLayout:YES]; };
        _namePrompt.nameEditor = editor;
    }
    if (prompt && wasHidden && !_namePrompt.nameEditor.saving) [_namePrompt.nameEditor reset];
    [_namePrompt.nameEditor reloadStrings];
    _namePrompt.nameEditor.field.placeholderString = SZFStr(prompt, @"placeholder");
    _namePrompt.nameEditor.field.accessibilityLabel = SZFStr(prompt, @"title");
}

- (void)showNameSaved:(NSString *)name {
    SZFriendsNameEditor *editor = _namePrompt.nameEditor;
    // The field goes, so the typing goes to search: the next thing a person does in the list. The field let go of
    // the typing while it rested for the helper's answer, which left nothing focused.
    NSResponder *focus = self.window.firstResponder;
    if (editor.field.currentEditor || !focus || focus == self.window) [self.window makeFirstResponder:_searchField];
    [editor reset];
    NSString *saved = [[self.context string:@"name_saved"] stringByReplacingOccurrencesOfString:@"{name}"
                                                                                     withString:name ?: @""];
    if (![self.context string:@"name_saved"].length) {
        _namePrompt.hidden = YES;
        [self setNeedsLayout:YES];
        return;
    }
    _namePromptSaved = YES;
    _namePrompt.hidden = NO;
    NSUInteger round = ++_namePromptRound;
    _namePrompt.titleLabel.stringValue = saved;
    _namePrompt.noteLabel.stringValue = @"";
    _namePrompt.nameEditor.hidden = YES;
    _namePrompt.secondaryButton = nil;
    _namePrompt.iconDrawer = ^(NSRect rect, NSColor *color) { SZFriendsDrawCheckIcon(rect, color); };
    _namePrompt.iconColor = self.context.appearance.successColor;
    _namePrompt.needsDisplay = YES;
    [self.context announce:saved];
    [self setNeedsLayout:YES];
    __weak SZFriendsListPage *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SZFriendsNameSavedSeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       SZFriendsListPage *page = weakSelf;
                       if (!page || !page->_namePromptSaved || page->_namePromptRound != round) return;
                       [page endNameSaved];
                       page->_namePrompt.hidden = YES;
                       [page setNeedsLayout:YES];
                   });
}

- (void)endNameSaved {
    _namePromptSaved = NO;
    _namePromptRound++;
    _namePrompt.iconDrawer = nil;
    _namePrompt.iconColor = nil;
    _namePrompt.nameEditor.hidden = NO;
    _namePrompt.needsDisplay = YES;
}

- (BOOL)showingNameSaved {
    return _namePromptSaved && !_namePrompt.hidden;
}

- (void)applyNearbySnapshot:(NSDictionary *)data {
    _nearbyData = [data copy];
    [self applyStaticStrings];
    [_nearbyPane applyNearby:data];
    if (_showingNearby) [_footer applyFooter:SZFDict(data, @"footer")];
    [self setNeedsLayout:YES];
}

- (void)setDropHint:(NSString *)hint {
    [self setDropHint:hint refusing:NO];
}

- (void)setDropHint:(NSString *)hint refusing:(BOOL)refusing {
    _dropHint = [hint copy];
    _dropHintRefuses = refusing && hint.length;
    [self updateSendNotice];
}

- (void)setSendPickerTitle:(NSString *)title {
    [self setSendPickerTitle:title toolTip:nil];
}

- (void)setSendPickerTitle:(NSString *)title toolTip:(NSString *)toolTip {
    _sendTitle = [title copy];
    _sendNotice.toolTip = title ? toolTip : nil;
    [self updateSendNotice];
}

- (void)setSendPickerLinkButton:(SZFriendsButton *)button {
    _sendNotice.secondaryButton = _sendTitle ? button : nil;
    [self setNeedsLayout:YES];
}

- (SZFriendsButton *)sendPickerLinkButton {
    return _sendNotice.hidden ? nil : _sendNotice.secondaryButton;
}

- (SZFriendsButton *)sendPickerCancelButton {
    return _sendNotice.hidden ? nil : _sendNotice.button;
}

// Whenever files are on their way in (dragged over the dropdown, or waiting for "Send 2 files to…"), a row that
// refuses them (a request, a blocked person) fades, so it never looks like a place to drop or click.
- (void)dimRowsThatRefuseFiles {
    BOOL sending = _sendTitle != nil || _dropHint != nil;
    BOOL refusalShown = _dropHintRefuses && !_sendTitle;
    for (SZFriendsRowView *row in _rowViews) {
        row.dimmed = sending && !row.dropLabel;
        row.dropRefusalShownAbove = refusalShown;
    }
}

- (void)updateSendNotice {
    [self dimRowsThatRefuseFiles];
    NSString *text = _sendTitle ?: _dropHint;
    _sendNotice.hidden = text.length == 0;
    _sendNotice.bodyLabel.stringValue = text ?: @"";
    _sendNotice.bodyLabel.font = _sendTitle ? SZFriendsSemibold(self.context.appearance.bodyFont)
                                            : self.context.appearance.secondaryFont;
    // A way out for the mouse, not only Escape: the static Cancel, at the strip's trailing edge.
    NSString *cancel = [self.context string:@"cancel"];
    if (_sendTitle && cancel.length && !_sendNotice.button) {
        SZFriendsButton *button = [SZFriendsButton buttonWithTitle:cancel style:SZFriendsButtonStyleLink
                                                        appearance:self.context.appearance];
        __weak SZFriendsListPage *weakSelf = self;
        button.onPress = ^(SZFriendsButton *pressed) {
            (void)pressed;
            [weakSelf.context.navigator finishSendPicker];
        };
        _sendNotice.button = button;
        _sendNotice.buttonTrailing = YES;
    } else if (!_sendTitle) {
        _sendNotice.button = nil;
        _sendNotice.secondaryButton = nil;
    }
    [self setNeedsLayout:YES];
}

#pragma mark - Several computers

// The name prompt's "Use my existing profile", the removed notice and the join rows (PROTOCOL.md § Devices). A removed
// computer can add nobody and look for nobody, so Add by ID and the Nearby tab go.
- (void)applyDevices:(NSDictionary *)data prompt:(NSDictionary *)prompt {
    [_devicesView applyList:data];
    [_devicesView offerJoin:SZFStr(prompt, @"join_label") inPrompt:_namePrompt];
    _tabTrack.hidden = _devicesView.removed;
    _footer.offersAdding = !_devicesView.removed;
    if (_devicesView.removed && _showingNearby) [self showNearby:NO];
}

- (SZFriendsButton *)joinButton {
    return _namePrompt.hidden ? nil : _namePrompt.secondaryButton;
}

#pragma mark - Actions

- (void)rowPressed:(SZFriendsRowView *)row {
    if (!row.conversationID) return;
    NSArray *files = [self.context.navigator pendingSendFiles];
    if (files) {
        // The send picker: the next friend clicked receives one offer per file. Rows that refuse drops (requests,
        // blocked people) cannot receive files this way either.
        if (!row.dropLabel) return;
        [self.context.link sendIntent:@"send_files"
                               fields:@{@"conversation_id" : row.conversationID, @"files" : files,
                                        @"client_token" : [SZFriendsContext clientToken]}
                                reply:^(NSDictionary *result, SZFriendsLinkError *error) {
                                    (void)result;
                                    // The helper copied them before it answered (SZFriendsPromiseCopies.h).
                                    if (!error) [SZFriendsPromiseCopies discardCopiesForFileObjects:files];
                                }];
        [self.context.navigator finishSendPicker];
        [self.context.navigator openConversation:row.conversationID highlightMessage:nil];
        return;
    }
    [self.context.navigator openConversation:row.conversationID highlightMessage:nil];
}

- (void)sendItems:(NSArray<SZFriendsAttachableItem *> *)items toConversation:(NSString *)conversationID {
    if (!conversationID.length || !items.count) return;
    NSMutableArray *files = [NSMutableArray array];
    for (SZFriendsAttachableItem *item in items) [files addObject:[SZFriendsContext fileObjectForItem:item]];
    [self.context.link sendIntent:@"send_files"
                           fields:@{@"conversation_id" : conversationID, @"files" : files,
                                    @"client_token" : [SZFriendsContext clientToken]}
                            reply:^(NSDictionary *result, SZFriendsLinkError *error) {
                                (void)result;
                                if (!error) [SZFriendsPromiseCopies discardCopiesForItems:items after:0];
                            }];
    [self setDropHint:nil];
}

// Accept, Decline or Block from the row: the intent with the row's conversation. The buttons rest until the reply,
// so a double click sends one answer; a success brings the new list (without the buttons) before its reply.
- (void)performRowAction:(NSDictionary *)action onRow:(SZFriendsRowView *)row {
    NSString *conversationID = row.conversationID;
    if (!conversationID) return;
    SZFriendsRowActionsView *actions = row.actionsView;
    actions.busy = YES;
    [self.context performAction:action ids:@{@"conversation_id" : conversationID}
                           done:^(SZFriendsLinkError *error) {
                               (void)error;
                               if ([row.conversationID isEqualToString:conversationID]) actions.busy = NO;
                           }];
}

// A row's menu (Remove): asked first as the action says; once confirmed the row goes at once, and comes back with
// the helper's reason if the helper refuses.
- (void)performMenuAction:(NSDictionary *)action conversation:(NSString *)conversationID {
    if (!conversationID.length) return;
    __weak SZFriendsListPage *weakSelf = self;
    [self.context performAction:action ids:@{@"conversation_id" : conversationID}
        sending:^{ [weakSelf hidePerson:conversationID]; }
        reply:^(NSDictionary *result, SZFriendsLinkError *error) {
            (void)result;
            [weakSelf person:conversationID leftWithError:error];
        }];
}

- (void)hidePerson:(NSString *)conversationID {
    if (!_leaving) {
        _leaving = [NSMutableSet set];
        _leavingSeenGone = [NSMutableSet set];
        _left = [NSMutableSet set];
    }
    [_leaving addObject:conversationID];
    [_leavingSeenGone removeObject:conversationID];
    [self applyRows:SZFArr(_listData, @"rows")];
}

- (void)person:(NSString *)conversationID leftWithError:(SZFriendsLinkError *)error {
    if (![_leaving containsObject:conversationID]) return;
    [_leaving removeObject:conversationID];
    BOOL seenGone = [_leavingSeenGone containsObject:conversationID];
    [_leavingSeenGone removeObject:conversationID];
    if (!error && !seenGone) [_left addObject:conversationID];
    [self applyRows:SZFArr(_listData, @"rows")];
    if (error) [self.context announce:error.message];
}

// Escape turns an armed "Block?" back first: it is the innermost thing open, and closing the dropdown under it
// would leave the person unsure whether they blocked someone.
- (BOOL)dismissInnermostPicker {
    for (SZFriendsRowView *row in _rowViews)
        if ([row.actionsView disarm]) return YES;
    if (SZFriendsDisarmActionButtons(_devicesView)) return YES; // a join row's "Deny?"
    if ([_footer cancelEditingName]) return YES;
    return !_namePrompt.hidden && !_namePromptSaved && [_namePrompt.nameEditor cancelTyping];
}

#pragma mark - Text fields

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object != _searchField) return;
    for (NSString *token in @[ _listToken ?: @"", _nearbyToken ?: @"" ])
        if (token.length) [self.context.link setFilter:_searchField.stringValue forSubscription:token];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command {
    (void)textView;
    if (command == @selector(cancelOperation:)) {
        SZFriendsForwardEscape(self);
        return YES;
    }
    (void)control;
    return NO;
}

#pragma mark - Layout

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds), height = NSHeight(self.bounds);
    CGFloat top = 12;
    if (!_titleLabel.hidden) {
        // One line at its natural width: a wrapping label's intrinsic width can be a few points short and cut it.
        NSSize titleSize = [_titleLabel.cell cellSizeForBounds:NSMakeRect(0, 0, CGFLOAT_MAX, CGFLOAT_MAX)];
        CGFloat titleWidth = MIN(ceil(titleSize.width), width - 24 - (_betaTag.hidden ? 0 : 48));
        _titleLabel.frame = NSMakeRect(12, 10, titleWidth, ceil(titleSize.height));
        if (!_betaTag.hidden) {
            NSSize betaSize = [_betaLabel.cell cellSizeForBounds:NSMakeRect(0, 0, CGFLOAT_MAX, CGFLOAT_MAX)];
            CGFloat tagWidth = ceil(betaSize.width) + 10, tagHeight = 16;
            _betaTag.frame = NSMakeRect(NSMaxX(_titleLabel.frame) + 6,
                                        floor(NSMidY(_titleLabel.frame) - tagHeight / 2), tagWidth, tagHeight);
            _betaLabel.frame = NSMakeRect(0, floor((tagHeight - ceil(betaSize.height)) / 2), tagWidth,
                                          ceil(betaSize.height));
        }
        top = NSMaxY(_titleLabel.frame) + 8;
    }
    _searchField.frame = NSMakeRect(12, top, width - 24, 28);
    _tabTrack.frame = NSMakeRect(12, top + 36, width - 24, 30);
    CGFloat half = floor((width - 24 - 6) / 2);
    _friendsTab.frame = NSMakeRect(2, 2, half, 26);
    _nearbyTab.frame = NSMakeRect(4 + half, 2, width - 24 - 6 - half, 26);
    CGFloat y = _tabTrack.hidden ? top + 36 : top + 74;
    for (SZFriendsFlippedView *notice in @[ _sendNotice, _banner, _devicesView, _namePrompt ]) {
        if (notice.hidden) continue;
        CGFloat noticeHeight = [(id)notice heightForWidth:width - 24];
        notice.frame = NSMakeRect(12, y, width - 24, noticeHeight);
        y += noticeHeight + 8;
    }
    CGFloat footerHeight = [_footer heightForWidth:width];
    _footer.frame = NSMakeRect(0, height - footerHeight, width, footerHeight);
    NSRect scrollFrame = NSMakeRect(0, y, width, MAX(0, height - footerHeight - y));
    _scrollView.frame = scrollFrame;
    _nearbyScroll.frame = scrollFrame;

    CGFloat rowsY = 0;
    for (SZFriendsRowView *row in _rowViews) {
        row.frame = NSMakeRect(6, rowsY, width - 12, SZFriendsRowHeight);
        rowsY += SZFriendsRowHeight;
    }
    BOOL showEmpty = _emptyTitle.stringValue.length || _emptyBody.stringValue.length;
    _emptyTitle.hidden = _emptyBody.hidden = !showEmpty;
    if (showEmpty) {
        CGFloat textWidth = width - 72;
        CGFloat textHeight = SZFriendsFieldHeight(_emptyTitle, textWidth) + 6;
        textHeight += SZFriendsFieldHeight(_emptyBody, textWidth);
        CGFloat top = rowsY + MAX(24, floor((NSHeight(scrollFrame) - rowsY - textHeight) / 2));
        CGFloat bottom = SZFriendsPlace(_emptyTitle, 36, top, textWidth);
        rowsY = SZFriendsPlace(_emptyBody, 36, bottom + 6, textWidth) + 24;
    }
    _rowsView.frame = NSMakeRect(0, 0, width, MAX(rowsY + 6, NSHeight(scrollFrame)));
    _nearbyPane.frame = NSMakeRect(0, 0, width, MAX([_nearbyPane heightForWidth:width], NSHeight(scrollFrame)));
}

@end
