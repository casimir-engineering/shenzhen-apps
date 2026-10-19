// The prober's budget, configuration and result (SZFriendsNATProber.h).

#import "service/online/nat/SZFriendsNATProber.h"

#include <time.h>

@implementation SZFriendsNATProbeBudget {
    NSTimeInterval _interval;
    NSTimeInterval (^_clock)(void);
    NSMutableDictionary<NSData *, NSNumber *> *_lastRun;
    BOOL _running;
}

+ (SZFriendsNATProbeBudget *)sharedBudget {
    static SZFriendsNATProbeBudget *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[SZFriendsNATProbeBudget alloc] init];
    });
    return shared;
}

- (instancetype)initWithInterval:(NSTimeInterval)interval clock:(NSTimeInterval (^)(void))clock {
    if ((self = [super init])) {
        _interval = interval;
        _clock = [clock copy];
        if (_clock == nil) {
            _clock = ^NSTimeInterval {
                return (NSTimeInterval)clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1e9;
            };
        }
        _lastRun = [NSMutableDictionary dictionary];
    }
    return self;
}

- (instancetype)init {
    return [self initWithInterval:600 clock:nil];
}

- (BOOL)beginRunForPeer:(NSData *)peer {
    @synchronized(self) {
        NSTimeInterval now = _clock();
        if (_running || peer.length == 0) return NO;
        NSNumber *last = _lastRun[peer];
        if (last != nil && now - last.doubleValue < _interval) return NO;
        // Forget peers whose interval has passed, so the table stays as small as the last ten minutes' runs.
        for (NSData *key in _lastRun.allKeys) {
            if (now - _lastRun[key].doubleValue >= _interval) [_lastRun removeObjectForKey:key];
        }
        _lastRun[[peer copy]] = @(now);
        _running = YES;
        return YES;
    }
}

- (void)endRun {
    @synchronized(self) {
        _running = NO;
    }
}

@end

// ICE ufrags and passwords use ALPHA, DIGIT, "+" and "/" (RFC 8839 § 5.4).
static BOOL IsICEString(NSString *text, NSUInteger minimum, NSUInteger maximum) {
    if (text.length < minimum || text.length > maximum) return NO;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        BOOL ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '+' || c == '/';
        if (!ok) return NO;
    }
    return YES;
}

@implementation SZFriendsNATProberConfiguration

- (BOOL)isValid {
    return (_role == SZFriendsNATProbeRoleHard || _role == SZFriendsNATProbeRoleEasy) && _peer.length > 0 &&
           _remote != nil && IsICEString(_localUfrag, SZFriendsNATProbeUfragMin, SZFriendsNATProbeUfragMax) &&
           IsICEString(_remoteUfrag, SZFriendsNATProbeUfragMin, SZFriendsNATProbeUfragMax) &&
           IsICEString(_localPassword, SZFriendsNATProbePasswordMin, 256) &&
           IsICEString(_remotePassword, SZFriendsNATProbePasswordMin, 256) && _budget != nil &&
           _portRangeLow >= 1024 && _portRangeHigh >= _portRangeLow && _socketCount <= SZFriendsNATProbeSockets &&
           _probeMax <= SZFriendsNATProbeMax && _duration > 0 && _duration <= 12 && _linger <= 1;
}

- (instancetype)init {
    if ((self = [super init])) {
        _budget = [SZFriendsNATProbeBudget sharedBudget];
        _duration = 12;
        _socketCount = SZFriendsNATProbeSockets;
        _probeMax = SZFriendsNATProbeMax;
        _linger = 0.5;
        _portRangeLow = 1024;
        _portRangeHigh = 65535;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    SZFriendsNATProberConfiguration *copy = [[[self class] allocWithZone:zone] init];
    copy.role = _role;
    copy.peer = _peer;
    copy.remote = _remote;
    copy.presented = _presented;
    copy.stunServer = _stunServer;
    copy.localUfrag = _localUfrag;
    copy.localPassword = _localPassword;
    copy.remoteUfrag = _remoteUfrag;
    copy.remotePassword = _remotePassword;
    copy.budget = _budget;
    copy.duration = _duration;
    copy.socketCount = _socketCount;
    copy.probeMax = _probeMax;
    copy.linger = _linger;
    copy.portRangeLow = _portRangeLow;
    copy.portRangeHigh = _portRangeHigh;
    copy.loopbackOnly = _loopbackOnly;
    copy.localPorts = _localPorts;
    return copy;
}

@end

@interface SZFriendsNATProbeHit ()
- (instancetype)initWithLocalPort:(uint16_t)localPort
                           remote:(SZFriendsNATEndpoint *)remote
                       probesSent:(NSUInteger)probesSent;
@end

@implementation SZFriendsNATProbeHit

- (instancetype)initWithLocalPort:(uint16_t)localPort
                           remote:(SZFriendsNATEndpoint *)remote
                       probesSent:(NSUInteger)probesSent {
    if ((self = [super init])) {
        _localPort = localPort;
        _remote = remote;
        _probesSent = probesSent;
    }
    return self;
}

@end
