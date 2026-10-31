// SZFriendsRouteMeter.h; the constants are the Rust core's transfer/meter.rs.

#import "service/transfer/SZFriendsRouteMeter.h"

static const double SZFriendsMeterActiveSeconds = 1.5;   // a route carried it "right now"
static const double SZFriendsMeterRateSeconds = 3.0;     // the speed's exponential average
static const double SZFriendsMeterSampleSeconds = 0.25;  // samples closer than this fold into the next
static const double SZFriendsMeterFirstRateSeconds = 1.0; // no speed before the first bytes are this old
static const double SZFriendsMeterLeftTolerance = 0.25;  // the time left keeps counting down within this share (or 2 s)
static const double SZFriendsMeterForgetSeconds = 120.0;

static const SZFriendsRouteMethod SZFriendsMeterRoutes[5] = {
    SZFriendsRouteMethodLAN, SZFriendsRouteMethodPeerToPeerWiFi, SZFriendsRouteMethodInternet,
    SZFriendsRouteMethodBluetooth, SZFriendsRouteMethodRelay};

static NSInteger SZFriendsMeterSlot(SZFriendsRouteMethod route) {
    for (NSInteger i = 0; i < 5; i++)
        if (SZFriendsMeterRoutes[i] == route) return i;
    return -1;
}

@implementation SZFriendsRouteReading
@end

@interface SZFriendsTransferMeter : NSObject {
@public
    uint64_t bytes[5];
    double first[5], last[5];
    uint64_t total, sampleTotal;
    double began, sampleAt, rate, touched;
    BOOL hasLeft;
    double leftAt, leftSaid;
}
@end
@implementation SZFriendsTransferMeter
@end

@implementation SZFriendsRouteMeter {
    NSMutableDictionary<NSString *, SZFriendsTransferMeter *> *_transfers;
}

- (instancetype)init {
    if ((self = [super init])) _transfers = [NSMutableDictionary dictionary];
    return self;
}

- (void)carried:(uint64_t)bytes route:(SZFriendsRouteMethod)route transfer:(NSString *)transferID now:(double)now {
    NSInteger i = SZFriendsMeterSlot(route);
    if (i < 0 || bytes == 0 || transferID.length == 0) return;
    SZFriendsTransferMeter *m = _transfers[transferID];
    if (m == nil) {
        for (NSString *key in _transfers.allKeys)
            if (now - _transfers[key]->touched >= SZFriendsMeterForgetSeconds) [_transfers removeObjectForKey:key];
        m = [SZFriendsTransferMeter new];
        m->began = now;
        m->sampleAt = now;
        _transfers[transferID] = m;
    }
    if (m->bytes[i] == 0 || now - m->last[i] > SZFriendsMeterActiveSeconds) m->first[i] = now;
    m->bytes[i] += bytes;
    m->last[i] = now;
    m->total += bytes;
    m->touched = now;
}

- (void)forget:(NSString *)transferID {
    [_transfers removeObjectForKey:transferID];
}

- (SZFriendsRouteReading *)readingFor:(NSString *)transferID remaining:(uint64_t)remaining now:(double)now {
    SZFriendsTransferMeter *m = _transfers[transferID];
    if (m == nil) return nil;
    double dt = now - m->sampleAt;
    if (dt >= SZFriendsMeterSampleSeconds && now - m->began >= SZFriendsMeterFirstRateSeconds) {
        double instant = (double)(m->total - m->sampleTotal) / dt;
        if (m->rate > 0) m->rate += (1.0 - exp(-dt / SZFriendsMeterRateSeconds)) * (instant - m->rate);
        else m->rate = instant;
        m->sampleAt = now;
        m->sampleTotal = m->total;
    }
    SZFriendsRouteReading *reading = [SZFriendsRouteReading new];
    reading.bytesPerSecond = m->rate;
    NSMutableDictionary<NSNumber *, NSNumber *> *carried = [NSMutableDictionary dictionary];
    NSMutableArray<NSNumber *> *active = [NSMutableArray array];
    for (NSInteger i = 0; i < 5; i++) {
        if (m->bytes[i] == 0) continue;
        carried[@(SZFriendsMeterRoutes[i])] = @(m->bytes[i]);
        // In use: carried something lately, and no other route took over since (one that began after this one's
        // last bytes replaced it, as the direct route replaces the relay: the icons switch at once).
        BOOL recent = now - m->last[i] <= SZFriendsMeterActiveSeconds;
        BOOL replaced = NO;
        for (NSInteger j = 0; j < 5; j++)
            if (j != i && m->bytes[j] > 0 && m->first[j] > m->last[i]) replaced = YES;
        if (recent && !replaced) [active addObject:@(SZFriendsMeterRoutes[i])];
    }
    reading.routeBytes = carried;
    reading.activeRoutes = active;
    if (m->rate > 0 && remaining > 0) {
        double estimate = (double)remaining / m->rate;
        double predicted = m->hasLeft ? m->leftSaid - (now - m->leftAt) : 0;
        BOOL kept = m->hasLeft && predicted > 0 &&
                    fabs(estimate - predicted) <= MAX(predicted * SZFriendsMeterLeftTolerance, 2.0);
        if (!kept) {
            m->hasLeft = YES;
            m->leftAt = now;
            m->leftSaid = estimate;
        }
        reading.secondsLeft = MAX(1.0, kept ? predicted : estimate);
    } else {
        m->hasLeft = NO;
    }
    return reading;
}

@end
