#import "mac/SZFriendsHistoryFollow.h"

@implementation SZFriendsHistoryFollow {
    __weak NSScrollView *_list;
    __weak SZFriendsContext *_context;
    NSString *_newestID;   // the newest item of the last snapshot
    NSString *_firstUnseen;
    BOOL _scrolling;       // the pill's own smooth scroll
}

- (instancetype)initWithList:(NSScrollView *)list host:(NSView *)host context:(SZFriendsContext *)context {
    if (!(self = [super init])) return nil;
    _list = list;
    _context = context;
    _pill = [SZFriendsButton buttonWithTitle:@"" style:SZFriendsButtonStylePrimary appearance:context.appearance];
    _pill.hidden = YES;
    _pill.identifier = @"newMessagesPill";
    __weak SZFriendsHistoryFollow *weakSelf = self;
    _pill.onPress = ^(SZFriendsButton *button) {
        (void)button;
        [weakSelf scrollToFirstUnseen];
    };
    [host addSubview:_pill positioned:NSWindowAbove relativeTo:list];
    return self;
}

static BOOL SZFFromFriend(NSDictionary *item) {
    NSString *kind = item[@"kind"];
    return [item[@"direction"] isEqual:@"in"] && ([kind isEqual:@"message"] || [kind isEqual:@"transfer"]);
}

- (BOOL)noteItems:(NSArray<NSDictionary *> *)items atBottom:(BOOL)atBottom {
    NSUInteger newest = NSNotFound;
    for (NSUInteger index = items.count; index > 0 && _newestID; index--)
        if ([items[index - 1][@"item_id"] isEqual:_newestID]) { newest = index - 1; break; }
    NSString *previous = _newestID;
    _newestID = [items.lastObject[@"item_id"] copy];
    // The first snapshot, or a history replaced (search, another conversation): nothing arrived below.
    if (!previous || newest == NSNotFound) return NO;
    BOOL sent = NO;
    for (NSUInteger index = newest + 1; index < items.count; index++)
        sent = sent || ([items[index][@"direction"] isEqual:@"out"] && !SZFFromFriend(items[index]));
    if (sent) {
        _unseen = 0;
        _firstUnseen = nil;
        return YES;
    }
    if (atBottom) return NO;
    for (NSUInteger index = newest + 1; index < items.count; index++) {
        if (!SZFFromFriend(items[index])) continue;
        _unseen++;
        if (!_firstUnseen) _firstUnseen = [items[index][@"item_id"] copy];
    }
    return NO;
}

- (nullable NSView *)viewForItem:(NSString *)itemID {
    for (NSView *view in self.itemViews ? self.itemViews() : @[])
        if ([[view valueForKey:@"itemID"] isEqual:itemID]) return view;
    return nil;
}

- (BOOL)atBottom {
    NSScrollView *list = _list;
    return NSMaxY(list.contentView.bounds) >= NSHeight(list.documentView.frame) - 4;
}

- (BOOL)firstUnseenInView {
    NSView *view = _firstUnseen ? [self viewForItem:_firstUnseen] : nil;
    if (!view) return _unseen == 0 || [self atBottom];
    NSRect visible = _list.contentView.bounds;
    return NSMinY(view.frame) < NSMaxY(visible) - MIN(30, NSHeight(view.frame)) && NSMaxY(view.frame) > NSMinY(visible);
}

- (void)layoutOverList:(NSRect)frame {
    CGFloat width = MIN([_pill fittingWidth], NSWidth(frame) - 20);
    _pill.frame = NSMakeRect(NSMidX(frame) - width / 2, NSMaxY(frame) - 36, width, 26);
}

- (void)refresh {
    if (_unseen && !_scrolling && [self firstUnseenInView]) {
        _unseen = 0;
        _firstUnseen = nil;
    }
    // The helper's words, or nothing (PROTOCOL.md § Static strings: never invent text).
    NSString *title = _unseen == 1 ? [_context string:@"new_message"] : _unseen > 1 ?
        [[_context string:@"new_messages"] stringByReplacingOccurrencesOfString:@"{count}"
                                                                     withString:@(_unseen).stringValue] : nil;
    BOOL show = title.length && !_list.hidden && ![self atBottom];
    if (show && ![_pill.title isEqual:title]) {
        _pill.title = title;
        _pill.accessibilityLabel = title;
        NSRect frame = _pill.frame;
        CGFloat width = [_pill fittingWidth];
        _pill.frame = NSMakeRect(NSMidX(frame) - width / 2, NSMinY(frame), width, NSHeight(frame));
    }
    _pill.hidden = !show;
}

- (void)scrollToFirstUnseen {
    NSScrollView *list = _list;
    NSView *view = _firstUnseen ? [self viewForItem:_firstUnseen] : nil;
    CGFloat end = MAX(0, NSHeight(list.documentView.frame) - NSHeight(list.contentView.bounds));
    CGFloat target = view ? MIN(end, MAX(0, NSMinY(view.frame) - 8)) : end;
    _scrolling = YES;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *animation) {
        animation.duration = 0.25;
        animation.allowsImplicitAnimation = YES;
        [list.contentView.animator setBoundsOrigin:NSMakePoint(0, target)];
    } completionHandler:^{
        self->_scrolling = NO;
        [list reflectScrolledClipView:list.contentView];
        [self refresh];
    }];
}

@end
