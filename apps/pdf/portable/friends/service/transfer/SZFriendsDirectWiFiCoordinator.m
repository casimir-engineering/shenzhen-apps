// SZFriendsDirectWiFiCoordinator (SZFriendsDirectWiFiBoost.h): the Mac's boosts, one per friend's group, and its one
// way back to its own Wi-Fi network. Runs on the nearby service's queue; the Wi-Fi's answers hop back onto it.

#import "service/transfer/SZFriendsDirectWiFiBoost.h"

static NSTimeInterval SZFriendsBoostNow(void) {
    return [NSProcessInfo processInfo].systemUptime;
}

static NSString *SZFriendsBoostHex(NSData *data) {
    NSMutableString *out = [NSMutableString stringWithCapacity:data.length * 2];
    const uint8_t *b = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) [out appendFormat:@"%02x", b[i]];
    return out;
}

static NSData *SZFriendsBoostBytes(NSString *hex) {
    if (hex.length != 32) return nil;
    NSMutableData *out = [NSMutableData dataWithCapacity:16];
    for (NSUInteger i = 0; i < 32; i += 2) {
        unsigned value = 0;
        if (sscanf([hex substringWithRange:NSMakeRange(i, 2)].UTF8String, "%2x", &value) != 1) return nil;
        uint8_t byte = (uint8_t)value;
        [out appendBytes:&byte length:1];
    }
    return out;
}

@implementation SZFriendsBoostRow
@end

@class SZFriendsDirectWiFiCoordinator;

// One group's boost and what it drives.
@interface SZFriendsBoostEntry : NSObject <SZFriendsBoostDriver>
@property(nonatomic, weak) SZFriendsDirectWiFiCoordinator *coordinator;
@property(nonatomic, weak) id<SZFriendsDirectWiFiGroup> group;
@property(nonatomic, strong) SZFriendsBoost *boost;
@property(nonatomic, copy) NSString *transfer;
@property(nonatomic) SZFriendsBoostEstimate estimate;
@property(nonatomic) BOOL laneUp;
@end

@interface SZFriendsDirectWiFiCoordinator () <SZFriendsBoostRejoinDriver>
- (void)entry:(SZFriendsBoostEntry *)entry join:(SZFriendsBoostLink *)link;
- (void)entryLeaves:(SZFriendsBoostEntry *)entry;
- (void)changed;
@end

@implementation SZFriendsBoostEntry

- (void)boostSend:(SZFriendsBoostMessage *)message {
    [self.group boostSendFrame:[message frameForTransfer:SZFriendsBoostBytes(self.transfer)]];
}

- (void)boostAsk:(BOOL)asking {
    [self.coordinator changed];
}

- (void)boostHost:(SZFriendsBoostLink *)link {
    // A Mac never hosts: its abilities never say it can, so no pairing gives it the role. Were it to, the link would
    // never come up and the boost would end after SZFriendsBoostLinkWithin like any other that does not.
}

- (void)boostJoin:(SZFriendsBoostLink *)link {
    [self.coordinator entry:self join:link];
}

- (void)boostDialAddress:(NSData *)address port:(uint16_t)port {
    [self.group boostDialAddress:address port:port];
}

- (void)boostAllowDirectLane:(BOOL)allowed {
    // AWDL already keeps direct Wi-Fi lanes on a Mac; the lane of a boost that ended is closed.
    if (!allowed) [self.group boostCloseDirectLane];
}

- (void)boostStopHosting {
}

- (void)boostLeaveJoined {
    [self.coordinator entryLeaves:self];
}

@end

@implementation SZFriendsDirectWiFiCoordinator {
    id<SZFriendsWiFiJoining> _wifi;
    NSString *_recordPath;
    dispatch_queue_t _queue;
    NSMutableDictionary<id, SZFriendsBoostEntry *> *_entries;
    NSMutableSet<NSString *> *_declined;
    SZFriendsBoostRejoin *_rejoin;
    NSString *_afterTransfer;
    SZFriendsBoostStage _afterStage;
    NSString *_savedName, *_failedName;
}

- (instancetype)initWithWiFi:(id<SZFriendsWiFiJoining>)wifi recordPath:(NSString *)recordPath
                       queue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _wifi = wifi;
        _recordPath = [recordPath copy];
        _queue = queue;
        _entries = [NSMutableDictionary dictionary];
        _declined = [NSMutableSet set];
        _rejoin = [[SZFriendsBoostRejoin alloc] initWithDriver:self];
    }
    return self;
}

- (SZFriendsBoostAbilities)abilities {
    return SZFriendsBoostCanJoin;
}

- (void)changed {
    if (self.onChanged) self.onChanged();
}

- (void)launched {
    SZFriendsBoostSaved *record = [SZFriendsBoostSaved savedFromJSON:[NSData dataWithContentsOfFile:_recordPath]];
    _savedName = record.networkName;
    [_rejoin launchedWithRecord:record now:SZFriendsBoostNow()];
}

- (SZFriendsBoostEntry *)entryForKey:(id)key transfer:(NSString *)transfer group:(id<SZFriendsDirectWiFiGroup>)group {
    SZFriendsBoostEntry *entry = [SZFriendsBoostEntry new];
    entry.coordinator = self;
    entry.group = group;
    entry.transfer = transfer;
    _entries[key] = entry;
    return entry;
}

- (BOOL)considerGroup:(id)key
             transfer:(NSString *)transfer
            remaining:(uint64_t)remaining
        bluetoothRate:(double)bluetoothRate
        bluetoothOnly:(BOOL)bluetoothOnly
     bluetoothOnlyFor:(NSTimeInterval)bluetoothOnlyFor
        seenOnNetwork:(BOOL)seenOnNetwork
      networkFailures:(NSUInteger)networkFailures
           sortsFirst:(BOOL)sortsFirst
                group:(id<SZFriendsDirectWiFiGroup>)group {
    SZFriendsBoostEstimate estimate;
    NSData *bytes = SZFriendsBoostBytes(transfer);
    if (_entries[key] != nil || bytes == nil || [_declined containsObject:transfer] || _rejoin.away ||
        !SZFriendsBoostNotOnSameNetwork(bluetoothOnly, bluetoothOnlyFor, seenOnNetwork, networkFailures) ||
        !SZFriendsBoostWorthIt(remaining, bluetoothRate, &estimate)) {
        return NO;
    }
    SZFriendsBoostEntry *entry = [self entryForKey:key transfer:transfer group:group];
    entry.estimate = estimate;
    entry.boost = [SZFriendsBoost proposeTransfer:bytes abilities:self.abilities connectivity:_wifi.connectivity
                                       sortsFirst:sortsFirst driver:entry];
    return YES;
}

- (void)group:(id)key
     receivedFrame:(SZFriendsFrame *)frame
         remaining:(uint64_t)remaining
        sortsFirst:(BOOL)sortsFirst
             group:(id<SZFriendsDirectWiFiGroup>)group {
    NSData *transfer = nil;
    SZFriendsBoostMessage *message = [SZFriendsBoostMessage messageFromFrame:frame transfer:&transfer];
    if (message == nil) return;
    NSString *hex = SZFriendsBoostHex(transfer);
    SZFriendsBoostEntry *entry = _entries[key];
    if (entry != nil) {
        if (message.step == SZFriendsBoostStepDecline && message.reason == SZFriendsBoostReasonNotNow) {
            [_declined addObject:entry.transfer];
        }
        [entry.boost message:message now:SZFriendsBoostNow()];
        [self sweep];
        return;
    }
    if (message.step != SZFriendsBoostStepPropose) return;
    if ([_declined containsObject:hex] || _rejoin.away) {
        [group boostSendFrame:[[SZFriendsBoostMessage decline:SZFriendsBoostReasonNotNow] frameForTransfer:transfer]];
        return;
    }
    entry = [self entryForKey:key transfer:hex group:group];
    entry.estimate = SZFriendsBoostEstimateFor(remaining, 0);
    entry.boost = [SZFriendsBoost proposedTransfer:transfer abilities:self.abilities peer:message.abilities
                                      connectivity:_wifi.connectivity sortsFirst:sortsFirst driver:entry
                                               now:SZFriendsBoostNow()];
    [self sweep];
    [self changed];
}

- (BOOL)answerTransfer:(NSString *)transfer goFaster:(BOOL)goFaster {
    for (SZFriendsBoostEntry *entry in _entries.allValues) {
        if (![entry.transfer isEqualToString:transfer] || entry.boost.phase != SZFriendsBoostPhaseAsking) continue;
        if (!goFaster) [_declined addObject:transfer];
        [entry.boost answer:goFaster now:SZFriendsBoostNow()];
        [self sweep];
        [self changed];
        return YES;
    }
    return NO;
}

- (void)group:(id)key directLaneUp:(BOOL)up {
    SZFriendsBoostEntry *entry = _entries[key];
    if (entry == nil) return;
    if (up && !entry.laneUp) {
        entry.laneUp = YES;
        [entry.boost laneUpAt:SZFriendsBoostNow()];
    } else if (!up && entry.laneUp) {
        entry.laneUp = NO;
        [entry.boost laneDownAt:SZFriendsBoostNow()];
    }
    [self sweep];
    [self changed];
}

- (void)group:(id)key directRate:(double)direct bluetoothRate:(double)bluetooth {
    [_entries[key].boost directRate:direct bluetoothRate:bluetooth now:SZFriendsBoostNow()];
    [self sweep];
}

- (void)group:(id)key transferEnded:(NSString *)transfer {
    SZFriendsBoostEntry *entry = _entries[key];
    if (![entry.transfer isEqualToString:transfer]) return;
    [entry.boost transferEndedAt:SZFriendsBoostNow()];
    [self sweep];
    [self changed];
}

- (void)groupEnded:(id)key {
    [_entries[key].boost sessionLostAt:SZFriendsBoostNow()];
    [_entries removeObjectForKey:key];
    [self changed];
}

- (void)quitting {
    for (SZFriendsBoostEntry *entry in _entries.allValues) [entry.boost quittingAt:SZFriendsBoostNow()];
    [_entries removeAllObjects];
}

- (void)tick {
    NSTimeInterval now = SZFriendsBoostNow();
    for (SZFriendsBoostEntry *entry in _entries.allValues) [entry.boost tick:now];
    [_rejoin tick:now];
    [self sweep];
}

- (void)sweep {
    for (id key in _entries.allKeys) {
        if (_entries[key].boost.phase == SZFriendsBoostPhaseEnded) [_entries removeObjectForKey:key];
    }
}

- (BOOL)hasBoostForGroup:(id)key {
    return _entries[key] != nil;
}

- (NSString *)transferOfGroup:(id)key {
    return _entries[key].transfer;
}

- (SZFriendsBoostRow *)rowForTransfer:(NSString *)transfer {
    SZFriendsBoostRow *row = [SZFriendsBoostRow new];
    row.network = _wifi.connectivity.wifiName;
    for (SZFriendsBoostEntry *entry in _entries.allValues) {
        if (![entry.transfer isEqualToString:transfer]) continue;
        SZFriendsBoost *boost = entry.boost;
        switch (boost.phase) {
        case SZFriendsBoostPhaseAsking: row.stage = SZFriendsBoostStageAsking; break;
        case SZFriendsBoostPhaseAgreed:
        case SZFriendsBoostPhaseHosting:
        case SZFriendsBoostPhaseJoining: row.stage = SZFriendsBoostStageConnecting; break;
        case SZFriendsBoostPhaseDirect: row.stage = SZFriendsBoostStageDirect; break;
        default: break;
        }
        row.bluetoothSeconds = entry.estimate.bluetoothSeconds;
        row.directSeconds = entry.estimate.directSeconds;
        row.leavesWiFi = boost.cost.kind != SZFriendsBoostCostNothing;
        row.overEthernet = boost.cost.kind == SZFriendsBoostCostLeavesWiFi && !boost.cost.overMobile;
        if (boost.cost.network) row.network = boost.cost.network;
        if (row.stage != SZFriendsBoostStageNone) return row;
    }
    if ([_afterTransfer isEqualToString:transfer]) {
        row.stage = _afterStage;
        row.network = (_afterStage == SZFriendsBoostStageRejoinFailed ? _failedName : _savedName) ?: row.network;
    }
    return row;
}

#pragma mark - Joining and coming back

- (void)entry:(SZFriendsBoostEntry *)entry join:(SZFriendsBoostLink *)link {
    SZFriendsBoostConnectivity *now = _wifi.connectivity;
    SZFriendsBoostSaved *saved = [SZFriendsBoostSaved savedWithNetwork:_wifi.currentNetwork networkName:now.wifiName
                                                                joined:link.network
                                                                leftAt:[NSDate date].timeIntervalSince1970];
    _savedName = now.wifiName;
    _afterTransfer = entry.transfer;
    _afterStage = SZFriendsBoostStageNone;
    [_rejoin leaving:saved];
    __weak SZFriendsBoostEntry *weakEntry = entry;
    dispatch_queue_t queue = _queue;
    [_wifi joinNetwork:link.network passphrase:link.passphrase completion:^(BOOL joined) {
        dispatch_async(queue, ^{
            SZFriendsBoost *boost = weakEntry.boost;
            if (joined) {
                [boost joinedAt:SZFriendsBoostNow()];
            } else {
                [boost failedAt:SZFriendsBoostNow()];
            }
            [self sweep];
            [self changed];
        });
    }];
}

- (void)entryLeaves:(SZFriendsBoostEntry *)entry {
    _afterTransfer = entry.transfer;
    _afterStage = SZFriendsBoostStageRejoining;
    [_rejoin comeBackAt:SZFriendsBoostNow()];
    [self changed];
}

- (void)rejoinWrite:(SZFriendsBoostSaved *)saved {
    NSError *error = nil;
    if (![saved.JSON writeToFile:_recordPath options:NSDataWritingAtomic error:&error]) {
        NSLog(@"direct Wi-Fi: the network to come back to was not written down: %@", error.localizedDescription);
    }
}

- (void)rejoinNetwork:(NSString *)network leaving:(NSString *)joined {
    dispatch_queue_t queue = _queue;
    __weak SZFriendsDirectWiFiCoordinator *weakSelf = self;
    [_wifi rejoinNetwork:network leaving:joined completion:^(BOOL ok) {
        dispatch_async(queue, ^{
            SZFriendsDirectWiFiCoordinator *strongSelf = weakSelf;
            [strongSelf->_rejoin rejoined:ok now:SZFriendsBoostNow()];
        });
    }];
}

- (void)rejoinCheckOnline {
    dispatch_queue_t queue = _queue;
    __weak SZFriendsDirectWiFiCoordinator *weakSelf = self;
    [_wifi checkOnline:^(BOOL online) {
        dispatch_async(queue, ^{
            SZFriendsDirectWiFiCoordinator *strongSelf = weakSelf;
            [strongSelf->_rejoin online:online now:SZFriendsBoostNow()];
        });
    }];
}

- (void)rejoinForget {
    [[NSFileManager defaultManager] removeItemAtPath:_recordPath error:NULL];
    if (_afterStage == SZFriendsBoostStageRejoining) _afterStage = SZFriendsBoostStageNone;
    [self changed];
}

- (void)rejoinTellNetworkName:(NSString *)networkName {
    _failedName = networkName;
    if (_afterTransfer != nil) _afterStage = SZFriendsBoostStageRejoinFailed;
    [self changed];
}

@end
