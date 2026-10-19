// Admission limits on incoming connections (SZFriendsDiscovery.h § SZFriendsAdmissionLimits; ADR 0001 review item
// 4). The adapters admit each accepted stream here and hand the session a wrapper that keeps its place until the
// responder says who the initiator is, or the stream closes, so the helper wires nothing.
//
// Places are never refused, only taken back (review finding "admission lockout"): with refusal, one LAN host with a
// few IPv6 addresses kept the hidden listener's 32 places full by renewing silent connections every 10 s, and every
// friend's next connection was dropped at accept. Now a newcomer closes the oldest connection holding a place where
// the limit is reached; a connection that sends no complete message 1 within 2 s is closed; and a friend's connection
// leaves the count at the key policy, one round trip after it arrived, so an attacker must out-run that to evict it.

#import "service/discovery/SZFriendsDiscoveryInternal.h"

#import <os/lock.h>
#import <time.h>

const NSUInteger SZFriendsPendingPerListenerMax = 32;
const NSUInteger SZFriendsPendingPerAddressMax = 4;
// An honest initiator sends the preamble and message 1 in its first write, as soon as the connection is up: on any
// route, even Bluetooth, that is well under a second. Two leaves room for a slow link and keeps a silent peer's
// place short (it was the 10 s handshake timeout).
const NSTimeInterval SZFriendsFirstMessageTimeout = 2;

static const NSTimeInterval kRateWindow = 60;
// Rate entries for addresses that went quiet are swept once this many keys exist, so many addresses passing
// through cannot grow the table without end.
static const NSUInteger kRateKeysBeforeSweep = 4096;

@interface SZFriendsAdmissionLimits (Rates)
- (void)perMinuteForPattern:(SZFriendsHandshakePattern)pattern
                   listener:(NSUInteger *)perListener
                    address:(NSUInteger *)perAddress;
@end

@implementation SZFriendsAdmissionLimits

+ (instancetype)defaultLimits {
    SZFriendsAdmissionLimits *limits = [[self alloc] init];
    limits.pendingPerListener = SZFriendsPendingPerListenerMax;
    limits.pendingPerAddress = SZFriendsPendingPerAddressMax;
    limits.firstMessageTimeout = SZFriendsFirstMessageTimeout;
    return limits;
}

- (id)copyWithZone:(NSZone *)zone {
    SZFriendsAdmissionLimits *copy = [[[self class] allocWithZone:zone] init];
    copy.pendingPerListener = _pendingPerListener;
    copy.pendingPerAddress = _pendingPerAddress;
    copy.firstMessageTimeout = _firstMessageTimeout;
    copy.xxPerMinutePerListener = _xxPerMinutePerListener;
    copy.xxPerMinutePerAddress = _xxPerMinutePerAddress;
    copy.ikPerMinutePerListener = _ikPerMinutePerListener;
    copy.ikPerMinutePerAddress = _ikPerMinutePerAddress;
    copy.nnPerMinutePerListener = _nnPerMinutePerListener;
    copy.nnPerMinutePerAddress = _nnPerMinutePerAddress;
    return copy;
}

- (void)perMinuteForPattern:(SZFriendsHandshakePattern)pattern
                   listener:(NSUInteger *)perListener
                    address:(NSUInteger *)perAddress {
    switch (pattern) {
    case SZFriendsHandshakeXX:
        *perListener = _xxPerMinutePerListener, *perAddress = _xxPerMinutePerAddress;
        return;
    case SZFriendsHandshakeIK:
        *perListener = _ikPerMinutePerListener, *perAddress = _ikPerMinutePerAddress;
        return;
    case SZFriendsHandshakeNN:
        *perListener = _nnPerMinutePerListener, *perAddress = _nnPerMinutePerAddress;
        return;
    }
    *perListener = *perAddress = 0;
}

@end

@class SZFriendsAdmittedStream;

// One place: who holds it and where it counts. Held weakly, so a stream its session drops without closing still
// gives its place back from -dealloc.
@interface SZFriendsPendingPlace : NSObject
@property(nonatomic, copy) NSString *listener;
@property(nonatomic, copy, nullable) NSString *address;
@property(nonatomic, weak, nullable) SZFriendsAdmittedStream *stream;
@end

@implementation SZFriendsPendingPlace
@end

@interface SZFriendsAdmissionController ()
- (void)releasePlace:(SZFriendsPendingPlace *)place;
- (void)evictPlace:(SZFriendsPendingPlace *)place error:(NSError *)error;
- (BOOL)admitPattern:(SZFriendsHandshakePattern)pattern
            listener:(NSString *)listener
             address:(nullable NSString *)address;
@end

// The stream the session sees: everything goes to the adapter's stream; the place is given back exactly once.
@interface SZFriendsAdmittedStream : NSObject <SZFriendsByteStream>
- (void)evictWithError:(NSError *)error;
- (void)firstMessageDeadlinePassed;
@end

@implementation SZFriendsAdmittedStream {
    id<SZFriendsByteStream> _inner;
    SZFriendsAdmissionController *_controller;
    SZFriendsPendingPlace *_place;
    BOOL _released, _asked, _firstMessageSeen;
    NSError *_evictionError;         // set once evicted: the close the session is told about
    dispatch_queue_t _callbackQueue; // from -startWithQueue:
    BOOL _closeDelivered;            // on _callbackQueue only
}

@synthesize onClose = _onClose;

- (instancetype)initWithStream:(id<SZFriendsByteStream>)inner
                    controller:(SZFriendsAdmissionController *)controller
                         place:(SZFriendsPendingPlace *)place {
    if ((self = [super init])) {
        _inner = inner;
        _controller = controller;
        _place = place;
        __weak SZFriendsAdmittedStream *weakSelf = self;
        // Set now, so the place comes back when the link ends even if nobody ever listens for the close.
        inner.onClose = ^(NSError *error) {
            SZFriendsAdmittedStream *strongSelf = weakSelf;
            if (strongSelf == nil) return;
            [strongSelf giveBackPlace];
            [strongSelf deliverClose:error];
        };
    }
    return self;
}

- (void)dealloc {
    [self giveBackPlace];
}

- (void)giveBackPlace {
    @synchronized(self) {
        if (_released) return;
        _released = YES;
    }
    [_controller releasePlace:_place];
}

// The controller already took the place back. The adapter's stream is closed, which tells nobody, so the session
// hears about it here, on its own queue: once started, or as soon as it starts.
- (void)evictWithError:(NSError *)error {
    dispatch_queue_t queue = nil;
    @synchronized(self) {
        if (_released) return;
        _released = YES;
        _evictionError = error;
        queue = _callbackQueue;
    }
    [_inner close];
    if (queue) {
        dispatch_async(queue, ^{
            [self deliverClose:error];
        });
    }
}

- (void)deliverClose:(NSError *)error {
    if (_closeDelivered) return;
    _closeDelivered = YES;
    if (self.onClose) self.onClose(error);
}

- (void)firstMessageDeadlinePassed {
    @synchronized(self) {
        if (_firstMessageSeen || _released) return;
    }
    [_controller evictPlace:_place
                      error:SZFriendsDiscoveryMakeError(SZFriendsDiscoveryErrorEvicted,
                                                        @"no complete message 1 in time")];
}

- (NSUInteger)preferredWriteSize {
    return _inner.preferredWriteSize;
}

- (void (^)(NSData *))onData {
    return _inner.onData;
}

- (void)setOnData:(void (^)(NSData *))onData {
    _inner.onData = onData;
}

- (void)startWithQueue:(dispatch_queue_t)queue {
    NSError *evicted = nil;
    @synchronized(self) {
        _callbackQueue = queue;
        evicted = _evictionError;
    }
    if (evicted) {
        dispatch_async(queue, ^{
            [self deliverClose:evicted];
        });
        return;
    }
    [_inner startWithQueue:queue];
}

- (void)writeData:(NSData *)data completion:(void (^)(NSError *))completion {
    [_inner writeData:data completion:completion];
}

- (void)close {
    [self giveBackPlace];
    [_inner close];
}

- (BOOL)admitHandshakePattern:(SZFriendsHandshakePattern)pattern {
    // One handshake per connection: a second question would be a second count.
    if (_asked) return NO;
    _asked = YES;
    return [_controller admitPattern:pattern listener:_place.listener address:_place.address];
}

- (void)handshakeDidReceiveFirstMessage {
    @synchronized(self) {
        _firstMessageSeen = YES;
    }
}

- (void)sessionDidAuthenticate {
    [self handshakeDidReceiveFirstMessage];
    [self giveBackPlace];
}

@end

@implementation SZFriendsAdmissionController {
    os_unfair_lock _lock;
    NSTimeInterval (^_clock)(void);
    SZFriendsAdmissionLimits *_limits;
    NSMutableArray<SZFriendsPendingPlace *> *_places; // oldest first
    NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *_admittedAt; // rate key -> recent admissions
}

- (instancetype)init {
    return [self initWithClock:nil];
}

- (instancetype)initWithClock:(NSTimeInterval (^)(void))clock {
    if ((self = [super init])) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _clock = [clock copy];
        if (_clock == nil) {
            _clock = ^NSTimeInterval {
                return (NSTimeInterval)clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1e9;
            };
        }
        _limits = [SZFriendsAdmissionLimits defaultLimits];
        _places = [NSMutableArray array];
        _admittedAt = [NSMutableDictionary dictionary];
    }
    return self;
}

- (SZFriendsAdmissionLimits *)limits {
    os_unfair_lock_lock(&_lock);
    SZFriendsAdmissionLimits *limits = _limits;
    os_unfair_lock_unlock(&_lock);
    return limits;
}

- (void)setLimits:(SZFriendsAdmissionLimits *)limits {
    SZFriendsAdmissionLimits *copy = [limits copy] ?: [SZFriendsAdmissionLimits defaultLimits];
    os_unfair_lock_lock(&_lock);
    _limits = copy;
    os_unfair_lock_unlock(&_lock);
}

static BOOL Full(NSUInteger count, NSUInteger limit) {
    return limit > 0 && count >= limit;
}

// With the lock held: when the places matching `test` are at `limit`, takes back the oldest and returns it.
- (SZFriendsPendingPlace *)takeOldestWhenFull:(NSUInteger)limit matching:(BOOL (^)(SZFriendsPendingPlace *))test {
    SZFriendsPendingPlace *oldest = nil;
    NSUInteger count = 0;
    for (SZFriendsPendingPlace *place in _places) {
        if (!test(place)) continue;
        if (oldest == nil) oldest = place;
        count++;
    }
    if (oldest == nil || !Full(count, limit)) return nil;
    [_places removeObjectIdenticalTo:oldest];
    return oldest;
}

- (id<SZFriendsByteStream>)admitStream:(id<SZFriendsByteStream>)stream
                              listener:(NSString *)listener
                               address:(NSString *)address {
    SZFriendsPendingPlace *place = [SZFriendsPendingPlace new];
    place.listener = listener;
    place.address = address;
    SZFriendsAdmittedStream *admitted = [[SZFriendsAdmittedStream alloc] initWithStream:stream
                                                                             controller:self
                                                                                  place:place];
    place.stream = admitted;
    NSMutableArray<SZFriendsPendingPlace *> *evicted = [NSMutableArray array];
    os_unfair_lock_lock(&_lock);
    // The address first: making room there may also make room on the listener.
    SZFriendsPendingPlace *sameAddress =
        address ? [self takeOldestWhenFull:_limits.pendingPerAddress
                                  matching:^BOOL(SZFriendsPendingPlace *p) {
                                      return [p.address isEqualToString:address];
                                  }]
                : nil;
    if (sameAddress) [evicted addObject:sameAddress];
    SZFriendsPendingPlace *sameListener = [self takeOldestWhenFull:_limits.pendingPerListener
                                                          matching:^BOOL(SZFriendsPendingPlace *p) {
                                                              return [p.listener isEqualToString:listener];
                                                          }];
    if (sameListener) [evicted addObject:sameListener];
    [_places addObject:place];
    NSTimeInterval deadline = _limits.firstMessageTimeout;
    os_unfair_lock_unlock(&_lock);

    NSError *error = SZFriendsDiscoveryMakeError(SZFriendsDiscoveryErrorEvicted, @"made way for a newer connection");
    for (SZFriendsPendingPlace *old in evicted) [old.stream evictWithError:error];
    if (deadline > 0) {
        __weak SZFriendsAdmittedStream *weakAdmitted = admitted;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(deadline * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                           [weakAdmitted firstMessageDeadlinePassed];
                       });
    }
    return admitted;
}

- (void)releasePlace:(SZFriendsPendingPlace *)place {
    os_unfair_lock_lock(&_lock);
    [_places removeObjectIdenticalTo:place];
    os_unfair_lock_unlock(&_lock);
}

- (void)evictPlace:(SZFriendsPendingPlace *)place error:(NSError *)error {
    os_unfair_lock_lock(&_lock);
    BOOL held = [_places indexOfObjectIdenticalTo:place] != NSNotFound;
    [_places removeObjectIdenticalTo:place];
    os_unfair_lock_unlock(&_lock);
    if (held) [place.stream evictWithError:error];
}

// Admissions under `key` within the last minute, pruned. Called with the lock held.
- (NSMutableArray<NSNumber *> *)recentForKey:(NSString *)key now:(NSTimeInterval)now {
    NSMutableArray<NSNumber *> *times = _admittedAt[key];
    if (times == nil) {
        if (_admittedAt.count >= kRateKeysBeforeSweep) [self sweepRatesAt:now];
        _admittedAt[key] = times = [NSMutableArray array];
    }
    while (times.count && now - times[0].doubleValue >= kRateWindow) [times removeObjectAtIndex:0];
    return times;
}

- (void)sweepRatesAt:(NSTimeInterval)now {
    for (NSString *key in _admittedAt.allKeys) {
        NSNumber *newest = _admittedAt[key].lastObject;
        if (newest == nil || now - newest.doubleValue >= kRateWindow) [_admittedAt removeObjectForKey:key];
    }
}

- (BOOL)admitPattern:(SZFriendsHandshakePattern)pattern listener:(NSString *)listener address:(NSString *)address {
    os_unfair_lock_lock(&_lock);
    NSUInteger perListener = 0, perAddress = 0;
    [_limits perMinuteForPattern:pattern listener:&perListener address:&perAddress];
    NSTimeInterval now = _clock();
    NSString *listenerKey = [NSString stringWithFormat:@"L%u|%@", (unsigned)pattern, listener];
    NSString *addressKey = address ? [NSString stringWithFormat:@"A%u|%@", (unsigned)pattern, address] : nil;
    NSMutableArray<NSNumber *> *onListener = perListener ? [self recentForKey:listenerKey now:now] : nil;
    NSMutableArray<NSNumber *> *fromAddress = perAddress && addressKey ? [self recentForKey:addressKey now:now] : nil;
    BOOL admit = !Full(onListener.count, perListener) && !Full(fromAddress.count, perAddress);
    if (admit) {
        [onListener addObject:@(now)];
        [fromAddress addObject:@(now)];
    }
    os_unfair_lock_unlock(&_lock);
    return admit;
}

- (NSUInteger)pendingOnListener:(NSString *)listener {
    os_unfair_lock_lock(&_lock);
    NSUInteger count = 0;
    for (SZFriendsPendingPlace *place in _places) count += [place.listener isEqualToString:listener];
    os_unfair_lock_unlock(&_lock);
    return count;
}

- (NSUInteger)pendingFromAddress:(NSString *)address {
    os_unfair_lock_lock(&_lock);
    NSUInteger count = 0;
    for (SZFriendsPendingPlace *place in _places) count += [place.address isEqualToString:address];
    os_unfair_lock_unlock(&_lock);
    return count;
}

@end
