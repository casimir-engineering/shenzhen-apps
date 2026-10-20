// Which discovery adapters the helper runs, and the harness's seams (SZFriendsHelperTesting.h).

#import "service/helper/SZFriendsHelperTesting.h"

#import "client/szfriends_client.h"

static NSArray<id<SZFriendsDiscoveryAdapter>> * (^SZFriendsExtraAdapters)(dispatch_queue_t);
static BOOL SZFriendsWithholdAcknowledgements;
static double SZFriendsChunkBytesPerSecond;
static NSTimeInterval SZFriendsOutboxClockOffset;
static NSTimeInterval SZFriendsStrangerIdleTimeoutOverride;
static NSTimeInterval SZFriendsStrangerSessionLifeOverride;
static NSString *SZFriendsInitialFriendsID;
static SZFriendsAdmissionLimits *SZFriendsAdmissionLimitsOverride;

@implementation SZFriendsHelperTestHooks

+ (NSArray<id<SZFriendsDiscoveryAdapter>> * (^)(dispatch_queue_t))extraAdapters {
    return SZFriendsExtraAdapters;
}
+ (void)setExtraAdapters:(NSArray<id<SZFriendsDiscoveryAdapter>> * (^)(dispatch_queue_t))extraAdapters {
    SZFriendsExtraAdapters = [extraAdapters copy];
}
+ (BOOL)withholdAcknowledgements {
    return SZFriendsWithholdAcknowledgements;
}
+ (void)setWithholdAcknowledgements:(BOOL)withhold {
    SZFriendsWithholdAcknowledgements = withhold;
}
+ (double)chunkBytesPerSecond {
    return SZFriendsChunkBytesPerSecond;
}
+ (void)setChunkBytesPerSecond:(double)rate {
    SZFriendsChunkBytesPerSecond = rate;
}
+ (NSTimeInterval)outboxClockOffset {
    return SZFriendsOutboxClockOffset;
}
+ (void)setOutboxClockOffset:(NSTimeInterval)offset {
    SZFriendsOutboxClockOffset = offset;
}
+ (NSTimeInterval)strangerIdleTimeout {
    return SZFriendsStrangerIdleTimeoutOverride;
}
+ (void)setStrangerIdleTimeout:(NSTimeInterval)timeout {
    SZFriendsStrangerIdleTimeoutOverride = timeout;
}
+ (NSTimeInterval)strangerSessionLife {
    return SZFriendsStrangerSessionLifeOverride;
}
+ (void)setStrangerSessionLife:(NSTimeInterval)life {
    SZFriendsStrangerSessionLifeOverride = life;
}
+ (NSString *)initialFriendsID {
    return SZFriendsInitialFriendsID;
}
+ (void)setInitialFriendsID:(NSString *)friendsID {
    SZFriendsInitialFriendsID = [friendsID copy];
}
+ (SZFriendsAdmissionLimits *)admissionLimits {
    return SZFriendsAdmissionLimitsOverride;
}
+ (void)setAdmissionLimits:(SZFriendsAdmissionLimits *)limits {
    SZFriendsAdmissionLimitsOverride = [limits copy];
}

@end

BOOL SZFriendsHelperTestServiceTypeIsValid(NSString *serviceType) {
    if (![serviceType hasPrefix:@"_"] || ![serviceType hasSuffix:@"._tcp"]) return NO;
    NSString *name = [serviceType substringWithRange:NSMakeRange(1, serviceType.length - 6)];
    // DNS-SD service names are at most 15 characters; the production name is refused so a test helper never
    // answers, or is found by, a real helper on this Mac.
    if (name.length < 1 || name.length > 15 || [serviceType isEqualToString:SZFriendsBonjourServiceType]) return NO;
    NSCharacterSet *allowed =
        [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
                                                           @"0123456789-"];
    return [name rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

NSArray<id<SZFriendsDiscoveryAdapter>> *SZFriendsHelperMakeAdapters(dispatch_queue_t queue,
                                                                    NSDictionary<NSString *, NSString *> *env) {
    NSMutableArray<id<SZFriendsDiscoveryAdapter>> *adapters = [NSMutableArray array];
    if (env[@SZFRIENDS_ENV_STATE_DIR] == nil) {
        [adapters addObject:SZFriendsMakeNetworkAdapter(queue)];
        [adapters addObject:SZFriendsMakeBluetoothAdapter(queue)];
    } else {
        // Tests and probes: a real browser on Wi-Fi would ask for Local Network access, and a Bluetooth manager
        // for Bluetooth access, on a Mac whose owner is working. Loopback only, and only when asked for.
        NSString *serviceType = env[@"SZFRIENDS_TEST_SERVICE_TYPE"];
        if (SZFriendsHelperTestServiceTypeIsValid(serviceType)) {
            [adapters addObject:SZFriendsMakeLoopbackNetworkAdapter(queue, serviceType)];
        }
    }
    NSArray<id<SZFriendsDiscoveryAdapter>> * (^extra)(dispatch_queue_t) = SZFriendsHelperTestHooks.extraAdapters;
    if (extra != nil) [adapters addObjectsFromArray:extra(queue) ?: @[]];
    return adapters;
}
