// The 5-minute visibility deadline (brief § Product: expiry, sleep/wake and disabling never extend it).

#import "service/discovery/SZFriendsDiscovery.h"

#include <mach/mach_time.h>

const NSTimeInterval SZFriendsVisibilityDuration = 300;

SZFriendsInstant SZFriendsInstantNow(void) {
    // mach_continuous_time keeps counting while the Mac sleeps, unlike mach_absolute_time: a deadline measured on
    // a clock that pauses in sleep would stretch by the length of every nap.
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        mach_timebase_info(&timebase);
    });
    double ticks = (double)mach_continuous_time();
    SZFriendsInstant now;
    now.wall = [NSDate date].timeIntervalSince1970;
    now.continuous = ticks * timebase.numer / timebase.denom / 1e9;
    return now;
}

@implementation SZFriendsVisibility {
    NSTimeInterval _deadlineWall;       // 0 when hidden
    BOOL _hasContinuousDeadline;        // NO for a deadline restored from the store
    NSTimeInterval _deadlineContinuous;
}

- (instancetype)initWithStoredDeadline:(NSDate *)storedDeadline now:(SZFriendsInstant)now {
    if ((self = [super init])) {
        if (storedDeadline) {
            NSTimeInterval remaining = storedDeadline.timeIntervalSince1970 - now.wall;
            // More than 5 minutes left can only mean the clock moved back since the deadline was stored; staying
            // visible on a deadline nobody chose would extend it, so drop it instead.
            if (remaining > 0 && remaining <= SZFriendsVisibilityDuration) {
                _deadlineWall = storedDeadline.timeIntervalSince1970;
            }
        }
    }
    return self;
}

- (NSDate *)deadline {
    return _deadlineWall > 0 ? [NSDate dateWithTimeIntervalSince1970:_deadlineWall] : nil;
}

- (NSDate *)startAt:(SZFriendsInstant)now {
    if (![self isVisibleAt:now]) {
        _deadlineWall = now.wall + SZFriendsVisibilityDuration;
        _deadlineContinuous = now.continuous + SZFriendsVisibilityDuration;
        _hasContinuousDeadline = YES;
    }
    return self.deadline;
}

- (void)stop {
    _deadlineWall = 0;
    _hasContinuousDeadline = NO;
}

- (BOOL)isVisibleAt:(SZFriendsInstant)now {
    if (_deadlineWall <= 0) return NO;
    BOOL wallOver = now.wall >= _deadlineWall;
    // Setting the wall clock back would otherwise buy time; the continuous clock cannot be set at all.
    BOOL continuousOver = _hasContinuousDeadline && now.continuous >= _deadlineContinuous;
    // A wall clock moved back below the start leaves more than 5 minutes "remaining": also over.
    BOOL wallImplausible = _deadlineWall - now.wall > SZFriendsVisibilityDuration;
    if (wallOver || continuousOver || wallImplausible) {
        [self stop];
        return NO;
    }
    return YES;
}

- (NSTimeInterval)remainingAt:(SZFriendsInstant)now {
    if (![self isVisibleAt:now]) return 0;
    NSTimeInterval remaining = _deadlineWall - now.wall;
    if (_hasContinuousDeadline) remaining = MIN(remaining, _deadlineContinuous - now.continuous);
    return MAX(0, remaining);
}

@end
