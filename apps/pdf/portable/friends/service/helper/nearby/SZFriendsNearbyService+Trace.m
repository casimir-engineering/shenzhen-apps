// What helper.log says about reaching friends and moving their files, so the log alone explains a slow or broken
// transfer: every dial and its outcome, every session and lane up and down with its route and both sides' reasons,
// the session race, lanes the scheduler asked for and why one was not dialled, each transfer's start and end with
// the routes it used and its average rate, and every 10 s while a file moves, what each lane carried.
//
// Friends are named by the first 8 hex digits of their conversation ID, transfers by the first 8 of theirs: never a
// name, a file name, a key or an address. The words match the Rust core's (core-rs nearby/trace.rs), so logs from a
// Mac and a phone read alike. Repeats are held back per key as there: the same line at most once a minute, and at
// most 6 lines a minute under one key; the next line that goes out says how many were left out.

#import "service/helper/nearby/SZFriendsNearbyInternal.h"

static const double SZFTraceRepeatSeconds = 60;
static const NSUInteger SZFTracePerKeyPerMinute = 6;
static const NSUInteger SZFTraceKeysMax = 2048;
// While a file moves: what each lane carried, at most this often per group.
static const double SZFTraceThroughputEvery = 10;

@interface SZFTraceSaid : NSObject
@property(nonatomic, copy) NSString *line;
@property(nonatomic) double at, minute;
@property(nonatomic) NSUInteger inMinute, leftOut;
@end
@implementation SZFTraceSaid
@end

// One transfer, from its first byte in this helper run to its end.
@interface SZFTraceRun : NSObject
@property(nonatomic, copy) NSString *conversationID;
@property(nonatomic) BOOL outgoing;
@property(nonatomic) double started;
@property(nonatomic) uint64_t from, size;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *byRoute; // route -> part bytes
@property(nonatomic) uint64_t late;                                                 // wasted: parts that came twice
@end
@implementation SZFTraceRun
@end

// One lane's bytes since its group's last throughput line.
@interface SZFTraceLane : NSObject
@property(nonatomic) SZFriendsRouteMethod route;
@property(nonatomic) uint64_t sent, received, late;
@property(nonatomic) BOOL silent;
@end
@implementation SZFTraceLane
@end

@interface SZFTraceState : NSObject
@property(nonatomic, strong) NSMutableDictionary<NSString *, SZFTraceSaid *> *said;
@property(nonatomic, strong) NSMutableDictionary<NSString *, SZFTraceRun *> *runs;
@property(nonatomic, strong) NSMutableDictionary<NSString *, SZFTraceLane *> *lanes; // "group:lane"
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *reportedAt; // group -> time
// What the store held for a transfer's routes before this helper run first wrote them (transfer -> route name ->
// bytes): the route meter counts this run only, so each write is this plus the meter's counts.
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *routeBases;
@end
@implementation SZFTraceState
@end

static double SZFTraceNow(void) {
    return CFAbsoluteTimeGetCurrent();
}

NSString *SZFriendsTraceRouteName(SZFriendsRouteMethod route) {
    switch (route) {
    case SZFriendsRouteMethodNone: return @"None";
    case SZFriendsRouteMethodLAN: return @"LAN";
    case SZFriendsRouteMethodPeerToPeerWiFi: return @"PeerToPeerWiFi";
    case SZFriendsRouteMethodBluetooth: return @"Bluetooth";
    case SZFriendsRouteMethodInternet: return @"Internet";
    case SZFriendsRouteMethodRelay: return @"Relay";
    }
    return [NSString stringWithFormat:@"route %ld", (long)route];
}

static NSString *SZFTracePurposeName(SZFriendsLinkPurpose purpose) {
    switch (purpose) {
    case SZFriendsLinkPurposeIncoming: return @"Incoming";
    case SZFriendsLinkPurposeFriend: return @"Friend";
    case SZFriendsLinkPurposeBrowse: return @"Browse";
    case SZFriendsLinkPurposeRequest: return @"Request";
    case SZFriendsLinkPurposeByID: return @"ByID";
    case SZFriendsLinkPurposeJoin: return @"Join";
    case SZFriendsLinkPurposeOwnDevice: return @"OwnDevice";
    }
    return [NSString stringWithFormat:@"purpose %ld", (long)purpose];
}

static NSString *SZFTraceCloseReason(NSInteger code) {
    NSString *name = nil;
    switch (code) {
    case SZFriendsCloseReasonNormal: name = @"normal"; break;
    case SZFriendsCloseReasonProtocolError: name = @"protocol error"; break;
    case SZFriendsCloseReasonSuperseded: name = @"superseded (lost the race)"; break;
    case SZFriendsCloseReasonExpired: name = @"expired"; break;
    case SZFriendsCloseReasonShuttingDown: name = @"shutting down"; break;
    case SZFriendsCloseReasonCodeMismatch: name = @"code mismatch"; break;
    case SZFriendsCloseReasonLaneRefused: name = @"lane refused"; break;
    default: name = @"unknown"; break;
    }
    return [NSString stringWithFormat:@"%@ (%ld)", name, (long)code];
}

static NSString *SZFTraceErrorText(NSError *_Nullable error) {
    if (error == nil) return nil;
    if (![error.domain isEqualToString:SZFriendsSessionErrorDomain]) {
        return [NSString stringWithFormat:@"%@ %ld", error.domain, (long)error.code];
    }
    switch (error.code) {
    case SZFriendsSessionErrorPeerClosed: {
        NSNumber *reason = error.userInfo[SZFriendsSessionCloseReasonKey];
        return [@"peer closed: " stringByAppendingString:SZFTraceCloseReason(reason.integerValue)];
    }
    case SZFriendsSessionErrorStreamClosed: {
        NSError *under = error.userInfo[NSUnderlyingErrorKey];
        return under ? [NSString stringWithFormat:@"link dropped without CLOSE (%@ %ld)", under.domain, (long)under.code]
                     : @"link dropped without CLOSE";
    }
    case SZFriendsSessionErrorSilent: return @"silent: nothing heard while a transfer ran (error 12)";
    case SZFriendsSessionErrorTimedOut: return @"handshake timed out (error 10)";
    case SZFriendsSessionErrorExpired: return @"expired (error 8)";
    default: return [NSString stringWithFormat:@"session error %ld", (long)error.code];
    }
}

NSString *SZFriendsTraceBytes(uint64_t bytes) {
    if (bytes >= 1048576) return [NSString stringWithFormat:@"%.1f MB", bytes / 1048576.0];
    if (bytes >= 1024) return [NSString stringWithFormat:@"%.0f KB", bytes / 1024.0];
    return [NSString stringWithFormat:@"%llu B", (unsigned long long)bytes];
}

NSString *SZFriendsTraceRate(double bytesPerSecond) {
    if (bytesPerSecond >= 1048576) return [NSString stringWithFormat:@"%.1f MB/s", bytesPerSecond / 1048576.0];
    if (bytesPerSecond >= 1024) return [NSString stringWithFormat:@"%.0f KB/s", bytesPerSecond / 1024.0];
    return [NSString stringWithFormat:@"%.0f B/s", bytesPerSecond];
}

static NSString *SZFTraceShort(NSString *_Nullable hex) {
    if (hex.length == 0) return @"?";
    return hex.length > 8 ? [hex substringToIndex:8] : hex;
}

NSString *SZFriendsTraceShort(NSString *_Nullable hex) {
    return SZFTraceShort(hex);
}

static NSString *SZFTraceByRoute(NSDictionary<NSNumber *, NSNumber *> *byRoute) {
    if (byRoute.count == 0) return @"no parts";
    NSMutableArray *parts = [NSMutableArray array];
    for (NSNumber *route in [byRoute.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [parts addObject:[NSString stringWithFormat:@"%@ %@", SZFriendsTraceRouteName(route.integerValue),
                                                    SZFriendsTraceBytes(byRoute[route].unsignedLongLongValue)]];
    }
    return [parts componentsJoinedByString:@", "];
}

@implementation SZFriendsNearbyService (Trace)

- (SZFTraceState *)traceState {
    SZFTraceState *state = self.traceStore;
    if (state == nil) {
        state = [[SZFTraceState alloc] init];
        state.said = [NSMutableDictionary dictionary];
        state.runs = [NSMutableDictionary dictionary];
        state.lanes = [NSMutableDictionary dictionary];
        state.reportedAt = [NSMutableDictionary dictionary];
        state.routeBases = [NSMutableDictionary dictionary];
        self.traceStore = state;
    }
    return state;
}

- (void)traceKey:(NSString *)key line:(NSString *)line {
    SZFTraceState *state = [self traceState];
    double now = SZFTraceNow();
    if (state.said.count >= SZFTraceKeysMax && state.said[key] == nil) {
        for (NSString *old in state.said.allKeys) {
            if (now - state.said[old].at >= SZFTraceRepeatSeconds) [state.said removeObjectForKey:old];
        }
    }
    SZFTraceSaid *said = state.said[key];
    if (said == nil) {
        said = [[SZFTraceSaid alloc] init];
        said.line = @"";
        said.at = -DBL_MAX;
        said.minute = now;
        state.said[key] = said;
    }
    if (now - said.minute >= 60) {
        said.minute = now;
        said.inMinute = 0;
    }
    if (([said.line isEqualToString:line] && now - said.at < SZFTraceRepeatSeconds) ||
        said.inMinute >= SZFTracePerKeyPerMinute) {
        said.leftOut++;
        return;
    }
    if (said.leftOut > 0) {
        SZFriendsHelperLog(@"%@ (%lu lines like it left out)", line, (unsigned long)said.leftOut);
    } else {
        SZFriendsHelperLog(@"%@", line);
    }
    said.leftOut = 0;
    said.line = line;
    said.at = now;
    said.inMinute++;
}

#pragma mark - Who and how

- (NSString *)traceWhoOfLink:(SZFriendsPeerLink *)link {
    if (link.ownDevice || link.purpose == SZFriendsLinkPurposeOwnDevice || link.purpose == SZFriendsLinkPurposeJoin) {
        return @"own device";
    }
    NSString *conversationID = link.conversationID ?: link.laneHead.conversationID;
    if (conversationID != nil) return [@"friend " stringByAppendingString:SZFTraceShort(conversationID)];
    return @"someone not in the list";
}

- (NSString *)traceSessionOfLink:(SZFriendsPeerLink *)link {
    return [NSString stringWithFormat:@"#%llu (%@, %@)", (unsigned long long)link.traceID,
                                      SZFriendsTraceRouteName(link.live ? link.raceRoute : link.dialedRoute),
                                      link.channel.isInitiator ? @"ours" : @"theirs"];
}

#pragma mark - Dials, sessions, lanes, the race

- (void)traceDial:(SZFriendsDialPlan *)plan what:(NSString *)what {
    NSString *conversationID = plan.conversationID ?: plan.laneHead.conversationID;
    NSString *who = plan.purpose == SZFriendsLinkPurposeOwnDevice ? @"own device"
                    : conversationID ? [@"friend " stringByAppendingString:SZFTraceShort(conversationID)]
                                     : @"someone not in the list";
    NSString *lane = plan.laneHead != nil
                         ? [NSString stringWithFormat:@", lane of #%llu", (unsigned long long)plan.laneHead.traceID]
                         : @"";
    NSString *line = [NSString stringWithFormat:@"dial %@ via %@ (%@%@%@): %@", who,
                                                SZFriendsTraceRouteName(plan.dialRoute),
                                                SZFTracePurposeName(plan.purpose), plan.probe ? @", probe" : @"", lane,
                                                what];
    [self traceKey:[NSString stringWithFormat:@"dial|%@|%ld|%ld", who, (long)plan.dialRoute, (long)plan.purpose]
              line:line];
}

- (void)traceUpOfLink:(SZFriendsPeerLink *)link what:(NSString *)what {
    NSString *who = [self traceWhoOfLink:link];
    NSString *line = [NSString stringWithFormat:@"%@ up #%llu (%@, %@, %@) %@%@", link.lane ? @"lane" : @"session",
                                                (unsigned long long)link.traceID, SZFTracePurposeName(link.purpose),
                                                SZFriendsTraceRouteName(link.raceRoute),
                                                link.channel.isInitiator ? @"we dialed" : @"they dialed", who,
                                                what.length ? [@": " stringByAppendingString:what] : @""];
    [self traceKey:[NSString stringWithFormat:@"up|%@|%ld", who, (long)link.raceRoute] line:line];
}

- (void)traceEndOfLink:(SZFriendsPeerLink *)link error:(nullable NSError *)error {
    // A probe, or a look at a public entry that ended as planned, says nothing about reaching anyone.
    if (link.probe || (link.purpose == SZFriendsLinkPurposeBrowse && error == nil)) return;
    NSString *who = [self traceWhoOfLink:link];
    NSString *live = link.liveAt ? [NSString stringWithFormat:@"live %.1f s", -link.liveAt.timeIntervalSinceNow]
                                 : @"handshaking";
    NSString *theirs = SZFTraceErrorText(error) ?: @"closed here";
    // The helper suites drive links with stand-in channels that have no close reason.
    NSInteger ours = [link.channel respondsToSelector:@selector(localCloseReason)] ? link.channel.localCloseReason : -1;
    NSString *why = ours >= 0 ? [NSString stringWithFormat:@"%@; our close: %@", theirs, SZFTraceCloseReason(ours)]
                              : theirs;
    BOOL lane = link.lane || link.laneHead != nil;
    NSString *of = lane ? [NSString stringWithFormat:@" of #%llu", (unsigned long long)link.laneHead.traceID] : @"";
    // "session ended (purpose N, route N, ...)" began this line in earlier builds and still does: logs and the
    // e2e scenarios that count a dial loop's ends read it that way.
    NSString *line = [NSString stringWithFormat:@"%@ ended (purpose %ld, route %ld %@, %@) #%llu%@ %@: %@",
                                                lane ? @"lane" : @"session", (long)link.purpose, (long)link.raceRoute,
                                                SZFriendsTraceRouteName(link.raceRoute), live,
                                                (unsigned long long)link.traceID, of, who, why];
    // Ends with a fault were each logged before and still are, so a loop of them shows in full; the others (our
    // own closes, the race's losers) are held back like the rest of the trace.
    if (error != nil) SZFriendsHelperLog(@"%@", line);
    else [self traceKey:[NSString stringWithFormat:@"end|%@|%ld", who, (long)link.raceRoute] line:line];
}

- (void)traceRaceOfLink:(SZFriendsPeerLink *)link against:(SZFriendsPeerLink *)current outcome:(NSString *)outcome {
    NSString *line = [NSString stringWithFormat:@"race friend %@: %@ against %@: %@", SZFTraceShort(link.conversationID),
                                                [self traceSessionOfLink:link], [self traceSessionOfLink:current],
                                                outcome];
    [self traceKey:[@"race|" stringByAppendingString:link.conversationID ?: @""] line:line];
}

- (void)traceLaneWanted:(SZFriendsPeerLink *)head route:(SZFriendsRouteMethod)route what:(NSString *)what {
    NSString *line = [NSString stringWithFormat:@"lane wanted %@ via %@ beside #%llu: %@", [self traceWhoOfLink:head],
                                                SZFriendsTraceRouteName(route), (unsigned long long)head.traceID, what];
    [self traceKey:[NSString stringWithFormat:@"lane|%@|%ld", head.conversationID, (long)route] line:line];
}

- (void)traceRoutesOf:(NSString *)who key:(NSString *)key candidate:(SZFriendsCandidate *)candidate
                 live:(SZFriendsRouteMethod)live notes:(NSArray<NSString *> *)notes {
    NSMutableArray<NSString *> *seen = [NSMutableArray array];
    for (SZFriendsSighting *sighting in candidate.sightings) {
        NSString *name = SZFriendsTraceRouteName(sighting.route);
        if (![seen containsObject:name]) [seen addObject:name];
    }
    NSString *line = [NSString stringWithFormat:@"routes %@: seen on [%@], live %@%@%@", who,
                                                [seen componentsJoinedByString:@", "], SZFriendsTraceRouteName(live),
                                                notes.count ? @"; " : @"", [notes componentsJoinedByString:@"; "]];
    [self traceKey:[@"routes|" stringByAppendingString:key] line:line];
}

#pragma mark - Transfers

- (void)traceTransferStarted:(NSString *)transferID
                      onLink:(SZFriendsPeerLink *)link
                    outgoing:(BOOL)outgoing
                        from:(uint64_t)from
                         how:(NSString *)how {
    SZFTraceState *state = [self traceState];
    if (state.runs[transferID] != nil) return; // moved to another session or lane group: the same run
    SZFriendsTransferRecord *record = [self.services.transfers transferWithID:transferID];
    SZFTraceRun *run = [[SZFTraceRun alloc] init];
    run.conversationID = link.conversationID ?: record.conversationID;
    run.outgoing = outgoing;
    run.started = SZFTraceNow();
    run.from = from;
    run.size = record.size;
    run.byRoute = [NSMutableDictionary dictionary];
    state.runs[transferID] = run;
    NSString *line = [NSString stringWithFormat:@"transfer %@ %@ friend %@ via %@ #%llu (%@): started at %llu of %llu "
                                                @"bytes",
                                                SZFTraceShort(transferID), outgoing ? @"to" : @"from",
                                                SZFTraceShort(run.conversationID),
                                                SZFriendsTraceRouteName(link.raceRoute),
                                                (unsigned long long)link.traceID, how, (unsigned long long)from,
                                                (unsigned long long)run.size];
    [self traceKey:[@"transfer|" stringByAppendingString:transferID] line:line];
}

- (void)traceTransferBytes:(NSString *)transferID route:(SZFriendsRouteMethod)route bytes:(uint64_t)bytes late:(BOOL)late {
    SZFTraceRun *run = [self traceState].runs[transferID];
    if (run == nil) return;
    if (late) {
        run.late += bytes;
        return;
    }
    run.byRoute[@(route)] = @(run.byRoute[@(route)].unsignedLongLongValue + bytes);
}

// The transfer's end in this helper run: delivered, received, cancelled, declined, failed, or only stopped here.
- (void)traceTransferEnded:(NSString *)transferID {
    SZFTraceState *state = [self traceState];
    SZFTraceRun *run = state.runs[transferID];
    if (run == nil) return;
    SZFriendsTransferRecord *record = [self.services.transfers transferWithID:transferID];
    NSString *outcome = nil;
    switch (record ? record.state : (SZFriendsTransferState)-1) {
    case SZFriendsTransferStateDelivered:
    case SZFriendsTransferStateReceived: outcome = @"finished"; break;
    case SZFriendsTransferStateCancelled: outcome = @"cancelled"; break;
    case SZFriendsTransferStateDeclined: outcome = @"declined"; break;
    case SZFriendsTransferStateFailed:
        outcome = [NSString stringWithFormat:@"failed (%@)", record.failureReason ?: @"?"];
        break;
    case SZFriendsTransferStateSending:
    case SZFriendsTransferStateReceiving:
        if (record.outgoing || record.verifiedBytes < record.size) return; // still going: not an end
        outcome = @"all bytes here, being checked and saved";
        break;
    default: outcome = record ? [NSString stringWithFormat:@"state %ld", (long)record.state] : @"gone"; break;
    }
    [state.runs removeObjectForKey:transferID];
    double seconds = MAX(SZFTraceNow() - run.started, 0.001);
    uint64_t moved = 0;
    for (NSNumber *bytes in run.byRoute.allValues) moved += bytes.unsignedLongLongValue;
    NSString *late = run.late ? [NSString stringWithFormat:@", %@ came twice", SZFriendsTraceBytes(run.late)] : @"";
    NSString *line = [NSString stringWithFormat:@"transfer %@ %@ friend %@: %@ after %.1f s, %@ moved this run "
                                                @"(file %@), average %@; by route: %@%@",
                                                SZFTraceShort(transferID), run.outgoing ? @"to" : @"from",
                                                SZFTraceShort(run.conversationID), outcome, seconds,
                                                SZFriendsTraceBytes(moved), SZFriendsTraceBytes(run.size),
                                                SZFriendsTraceRate(moved / seconds), SZFTraceByRoute(run.byRoute), late];
    [self traceKey:[@"transfer-end|" stringByAppendingString:transferID] line:line];
    if (record != nil) [self keepRoutesOfTransfer:transferID];
}

// The protocol's name for a route, as transfers.route_bytes and the views' segments name it.
static NSString *_Nullable SZFTraceRouteKey(SZFriendsRouteMethod route) {
    switch (route) {
    case SZFriendsRouteMethodLAN: return @"lan";
    case SZFriendsRouteMethodPeerToPeerWiFi: return @"p2p_wifi";
    case SZFriendsRouteMethodInternet: return @"internet";
    case SZFriendsRouteMethodBluetooth: return @"bluetooth";
    case SZFriendsRouteMethodRelay: return @"relay";
    case SZFriendsRouteMethodNone: return nil;
    }
    return nil;
}

// How the file went through, kept with the transfer when a run of it ends, so its card can still show it once the
// file is delivered, received, cancelled or failed, after a restart too (PROTOCOL.md § Fast transfers, Progress by
// route): what earlier runs of the helper recorded plus what the route meter counted in this one, the same counts the
// moving bar was split by.
- (void)keepRoutesOfTransfer:(NSString *)transferID {
    NSDictionary<NSNumber *, NSNumber *> *counted = [self.routeMeter routeBytesOf:transferID];
    if (counted.count == 0) return;
    SZFTraceState *state = [self traceState];
    NSDictionary<NSString *, NSNumber *> *base = state.routeBases[transferID];
    if (base == nil) {
        base = [self.services.transfers transferWithID:transferID].routeBytes ?: @{};
        state.routeBases[transferID] = base;
    }
    NSMutableDictionary<NSString *, NSNumber *> *total = [base mutableCopy];
    for (NSNumber *route in counted) {
        NSString *key = SZFTraceRouteKey(route.integerValue);
        if (key == nil) continue;
        total[key] = @(total[key].unsignedLongLongValue + counted[route].unsignedLongLongValue);
    }
    NSError *error = nil;
    if (![self.services.transfers setRouteBytes:total forTransfer:transferID error:&error]) {
        SZFriendsHelperLog(@"transfer %@: could not keep its routes: %@", SZFTraceShort(transferID),
                           error.localizedDescription);
    }
}

#pragma mark - Lanes while a file moves

- (void)tracePartOnGroup:(SZFriendsPeerLink *)head
                transfer:(NSString *)transferID
                    lane:(SZFriendsLaneID)lane
                   route:(SZFriendsRouteMethod)route
                   bytes:(NSUInteger)bytes
                outgoing:(BOOL)outgoing
                    late:(BOOL)late {
    [self traceTransferBytes:transferID route:route bytes:bytes late:late];
    if (head == nil) return;
    NSString *key = [NSString stringWithFormat:@"%llu:%llu", (unsigned long long)head.traceID, lane];
    SZFTraceLane *window = [self traceState].lanes[key];
    if (window == nil) {
        window = [[SZFTraceLane alloc] init];
        [self traceState].lanes[key] = window;
    }
    window.route = route;
    if (late) window.late += bytes;
    else if (outgoing) window.sent += bytes;
    else window.received += bytes;
}

// Called from the group's timers (0.25 s while it sends, the durability timer while it receives): a lane that went
// silent or came back is said at once; what each lane carried, every SZFTraceThroughputEvery.
- (void)traceGroupOfLink:(SZFriendsPeerLink *)head {
    SZFriendsBlockExchange *blocks = head.blocks;
    if (blocks == nil || head.closed) return;
    SZFTraceState *state = [self traceState];
    NSArray<NSDictionary<NSString *, NSNumber *> *> *lanes = [blocks laneSnapshot];
    NSString *who = [self traceWhoOfLink:head];
    for (NSDictionary<NSString *, NSNumber *> *lane in lanes) {
        if (lane[@"silent"] == nil) continue;
        NSString *key = [NSString stringWithFormat:@"%llu:%@", (unsigned long long)head.traceID, lane[@"lane"]];
        SZFTraceLane *window = state.lanes[key];
        if (window == nil) {
            window = [[SZFTraceLane alloc] init];
            window.route = lane[@"route"].integerValue;
            state.lanes[key] = window;
        }
        BOOL silent = lane[@"silent"].boolValue;
        if (silent != window.silent) {
            window.silent = silent;
            NSString *line = [NSString stringWithFormat:
                @"lane %@ of #%llu (%@) %@: %@", lane[@"lane"], (unsigned long long)head.traceID,
                SZFriendsTraceRouteName(lane[@"route"].integerValue), who,
                silent ? [NSString stringWithFormat:@"silent, its %@ in flight go to the other lanes (%@)",
                                                    SZFriendsTraceBytes(lane[@"in_flight"].unsignedLongLongValue),
                                                    lane[@"reaches"].boolValue ? @"still heard from"
                                                                               : @"nothing heard either"]
                       : @"moving again"];
            [self traceKey:[@"silent|" stringByAppendingString:key] line:line];
        }
    }
    double now = SZFTraceNow();
    NSNumber *groupKey = @(head.traceID);
    NSNumber *last = state.reportedAt[groupKey];
    if (last == nil) {
        state.reportedAt[groupKey] = @(now); // the first window starts now
        return;
    }
    double span = now - last.doubleValue;
    if (span < SZFTraceThroughputEvery) return;
    state.reportedAt[groupKey] = @(now);
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    BOOL moved = NO;
    for (NSDictionary<NSString *, NSNumber *> *lane in lanes) {
        NSString *key = [NSString stringWithFormat:@"%llu:%@", (unsigned long long)head.traceID, lane[@"lane"]];
        SZFTraceLane *window = state.lanes[key];
        uint64_t bytes = window.sent + window.received;
        moved |= bytes > 0;
        NSMutableString *text = [NSMutableString stringWithFormat:@"%@ lane %@ %@",
                                                                  SZFriendsTraceRouteName(lane[@"route"].integerValue),
                                                                  lane[@"lane"], SZFriendsTraceRate(bytes / span)];
        if (window.late) [text appendFormat:@" (+%@ twice)", SZFriendsTraceBytes(window.late)];
        if (lane[@"rate"] != nil) {
            [text appendFormat:@" [est %@%@, rtt %.0f ms, %@ in flight%@%@]", SZFriendsTraceRate(lane[@"rate"].doubleValue),
                               lane[@"measured"].boolValue ? @"" : @" assumed", lane[@"rtt"].doubleValue * 1000,
                               SZFriendsTraceBytes(lane[@"in_flight"].unsignedLongLongValue),
                               lane[@"silent"].boolValue ? @", silent" : @"",
                               lane[@"reaches"].boolValue ? @"" : @", unheard"];
        }
        [parts addObject:text];
        window.sent = window.received = window.late = 0;
    }
    if (!moved && blocks.sending.count == 0 && blocks.receiving.count == 0) return;
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    NSDictionary<NSString *, NSNumber *> *progress = [blocks sendingProgress];
    for (NSString *transferID in [progress.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        SZFriendsTransferRecord *record = [self.services.transfers transferWithID:transferID];
        uint64_t done = progress[transferID].unsignedLongLongValue;
        [files addObject:[NSString stringWithFormat:@"%@ to %@ of %@", SZFTraceShort(transferID),
                                                    SZFriendsTraceBytes(done), SZFriendsTraceBytes(record.size)]];
    }
    for (NSString *transferID in [blocks.receiving.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
        SZFriendsTransferRecord *record = [self.services.transfers transferWithID:transferID];
        [files addObject:[NSString stringWithFormat:@"%@ from, %@ durable of %@", SZFTraceShort(transferID),
                                                    SZFriendsTraceBytes(record.verifiedBytes),
                                                    SZFriendsTraceBytes(record.size)]];
    }
    NSString *line = [NSString stringWithFormat:@"lanes of #%llu %@, last %.0f s: %@; files: %@",
                                                (unsigned long long)head.traceID, who, span,
                                                [parts componentsJoinedByString:@", "],
                                                files.count ? [files componentsJoinedByString:@", "] : @"none"];
    [self traceKey:[NSString stringWithFormat:@"lanes|%llu", (unsigned long long)head.traceID] line:line];
}

- (void)traceGroupEnded:(SZFriendsPeerLink *)head {
    SZFTraceState *state = self.traceStore;
    if (state == nil) return;
    [state.reportedAt removeObjectForKey:@(head.traceID)];
    NSString *prefix = [NSString stringWithFormat:@"%llu:", (unsigned long long)head.traceID];
    for (NSString *key in state.lanes.allKeys) {
        if ([key hasPrefix:prefix]) [state.lanes removeObjectForKey:key];
    }
}

@end
