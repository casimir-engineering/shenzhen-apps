// SZFriendsNearbyPane: visibility, the one alert or quiet note, and people as each method reports them.
//
// While visible the helper sends a snapshot every second for the countdown, so every subview here is created
// once and updated in place; rows are reused by position.

#import "mac/SZFriendsListPage.h"

@implementation SZFriendsNearbyPane {
    SZFriendsContext *_context;
    SZFriendsNoticeView *_visibility;
    SZFriendsNoticeView *_alert;
    SZFriendsNoticeView *_note;
    NSTextField *_peopleHeader;
    NSTextField *_statusLabel;
    BOOL _showsStatus;
    NSMutableArray<SZFriendsRowView *> *_rows;
    NSTextField *_emptyTitle;
    NSTextField *_emptyBody;
    BOOL _emptySearching;
    BOOL _hasAlert;
    BOOL _hasNote;
}

- (instancetype)initWithContext:(SZFriendsContext *)context {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, context.appearance.dropdownWidth, 300)])) return nil;
    _context = context;
    SZFriendsAppearance *appearance = context.appearance;
    _visibility = [[SZFriendsNoticeView alloc] initWithContext:context];
    _alert = [[SZFriendsNoticeView alloc] initWithContext:context];
    _alert.fillColor = [appearance.warningColor colorWithAlphaComponent:0.14];
    _alert.strokeColor = [appearance.warningColor colorWithAlphaComponent:0.45];
    _alert.titleLabel.textColor = appearance.primaryTextColor;
    _note = [[SZFriendsNoticeView alloc] initWithContext:context];
    _note.padding = 2;
    _note.iconDrawer = ^(NSRect rect, NSColor *color) { SZFriendsDrawInfoIcon(rect, color); };
    _note.bodyLabel.textColor = appearance.primaryTextColor;
    for (NSView *view in @[ _visibility, _alert, _note ]) [self addSubview:view];
    _peopleHeader = SZFriendsLabel(@"", SZFriendsSemibold(appearance.captionFont), appearance.secondaryTextColor);
    _statusLabel = SZFriendsLabel(@"", appearance.captionFont, appearance.secondaryTextColor);
    _statusLabel.alignment = NSTextAlignmentRight;
    _emptyTitle = SZFriendsLabel(@"", SZFriendsSemibold(appearance.bodyFont), appearance.primaryTextColor);
    _emptyBody = SZFriendsLabel(@"", appearance.secondaryFont, appearance.secondaryTextColor);
    _emptyTitle.alignment = _emptyBody.alignment = NSTextAlignmentCenter;
    for (NSView *view in @[ _peopleHeader, _statusLabel, _emptyTitle, _emptyBody ]) [self addSubview:view];
    _rows = [NSMutableArray array];
    return self;
}

- (NSArray<SZFriendsRowView *> *)personRows {
    return [_rows copy];
}

- (SZFriendsButton *)visibilityButton {
    return _visibility.button;
}

- (void)perform:(NSDictionary *)action ids:(NSDictionary *)ids {
    [_context performAction:action ids:ids done:nil];
}

- (void)applyNearby:(NSDictionary *)data {
    SZFriendsAppearance *appearance = _context.appearance;
    __weak SZFriendsNearbyPane *weakSelf = self;
    void (^perform)(NSDictionary *) = ^(NSDictionary *action) { [weakSelf perform:action ids:nil]; };

    NSDictionary *visibility = SZFDict(data, @"visibility");
    BOOL visible = [SZFStr(visibility, @"state") isEqualToString:@"visible"];
    _visibility.titleLabel.stringValue = SZFStr(visibility, @"title") ?: @"";
    _visibility.bodyLabel.stringValue = SZFStr(visibility, @"body") ?: @"";
    [_visibility setAction:SZFDict(visibility, @"action") onPress:perform];
    _visibility.buttonTrailing = visible;
    _visibility.buttonFullWidth = !visible;
    _visibility.buttonFirst = !visible;
    if (visible) {
        // The countdown card: tinted like the mockup, remaining time large and tabular so it does not jitter.
        _visibility.fillColor = [appearance.accentColor colorWithAlphaComponent:0.12];
        _visibility.strokeColor = [appearance.accentColor colorWithAlphaComponent:0.45];
        _visibility.padding = 12;
        if (!_visibility.bigLabel) {
            NSFont *digits = [NSFont monospacedDigitSystemFontOfSize:20 weight:NSFontWeightSemibold];
            _visibility.bigLabel = SZFriendsLabel(@"", digits, appearance.primaryTextColor);
            _visibility.bigLabel.alignment = NSTextAlignmentCenter;
        }
        _visibility.bigLabel.stringValue = SZFStr(visibility, @"remaining_label") ?: @"";
        _visibility.bigLabel.accessibilityLabel = SZFStr(visibility, @"remaining_accessibility_label");
    } else {
        // Hidden: the full-width action first, then the explanation under it (buttonFirst), as Nearby's states
        // draw it.
        _visibility.fillColor = nil;
        _visibility.strokeColor = nil;
        _visibility.padding = 0;
        _visibility.bigLabel = nil;
    }

    NSDictionary *alert = SZFDict(data, @"alert");
    _hasAlert = alert != nil;
    _alert.titleLabel.stringValue = SZFStr(alert, @"title") ?: @"";
    _alert.bodyLabel.stringValue = SZFStr(alert, @"body") ?: @"";
    [_alert setAction:SZFDict(alert, @"action") onPress:perform];
    _alert.hidden = !_hasAlert;

    NSDictionary *note = SZFDict(data, @"note");
    _hasNote = note != nil;
    _note.bodyLabel.stringValue = SZFStr(note, @"text") ?: @"";
    [_note setAction:SZFDict(note, @"action") onPress:perform];
    _note.hidden = !_hasNote;

    _peopleHeader.stringValue = [_context string:@"people_nearby"];
    NSDictionary *status = SZFDict(data, @"status");
    _showsStatus = status != nil;
    _statusLabel.stringValue = SZFStr(status, @"label") ?: @"";
    // Each method's own state, for anyone who wonders what is being searched; the note and alert already say
    // what matters, so this stays a tooltip rather than more lines.
    NSMutableArray *methodLines = [NSMutableArray array];
    for (NSDictionary *method in SZFArr(data, @"methods")) {
        NSString *label = SZFStr(method, @"label");
        if (label.length) [methodLines addObject:label];
    }
    _peopleHeader.toolTip = methodLines.count ? [methodLines componentsJoinedByString:@"\n"] : nil;
    _statusLabel.toolTip = _peopleHeader.toolTip;

    NSArray *people = SZFArr(data, @"people");
    while (_rows.count > people.count) {
        [_rows.lastObject removeFromSuperview];
        [_rows removeLastObject];
    }
    while (_rows.count < people.count) {
        SZFriendsRowView *row = [[SZFriendsRowView alloc] initWithContext:_context];
        [_rows addObject:row];
        [self addSubview:row];
    }
    [people enumerateObjectsUsingBlock:^(NSDictionary *person, NSUInteger index, BOOL *stop) {
        (void)stop;
        SZFriendsRowView *row = self->_rows[index];
        [row configureWithNearbyPerson:person];
        NSString *conversationID = SZFStr(person, @"conversation_id");
        row.onPress = ^(SZFriendsButton *button) {
            (void)button;
            SZFriendsNearbyPane *pane = weakSelf;
            if (pane.onOpenConversation && conversationID) pane.onOpenConversation(conversationID);
        };
        NSDictionary *action = SZFDict(person, @"action");
        NSString *nearbyID = SZFStr(person, @"nearby_id");
        row.accessoryButton.onPress = ^(SZFriendsButton *button) {
            (void)button;
            [weakSelf perform:action ids:nearbyID ? @{@"nearby_id" : nearbyID} : nil];
        };
    }];

    NSDictionary *empty = SZFDict(data, @"empty");
    _emptyTitle.stringValue = SZFStr(empty, @"title") ?: @"";
    _emptyBody.stringValue = SZFStr(empty, @"body") ?: @"";
    _emptySearching = [SZFStr(empty, @"kind") isEqualToString:@"searching"];
    [self setNeedsLayout:YES];
    self.needsDisplay = YES;
}

- (CGFloat)layoutForWidth:(CGFloat)width apply:(BOOL)apply {
    CGFloat pad = 12;
    CGFloat inner = width - 2 * pad;
    CGFloat y = 4;
    CGFloat height = [_visibility heightForWidth:inner];
    if (apply) _visibility.frame = NSMakeRect(pad, y, inner, height);
    y += height;
    if (_hasAlert) {
        y += 10;
        height = [_alert heightForWidth:inner];
        if (apply) _alert.frame = NSMakeRect(pad, y, inner, height);
        y += height;
    }
    if (_hasNote) {
        y += 10;
        height = [_note heightForWidth:inner];
        if (apply) _note.frame = NSMakeRect(pad, y, inner, height);
        y += height;
    }
    y += 14;
    if (apply) {
        CGFloat statusWidth = _showsStatus ? 150 : 0;
        _peopleHeader.frame = NSMakeRect(pad + 6, y, inner - 12 - statusWidth, 16);
        _statusLabel.frame = NSMakeRect(width - pad - 6 - statusWidth + 16, y, statusWidth - 16, 16);
        _statusLabel.hidden = !_showsStatus;
    }
    y += 22;
    for (SZFriendsRowView *row in _rows) {
        if (apply) row.frame = NSMakeRect(6, y, width - 12, SZFriendsRowHeight);
        y += SZFriendsRowHeight;
    }
    if (_emptyTitle.stringValue.length || _emptyBody.stringValue.length) {
        y += _emptySearching ? 34 : 16;
        CGFloat textWidth = width - 80;
        if (apply) {
            y = SZFriendsPlace(_emptyTitle, 40, y, textWidth);
            y = SZFriendsPlace(_emptyBody, 40, y + (_emptyTitle.stringValue.length ? 6 : 0), textWidth);
        } else {
            y += SZFriendsFieldHeight(_emptyTitle, textWidth) + 6 + SZFriendsFieldHeight(_emptyBody, textWidth);
        }
    } else if (apply) {
        _emptyTitle.hidden = _emptyBody.hidden = YES;
    }
    return y + 8;
}

- (CGFloat)heightForWidth:(CGFloat)width {
    return [self layoutForWidth:width apply:NO];
}

- (void)layout {
    [super layout];
    [self layoutForWidth:NSWidth(self.bounds) apply:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    SZFriendsAppearance *appearance = _context.appearance;
    if (_showsStatus && !_statusLabel.hidden) {
        CGFloat textWidth = SZFriendsTextWidth(_statusLabel.stringValue, _statusLabel.font);
        NSRect frame = _statusLabel.frame;
        SZFriendsDrawArcIcon(NSMakeRect(NSMaxX(frame) - textWidth - 18, NSMinY(frame) + 2, 11, 11),
                             appearance.secondaryTextColor);
    }
    if (_emptySearching && !_emptyTitle.hidden)
        SZFriendsDrawArcIcon(NSMakeRect(floor(NSWidth(self.bounds) / 2) - 11, NSMinY(_emptyTitle.frame) - 30, 22, 22),
                             appearance.secondaryTextColor);
}

@end
