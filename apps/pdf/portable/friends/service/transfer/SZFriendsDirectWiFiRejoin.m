// Coming back from a Wi-Fi Direct boost (SZFriendsDirectWiFiBoost.h, ADR 0019), as the Rust core's transfer/boost/rejoin.rs:
// the record written before leaving the network, and the rejoin that runs when the boost ends or at the next launch.

#import "service/transfer/SZFriendsDirectWiFiBoost.h"

#pragma mark - Coming back

@implementation SZFriendsBoostSaved

+ (instancetype)savedWithNetwork:(NSString *)network
                     networkName:(NSString *)networkName
                          joined:(NSString *)joined
                          leftAt:(NSTimeInterval)leftAt {
    SZFriendsBoostSaved *saved = [self new];
    saved->_network = [network copy];
    saved->_networkName = [networkName copy];
    saved->_joined = [joined copy];
    saved->_leftAt = leftAt;
    return saved;
}

+ (instancetype)savedFromJSON:(NSData *)json {
    NSDictionary *value = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL] : nil;
    if (![value isKindOfClass:[NSDictionary class]] || ![value[@"version"] isEqual:@1]) return nil;
    id (^text)(NSString *) = ^id(NSString *key) {
        id v = value[key];
        return [v isKindOfClass:[NSString class]] ? v : nil;
    };
    NSString *joined = text(@"joined");
    NSNumber *left = [value[@"left_at"] isKindOfClass:[NSNumber class]] ? value[@"left_at"] : nil;
    if (joined.length == 0 || left == nil) return nil;
    return [self savedWithNetwork:text(@"network") networkName:text(@"network_name") joined:joined
                           leftAt:left.doubleValue];
}

- (NSData *)JSON {
    NSDictionary *value = @{
        @"version" : @1,
        @"network" : _network ?: [NSNull null],
        @"network_name" : _networkName ?: [NSNull null],
        @"joined" : _joined,
        @"left_at" : @(_leftAt),
    };
    return [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:NULL];
}

@end

typedef NS_ENUM(NSInteger, SZFriendsRejoinStep) {
    SZFriendsRejoinIdle,
    SZFriendsRejoinAway,
    SZFriendsRejoinRejoining,
    SZFriendsRejoinChecking,
    SZFriendsRejoinFailed,
};

@implementation SZFriendsBoostRejoin {
    __weak id<SZFriendsBoostRejoinDriver> _driver;
    SZFriendsRejoinStep _step;
    SZFriendsBoostSaved *_saved;
    NSUInteger _tries;
    NSTimeInterval _at, _since;
}

- (instancetype)initWithDriver:(id<SZFriendsBoostRejoinDriver>)driver {
    if ((self = [super init])) _driver = driver;
    return self;
}

- (void)launchedWithRecord:(SZFriendsBoostSaved *)record now:(NSTimeInterval)now {
    if (record == nil) return;
    _saved = record;
    _step = SZFriendsRejoinAway;
    [self comeBackAt:now];
}

- (BOOL)away {
    return _step != SZFriendsRejoinIdle && _step != SZFriendsRejoinFailed;
}

- (void)leaving:(SZFriendsBoostSaved *)saved {
    _saved = saved;
    _step = SZFriendsRejoinAway;
    [_driver rejoinWrite:saved];
}

- (void)comeBackAt:(NSTimeInterval)now {
    if (_step != SZFriendsRejoinAway) return;
    _step = SZFriendsRejoinRejoining;
    _tries = 1;
    _at = now;
    [_driver rejoinNetwork:_saved.network leaving:_saved.joined];
}

- (void)rejoined:(BOOL)ok now:(NSTimeInterval)now {
    if (_step != SZFriendsRejoinRejoining) return;
    if (ok) {
        if (_saved.network == nil) return [self done];
        _step = SZFriendsRejoinChecking;
        _since = now;
        _at = now;
        [_driver rejoinCheckOnline];
    } else if (_tries >= SZFriendsBoostRejoinTries) {
        [self giveUp];
    } else {
        _at = now;
    }
}

- (void)online:(BOOL)online now:(NSTimeInterval)now {
    if (_step != SZFriendsRejoinChecking) return;
    if (online) {
        [self done];
    } else if (now - _since >= SZFriendsBoostOnlineWithin) {
        [self giveUp];
    } else {
        _at = now;
    }
}

- (void)tick:(NSTimeInterval)now {
    if (_step == SZFriendsRejoinRejoining && now - _at >= SZFriendsBoostRejoinAgainAfter) {
        if (_tries >= SZFriendsBoostRejoinTries) return [self giveUp];
        _tries++;
        _at = now;
        [_driver rejoinNetwork:_saved.network leaving:_saved.joined];
    } else if (_step == SZFriendsRejoinChecking && now - _at >= SZFriendsBoostCheckEvery) {
        if (now - _since >= SZFriendsBoostOnlineWithin) return [self giveUp];
        _at = now;
        [_driver rejoinCheckOnline];
    }
}

- (void)done {
    _step = SZFriendsRejoinIdle;
    [_driver rejoinForget];
}

- (void)giveUp {
    // The record goes too: the person decides which network to be on now, and a later launch must not fight it.
    _step = SZFriendsRejoinFailed;
    [_driver rejoinForget];
    [_driver rejoinTellNetworkName:_saved.networkName];
}

@end
