// Pure decisions of the helper: protocol negotiation, handover ordering and when to exit (SZFriendsHelper.h).
// No clock reads, sockets or state here, so every rule is tested with plain values.

#import "service/helper/SZFriendsHelperInternal.h"

BOOL SZFriendsNegotiateProtocol(SZFriendsProtocolVersion helperVersion, NSInteger helperMinMajor,
                                SZFriendsProtocolVersion clientVersion, NSInteger clientMinMajor,
                                SZFriendsProtocolVersion *negotiated) {
    if (helperVersion.major < 1 || clientVersion.major < 1 || helperVersion.minor < 0 || clientVersion.minor < 0 ||
        helperMinMajor < 1 || clientMinMajor < 1 || helperMinMajor > helperVersion.major ||
        clientMinMajor > clientVersion.major) {
        return NO;
    }
    // Each side accepts the majors from its min_major to its own major; take the highest both accept.
    NSInteger lowest = MAX(helperMinMajor, clientMinMajor);
    NSInteger major = MIN(helperVersion.major, clientVersion.major);
    if (major < lowest) return NO;
    // Within that major, the lower minor. A side whose own major is newer speaks the older major as it was
    // frozen when the newer one appeared, which includes every minor the older side can know, so the older
    // side's minor applies.
    NSInteger minor;
    if (helperVersion.major == major && clientVersion.major == major) {
        minor = MIN(helperVersion.minor, clientVersion.minor);
    } else if (helperVersion.major == major) {
        minor = helperVersion.minor;
    } else {
        minor = clientVersion.minor;
    }
    if (negotiated) *negotiated = (SZFriendsProtocolVersion){.major = major, .minor = minor};
    return YES;
}

BOOL SZFriendsEmbeddedHelperIsNewer(SZFriendsProtocolVersion runningProtocol, uint64_t runningBuild,
                                    SZFriendsProtocolVersion embeddedProtocol, uint64_t embeddedBuild) {
    if (embeddedProtocol.major != runningProtocol.major) return embeddedProtocol.major > runningProtocol.major;
    if (embeddedProtocol.minor != runningProtocol.minor) return embeddedProtocol.minor > runningProtocol.minor;
    // Equal builds never hand over, so two apps embedding the same helper cannot ping-pong.
    return embeddedBuild > runningBuild;
}

BOOL SZFriendsHandoverBuildIsPlausible(uint64_t runningBuild, uint64_t claimedBuild) {
    // YYMMDD of our own build plus one year, with any build number of that day (dividing by 100 first leaves room,
    // so the sum cannot overflow). Our build 0 (a helper run outside a bundle) still bounds the claim, at year 1.
    const uint64_t day = 100, year = 10000;
    return claimedBuild / day <= runningBuild / day + year;
}

@implementation SZFriendsLifecyclePolicy

- (instancetype)init {
    if ((self = [super init])) {
        _gracePeriod = 10;
        _firstClientDeadline = 30;
        _handoverDeadline = 5;
    }
    return self;
}

- (SZFriendsExitReason)exitReasonWithClientCount:(NSUInteger)clientCount
                                       startedAt:(NSDate *)startedAt
                                  everHadClient:(BOOL)everHadClient
                                  lastClientLeft:(nullable NSDate *)lastClientLeft
                                disabledByLastApp:(BOOL)disabledByLastApp
                              handoverRequestedAt:(nullable NSDate *)handoverRequestedAt
                                     workInFlight:(BOOL)workInFlight
                                             now:(NSDate *)now {
    // A handover goes ahead with clients connected: they reconnect to the successor. It waits only for work in
    // flight, and never past the deadline, since a stuck transfer resumes in the successor anyway.
    if (handoverRequestedAt != nil) {
        NSTimeInterval waited = [now timeIntervalSinceDate:handoverRequestedAt];
        if (!workInFlight || waited >= self.handoverDeadline) return SZFriendsExitReasonHandover;
    }
    if (clientCount > 0) return SZFriendsExitReasonNone;
    if (everHadClient) {
        // Friends turned off in the last app: nothing to wait for.
        if (disabledByLastApp) return SZFriendsExitReasonDisabled;
        if (lastClientLeft != nil && [now timeIntervalSinceDate:lastClientLeft] >= self.gracePeriod) {
            return SZFriendsExitReasonIdle;
        }
        return SZFriendsExitReasonNone;
    }
    // Nobody ever came: the app that spawned us died before connecting.
    if ([now timeIntervalSinceDate:startedAt] >= self.firstClientDeadline) return SZFriendsExitReasonNoClient;
    return SZFriendsExitReasonNone;
}

@end
