#import "SPDFMacFriendsChatGrant.h"
#import "SPDFMacFriendsComposerText.h"

NSNotificationName const SPDFMacFriendsChatGrantDidChangeNotification = @"SPDFMacFriendsChatGrantDidChange";

// The bar's minute count changes at most this often; expiry itself is checked by the clock at every tool call.
static const NSTimeInterval kTickInterval = 20.0;

NSDate* SPDFMacFriendsGrantExpiry(SPDFMacFriendsGrantLength length, NSDate* now, NSCalendar* calendar) {
    if (length == SPDFMacFriendsGrantLengthHour) return [now dateByAddingTimeInterval:3600];
    if (length != SPDFMacFriendsGrantLengthUntilTomorrow) return nil;
    NSDate* tomorrow = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:now options:0];
    return tomorrow ? [calendar startOfDayForDate:tomorrow] : nil;
}

NSArray<NSDictionary<NSString*, id>*>* SPDFMacFriendsGrantLengthChoices(void) {
    NSString* all = SPDFMacFriendsAllChatsChoiceID;
    return @[@{@"id" : all, @"name" : @"This request", @"length" : @(SPDFMacFriendsGrantLengthRequest)},
             @{@"id" : all, @"name" : @"1 hour", @"length" : @(SPDFMacFriendsGrantLengthHour)},
             @{@"id" : all, @"name" : @"Until tomorrow", @"length" : @(SPDFMacFriendsGrantLengthUntilTomorrow)}];
}

@implementation SPDFMacFriendsChatGrant {
    NSDate* (^_clock)(void);
    NSCalendar* _calendar;
    uint64_t _token, _lastToken;
    BOOL _available;
    NSTimer* _timer;
}

- (instancetype)init { return [self initWithClock:nil calendar:nil]; }

- (instancetype)initWithClock:(NSDate* (^)(void))clock calendar:(NSCalendar*)calendar {
    if (!(self = [super init])) return nil;
    _clock = clock ? [clock copy] : [^NSDate* { return [NSDate date]; } copy];
    _calendar = calendar ?: NSCalendar.currentCalendar;
    return self;
}

- (void)dealloc { [_timer invalidate]; }

- (BOOL)active { return _token != 0 && _expiry && [_clock() compare:_expiry] == NSOrderedAscending; }
- (uint64_t)activeToken { return self.active ? _token : 0; }
- (BOOL)isActiveToken:(uint64_t)token { return token != 0 && token == self.activeToken; }
- (NSTimeInterval)remaining { return self.active ? [_expiry timeIntervalSinceDate:_clock()] : 0; }

- (void)changed {
    [NSNotificationCenter.defaultCenter postNotificationName:SPDFMacFriendsChatGrantDidChangeNotification
                                                      object:self];
}

- (BOOL)grantAllChatsFor:(SPDFMacFriendsGrantLength)length {
    NSDate* expiry = _available ? SPDFMacFriendsGrantExpiry(length, _clock(), _calendar) : nil;
    if (!expiry) return NO;
    _token = ++_lastToken;
    _expiry = expiry;
    _length = length;
    [_timer invalidate];
    __weak SPDFMacFriendsChatGrant* weakSelf = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:kTickInterval repeats:YES block:^(NSTimer* timer) {
        (void)timer;
        [weakSelf tick];
    }];
    _timer.tolerance = 2.0;
    [self changed];
    return YES;
}

- (void)end {
    BOOL had = _token != 0;
    _token = 0;
    _expiry = nil;
    _length = SPDFMacFriendsGrantLengthRequest;
    [_timer invalidate];
    _timer = nil;
    if (had) [self changed];
}

- (void)stop { [self end]; }

- (void)friendsAvailabilityChanged:(BOOL)available {
    _available = available;
    if (!available) [self end];
}

- (void)tick {
    if (!_token) return;
    if (!self.active) [self end];
    else [self changed];
}

@end

static NSString* SPDFMacFriendsGrantTimeLeft(SPDFMacFriendsChatGrant* grant) {
    if (grant.length == SPDFMacFriendsGrantLengthUntilTomorrow) return @"until midnight";
    return [NSString stringWithFormat:@"%ld min left", (long)MAX(1.0, ceil(grant.remaining / 60.0))];
}

NSString* SPDFMacFriendsGrantBarText(SPDFMacFriendsChatGrant* grant) {
    if (!grant.active) return nil;
    NSString* left = SPDFMacFriendsGrantTimeLeft(grant);
    return [@"The assistant can read all your Friends chats · " stringByAppendingString:left];
}

NSString* SPDFMacFriendsGrantBarShortText(SPDFMacFriendsChatGrant* grant) {
    if (!grant.active) return nil;
    return [@"All Friends chats · " stringByAppendingString:SPDFMacFriendsGrantTimeLeft(grant)];
}

@implementation SPDFMacFriendsGrantChip {
    uint64_t _grantToken;
}
+ (instancetype)chipForGrantToken:(uint64_t)token {
    SPDFMacFriendsGrantChip* chip = [self friendsChipWithConversationIDs:nil displayName:@"All Friends chats"];
    chip->_grantToken = token;
    return chip;
}
- (uint64_t)grantToken { return _grantToken; }
@end
