// Peer-to-peer Wi-Fi (AWDL) on demand (ADR 0021).
//
// A Bonjour browser, listener or connection that includes peer-to-peer Wi-Fi keeps AWDL awake, and awake AWDL takes
// the Wi-Fi radio off the network's channel for about a fifth of the time (measured: 72 ms in every 524 ms, every
// packet of the Mac's own Wi-Fi traffic waiting behind it). Friends used to keep it awake all the time. Now the
// network adapters leave AWDL out unless one of these holds:
//   - this Mac is on no network (Wi-Fi not joined, no Ethernet): AWDL is then the only Wi-Fi route, as before;
//   - a transfer's group wants a direct Wi-Fi lane: the sender's scheduler asked for one (its LAN is missing or below
//     25 MB/s), or the receiver gets the file below 25 MB/s, so both ends turn it on and the sender can dial;
//   - a direct Wi-Fi lane is up.
// A group gives up on direct Wi-Fi for the rest of its transfer when no lane came within 20 s, when its lane ended,
// or when, 8 s after the lane came up, the group's rate is not 10 % better than before it (the sender closes the
// lane then). AWDL goes off 30 s after the last reason ended, and sessions or lanes still on it are closed then, since
// any socket on awdl keeps it awake.

#import "service/discovery/SZFriendsDiscoveryInternal.h"
#import "service/helper/nearby/SZFriendsNearbyInternal.h"
#import "service/transfer/SZFriendsDirectWiFiBoost.h"
#import "service/transfer/SZFriendsScheduler.h"

static const double SZFP2PGiveUpAfter = 20;    // no direct Wi-Fi lane this long after wanting one: give up
static const double SZFP2PJudgeAfter = 8;      // the lane's worth is measured this long after it came up...
static const double SZFP2PJudgeSettle = 3;     // ...from this long after (its start-up is not held against it)
static const double SZFP2PBeforeSpan = 5;      // against the group's rate over this long before it
static const double SZFP2PHelpsBy = 1.1;       // ...and kept only when the group's rate rose by this much
static const double SZFP2POffAfter = 30;       // AWDL off this long after nothing needs it any more
static const double SZFP2PReceiveWindow = 3;   // the receiver measures its rate over this long
static const double SZFP2PTick = 1;
// A friend whose transfer got no direct Wi-Fi lane (an Android phone or a PC never shows up on AWDL, an older Mac
// never dials one) is not asked again for this long.
static const double SZFP2PNotAgainFor = 3600;

@interface SZFP2PGroup : NSObject
@property(nonatomic) double wantedAt;     // when this group first wanted direct Wi-Fi; 0 for not
@property(nonatomic) BOOL sightedThere;   // the friend was sighted on direct Wi-Fi when last looked (sender)
@property(nonatomic) BOOL hadLane, givenUp;
@property(nonatomic) uint64_t received;   // bytes received since receivedSince (receiver)
@property(nonatomic) double receivedSince;
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
@property(nonatomic) double unneededSince; // when the last reason ended; 0 while one holds
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
                SZFriendsHelperLog(@"direct Wi-Fi: this Mac is %@", hasNetwork ? @"on a network again"
                                                                                : @"on no network now");
                [strongSelf peerToPeerEvaluate];
            });
        });
    }
    [self peerToPeerEvaluate];
}

- (BOOL)p2pHasNetwork {
    for (id<SZFriendsDiscoveryAdapter> adapter in self.adapters) {
        if (!SZFriendsNetworkAdapterHasNetwork(adapter)) return NO;
    }
    return YES;
}

- (BOOL)p2pBoosting:(SZFriendsPeerLink *)head {
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
    if (group.givenUp) return NO;
    if (group.wantedAt == 0) {
        group.wantedAt = CFAbsoluteTimeGetCurrent();
        SZFriendsHelperLog(@"direct Wi-Fi wanted for %@: the scheduler asks for a lane there (LAN below %@)",
                           [self p2pWhoOfHead:head], SZFriendsTraceRate(SZFriendsDirectWiFiHelpsBelow));
    }
    BOOL wasOn = [self p2pState].on;
    [self peerToPeerEvaluate];
    // Just turned on, nobody is sighted there yet: the lane is dialed when the friend shows up
    // (-peerToPeerSightingsChanged).
    group.sightedThere = wasOn && [self p2pSightedOnPeerToPeer:head.conversationID];
    return wasOn;
}

- (void)peerToPeerNoteReceived:(NSUInteger)bytes onGroup:(SZFriendsPeerLink *)head {
    if (head.closed || head.lane) return;
    SZFP2PGroup *group = [self p2pGroupOfHead:head];
    if (group.receivedSince == 0) group.receivedSince = CFAbsoluteTimeGetCurrent();
    group.received += bytes;
    [self p2pScheduleTick];
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
    NSMutableArray<NSString *> *reasons = [NSMutableArray array];
    if (![self p2pHasNetwork]) [reasons addObject:@"this Mac is on no network"];
    NSMutableSet<NSNumber *> *heads = [NSMutableSet set];
    for (SZFriendsPeerLink *head in self.links.allObjects) {
        if (head.lane || head.closed || head.blocks == nil || [self p2pBoosting:head]) continue;
        // Between transfers nothing here needs AWDL: a direct Wi-Fi lane left over closes when it goes off, and the
        // next transfer starts afresh.
        if (!head.blocks.carriesTransfers) {
            [state.groups removeObjectForKey:@(head.traceID)];
            continue;
        }
        NSArray<SZFriendsPeerLink *> *lanes = [self p2pLanesOfHead:head];
        SZFP2PGroup *group = state.groups[@(head.traceID)];
        if (group == nil && lanes.count == 0) continue;
        if (group == nil) group = [self p2pGroupOfHead:head]; // the friend opened a direct Wi-Fi lane to us
        [heads addObject:@(head.traceID)];
        [self p2pMeasureReceiving:head group:group now:now];
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
        if ([self p2pLanesOfHead:head].count > 0) {
            [reasons addObject:[NSString stringWithFormat:@"a direct Wi-Fi lane of %@", [self p2pWhoOfHead:head]]];
        } else if (group.wantedAt > 0 && !group.givenUp) {
            [reasons addObject:[NSString stringWithFormat:@"a transfer with %@ wants a direct Wi-Fi lane",
                                                          [self p2pWhoOfHead:head]]];
        }
    }
    for (NSNumber *key in state.groups.allKeys) {
        if (![heads containsObject:key]) [state.groups removeObjectForKey:key];
    }
    if (reasons.count > 0) {
        state.unneededSince = 0;
        if (!state.on) [self p2pTurn:YES why:[reasons componentsJoinedByString:@"; "]];
    } else if (state.on) {
        if (state.unneededSince == 0) state.unneededSince = now;
        if (now - state.unneededSince >= SZFP2POffAfter) {
            [self p2pTurn:NO why:[NSString stringWithFormat:@"nothing has needed it for %.0f s", SZFP2POffAfter]];
        }
    }
    if (state.on || state.groups.count > 0) [self p2pScheduleTick];
}

// Receiver: the file arrives below 25 MB/s, with enough of it left to matter: direct Wi-Fi on, so the sender sees
// us there and can open a lane.
- (void)p2pMeasureReceiving:(SZFriendsPeerLink *)head group:(SZFP2PGroup *)group now:(double)now {
    if (group.receivedSince == 0 || now - group.receivedSince < SZFP2PReceiveWindow) return;
    double rate = group.received / (now - group.receivedSince);
    group.received = 0;
    group.receivedSince = now;
    if (group.wantedAt > 0 || group.givenUp || head.blocks.receiving.count == 0 || [self p2pNotAgain:head]) return;
    if (rate <= 0 || rate >= SZFriendsDirectWiFiHelpsBelow) return;
    uint64_t left = 0;
    for (NSString *transferID in head.blocks.receiving) {
        SZFriendsTransferRecord *record = [self.services.transfers transferWithID:transferID];
        if (record.size > record.verifiedBytes) left += record.size - record.verifiedBytes;
    }
    if ((double)left < 4 * rate) return; // done in a few seconds anyway
    group.wantedAt = now;
    SZFriendsHelperLog(@"direct Wi-Fi wanted for %@: receiving at %@ (below %@), %@ left", [self p2pWhoOfHead:head],
                       SZFriendsTraceRate(rate), SZFriendsTraceRate(SZFriendsDirectWiFiHelpsBelow),
                       SZFriendsTraceBytes(left));
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
    state.unneededSince = 0;
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
