// The Wi-Fi Direct boost on a Mac (ADR 0019; SZFriendsDirectWiFiBoost.h): the nearby service's side of the
// coordinator. A friend's group that runs over Bluetooth alone is watched while it sends a file; BOOST frames from the
// friend go to the coordinator; its lane is dialed to the host's address on the link, as a lane of that group (route
// peer-to-peer Wi-Fi, the group's token), so it reaches the same identity or nothing. A Mac only ever joins.
//
// Made only for a person's own home with CoreWLAN (SZFriendsCoreWLANWiFi); a test home has none, so its sessions never
// set capability bit 5 and nothing here runs, unless a test installs a mocked Wi-Fi with -useDirectWiFi:.

#import <arpa/inet.h>
#import <objc/runtime.h>

#import "service/helper/nearby/SZFriendsCoreWLANWiFi.h"
#import "service/discovery/SZFriendsDiscoveryInternal.h"
#import "service/helper/nearby/SZFriendsNearbyInternal.h"

// When a group last went to Bluetooth alone, and how many lane dials on the network failed, by group key.
static const void *SZFriendsBoostSinceKey = &SZFriendsBoostSinceKey;
static const void *SZFriendsBoostFailuresKey = &SZFriendsBoostFailuresKey;
static const void *SZFriendsBoostCoordinatorKey = &SZFriendsBoostCoordinatorKey;
// On a head link: its SZFriendsBoostGroup.
static const void *SZFriendsBoostGroupKey = &SZFriendsBoostGroupKey;

// A group as the coordinator sees it: the head link.
@interface SZFriendsBoostGroup : NSObject <SZFriendsDirectWiFiGroup>
@property(nonatomic, weak) SZFriendsNearbyService *service;
@property(nonatomic, weak) SZFriendsPeerLink *head;
@end

@interface SZFriendsNearbyService (BoostDial)
- (void)dialDirectLaneOfLink:(SZFriendsPeerLink *)head address:(NSData *)address port:(uint16_t)port;
@end

@implementation SZFriendsBoostGroup

- (BOOL)boostSendFrame:(SZFriendsFrame *)frame {
    return [self.head.channel sendFrame:frame];
}

- (void)boostDialAddress:(NSData *)address port:(uint16_t)port {
    SZFriendsPeerLink *head = self.head;
    if (head != nil) [self.service dialDirectLaneOfLink:head address:address port:port];
}

- (void)boostCloseDirectLane {
    for (SZFriendsPeerLink *lane in self.head.lanes.allObjects) {
        if (lane.raceRoute == SZFriendsRouteMethodPeerToPeerWiFi) [lane.channel closeWithReason:SZFriendsCloseReasonNormal];
    }
}

@end

static id SZFriendsBoostKey(SZFriendsPeerLink *head) {
    return [NSValue valueWithNonretainedObject:head];
}

@implementation SZFriendsNearbyService (Boost)

- (nullable SZFriendsDirectWiFiCoordinator *)directWiFi {
    return objc_getAssociatedObject(self, SZFriendsBoostCoordinatorKey);
}

- (NSMutableDictionary *)boostTable:(const void *)key {
    NSMutableDictionary *table = objc_getAssociatedObject(self, key);
    if (table == nil) {
        table = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(self, key, table, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return table;
}

- (void)useDirectWiFi:(id<SZFriendsWiFiJoining>)wifi {
    NSString *record = [self.services.paths.stateDirectory stringByAppendingPathComponent:@"direct-wifi.json"];
    SZFriendsDirectWiFiCoordinator *coordinator = [[SZFriendsDirectWiFiCoordinator alloc] initWithWiFi:wifi
                                                                                          recordPath:record
                                                                                               queue:self.queue];
    __weak SZFriendsNearbyService *weakSelf = self;
    coordinator.onChanged = ^{
        [weakSelf changed];
    };
    objc_setAssociatedObject(self, SZFriendsBoostCoordinatorKey, coordinator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SZFriendsSetDirectWiFiBoostEnabled(YES);
    [coordinator launched];
}

- (void)startDirectWiFiForOwnHome {
    // Never in a test home: no test helper may ever touch this Mac's Wi-Fi.
    if (getenv("SZFRIENDS_STATE_DIR") != NULL || self.directWiFi != nil) return;
    [self useDirectWiFi:[SZFriendsCoreWLANWiFi new]];
}

- (void)stopDirectWiFi {
    [self.directWiFi quitting];
}

// The boost's transfer on this group: what it sends, or receives, by blocks.
- (nullable NSString *)boostTransferOfLink:(SZFriendsPeerLink *)head remaining:(uint64_t *)remaining {
    SZFriendsBlockExchange *blocks = head.blocks;
    NSString *best = nil;
    uint64_t most = 0;
    NSMutableSet *ids = [NSMutableSet setWithSet:blocks.sending ?: [NSSet set]];
    [ids unionSet:blocks.receiving ?: [NSSet set]];
    for (NSString *transferID in ids) {
        SZFriendsTransferRecord *record = [self.services.transfers transferWithID:transferID];
        uint64_t left = record.size > record.verifiedBytes ? record.size - record.verifiedBytes : 0;
        if (best == nil || left > most) {
            best = transferID;
            most = left;
        }
    }
    if (remaining) *remaining = most;
    return best;
}

- (BOOL)boostSortsFirstOnLink:(SZFriendsPeerLink *)head {
    NSData *ours = self.services.identity.publicKey, *theirs = head.channel.remoteIdentityKey;
    if (ours.length != theirs.length || theirs.length == 0) return YES;
    return memcmp(ours.bytes, theirs.bytes, ours.length) < 0;
}

// Called with the group's block tick: § 1, lanes coming and going, rates, transfers that ended.
- (void)boostTickOnLink:(SZFriendsPeerLink *)head {
    SZFriendsDirectWiFiCoordinator *coordinator = self.directWiFi;
    if (coordinator == nil || head.lane || head.closed || !head.channel.directWiFiBoost) return;
    id key = SZFriendsBoostKey(head);
    BOOL direct = NO, other = NO;
    for (SZFriendsPeerLink *lane in head.lanes.allObjects) {
        if (!lane.live || lane.closed) continue;
        if (lane.raceRoute == SZFriendsRouteMethodPeerToPeerWiFi) direct = YES;
        if (lane.raceRoute != SZFriendsRouteMethodBluetooth) other = YES;
    }
    BOOL bluetoothOnly = head.raceRoute == SZFriendsRouteMethodBluetooth && !other;
    NSMutableDictionary *since = [self boostTable:SZFriendsBoostSinceKey];
    if (!bluetoothOnly) {
        [since removeObjectForKey:key];
    } else if (since[key] == nil) {
        since[key] = [NSDate date];
    }
    if ([coordinator hasBoostForGroup:key]) {
        NSString *transfer = [coordinator transferOfGroup:key];
        BOOL still = [head.blocks.sending containsObject:transfer] || [head.blocks.receiving containsObject:transfer];
        if (!still) [coordinator group:key transferEnded:transfer];
        [coordinator group:key directLaneUp:direct];
        if (direct) {
            [coordinator group:key directRate:[head.blocks rateOfRoute:SZFriendsRouteMethodPeerToPeerWiFi]
                 bluetoothRate:[head.blocks rateOfRoute:SZFriendsRouteMethodBluetooth]];
        }
        [coordinator tick];
        return;
    }
    [coordinator tick];
    if (head.blocks.sending.count == 0 || since[key] == nil) return;
    uint64_t remaining = 0;
    NSString *transfer = [self boostTransferOfLink:head remaining:&remaining];
    if (transfer == nil || ![head.blocks.sending containsObject:transfer]) return;
    BOOL seen = NO;
    for (SZFriendsCandidate *candidate in self.coordinator.merger.candidates) {
        if (![candidate.conversationID isEqualToString:head.conversationID]) continue;
        for (SZFriendsSighting *sighting in candidate.sightings) {
            if (sighting.method == SZFriendsDiscoveryMethodNetwork) seen = YES;
        }
    }
    NSUInteger failures = [[self boostTable:SZFriendsBoostFailuresKey][key] unsignedIntegerValue];
    SZFriendsGroupBoost(self, coordinator, head, key, transfer, remaining, seen, failures, -[since[key] timeIntervalSinceNow]);
}

static void SZFriendsGroupBoost(SZFriendsNearbyService *service, SZFriendsDirectWiFiCoordinator *coordinator,
                                SZFriendsPeerLink *head, id key, NSString *transfer, uint64_t remaining, BOOL seen,
                                NSUInteger failures, NSTimeInterval bluetoothFor) {
    SZFriendsBoostGroup *group = [SZFriendsBoostGroup new];
    group.service = service;
    group.head = head;
    objc_setAssociatedObject(head, SZFriendsBoostGroupKey, group, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if ([coordinator considerGroup:key transfer:transfer remaining:remaining
                     bluetoothRate:[head.blocks rateOfRoute:SZFriendsRouteMethodBluetooth]
                     bluetoothOnly:YES
                  bluetoothOnlyFor:bluetoothFor
                     seenOnNetwork:seen
                   networkFailures:failures
                        sortsFirst:[service boostSortsFirstOnLink:head]
                             group:group]) {
        SZFriendsHelperLog(@"direct Wi-Fi: proposed for a file over Bluetooth alone");
    }
}

- (void)link:(SZFriendsPeerLink *)link receivedBoostFrame:(SZFriendsFrame *)frame {
    SZFriendsDirectWiFiCoordinator *coordinator = self.directWiFi;
    SZFriendsPeerLink *head = link.lane ? link.laneHead : link;
    if (coordinator == nil || head == nil) return;
    SZFriendsBoostGroup *group = objc_getAssociatedObject(head, SZFriendsBoostGroupKey);
    if (group == nil) {
        group = [SZFriendsBoostGroup new];
        group.service = self;
        group.head = head;
        objc_setAssociatedObject(head, SZFriendsBoostGroupKey, group, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [self blocksOnLink:head];
    uint64_t remaining = 0;
    [self boostTransferOfLink:head remaining:&remaining];
    [coordinator group:SZFriendsBoostKey(head) receivedFrame:frame remaining:remaining
            sortsFirst:[self boostSortsFirstOnLink:head] group:group];
    [self scheduleBlockTickOnLink:head];
}

- (void)boostLinkClosed:(SZFriendsPeerLink *)link {
    id key = SZFriendsBoostKey(link);
    [[self boostTable:SZFriendsBoostSinceKey] removeObjectForKey:key];
    [[self boostTable:SZFriendsBoostFailuresKey] removeObjectForKey:key];
    [self.directWiFi groupEnded:key];
}

- (void)boostLaneDialFailedOnLink:(SZFriendsPeerLink *)head route:(SZFriendsRouteMethod)route {
    if (route != SZFriendsRouteMethodLAN || head == nil) return;
    NSMutableDictionary *failures = [self boostTable:SZFriendsBoostFailuresKey];
    id key = SZFriendsBoostKey(head);
    failures[key] = @([failures[key] unsignedIntegerValue] + 1);
}

- (BOOL)answerBoostForTransfer:(NSString *)transferID goFaster:(BOOL)goFaster {
    return [self.directWiFi answerTransfer:transferID goFaster:goFaster];
}

- (nullable SZFriendsBoostRow *)boostRowForTransfer:(NSString *)transferID {
    return [self.directWiFi rowForTransfer:transferID];
}

@end

@implementation SZFriendsNearbyService (BoostDial)

// A lane of the group to the host's address on the link: the next index's token, route peer-to-peer Wi-Fi.
- (void)dialDirectLaneOfLink:(SZFriendsPeerLink *)head address:(NSData *)address port:(uint16_t)port {
    SZFriendsPersonRecord *person = [self.services.store personWithConversationID:head.conversationID];
    id<SZFriendsDiscoveryAdapter> adapter = nil;
    for (id<SZFriendsDiscoveryAdapter> candidate in self.adapters) {
        if (candidate.method == SZFriendsDiscoveryMethodNetwork) adapter = candidate;
    }
    if (head.closed || person.staticKey == nil || person.identityKey == nil || adapter == nil) return;
    static uint64_t serials = 1ull << 48; // apart from +Blocks' own serials
    uint64_t serial = ++serials;
    NSData *token = nil;
    if ([[self blocksOnLink:head] reserveLane:serial route:SZFriendsRouteMethodPeerToPeerWiFi token:&token] == 0) return;
    SZFriendsHandshakeOptions *options = [self ikOptionsForPerson:person route:SZFriendsRouteMethodPeerToPeerWiFi];
    options.requestToken = nil;
    options.lane = token;
    char text[INET6_ADDRSTRLEN] = {0};
    inet_ntop(address.length == 4 ? AF_INET : AF_INET6, address.bytes, text, sizeof text);
    NSString *host = @(text);
    NSString *endpoint = [NSString stringWithFormat:@"boost|%@|%u", host, port];
    SZFriendsSighting *sighting = [[SZFriendsSighting alloc] initWithMethod:SZFriendsDiscoveryMethodNetwork
                                                                      route:SZFriendsRouteMethodPeerToPeerWiFi
                                                                 endpointID:endpoint
                                                                presenceTag:nil
                                                               callbackTags:@[]
                                                                   isPublic:NO
                                                                     seenAt:[NSDate date]];
    SZFriendsDialPlan *plan = [SZFriendsDialPlan planWithSighting:sighting purpose:SZFriendsLinkPurposeFriend
                                                          options:options];
    plan.laneHead = head;
    plan.laneSerial = serial;
    __weak SZFriendsNearbyService *weakSelf = self;
    SZFriendsNetworkAdapterOpenStreamToHost(adapter, host, port, ^(id<SZFriendsByteStream> stream) {
        dispatch_async(self.queue, ^{
            SZFriendsNearbyService *strongSelf = weakSelf;
            if (strongSelf == nil || stream == nil || strongSelf.shutDown || head.closed) {
                [stream close];
                [head.blocks laneDown:serial];
                return;
            }
            SZFriendsPeerLink *link = [strongSelf linkForInitiatorStream:stream plan:plan];
            link.laneHead = head;
            link.laneSerial = serial;
            [strongSelf startLink:link];
        });
    });
}

@end
