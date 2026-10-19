// The responders' memory of message 1 ephemeral keys (SZFriendsSession.h § SZFriendsReplayCache).

#import "service/session/SZFriendsSession.h"

#import <os/lock.h>
#import <time.h>

static const NSUInteger kDefaultCapacity = 65536;

@implementation SZFriendsReplayCache {
    os_unfair_lock _lock;
    NSUInteger _capacity;
    NSTimeInterval (^_clock)(void);
    NSMutableDictionary<NSData *, NSNumber *> *_seenAt; // ephemeral key -> when it was recorded
    // Keys in recording order, so expiry and eviction take from the front. `_head` skips the consumed part, which
    // is compacted now and then rather than shifted on every removal.
    NSMutableArray<NSData *> *_order;
    NSUInteger _head;
}

+ (SZFriendsReplayCache *)sharedCache {
    static SZFriendsReplayCache *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[SZFriendsReplayCache alloc] init];
    });
    return shared;
}

- (instancetype)init {
    return [self initWithCapacity:kDefaultCapacity clock:nil];
}

- (instancetype)initWithCapacity:(NSUInteger)capacity clock:(NSTimeInterval (^)(void))clock {
    if ((self = [super init])) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _capacity = MAX(capacity, (NSUInteger)1);
        // The same clock as the channel's: it keeps counting while the Mac sleeps, so a long sleep ages entries.
        _clock = [clock copy];
        if (_clock == nil) {
            _clock = ^NSTimeInterval {
                return (NSTimeInterval)clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1e9;
            };
        }
        _seenAt = [NSMutableDictionary dictionary];
        _order = [NSMutableArray array];
    }
    return self;
}

- (NSUInteger)count {
    os_unfair_lock_lock(&_lock);
    NSUInteger count = _seenAt.count;
    os_unfair_lock_unlock(&_lock);
    return count;
}

// Drops the oldest entry. Called with the lock held.
- (void)dropOldest {
    [_seenAt removeObjectForKey:_order[_head]];
    _head++;
    if (_head > 1024 && _head * 2 > _order.count) {
        [_order removeObjectsInRange:NSMakeRange(0, _head)];
        _head = 0;
    }
}

- (BOOL)recordEphemeralKey:(NSData *)ephemeralKey {
    NSData *key = [ephemeralKey copy];
    os_unfair_lock_lock(&_lock);
    NSTimeInterval now = _clock();
    while (_head < _order.count && now - _seenAt[_order[_head]].doubleValue >= SZFriendsReplayWindow) {
        [self dropOldest];
    }
    BOOL fresh = _seenAt[key] == nil;
    if (fresh) {
        while (_seenAt.count >= _capacity) {
            [self dropOldest];
        }
        _seenAt[key] = @(now);
        [_order addObject:key];
    }
    os_unfair_lock_unlock(&_lock);
    return fresh;
}

@end
