// SZFriendsYourLinksView: the profile's "Your links", the friend link and every live download link (PROTOCOL.md
// § Links).

#import "mac/SZFriendsLinkPage.h"

@implementation SZFriendsYourLinksView {
    SZFriendsContext *_context;
    NSDictionary *_links;
    NSTextField *_title;
    SZFriendsFlippedView *_friendCard;
    NSTextField *_friendLabel;
    NSTextField *_friendURL;
    NSTextField *_friendNote;
    NSTextField *_downloadsTitle;
    NSTextField *_downloadsEmpty;
    NSMutableArray<NSTextField *> *_files;
    NSMutableArray<NSTextField *> *_details;
    NSMutableArray<SZFriendsButton *> *_revokes;
}

- (instancetype)initWithContext:(SZFriendsContext *)context {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 368, 10)])) return nil;
    _context = context;
    SZFriendsAppearance *appearance = context.appearance;
    __weak SZFriendsYourLinksView *weakSelf = self;
    _title = SZFriendsLabel(@"", SZFriendsSemibold(appearance.bodyFont), appearance.primaryTextColor);
    _friendCard = [SZFriendsFlippedView new];
    _friendCard.fillColor = appearance.fieldBackgroundColor;
    _friendCard.strokeColor = appearance.separatorColor;
    _friendCard.cornerRadius = 10;
    _friendLabel = SZFriendsLabel(@"", SZFriendsSemibold(appearance.captionFont), appearance.secondaryTextColor);
    _friendURL = SZFriendsLabel(@"", appearance.secondaryFont, appearance.primaryTextColor);
    _friendURL.maximumNumberOfLines = 1;
    _friendURL.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _friendNote = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    _friendCopyButton = [SZFriendsButton buttonWithTitle:@"" style:SZFriendsButtonStyleSecondary
                                              appearance:appearance];
    _friendCopyButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        SZFriendsYourLinksView *view = weakSelf;
        if (view) [view->_context copyText:SZFStr(SZFDict(view->_links, @"friend"), @"url")];
    };
    _friendResetButton = [SZFriendsButton buttonWithTitle:@"" style:SZFriendsButtonStyleSecondary
                                               appearance:appearance];
    _friendResetButton.onPress = ^(SZFriendsButton *button) {
        (void)button;
        SZFriendsYourLinksView *view = weakSelf;
        if (!view) return;
        NSDictionary *reset = SZFDict(SZFDict(view->_links, @"friend"), @"reset");
        if (reset) [view->_context performAction:reset ids:nil done:nil];
    };
    for (NSView *view in @[ _friendLabel, _friendURL, _friendNote, _friendCopyButton, _friendResetButton ])
        [_friendCard addSubview:view];
    _downloadsTitle = SZFriendsLabel(@"", SZFriendsSemibold(appearance.captionFont), appearance.secondaryTextColor);
    _downloadsEmpty = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    for (NSView *view in @[ _title, _friendCard, _downloadsTitle, _downloadsEmpty ]) [self addSubview:view];
    _files = [NSMutableArray array];
    _details = [NSMutableArray array];
    _revokes = [NSMutableArray array];
    self.hidden = YES;
    return self;
}

- (NSArray<SZFriendsButton *> *)revokeButtons {
    return [_revokes copy];
}

- (NSArray<NSTextField *> *)fileLabels {
    return [_files copy];
}

- (void)applyLinks:(NSDictionary *)links {
    _links = [links copy];
    self.hidden = links == nil;
    _title.stringValue = SZFStr(links, @"title") ?: @"";
    NSDictionary *friendLink = SZFDict(links, @"friend");
    _friendCard.hidden = friendLink == nil;
    _friendLabel.stringValue = SZFStr(friendLink, @"label") ?: @"";
    _friendURL.stringValue = SZFStr(friendLink, @"url") ?: @"";
    _friendURL.toolTip = _friendURL.stringValue;
    _friendNote.stringValue = SZFStr(friendLink, @"note") ?: @"";
    _friendCopyButton.title = SZFStr(friendLink, @"copy_label") ?: @"";
    _friendCopyButton.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", _friendCopyButton.title,
                                                                      _friendLabel.stringValue];
    NSDictionary *reset = SZFDict(friendLink, @"reset");
    _friendResetButton.title = SZFStr(reset, @"label") ?: @"";
    _friendResetButton.style = SZFriendsButtonStyleNamed(SZFStr(reset, @"style"));
    _friendResetButton.hidden = ![SZFriendsContext knowsAction:SZFStr(reset, @"action")];
    _downloadsTitle.stringValue = SZFStr(links, @"downloads_label") ?: @"";
    _downloadsEmpty.stringValue = SZFStr(links, @"downloads_empty") ?: @"";
    [self rebuildDownloads:SZFArr(links, @"downloads")];
    [self setNeedsLayout:YES];
}

- (void)rebuildDownloads:(NSArray *)downloads {
    for (NSArray *views in @[ _files, _details, _revokes ])
        for (NSView *view in views) [view removeFromSuperview];
    [_files removeAllObjects];
    [_details removeAllObjects];
    [_revokes removeAllObjects];
    SZFriendsAppearance *appearance = _context.appearance;
    __weak SZFriendsYourLinksView *weakSelf = self;
    for (id download in downloads) {
        if (![download isKindOfClass:NSDictionary.class]) continue;
        NSTextField *file = SZFriendsLabel(SZFStr(download, @"file_name"), appearance.bodyFont,
                                           appearance.primaryTextColor);
        file.maximumNumberOfLines = 1;
        file.lineBreakMode = NSLineBreakByTruncatingMiddle;
        file.toolTip = file.stringValue;
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (NSString *key in @[ @"downloads_label", @"expires_label" ])
            if (SZFStr(download, key).length) [parts addObject:SZFStr(download, key)];
        NSTextField *detail = SZFriendsLabel([parts componentsJoinedByString:@" · "], appearance.secondaryFont,
                                             appearance.secondaryTextColor);
        NSDictionary *revoke = SZFDict(download, @"revoke");
        SZFriendsButton *button = [SZFriendsButton buttonWithTitle:SZFStr(revoke, @"label") ?: @""
                                                            style:SZFriendsButtonStyleNamed(SZFStr(revoke, @"style"))
                                                       appearance:appearance];
        button.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", button.title, file.stringValue];
        button.hidden = ![SZFriendsContext knowsAction:SZFStr(revoke, @"action")];
        button.onPress = ^(SZFriendsButton *pressed) {
            SZFriendsYourLinksView *view = weakSelf;
            if (!view) return;
            pressed.enabled = NO;
            [view->_context performAction:revoke ids:nil done:^(SZFriendsLinkError *error) {
                // A success brings the profile without this link; a failure leaves it and the button usable.
                pressed.enabled = error != nil;
            }];
        };
        [_files addObject:file];
        [_details addObject:detail];
        [_revokes addObject:button];
        for (NSView *view in @[ file, detail, button ]) [self addSubview:view];
    }
}

- (CGFloat)layoutForWidth:(CGFloat)width {
    if (self.hidden) return 0;
    CGFloat y = 0, cardInner = width - 24;
    if (_title.stringValue.length) y = SZFriendsPlace(_title, 0, y, width) + 8;
    if (!_friendCard.hidden) {
        CGFloat cardY = SZFriendsPlace(_friendLabel, 12, 12, cardInner) + 4;
        _friendURL.frame = NSMakeRect(12, cardY, cardInner, 16);
        cardY += 16 + 8;
        CGFloat copyWidth = MAX(56, [_friendCopyButton fittingWidth]);
        _friendCopyButton.frame = NSMakeRect(12, cardY, copyWidth, 26);
        CGFloat resetWidth = MAX(72, [_friendResetButton fittingWidth]);
        _friendResetButton.frame = NSMakeRect(12 + copyWidth + 8, cardY, resetWidth, 26);
        cardY += 26 + 8;
        cardY = SZFriendsPlace(_friendNote, 12, cardY, cardInner);
        _friendCard.frame = NSMakeRect(0, y, width, cardY + 12);
        y += cardY + 12 + 14;
    }
    _downloadsTitle.hidden = _downloadsTitle.stringValue.length == 0;
    if (!_downloadsTitle.hidden) y = SZFriendsPlace(_downloadsTitle, 0, y, width) + 6;
    _downloadsEmpty.hidden = _files.count > 0 || _downloadsEmpty.stringValue.length == 0;
    if (!_downloadsEmpty.hidden) y = SZFriendsPlace(_downloadsEmpty, 0, y, width) + 6;
    for (NSUInteger i = 0; i < _files.count; i++) {
        SZFriendsButton *revoke = _revokes[i];
        CGFloat revokeWidth = revoke.hidden ? 0 : MAX(64, [revoke fittingWidth]);
        CGFloat textWidth = width - revokeWidth - (revokeWidth ? 8 : 0);
        _files[i].frame = NSMakeRect(0, y, textWidth, 18);
        CGFloat bottom = SZFriendsPlace(_details[i], 0, y + 19, textWidth);
        revoke.frame = NSMakeRect(width - revokeWidth, y + floor((bottom - y - 24) / 2), revokeWidth, 24);
        y = bottom + 10;
    }
    return y;
}

@end
