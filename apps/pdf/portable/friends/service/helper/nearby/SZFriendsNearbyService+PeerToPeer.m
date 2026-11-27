// Peer-to-peer Wi-Fi (AWDL) under the owner's rule (ADR 0022; ADR 0021 for how it is turned on and off).
//
// The owner: "use wifi direct only if the conditions are matched, which means both devices are not on a wifi". A
// Bonjour browser, listener or connection that includes peer-to-peer Wi-Fi keeps AWDL awake, and awake AWDL takes the
// Wi-Fi radio off the network's channel for about a fifth of the time (measured: 72 ms in every 524 ms, every packet
// of the Mac's own Wi-Fi traffic waiting behind it). So:
//   - AWDL is on exactly while this Mac is on no Wi-Fi network (Ethernet only, or no network at all): then it costs
//     no network anything. Joining a Wi-Fi network turns it off at once, and sessions or lanes still on it close.
//   - New sessions say so in their handshake (capability bit 6, SZFriendsSetDirectWiFiAllowedHere), and a session or
//     lane on peer-to-peer Wi-Fi stays open only when the friend's handshake said the same (+Sessions); a friend
//     whose helper predates the rule never says it.
//   - A group's scheduler may ask for a direct Wi-Fi lane only while both allow it and the group has no LAN lane; it is
//     dialed once the friend is sighted there. Never beside a LAN for speed: the old "LAN below 25 MB/s" triggers,
//     which turned AWDL on mid-transfer on a Mac on Wi-Fi, are gone.
// A group gives up on direct Wi-Fi for the rest of its transfer when no lane came within 20 s, when its lane ended,
// or when, 8 s after the lane came up, the group's rate is not 10 % better than before it (the sender closes the lane
// then). A boost's lane (ADR 0019) is the boost's and is left alone here.

#import <CoreWLAN/CoreWLAN.h>

#import "service/discovery/SZFriendsDiscoveryInternal.h"
#import "service/helper/nearby/SZFriendsNearbyInternal.h"
#import "service/transfer/SZFriendsDirectWiFiBoost.h"
#import "service/transfer/SZFriendsScheduler.h"

static const double SZFP2PGiveUpAfter = 20;    // no direct Wi-Fi lane this long after wanting one: give up
static const double SZFP2PJudgeAfter = 8;      // the lane's worth is measured this long after it came up...
static const double SZFP2PJudgeSettle = 3;     // ...from this long after (its start-up is not held against it)
static const double SZFP2PBeforeSpan = 5;      // against the group's rate over this long before it
static const double SZFP2PHelpsBy = 1.1;       // ...and kept only when the group's rate rose by this much
static const double SZFP2PTick = 1;
// A friend whose transfer got no direct Wi-Fi lane (an Android phone or a PC never shows up on AWDL, an older Mac
// never dials one) is not asked again for this long.
static const double SZFP2PNotAgainFor = 3600;

@interface SZFP2PGroup : NSObject
@property(nonatomic) double wantedAt;     // when this group first wanted direct Wi-Fi; 0 for not
@property(nonatomic) BOOL sightedThere;   // the friend was sighted on direct Wi-Fi when last looked (sender)
@property(nonatomic) BOOL hadLane, givenUp;
@property(nonatomic) uint64_t judgedLane; // the sender's direct Wi-Fi lane being measured, and from when
@property(nonatomic) double judgeFrom, rateBefore;
@property(nonatomic) BOOL judged;
// Sender: (time, bytes the friend acknowledged) once a second, the last 20 s: what the group really moves, before
// and with the lane (the scheduler's per-lane rates are peaks, not throughput).
@property(nonatomic, strong) NSMutableArray<NSArray<NSNumber *> *> *acked;
@end
@implementation SZFP2PGroup
@end

@interface SZFP2PState : NSObject
@property(nonatomic) BOOL on, started, tickScheduled;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, SZFP2PGroup *> *groups; // by head trace id
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *sighted;   // conversation -> last log text
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *notAgainUntil; // conversation -> time
@end
@implementation SZFP2PState
@end

static NSString *SZFP2PShort(NSString *hex) {
    return hex.length > 8 ? [hex substringToIndex:8] : (hex ?: @"?");
}

@implementation SZFriendsNearbyService (PeerToPeer)

- (SZFP2PState *)p2pState {
    SZFP2PState *state = self.peerToPeerStore;
    if (state == nil) {
        state = [[SZFP2PState alloc] init];
        state.groups = [NSMutableDictionary dictionary];
        state.sighted = [NSMutableDictionary dictionary];
        state.notAgainUntil = [NSMutableDictionary dictionary];
        self.peerToPeerStore = state;
    }
    return state;
}

- (SZFP2PGroup *)p2pGroupOfHead:(SZFriendsPeerLink *)head {
    SZFP2PState *state = [self p2pState];
    SZFP2PGroup *group = state.groups[@(head.traceID)];
    if (group == nil) {
        group = [[SZFP2PGroup alloc] init];
        state.groups[@(head.traceID)] = group;
    }
    return group;
}

- (void)startPeerToPeerPolicy {
    SZFP2PState *state = [self p2pState];
    if (state.started) return;
    state.started = YES;
    __weak SZFriendsNearbyService *weakSelf = self;
    for (id<SZFriendsDiscoveryAdapter> adapter in self.adapters) {
        SZFriendsNetworkAdapterOnNetworkChange(adapter, ^(BOOL hasNetwork) {
            SZFriendsNearbyService *strongSelf = weakSelf;
            if (strongSelf == nil) return;
            dispatch_async(strongSelf.queue, ^{
                SZFriendsHelperLog(@"direct Wi-Fi: this Mac is %@ (%@)",
                                   [strongSelf p2pOnWiFi] ? @"on a Wi-Fi network" : @"on no Wi-Fi network",
                                   hasNetwork ? @"has a network" : @"no network at all");
                [strongSelf peerToPeerEvaluate];
            });
        });
    }
    [self peerToPeerEvaluate];
}

- (BOOL)p2pOnWiFi {
    for (id<SZFriendsDiscoveryAdapter> adapter in self.adapters) {
        if (SZFriendsNetworkAdapterOnWiFi(adapter)) return YES;
    }
    // Joined but without a routable address (DHCP still asking, a network that gives none): no path runs over it, yet
    // the radio sits on the network's channel all the same. CoreWLAN knows (the name needs Location Services; the
    // channel and signal of a station do not).
    CWInterface *wifi = [CWWiFiClient sharedWiFiClient].interface;
    return wifi.powerOn && wifi.interfaceMode == kCWInterfaceModeStation &&
           (wifi.ssid != nil || wifi.bssid != nil || (wifi.wlanChannel != nil && wifi.rssiValue != 0));
}

// This Mac's side of the owner's rule: on no Wi-Fi network (a Mac is never a phone on mobile data).
- (BOOL)p2pAllowedHere {
    return ![self p2pOnWiFi];
}

- (BOOL)peerToPeerAllowedWith:(SZFriendsPeerLink *)link {
    SZFriendsPeerLink *head = link.laneHead ?: link;
    return [self p2pAllowedHere] && head.channel.directWiFiAllowed;
}

- (BOOL)p2pBoosting:(SZFriendsPeerLink *)head {
    return [self boostingGroup:head];
}

- (BOOL)boostingGroup:(SZFriendsPeerLink *)head {
    return [self.directWiFi hasBoostForGroup:[NSValue valueWithNonretainedObject:head]];
}

- (NSArray<SZFriendsPeerLink *> *)p2pLanesOfHead:(SZFriendsPeerLink *)head {
    NSMutableArray<SZFriendsPeerLink *> *lanes = [NSMutableArray array];
    for (SZFriendsPeerLink *lane in head.lanes.allObjects) {
        if (!lane.closed && lane.live && lane.raceRoute == SZFriendsRouteMethodPeerToPeerWiFi) [lanes addObject:lane];
    }
    return lanes;
}

// Bytes per second the friend acknowledged over [from, to], from the samples; negative without two samples there.
- (double)p2pAckedRateOf:(SZFP2PGroup *)group from:(double)from to:(double)to {
    NSArray<NSNumber *> *first = nil, *last = nil;
    for (NSArray<NSNumber *> *sample in group.acked) {
        double at = sample[0].doubleValue;
        if (at < from - 0.5 || at > to) continue;
        if (first == nil) first = sample;
        last = sample;
    }
    double span = last[0].doubleValue - first[0].doubleValue;
    if (first == nil || span < 1.5) return -1;
    return (last[1].doubleValue - first[1].doubleValue) / span;
}

- (void)p2pSampleAcked:(SZFriendsPeerLink *)head group:(SZFP2PGroup *)group now:(double)now {
    if (head.blocks.sending.count == 0) return;
    uint64_t acked = 0;
    NSDictionary<NSString *, NSNumber *> *progress = [head.blocks sendingProgress];
    for (NSNumber *bytes in progress.allValues) acked += bytes.unsignedLongLongValue;
    if (group.acked == nil) group.acked = [NSMutableArray array];
    // A file that finished leaves the sum: the samples start over rather than read a drop as a rate.
    if (group.acked.count && acked < group.acked.lastObject[1].unsignedLongLongValue) [group.acked removeAllObjects];
    [group.acked addObject:@[ @(now), @(acked) ]];
    while (group.acked.count && now - group.acked.firstObject[0].doubleValue > 20) [group.acked removeObjectAtIndex:0];
}

- (NSString *)p2pWhoOfHead:(SZFriendsPeerLink *)head {
    return [NSString stringWithFormat:@"%@ (#%llu)", [self traceWhoOfLink:head], (unsigned long long)head.traceID];
}

#pragma mark - What the groups ask

- (nullable NSString *)peerToPeerLaneRefusalBeside:(SZFriendsPeerLink *)head {
    SZFP2PGroup *group = [self p2pState].groups[@(head.traceID)];
    if (![self peerToPeerAllowedWith:head]) {
        return [self p2pAllowedHere] ? @"the friend's device does not allow direct Wi-Fi (on a Wi-Fi network)"
                                     : @"this Mac is on a Wi-Fi network";
    }
    if (group.givenUp) return @"direct Wi-Fi did not help this transfer, which goes on without it";
    if ([self p2pNotAgain:head]) return @"no direct Wi-Fi lane with this friend's device in the last hour";
    return nil;
}

- (BOOL)p2pNotAgain:(SZFriendsPeerLink *)head {
    NSString *conversationID = head.conversationID;
    NSNumber *until = conversationID ? [self p2pState].notAgainUntil[conversationID] : nil;
    if (until == nil) return NO;
    if (until.doubleValue > CFAbsoluteTimeGetCurrent()) return YES;
    [[self p2pState].notAgainUntil removeObjectForKey:conversationID];
    return NO;
}

- (BOOL)peerToPeerLaneWantedBeside:(SZFriendsPeerLink *)head {
    SZFP2PGroup *group = [self p2pGroupOfHead:head];
    if (group.givenUp || ![self peerToPeerAllowedWith:head]) return NO;
    if (group.wantedAt == 0) {
        group.wantedAt = CFAbsoluteTimeGetCurrent();
        SZFriendsHelperLog(@"direct Wi-Fi wanted for %@: no LAN lane, and neither device is on a Wi-Fi network",
                           [self p2pWhoOfHead:head]);
        [self p2pScheduleTick];
    }
    // Not sighted there yet: the lane is dialed when the friend shows up (-peerToPeerSightingsChanged).
    group.sightedThere = [self p2pState].on && [self p2pSightedOnPeerToPeer:head.conversationID];
    return [self p2pState].on;
}

// A sender whose group wants a direct Wi-Fi lane dials it the moment the friend shows up there, rather than at the
// scheduler's next ask (every 10 s).
- (void)peerToPeerSightingsChanged {
    SZFP2PState *state = self.peerToPeerStore;
    if (state == nil || !state.on) return;
    for (SZFriendsPeerLink *head in self.links.allObjects) {
        SZFP2PGroup *group = state.groups[@(head.traceID)];
        if (group == nil || group.wantedAt == 0 || group.givenUp || head.closed || head.lane) continue;
        BOOL sighted = [self p2pSightedOnPeerToPeer:head.conversationID];
        BOOL arrived = sighted && !group.sightedThere;
        group.sightedThere = sighted;
        if (!arrived || head.blocks.sending.count == 0 || [self p2pLanesOfHead:head].count > 0) continue;
        [self openLaneOfLink:head route:SZFriendsRouteMethodPeerToPeerWiFi];
    }
}

- (BOOL)p2pSightedOnPeerToPeer:(NSString *)conversationID {
    for (SZFriendsCandidate *candidate in self.coordinator.merger.candidates) {
        if (![candidate.conversationID isEqualToString:conversationID]) continue;
        for (SZFriendsSighting *sighting in candidate.sightings) {
            if (!sighting.isPublic && [sighting seenOnRoute:SZFriendsRouteMethodPeerToPeerWiFi]) return YES;
        }
    }
    return NO;
}

#pragma mark - The decision

- (void)p2pScheduleTick {
    SZFP2PState *state = [self p2pState];
    if (state.tickScheduled) return;
    state.tickScheduled = YES;
    __weak SZFriendsNearbyService *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SZFP2PTick * NSEC_PER_SEC)), self.queue, ^{
        SZFriendsNearbyService *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        [strongSelf p2pState].tickScheduled = NO;
        [strongSelf peerToPeerEvaluate];
    });
}

- (void)peerToPeerEvaluate {
    SZFP2PState *state = [self p2pState];
    if (self.shutDown) return;
    double now = CFAbsoluteTimeGetCurrent();
    BOOL allowedHere = [self p2pAllowedHere];
    SZFriendsSetDirectWiFiAllowedHere(allowedHere);
    NSMutableSet<NSNumber *> *heads = [NSMutableSet set];
    for (SZFriendsPeerLink *head in self.links.allObjects) {
        if (head.lane || head.closed || head.blocks == nil) continue;
        head.blocks.directWiFi = [self peerToPeerAllowedWith:head];
        if ([self p2pBoosting:head]) continue;
        // Between transfers nothing here needs watching: the next transfer starts afresh.
        if (!head.blocks.carriesTransfers) {
            [state.groups removeObjectForKey:@(head.traceID)];
            continue;
        }
        NSArray<SZFriendsPeerLink *> *lanes = [self p2pLanesOfHead:head];
        SZFP2PGroup *group = state.groups[@(head.traceID)];
        if (group == nil && lanes.count == 0) continue;
        if (group == nil) group = [self p2pGroupOfHead:head]; // the friend opened a direct Wi-Fi lane to us
        [heads addObject:@(head.traceID)];
        [self p2pSampleAcked:head group:group now:now];
        if (lanes.count > 0) {
            group.hadLane = YES;
            [self p2pJudgeLane:lanes.firstObject ofHead:head group:group now:now];
        } else if (group.hadLane && !group.givenUp) {
            group.givenUp = YES;
            SZFriendsHelperLog(@"direct Wi-Fi lane of %@ ended: the transfer goes on without direct Wi-Fi",
                               [self p2pWhoOfHead:head]);
        }
        if (group.wantedAt > 0 && !group.hadLane && !group.givenUp && now - group.wantedAt >= SZFP2PGiveUpAfter) {
            group.givenUp = YES;
            if (head.conversationID) state.notAgainUntil[head.conversationID] = @(now + SZFP2PNotAgainFor);
            SZFriendsHelperLog(@"direct Wi-Fi for %@: no lane there within %.0f s (%@); the transfer goes on "
                               @"without it",
                               [self p2pWhoOfHead:head], SZFP2PGiveUpAfter,
                               [self p2pSightedOnPeerToPeer:head.conversationID] ? @"the friend is sighted there"
                                                                                  : @"the friend never showed up there");
            SZFriendsHelperLog(@"direct Wi-Fi: not asked again for friend %@ for %.0f minutes",
                               SZFP2PShort(head.conversationID), SZFP2PNotAgainFor / 60);
        }
    }
    for (NSNumber *key in state.groups.allKeys) {
        if (![heads containsObject:key]) [state.groups removeObjectForKey:key];
    }
    if (allowedHere != state.on) {
        [self p2pTurn:allowedHere why:allowedHere ? @"this Mac is on no Wi-Fi network"
                                                  : @"this Mac is on a Wi-Fi network"];
    }
    // While direct Wi-Fi is on, joining a network is watched for every second too: one joined without an address
    // changes no path the monitor would report.
    if (state.groups.count > 0 || state.on) [self p2pScheduleTick];
}

// Sender: from 3 to 8 s after our direct Wi-Fi lane came up, the group must move at least 10 % more than in the 5 s
// before it; otherwise the lane only took airtime from the LAN (AWDL time-slices the same radio), and it is closed.
// Measured as bytes the friend acknowledged, never from the scheduler's estimates.
- (void)p2pJudgeLane:(SZFriendsPeerLink *)lane ofHead:(SZFriendsPeerLink *)head group:(SZFP2PGroup *)group now:(double)now {
    if (group.judged || head.blocks.sending.count == 0) return;
    if (group.judgedLane != lane.laneSerial) {
        // From the moment it went live: a tick later its first burst would already count as "before".
        double up = lane.liveAt ? lane.liveAt.timeIntervalSinceReferenceDate : now;
        group.judgedLane = lane.laneSerial;
        group.judgeFrom = up;
        group.rateBefore = [self p2pAckedRateOf:group from:up - SZFP2PBeforeSpan to:up];
        return;
    }
    if (now - group.judgeFrom < SZFP2PJudgeAfter) return;
    group.judged = YES;
    double before = group.rateBefore;
    double with = [self p2pAckedRateOf:group from:group.judgeFrom + SZFP2PJudgeSettle to:now];
    NSString *byLane = [self p2pLaneRatesOfHead:head];
    if (before <= 0 || with < 0) {
        SZFriendsHelperLog(@"direct Wi-Fi lane %llu of %@ kept: too little measured to judge it (%@)",
                           (unsigned long long)lane.laneSerial, [self p2pWhoOfHead:head], byLane);
        return;
    }
    if (with < before * SZFP2PHelpsBy) {
        group.givenUp = YES;
        SZFriendsHelperLog(@"direct Wi-Fi lane %llu of %@ did not help: %@ before it, %@ with it (%@); closing it, the "
                           @"transfer goes on without direct Wi-Fi",
                           (unsigned long long)lane.laneSerial, [self p2pWhoOfHead:head], SZFriendsTraceRate(before),
                           SZFriendsTraceRate(with), byLane);
        for (SZFriendsPeerLink *other in [self p2pLanesOfHead:head]) {
            [other.channel closeWithReason:SZFriendsCloseReasonNormal];
        }
        return;
    }
    SZFriendsHelperLog(@"direct Wi-Fi lane %llu of %@ helps: %@ before it, %@ with it (%@)",
                       (unsigned long long)lane.laneSerial, [self p2pWhoOfHead:head], SZFriendsTraceRate(before),
                       SZFriendsTraceRate(with), byLane);
}

// The scheduler's estimates per route, for the judgement's line.
- (NSString *)p2pLaneRatesOfHead:(SZFriendsPeerLink *)head {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSNumber *route in @[ @(SZFriendsRouteMethodLAN), @(SZFriendsRouteMethodPeerToPeerWiFi),
                               @(SZFriendsRouteMethodInternet), @(SZFriendsRouteMethodBluetooth) ]) {
        double rate = [head.blocks rateOfRoute:route.integerValue];
        if (rate > 0) {
            [parts addObject:[NSString stringWithFormat:@"%@ est %@", SZFriendsTraceRouteName(route.integerValue),
                                                        SZFriendsTraceRate(rate)]];
        }
    }
    return parts.count ? [parts componentsJoinedByString:@", "] : @"no estimates";
}

- (void)p2pTurn:(BOOL)on why:(NSString *)why {
    SZFP2PState *state = [self p2pState];
    state.on = on;
    for (id<SZFriendsDiscoveryAdapter> adapter in self.adapters) SZFriendsNetworkAdapterSetPeerToPeer(adapter, on);
    SZFriendsHelperLog(@"direct Wi-Fi (AWDL) %@: %@", on ? @"on" : @"off", why);
    if (on) return;
    // Any socket on awdl keeps AWDL awake: what still runs there ends, and the race finds those friends elsewhere.
    for (SZFriendsPeerLink *link in self.links.allObjects) {
        SZFriendsPeerLink *head = link.laneHead ?: link;
        if (link.closed || link.raceRoute != SZFriendsRouteMethodPeerToPeerWiFi || [self p2pBoosting:head]) continue;
        SZFriendsHelperLog(@"%@ #%llu %@ on direct Wi-Fi closed: direct Wi-Fi is off", link.lane ? @"lane" : @"session",
                           (unsigned long long)link.traceID, [self traceWhoOfLink:link]);
        [link.channel closeWithReason:SZFriendsCloseReasonNormal];
    }
    for (SZFP2PGroup *group in state.groups.allValues) group.sightedThere = NO;
}

#pragma mark - helper.log

- (void)traceSightingsOfCandidate:(SZFriendsCandidate *)candidate conversationID:(NSString *)conversationID {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (SZFriendsSighting *sighting in candidate.sightings) {
        if (sighting.isPublic) continue;
        NSMutableArray<NSString *> *routes = [NSMutableArray array];
        for (NSNumber *route in sighting.routes) [routes addObject:SZFriendsTraceRouteName(route.integerValue)];
        NSString *text = [routes componentsJoinedByString:@" + "];
        if (sighting.interfaces.length) text = [text stringByAppendingFormat:@" (%@)", sighting.interfaces];
        if (![parts containsObject:text]) [parts addObject:text];
    }
    NSString *line = parts.count ? [parts componentsJoinedByString:@", "] : @"nowhere";
    SZFP2PState *state = [self p2pState];
    if ([state.sighted[conversationID] isEqualToString:line]) return;
    if (state.sighted.count > 512 && state.sighted[conversationID] == nil) [state.sighted removeAllObjects];
    state.sighted[conversationID] = line;
    [self traceKey:[@"sighted|" stringByAppendingString:conversationID]
              line:[NSString stringWithFormat:@"friend %@ sighted via %@", SZFP2PShort(conversationID), line]];
}

@end
