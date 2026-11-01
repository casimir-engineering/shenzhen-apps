// SZFriendsConversationCache: the latest snapshot of the conversations a click may open next.

#import "mac/SZFriendsConversationCache.h"

#import "mac/SZFriendsHelperLink.h"

#import <objc/runtime.h>

NSNotificationName const SZFriendsConversationCacheDidForgetNotification =
    @"SZFriendsConversationCacheDidForgetNotification";

// About two dropdowns of friends: more is rarely clicked before its snapshot is old.
static const NSUInteger SZFKeptConversations = 16;
// A list snapshot comes with every change; the first rows are fetched again only once what is kept is this old.
static const NSTimeInterval SZFPrefetchAgainAfter = 60;

@implementation SZFriendsConversationCache {
    __weak SZFriendsHelperLink *_link;
    NSMutableDictionary<NSString *, NSDictionary *> *_snapshots;
    NSMutableArray<NSString *> *_order; // least recently kept first
    NSMutableDictionary<NSString *, NSDate *> *_keptAt;
    NSString *_followed;
    NSString *_followToken;
    NSMutableDictionary<NSString *, NSString *> *_prefetching; // conversation id -> subscription token
}

+ (instancetype)cacheForLink:(SZFriendsHelperLink *)link {
    static char key;
    SZFriendsConversationCache *cache = objc_getAssociatedObject(link, &key);
    if (!cache) {
        cache = [[self alloc] initWithLink:link];
        objc_setAssociatedObject(link, &key, cache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return cache;
}

- (instancetype)initWithLink:(SZFriendsHelperLink *)link {
    if (!(self = [super init])) return nil;
    _link = link;
    _snapshots = [NSMutableDictionary dictionary];
    _order = [NSMutableArray array];
    _keptAt = [NSMutableDictionary dictionary];
    _prefetching = [NSMutableDictionary dictionary];
    return self;
}

- (BOOL)previews {
    return [_link.helperCapabilities containsObject:@"conversation.preview"];
}

- (NSDictionary *)snapshotFor:(NSString *)conversationID {
    return conversationID ? _snapshots[conversationID] : nil;
}

- (void)remember:(NSDictionary *)data forConversation:(NSString *)conversationID {
    // A snapshot around a message asked for (search, a citation) is not how the conversation opens from its row.
    if (!conversationID.length || ![data isKindOfClass:NSDictionary.class] ||
        [data[@"highlight_item_id"] isKindOfClass:NSString.class])
        return;
    _snapshots[conversationID] = data;
    _keptAt[conversationID] = [NSDate date];
    [_order removeObject:conversationID];
    [_order addObject:conversationID];
    while (_order.count > SZFKeptConversations) {
        [_snapshots removeObjectForKey:_order.firstObject];
        [_keptAt removeObjectForKey:_order.firstObject];
        [_order removeObjectAtIndex:0];
    }
}

- (NSString *)previewOf:(NSString *)conversationID once:(BOOL)once {
    __weak SZFriendsConversationCache *weakSelf = self;
    return [_link subscribeToView:@"conversation_preview" params:@{@"conversation_id" : conversationID}
                           handler:^(NSDictionary *data, NSInteger rev) {
                               (void)rev;
                               SZFriendsConversationCache *cache = weakSelf;
                               [cache remember:data forConversation:conversationID];
                               if (once) [cache endPrefetch:conversationID];
                           }];
}

- (void)follow:(NSString *)conversationID {
    if (!conversationID.length || [conversationID isEqualToString:_followed] || !self.previews) return;
    if (_followed) [self stopFollowing:_followed];
    _followed = [conversationID copy];
    _followToken = [self previewOf:conversationID once:NO];
}

- (void)stopFollowing:(NSString *)conversationID {
    if (!_followed || (conversationID && ![conversationID isEqualToString:_followed])) return;
    if (_followToken) [_link unsubscribe:_followToken];
    _followed = _followToken = nil;
}

- (void)prefetch:(NSArray<NSString *> *)conversationIDs {
    if (!self.previews) return;
    for (NSString *conversationID in conversationIDs) {
        if (!conversationID.length || _prefetching[conversationID] || [conversationID isEqualToString:_followed] ||
            (_keptAt[conversationID] && -[_keptAt[conversationID] timeIntervalSinceNow] < SZFPrefetchAgainAfter))
            continue;
        _prefetching[conversationID] = [self previewOf:conversationID once:YES];
    }
}

- (void)endPrefetch:(NSString *)conversationID {
    NSString *token = _prefetching[conversationID];
    if (!token) return;
    [_prefetching removeObjectForKey:conversationID];
    [_link unsubscribe:token];
}

- (void)forgetAll {
    [_snapshots removeAllObjects];
    [_order removeAllObjects];
    [_keptAt removeAllObjects];
    [NSNotificationCenter.defaultCenter postNotificationName:SZFriendsConversationCacheDidForgetNotification
                                                      object:self];
}

@end
