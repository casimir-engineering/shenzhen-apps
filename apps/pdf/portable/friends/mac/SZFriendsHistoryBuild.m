// SZFriendsHistoryBuild: the newest items first, the rest after the first frame.

#import "mac/SZFriendsHistoryBuild.h"

#import "mac/SZFriendsItemViewsInternal.h"

// A history this short is built at once: it costs less than a frame.
static const NSUInteger SZFSmallHistory = 12;
// Older items built per turn of the run loop: a few milliseconds of the main thread for plain messages.
static const NSUInteger SZFSlice = 16;

static NSString *SZFBuildKey(NSString *kind, NSString *itemID) {
    return [NSString stringWithFormat:@"%@:%@", kind ?: @"", itemID ?: @""];
}

void SZFriendsAfterNextFrame(dispatch_block_t block) {
    dispatch_block_t copied = [block copy];
    // After Core Animation's commit (order 2000000), which hands the frame to the screen. The work itself goes to a
    // timer, so the run loop wakes for it and draws what it adds in the next frame.
    CFRunLoopObserverRef observer = CFRunLoopObserverCreateWithHandler(
        NULL, kCFRunLoopBeforeWaiting | kCFRunLoopExit, false, 2000001, ^(CFRunLoopObserverRef o, CFRunLoopActivity a) {
            (void)o, (void)a;
            CFRunLoopTimerRef timer = CFRunLoopTimerCreateWithHandler(
                NULL, CFAbsoluteTimeGetCurrent(), 0, 0, 0, ^(CFRunLoopTimerRef t) {
                    (void)t;
                    copied();
                });
            CFRunLoopAddTimer(CFRunLoopGetMain(), timer, kCFRunLoopCommonModes);
            CFRelease(timer);
        });
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
    CFRelease(observer);
}

@implementation SZFriendsHistoryBuild {
    SZFriendsContext *_context;
    __weak NSView *_container;
    NSArray<NSDictionary *> *_items;
    NSMutableArray<SZFriendsItemView *> *_views;
    NSSet<NSString *> *_capabilities; // the helper's, when the views were last applied
    BOOL _scheduled;
    BOOL _holdsPass;
}

@synthesize paused = _paused;

- (instancetype)initWithContext:(SZFriendsContext *)context container:(NSView *)container {
    if (!(self = [super init])) return nil;
    _context = context;
    _container = container;
    _items = @[];
    _views = [NSMutableArray array];
    return self;
}

- (void)dealloc {
    if (_holdsPass) [_context releaseMarkdownPass];
}

- (NSArray<SZFriendsItemView *> *)views {
    return [_views copy];
}

- (NSUInteger)pending {
    return _items.count > _views.count ? _items.count - _views.count : 0;
}

- (SZFriendsItemView *)viewForItem:(NSDictionary *)item
                          existing:(NSMutableDictionary<NSString *, SZFriendsItemView *> *)existing
                      reapplyingAll:(BOOL)reapplyingAll {
    NSString *key = SZFBuildKey(SZFStr(item, @"kind"), SZFStr(item, @"item_id"));
    SZFriendsItemView *view = existing[key];
    if (view) {
        [existing removeObjectForKey:key];
        if (reapplyingAll || ![view.item isEqualToDictionary:item]) [view applyItem:item];
        return view;
    }
    view = [SZFriendsItemView viewForItem:item context:_context];
    [_container addSubview:view];
    return view;
}

- (void)applyItems:(NSArray<NSDictionary *> *)items everything:(BOOL)everything width:(CGFloat)width
            height:(CGFloat)height {
    NSMutableDictionary<NSString *, SZFriendsItemView *> *existing = [NSMutableDictionary dictionary];
    for (SZFriendsItemView *view in _views) existing[SZFBuildKey(view.itemKind, view.itemID)] = view;
    // What a view shows can depend on the helper's capabilities too (Cancel needs messages.cancel): a new helper
    // applies every item again.
    NSSet *capabilities = _context.link.helperCapabilities;
    BOOL reapplyingAll = ![capabilities isEqualToSet:_capabilities ?: [NSSet set]];
    _capabilities = capabilities;
    // From which item views are built now: all, from the oldest one already built, or (NSNotFound) as many of the
    // newest as fill `height`.
    NSUInteger first = NSNotFound;
    if (everything || items.count <= SZFSmallHistory || width <= 0) first = 0;
    else if (_views.count) {
        SZFriendsItemView *oldest = _views.firstObject;
        NSString *key = SZFBuildKey(oldest.itemKind, oldest.itemID);
        for (NSUInteger index = 0; index < items.count && first == NSNotFound; index++)
            if ([SZFBuildKey(SZFStr(items[index], @"kind"), SZFStr(items[index], @"item_id")) isEqualToString:key])
                first = index;
    }
    NSMutableArray<SZFriendsItemView *> *built = [NSMutableArray array]; // newest first
    __block NSUInteger index = items.count;
    void (^build)(void) = ^{
        CGFloat filled = 0;
        while (index > 0 && (first == NSNotFound || index > first)) {
            index--;
            SZFriendsItemView *view = [self viewForItem:items[index] existing:existing reapplyingAll:reapplyingAll];
            [built addObject:view];
            if (first != NSNotFound) continue;
            // Measured in the container, with its appearance, as the page's layout measures it next.
            filled += [view heightForWidth:width] + 10;
            if (filled >= height) break;
        }
    };
    // The newest items' renders come out of the same allowance as the older ones built after them.
    if (first == NSNotFound && !_holdsPass) {
        [_context holdMarkdownPass];
        _holdsPass = YES;
    }
    if (first == NSNotFound) [_context markdownPass:build];
    else build();
    for (SZFriendsItemView *gone in existing.allValues) [gone removeFromSuperview];
    _items = [items copy];
    _views = [[built reverseObjectEnumerator].allObjects mutableCopy];
    [self continueBuilding];
}

- (BOOL)buildSlice {
    NSUInteger pending = self.pending;
    if (!pending) return NO;
    NSUInteger from = pending > SZFSlice ? pending - SZFSlice : 0;
    NSMutableArray<SZFriendsItemView *> *slice = [NSMutableArray array];
    for (NSUInteger index = from; index < pending; index++) {
        SZFriendsItemView *view = [SZFriendsItemView viewForItem:_items[index] context:_context];
        [_container addSubview:view];
        [slice addObject:view];
    }
    [_views insertObjects:slice atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, slice.count)]];
    // Laid out (and so measured) before the pass may close with the last slice.
    if (self.onGrow) self.onGrow();
    [self continueBuilding];
    return YES;
}

- (void)setPaused:(BOOL)paused {
    _paused = paused;
    [self continueBuilding];
}

// While items wait on screen, the host's render pass stays open and the next slice waits for the next frame.
- (void)continueBuilding {
    BOOL building = self.pending > 0 && !_paused;
    if (building && !_holdsPass) [_context holdMarkdownPass];
    if (!building && _holdsPass) [_context releaseMarkdownPass];
    _holdsPass = building;
    if (!building || _scheduled) return;
    _scheduled = YES;
    __weak SZFriendsHistoryBuild *weakSelf = self;
    SZFriendsAfterNextFrame(^{
        SZFriendsHistoryBuild *build = weakSelf;
        if (!build) return;
        build->_scheduled = NO;
        if (!build->_paused) [build buildSlice];
    });
}

@end
