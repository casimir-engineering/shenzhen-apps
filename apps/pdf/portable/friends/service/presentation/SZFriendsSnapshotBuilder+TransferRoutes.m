// A moving transfer's progress by route (PROTOCOL.md § Fast transfers, Progress by route), for views that declared
// `transfers.progress`, as the Rust core's presentation/transfer_routes.rs: the routes carrying it as icons, the bar
// split by what each route carried, "31.2 MB of 48 MB · 12.4 MB/s" with "2 s left", and "Via Same Wi-Fi + Bluetooth"
// with the transfer's notes. Other views keep the percentage in `status_label` and the estimate in `route_note`.

#import "service/presentation/SZFriendsPresentationPrivate.h"
#import "service/store/SZFriendsTransfers.h"

// The order the icons, the bar's segments and "Via …" follow: the owner's route rank.
static const SZFriendsRouteMethod SZFriendsTransferRouteOrder[5] = {
    SZFriendsRouteMethodLAN, SZFriendsRouteMethodPeerToPeerWiFi, SZFriendsRouteMethodInternet,
    SZFriendsRouteMethodBluetooth, SZFriendsRouteMethodRelay};

static NSString *SZFriendsTransferRouteName(SZFriendsRouteMethod route) {
    switch (route) {
    case SZFriendsRouteMethodLAN: return @"lan";
    case SZFriendsRouteMethodPeerToPeerWiFi: return @"p2p_wifi";
    case SZFriendsRouteMethodInternet: return @"internet";
    case SZFriendsRouteMethodBluetooth: return @"bluetooth";
    default: return @"relay";
    }
}

@implementation SZFriendsSnapshotBuilder (SZFriendsTransferRoutes)

// "2 s left", "4 min left", "1 h 5 min left": exact seconds under a minute, so the helper's steady countdown shows.
- (NSString *)timeLeftLabelForSeconds:(double)seconds {
    SZFriendsStrings *s = self.strings;
    NSString *(^n)(long) = ^(long value) {
      return [NSString stringWithFormat:@"%ld", value];
    };
    if (seconds < 59.5) return [s text:@"transfer.left.seconds" values:@{@"n" : n(MAX(1L, (long)ceil(seconds)))}];
    long minutes = MAX(1L, lround(seconds / 60.0));
    if (minutes < 60) return [s text:@"transfer.left.minutes" values:@{@"n" : n(minutes)}];
    if (minutes % 60 == 0) return [s text:@"transfer.left.hours" values:@{@"h" : n(minutes / 60)}];
    return [s text:@"transfer.left.hours_minutes" values:@{@"h" : n(minutes / 60), @"m" : n(minutes % 60)}];
}

- (NSDictionary<NSString *, id> *)transfer:(NSDictionary<NSString *, id> *)transfer
                            withRoutesOfItem:(SZFriendsItemFacts *)item {
    if (![self.audience.capabilities containsObject:@"transfers.progress"]) return transfer;
    NSDictionary *given = transfer[@"progress"];
    if (![given isKindOfClass:NSDictionary.class]) return transfer;
    SZFriendsStrings *s = self.strings;
    NSMutableDictionary *progress = [given mutableCopy];
    BOOL finishing = item.finishing && item.transferState == SZFriendsTransferStateReceiving;
    double fraction = MAX(0.0, MIN(1.0, [given[@"fraction"] doubleValue]));
    uint64_t size = item.fileSize;
    BOOL moving = item.transferState == SZFriendsTransferStateSending ||
                  item.transferState == SZFriendsTransferStateReceiving;
    uint64_t done = MIN(size, moving ? item.bytesDone : (uint64_t)llround(fraction * (double)size));

    // What carried it: the helper's counts, or else the one route the transfer is on.
    NSMutableDictionary<NSNumber *, NSNumber *> *carried = [item.routeBytes ?: @{} mutableCopy];
    NSArray<NSNumber *> *active = item.activeRoutes ?: @[];
    if (carried.count == 0 && item.transferRoute != SZFriendsRouteMethodNone) {
        carried[@(item.transferRoute)] = @1;
        active = @[ @(item.transferRoute) ];
    }
    if (finishing) active = @[];
    uint64_t total = 0;
    for (NSNumber *bytes in carried.allValues) total += bytes.unsignedLongLongValue;
    NSMutableArray *routes = [NSMutableArray array], *segments = [NSMutableArray array], *names = [NSMutableArray array];
    for (int i = 0; i < 5; i++) {
        SZFriendsRouteMethod route = SZFriendsTransferRouteOrder[i];
        NSNumber *bytes = carried[@(route)];
        BOOL inUse = [active containsObject:@(route)];
        NSString *name = [s text:[@"transfer.route." stringByAppendingString:SZFriendsTransferRouteName(route)]];
        if (inUse) [names addObject:name];
        if (bytes != nil && total > 0)
            [segments addObject:@{
                @"method" : SZFriendsTransferRouteName(route),
                @"fraction" : @(fraction * bytes.doubleValue / (double)total)
            }];
        if (finishing || (!inUse && bytes == nil)) continue;
        [routes addObject:@{
            @"method" : SZFriendsTransferRouteName(route),
            @"active" : SZFriendsBool(inUse),
            @"label" : [s text:inUse ? @"transfer.route.in_use" : @"transfer.route.used" values:@{@"route" : name}]
        }];
    }

    NSString *sizeLabel = [s sizeLabelForBytes:size];
    // Whole numbers, as the bar and its spoken label count them.
    NSString *percent = [NSString stringWithFormat:@"%ld", MAX(0L, MIN(100L, lround(fraction * 100)))];
    NSString *amount = [s text:@"transfer.amount.whole" values:@{@"size" : sizeLabel, @"percent" : percent}];
    if (!finishing) {
        amount = [s text:@"transfer.amount"
                  values:@{@"done" : [s sizeLabelForBytes:done], @"size" : sizeLabel, @"percent" : percent}];
        if (item.bytesPerSecond > 0) {
            NSString *rate = [s text:@"transfer.rate"
                              values:@{@"size" : [s sizeLabelForBytes:(uint64_t)item.bytesPerSecond]}];
            amount = [s text:@"transfer.amount.rate" values:@{@"amount" : amount, @"rate" : rate}];
        }
    }
    id left = [NSNull null];
    if (finishing) left = [s text:@"transfer.finishing"];
    else if (item.secondsLeft > 0 && done < size) left = [self timeLeftLabelForSeconds:item.secondsLeft];

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (names.count)
        [parts addObject:[s text:@"transfer.via"
                          values:@{@"routes" : [names componentsJoinedByString:[s text:@"transfer.via.separator"]]}]];
    if (item.holders >= 2)
        [parts addObject:[s text:item.ownHolders == item.holders ? @"transfer.note.holders" : @"transfer.note.devices"
                          values:@{@"count" : [NSString stringWithFormat:@"%lu", (unsigned long)item.holders]}]];
    if (item.boostStage == 3 && item.boostLeavesWiFi) {
        NSString *network = item.boostNetwork.length
                                ? [s text:@"transfer.boost.network" values:@{@"name" : item.boostNetwork}]
                                : [s text:@"transfer.boost.your_wifi"];
        [parts addObject:[s text:@"transfer.note.rejoin" values:@{@"network" : network}]];
    }
    id detail = parts.count ? [parts componentsJoinedByString:[s text:@"transfer.detail.separator"]] : [NSNull null];

    progress[@"routes"] = routes;
    progress[@"segments"] = segments;
    progress[@"amount_label"] = amount;
    progress[@"time_left_label"] = left;
    progress[@"detail_label"] = detail;
    progress[@"finishing"] = SZFriendsBool(finishing);
    NSMutableDictionary *result = [transfer mutableCopy];
    result[@"progress"] = progress;
    // The detail line says the routes and the boost's direct leg; the estimate and the copy's route line would say
    // them again. The boost's question and its other steps stay, with their actions.
    BOOL boostSpeaks = item.boostStage == 2 || item.boostStage == 4 || item.boostStage == 5 ||
                       (item.boostStage == 1 && [self asksBoost:item]);
    if (!boostSpeaks) result[@"route_note"] = [NSNull null];
    [result removeObjectForKey:@"route"];
    return result;
}

@end
