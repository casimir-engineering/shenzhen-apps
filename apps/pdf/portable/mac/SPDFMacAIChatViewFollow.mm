// Where the transcript stays while a chat grows (SPDFMacAIChatViewInternal.h § Follow). Sending (Return, the send
// button, Retry, Continue) takes the person to the end and keeps them there while the reply comes in, also after rows
// that finish laying out late have grown the transcript. Scrolling up lets go: nothing moves under them, and a pill at
// the bottom says what is below, "New message ↓" or "3 new messages ↓" once messages arrive there, "Jump to latest ↓"
// while a reply is still coming. Clicking it scrolls smoothly to the first message they haven't seen, or to the end;
// it goes once that message is in view.
#import "SPDFMacAIChatViewInternal.h"
#import "SPDFMacAIChatSession.h"

@implementation SPDFMacAIChatView (Follow)

- (void)setUpFollowing {
    _followNewest = YES;
    _firstUnseenIndex = NSNotFound;
    // The chat's own accent pill (SPDFMacAIChatViewParts.h), so it reads over any message.
    _newMessagesPill = SPDFChatMakePill(@"", @"newMessagesPill", self, @selector(jumpToLatest:), YES);
    _newMessagesPill.hidden = YES;
    [self addSubview:_newMessagesPill positioned:NSWindowAbove relativeTo:_scroll];
    [NSLayoutConstraint activateConstraints:@[
        [_newMessagesPill.centerXAnchor constraintEqualToAnchor:_scroll.centerXAnchor],
        [_newMessagesPill.bottomAnchor constraintEqualToAnchor:_scroll.bottomAnchor constant:-10]]];
    _scroll.contentView.postsBoundsChangedNotifications = YES;
    _scroll.documentView.postsFrameChangedNotifications = YES;
    NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(transcriptScrolled:) name:NSViewBoundsDidChangeNotification
                 object:_scroll.contentView];
    [center addObserver:self selector:@selector(transcriptGrew:) name:NSViewFrameDidChangeNotification
                 object:_scroll.documentView];
    [center addObserver:self selector:@selector(transcriptScrolled:) name:NSScrollViewDidEndLiveScrollNotification
                 object:_scroll];
}

- (BOOL)scrolledToEnd {
    return NSMaxY(_scroll.contentView.bounds) >= NSHeight(_scroll.documentView.bounds) - 24;
}

- (BOOL)followsNewest { return _followNewest; }
- (NSUInteger)unseenMessages { return _unseenMessages; }
- (NSButton*)newMessagesPill { return _newMessagesPill; }

- (void)scrollToNewest {
    if (_chatSearch.stringValue.length) return;
    // Rebuilt rich rows change document height. Resolve their layout before clamping the scroll origin, otherwise
    // the first label can be half hidden.
    [self layoutSubtreeIfNeeded];
    [_scroll.documentView layoutSubtreeIfNeeded];
    _scrollingItself = YES;
    [_scroll.contentView scrollToPoint:NSMakePoint(0, MAX(0, NSHeight(_scroll.documentView.bounds) -
                                                             NSHeight(_scroll.contentView.bounds)))];
    [_scroll reflectScrolledClipView:_scroll.contentView];
    _scrollingItself = NO;
}

// The person sent something (or Retry, Continue, a new chat): back to the end, and staying there.
- (void)followNewest {
    _followNewest = YES;
    _unseenMessages = 0;
    _firstUnseenIndex = NSNotFound;
    _firstUnseenRow = nil;
    [self scrollToNewest];
    [self updateNewMessagesPill];
}

// Messages from `first` on arrived while the person was reading above: counted, and the first remembered.
- (void)noteUnseenMessages:(NSArray*)messages from:(NSUInteger)first {
    for (NSUInteger index = first; index < messages.count; index++) {
        NSDictionary* message = messages[index];
        NSString* role = message[@"role"], *content = message[@"content"];
        BOOL shown = ([role isEqual:@"assistant"] || [role isEqual:@"user"]) && [content isKindOfClass:NSString.class] &&
            [content stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length;
        if (!shown) continue;
        _unseenMessages++;
        if (_firstUnseenIndex == NSNotFound) _firstUnseenIndex = index;
    }
}

// The row just added for message `index` (rows from `rows` on) is the first unseen one: kept to scroll to.
- (void)noteRowsFrom:(NSUInteger)rows forMessage:(NSUInteger)index {
    if (index == _firstUnseenIndex && rows < _messages.arrangedSubviews.count)
        _firstUnseenRow = _messages.arrangedSubviews[rows];
}

- (BOOL)firstUnseenInView {
    NSView* row = _firstUnseenRow;
    if (!row || !row.superview) return _unseenMessages == 0;
    NSRect frame = [row convertRect:row.bounds toView:_scroll.documentView];
    NSRect visible = _scroll.contentView.bounds;
    // In view once its top is on screen with a few lines of it.
    return NSMinY(frame) < NSMaxY(visible) - MIN(40, NSHeight(frame)) && NSMaxY(frame) > NSMinY(visible);
}

- (void)updateNewMessagesPill {
    if (_unseenMessages && [self firstUnseenInView]) {
        _unseenMessages = 0;
        _firstUnseenIndex = NSNotFound;
        _firstUnseenRow = nil;
    }
    BOOL away = !_history && !_chatSearch.stringValue.length && ![self scrolledToEnd];
    NSString* title = _unseenMessages == 1 ? @"New message ↓" : _unseenMessages > 1 ?
        [NSString stringWithFormat:@"%lu new messages ↓", (unsigned long)_unseenMessages] :
        _running ? @"Jump to latest ↓" : nil;
    _newMessagesPill.hidden = !away || !title;
    if (title && ![_newMessagesPill.title isEqual:title]) {
        _newMessagesPill.title = title;
        _newMessagesPill.accessibilityLabel = title;
        [_newMessagesPill invalidateIntrinsicContentSize];
        _newMessagesPill.needsDisplay = YES;
    }
}

- (void)transcriptScrolled:(NSNotification*)note {
    (void)note;
    // Any move the view didn't make itself (it marks its own scrolls and rebuilds) is the person's: a wheel, a
    // trackpad, the scroller, the keys, Show older messages. Left at the end, it follows again.
    if (!_scrollingItself) _followNewest = [self scrolledToEnd];
    [self updateNewMessagesPill];
}

- (void)transcriptGrew:(NSNotification*)note {
    (void)note;
    // Rows that lay out after they were added (answers, pictures) grow the transcript: stay at its end.
    if (_followNewest && !_preserveScroll && !_history && !_chatSearch.stringValue.length)
        dispatch_async(dispatch_get_main_queue(), ^{ if (self->_followNewest) [self scrollToNewest]; });
    [self updateNewMessagesPill];
}

- (void)jumpToLatest:(id)sender {
    (void)sender;
    NSView* row = _firstUnseenRow;
    CGFloat end = MAX(0, NSHeight(_scroll.documentView.bounds) - NSHeight(_scroll.contentView.bounds));
    CGFloat target = end;
    if (_unseenMessages && row.superview)
        target = MIN(end, MAX(0, NSMinY([row convertRect:row.bounds toView:_scroll.documentView]) - 8));
    _followNewest = target >= end - 1;
    _scrollingItself = YES;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext* context) {
        context.duration = 0.25;
        context.allowsImplicitAnimation = YES;
        [self->_scroll.contentView.animator setBoundsOrigin:NSMakePoint(0, target)];
    } completionHandler:^{
        self->_scrollingItself = NO;
        [self->_scroll reflectScrolledClipView:self->_scroll.contentView];
        if (self->_followNewest) [self scrollToNewest];
        [self updateNewMessagesPill];
    }];
}

@end
