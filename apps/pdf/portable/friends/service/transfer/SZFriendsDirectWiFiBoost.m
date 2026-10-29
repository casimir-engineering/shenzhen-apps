// See SZFriendsDirectWiFiBoost.h. A port of szfriends-core's transfer/boost.rs: change both together.

#import "service/transfer/SZFriendsDirectWiFiBoost.h"

#import <sodium.h>

const NSTimeInterval SZFriendsBoostBluetoothOnlyFor = 10;
const NSUInteger SZFriendsBoostNetworkTries = 3;
const double SZFriendsBoostSavesAtLeast = 20;
const double SZFriendsBoostSetupSeconds = 15;
const double SZFriendsBoostDirectBytesPerSecond = 8e6;
const double SZFriendsBoostBluetoothBytesPerSecond = 0.15e6;
const NSTimeInterval SZFriendsBoostMeasureFor = 6;
const NSTimeInterval SZFriendsBoostLinkWithin = 45;
const NSUInteger SZFriendsBoostRejoinTries = 3;
const NSTimeInterval SZFriendsBoostRejoinAgainAfter = 3;
const NSTimeInterval SZFriendsBoostOnlineWithin = 20;
const NSTimeInterval SZFriendsBoostCheckEvery = 2;

SZFriendsBoostEstimate SZFriendsBoostEstimateFor(uint64_t remaining, double bluetoothRate) {
    double rate = bluetoothRate > 0 ? bluetoothRate : SZFriendsBoostBluetoothBytesPerSecond;
    double bytes = (double)remaining;
    return (SZFriendsBoostEstimate){bytes / rate, SZFriendsBoostSetupSeconds + bytes / SZFriendsBoostDirectBytesPerSecond};
}

BOOL SZFriendsBoostWorthIt(uint64_t remaining, double bluetoothRate, SZFriendsBoostEstimate *estimate) {
    SZFriendsBoostEstimate e = SZFriendsBoostEstimateFor(remaining, bluetoothRate);
    if (estimate) *estimate = e;
    return e.bluetoothSeconds - e.directSeconds >= SZFriendsBoostSavesAtLeast;
}

BOOL SZFriendsBoostNotOnSameNetwork(BOOL bluetoothOnly, NSTimeInterval bluetoothOnlyFor, BOOL seenOnNetwork,
                                    NSUInteger networkFailures) {
    return bluetoothOnly && bluetoothOnlyFor >= SZFriendsBoostBluetoothOnlyFor &&
           (!seenOnNetwork || networkFailures >= SZFriendsBoostNetworkTries);
}

SZFriendsBoostRole SZFriendsBoostRoleFor(SZFriendsBoostAbilities local, SZFriendsBoostAbilities peer,
                                         BOOL localSortsFirst) {
    int (^cost)(SZFriendsBoostAbilities, SZFriendsBoostAbilities) = ^int(SZFriendsBoostAbilities host,
                                                                         SZFriendsBoostAbilities joiner) {
        return !(host & SZFriendsBoostHostKeepsWiFi) + !(joiner & SZFriendsBoostJoinKeepsWiFi);
    };
    BOOL localHosts = (local & SZFriendsBoostCanHost) && (peer & SZFriendsBoostCanJoin);
    BOOL peerHosts = (peer & SZFriendsBoostCanHost) && (local & SZFriendsBoostCanJoin);
    if (localHosts && peerHosts) {
        int a = cost(local, peer), b = cost(peer, local);
        if (a == b) return localSortsFirst ? SZFriendsBoostRoleHost : SZFriendsBoostRoleJoin;
        return a < b ? SZFriendsBoostRoleHost : SZFriendsBoostRoleJoin;
    }
    if (localHosts) return SZFriendsBoostRoleHost;
    if (peerHosts) return SZFriendsBoostRoleJoin;
    return SZFriendsBoostRoleNone;
}

@implementation SZFriendsBoostConnectivity
@end

@implementation SZFriendsBoostCost

+ (instancetype)costForRole:(SZFriendsBoostRole)role
                  abilities:(SZFriendsBoostAbilities)abilities
               connectivity:(SZFriendsBoostConnectivity *)connectivity {
    SZFriendsBoostCost *cost = [self new];
    BOOL keeps = role == SZFriendsBoostRoleHost ? (abilities & SZFriendsBoostHostKeepsWiFi) != 0
                                                : (abilities & SZFriendsBoostJoinKeepsWiFi) != 0;
    if (keeps || !connectivity.onWiFi) return cost;
    cost->_network = connectivity.wifiName.length ? [connectivity.wifiName copy] : nil;
    if (connectivity.wired || connectivity.mobile) {
        cost->_kind = SZFriendsBoostCostLeavesWiFi;
        cost->_overMobile = !connectivity.wired;
    } else {
        cost->_kind = SZFriendsBoostCostLeavesInternet;
    }
    return cost;
}

- (BOOL)asks {
    return _kind == SZFriendsBoostCostLeavesInternet;
}

@end

#pragma mark - Link

static const char SZFriendsBoostAlphanumeric[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

static NSString *SZFriendsBoostPick(const uint8_t *bytes, NSUInteger count) {
    NSMutableString *out = [NSMutableString stringWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) [out appendFormat:@"%c", SZFriendsBoostAlphanumeric[bytes[i] % 62]];
    return out;
}

static BOOL SZFriendsBoostPrintable(NSString *text) {
    NSData *bytes = [text dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *b = bytes.bytes;
    for (NSUInteger i = 0; i < bytes.length; i++) {
        if (b[i] < 0x21 || b[i] >= 0x7f) return NO;
    }
    return YES;
}

@implementation SZFriendsBoostLink

+ (instancetype)random {
    uint8_t bytes[64];
    randombytes_buf(bytes, sizeof bytes);
    SZFriendsBoostLink *link = [self linkFromRandom:[NSData dataWithBytes:bytes length:sizeof bytes]];
    sodium_memzero(bytes, sizeof bytes);
    return link;
}

+ (instancetype)linkFromRandom:(NSData *)sixtyFourBytes {
    const uint8_t *b = sixtyFourBytes.bytes;
    SZFriendsBoostLink *link = [self new];
    link->_network = [NSString stringWithFormat:@"DIRECT-%@%@", SZFriendsBoostPick(b, 2), SZFriendsBoostPick(b + 2, 8)];
    link->_passphrase = SZFriendsBoostPick(b + 10, 20);
    return link;
}

+ (instancetype)linkWithNetwork:(NSString *)network passphrase:(NSString *)passphrase {
    NSUInteger n = [network lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    NSUInteger p = [passphrase lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (![network hasPrefix:@"DIRECT-"] || n < 9 || n > 32 || p < 8 || p > 63 || !SZFriendsBoostPrintable(network) ||
        !SZFriendsBoostPrintable(passphrase)) {
        return nil;
    }
    SZFriendsBoostLink *link = [self new];
    link->_network = [network copy];
    link->_passphrase = [passphrase copy];
    return link;
}

// The passphrase never reaches a log.
- (NSString *)description {
    return [NSString stringWithFormat:@"<link %@>", _network];
}

@end

BOOL SZFriendsBoostAddressIsPrivate(NSData *address) {
    const uint8_t *a = address.bytes;
    if (address.length == 4) {
        return a[0] == 10 || (a[0] == 172 && (a[1] & 0xf0) == 16) || (a[0] == 192 && a[1] == 168) ||
               (a[0] == 169 && a[1] == 254);
    }
    if (address.length == 16) {
        return (a[0] == 0xfe && (a[1] & 0xc0) == 0x80) || (a[0] & 0xfe) == 0xfc;
    }
    return NO;
}

#pragma mark - Messages

static NSData *SZFriendsBoostByte(uint8_t value) {
    return [NSData dataWithBytes:&value length:1];
}

@implementation SZFriendsBoostMessage

+ (instancetype)step:(SZFriendsBoostStep)step {
    SZFriendsBoostMessage *message = [self new];
    message->_step = step;
    return message;
}

+ (instancetype)propose:(SZFriendsBoostAbilities)abilities {
    SZFriendsBoostMessage *m = [self step:SZFriendsBoostStepPropose];
    m->_abilities = abilities;
    return m;
}

+ (instancetype)ready:(SZFriendsBoostAbilities)abilities {
    SZFriendsBoostMessage *m = [self step:SZFriendsBoostStepReady];
    m->_abilities = abilities;
    return m;
}

+ (instancetype)host:(SZFriendsBoostLink *)link address:(NSData *)address port:(uint16_t)port {
    SZFriendsBoostMessage *m = [self step:SZFriendsBoostStepHost];
    m->_link = link;
    m->_address = [address copy];
    m->_port = port;
    return m;
}

+ (instancetype)end:(SZFriendsBoostReason)reason {
    SZFriendsBoostMessage *m = [self step:SZFriendsBoostStepEnd];
    m->_reason = reason;
    return m;
}

+ (instancetype)decline:(SZFriendsBoostReason)reason {
    SZFriendsBoostMessage *m = [self step:SZFriendsBoostStepDecline];
    m->_reason = reason;
    return m;
}

- (SZFriendsFrame *)frameForTransfer:(NSData *)transfer {
    NSMutableDictionary *fields = [@{@(SZFriendsFieldID) : transfer, @(SZFriendsFieldStep) : SZFriendsBoostByte(_step)}
        mutableCopy];
    switch (_step) {
    case SZFriendsBoostStepPropose:
    case SZFriendsBoostStepReady: fields[@(SZFriendsFieldAbilities)] = SZFriendsBoostByte(_abilities); break;
    case SZFriendsBoostStepHost: {
        uint16_t port = CFSwapInt16HostToBig(_port);
        fields[@(SZFriendsFieldNetwork)] = [_link.network dataUsingEncoding:NSUTF8StringEncoding];
        fields[@(SZFriendsFieldPassphrase)] = [_link.passphrase dataUsingEncoding:NSUTF8StringEncoding];
        fields[@(SZFriendsFieldAddress)] = _address;
        fields[@(SZFriendsFieldPort)] = [NSData dataWithBytes:&port length:2];
        break;
    }
    case SZFriendsBoostStepEnd:
    case SZFriendsBoostStepDecline: fields[@(SZFriendsFieldReason)] = SZFriendsBoostByte(_reason); break;
    }
    return [SZFriendsFrame frameWithType:SZFriendsFrameTypeBoost fields:fields];
}

+ (instancetype)messageFromFrame:(SZFriendsFrame *)frame transfer:(NSData **)transfer {
    NSDictionary<NSNumber *, NSData *> *f = frame.fields;
    NSData *id_ = f[@(SZFriendsFieldID)], *step = f[@(SZFriendsFieldStep)];
    if (frame.type != SZFriendsFrameTypeBoost || id_.length != 16 || step.length != 1) return nil;
    uint8_t (^byte)(NSNumber *, uint8_t) = ^uint8_t(NSNumber *tag, uint8_t otherwise) {
        NSData *value = f[tag];
        return value.length == 1 ? ((const uint8_t *)value.bytes)[0] : otherwise;
    };
    SZFriendsBoostMessage *message = nil;
    switch (((const uint8_t *)step.bytes)[0]) {
    case SZFriendsBoostStepPropose:
    case SZFriendsBoostStepReady:
        if (f[@(SZFriendsFieldAbilities)].length != 1) return nil;
        message = [self step:((const uint8_t *)step.bytes)[0]];
        message->_abilities = byte(@(SZFriendsFieldAbilities), 0) & 0x0f;
        break;
    case SZFriendsBoostStepHost: {
        NSString *network = [[NSString alloc] initWithData:f[@(SZFriendsFieldNetwork)] ?: [NSData data]
                                                  encoding:NSUTF8StringEncoding];
        NSString *passphrase = [[NSString alloc] initWithData:f[@(SZFriendsFieldPassphrase)] ?: [NSData data]
                                                     encoding:NSUTF8StringEncoding];
        NSData *address = f[@(SZFriendsFieldAddress)], *port = f[@(SZFriendsFieldPort)];
        SZFriendsBoostLink *link = network && passphrase ? [SZFriendsBoostLink linkWithNetwork:network
                                                                                   passphrase:passphrase]
                                                         : nil;
        if (link == nil || port.length != 2 || !SZFriendsBoostAddressIsPrivate(address ?: [NSData data])) return nil;
        const uint8_t *p = port.bytes;
        uint16_t value = (uint16_t)(p[0] << 8 | p[1]);
        if (value == 0) return nil;
        message = [self host:link address:address port:value];
        break;
    }
    case SZFriendsBoostStepEnd: message = [self end:byte(@(SZFriendsFieldReason), SZFriendsBoostReasonDone)]; break;
    case SZFriendsBoostStepDecline:
        message = [self decline:byte(@(SZFriendsFieldReason), SZFriendsBoostReasonFailed)];
        break;
    default: return nil;
    }
    *transfer = id_;
    return message;
}

@end

#pragma mark - Negotiation

@implementation SZFriendsBoost {
    __weak id<SZFriendsBoostDriver> _driver;
    SZFriendsBoostAbilities _local;
    SZFriendsBoostConnectivity *_connectivity;
    BOOL _sortsFirst, _sentReady, _gotReady, _hosting, _joining;
    SZFriendsBoostLink *_link;
    NSData *_dialAddress;
    uint16_t _dialPort;
    NSTimeInterval _agreedAt, _laneAt;
}

- (instancetype)initWithTransfer:(NSData *)transfer
                       abilities:(SZFriendsBoostAbilities)abilities
                    connectivity:(SZFriendsBoostConnectivity *)connectivity
                     sortsFirst:(BOOL)sortsFirst
                          driver:(id<SZFriendsBoostDriver>)driver {
    if ((self = [super init])) {
        _transfer = [transfer copy];
        _local = abilities;
        _connectivity = connectivity;
        _sortsFirst = sortsFirst;
        _driver = driver;
        _phase = SZFriendsBoostPhaseProposed;
        _cost = [SZFriendsBoostCost new];
        _agreedAt = -1;
        _laneAt = -1;
    }
    return self;
}

+ (instancetype)proposeTransfer:(NSData *)transfer
                      abilities:(SZFriendsBoostAbilities)abilities
                   connectivity:(SZFriendsBoostConnectivity *)connectivity
                    sortsFirst:(BOOL)sortsFirst
                         driver:(id<SZFriendsBoostDriver>)driver {
    SZFriendsBoost *boost = [[self alloc] initWithTransfer:transfer abilities:abilities connectivity:connectivity
                                                sortsFirst:sortsFirst driver:driver];
    [driver boostSend:[SZFriendsBoostMessage propose:abilities]];
    return boost;
}

+ (instancetype)proposedTransfer:(NSData *)transfer
                       abilities:(SZFriendsBoostAbilities)abilities
                            peer:(SZFriendsBoostAbilities)peer
                    connectivity:(SZFriendsBoostConnectivity *)connectivity
                     sortsFirst:(BOOL)sortsFirst
                          driver:(id<SZFriendsBoostDriver>)driver
                             now:(NSTimeInterval)now {
    SZFriendsBoost *boost = [[self alloc] initWithTransfer:transfer abilities:abilities connectivity:connectivity
                                                sortsFirst:sortsFirst driver:driver];
    [boost peerSaid:peer now:now];
    return boost;
}

- (void)peerSaid:(SZFriendsBoostAbilities)peer now:(NSTimeInterval)now {
    SZFriendsBoostRole role = (_local & (SZFriendsBoostCanHost | SZFriendsBoostCanJoin))
                                  ? SZFriendsBoostRoleFor(_local, peer, _sortsFirst)
                                  : SZFriendsBoostRoleNone;
    if (role == SZFriendsBoostRoleNone) {
        [self end:SZFriendsBoostReasonUnsupported tell:YES];
        return;
    }
    _role = role;
    _cost = [SZFriendsBoostCost costForRole:role abilities:_local connectivity:_connectivity];
    if (_cost.asks) {
        _phase = SZFriendsBoostPhaseAsking;
        [_driver boostAsk:YES];
    } else {
        [self agree:now];
    }
}

- (void)agree:(NSTimeInterval)now {
    _sentReady = YES;
    _phase = SZFriendsBoostPhaseAgreed;
    [_driver boostSend:[SZFriendsBoostMessage ready:_local]];
    [self bothAgreed:now];
}

- (void)bothAgreed:(NSTimeInterval)now {
    if (!(_sentReady && _gotReady)) return;
    _agreedAt = now;
    if (_role == SZFriendsBoostRoleHost) {
        _link = [SZFriendsBoostLink random];
        _hosting = YES;
        _phase = SZFriendsBoostPhaseHosting;
        [_driver boostAllowDirectLane:YES];
        [_driver boostHost:_link];
    }
}

- (void)answer:(BOOL)goFaster now:(NSTimeInterval)now {
    if (_phase != SZFriendsBoostPhaseAsking) return;
    [_driver boostAsk:NO];
    if (goFaster) {
        [self agree:now];
    } else {
        _declinedByPerson = YES;
        _phase = SZFriendsBoostPhaseEnded;
        _endReason = SZFriendsBoostReasonNotNow;
        [_driver boostSend:[SZFriendsBoostMessage decline:SZFriendsBoostReasonNotNow]];
    }
}

- (void)message:(SZFriendsBoostMessage *)message now:(NSTimeInterval)now {
    if (_phase == SZFriendsBoostPhaseEnded) return;
    switch (message.step) {
    case SZFriendsBoostStepPropose:
        // Both proposed at once: each takes the other's PROPOSE as its answer.
        if (_phase == SZFriendsBoostPhaseProposed) [self peerSaid:message.abilities now:now];
        break;
    case SZFriendsBoostStepReady:
        if (_role == SZFriendsBoostRoleNone) [self peerSaid:message.abilities now:now];
        if (_phase != SZFriendsBoostPhaseEnded) {
            _gotReady = YES;
            [self bothAgreed:now];
        }
        break;
    case SZFriendsBoostStepHost:
        if (_role != SZFriendsBoostRoleJoin || !_sentReady || !_gotReady || _joining) return;
        _joining = YES;
        _phase = SZFriendsBoostPhaseJoining;
        _link = message.link;
        _dialAddress = message.address;
        _dialPort = message.port;
        [_driver boostAllowDirectLane:YES];
        [_driver boostJoin:message.link];
        break;
    case SZFriendsBoostStepDecline:
        if (message.reason == SZFriendsBoostReasonNotNow) _declinedByPerson = YES;
        [self end:message.reason tell:NO];
        break;
    case SZFriendsBoostStepEnd: [self end:message.reason tell:NO]; break;
    }
}

- (void)hostedAt:(NSData *)address port:(uint16_t)port now:(NSTimeInterval)now {
    if (_phase != SZFriendsBoostPhaseHosting || _link == nil) return;
    [_driver boostSend:[SZFriendsBoostMessage host:_link address:address port:port]];
}

- (void)joinedAt:(NSTimeInterval)now {
    if (_phase != SZFriendsBoostPhaseJoining || _dialAddress == nil) return;
    [_driver boostDialAddress:_dialAddress port:_dialPort];
}

- (void)failedAt:(NSTimeInterval)now {
    [self end:SZFriendsBoostReasonFailed tell:YES];
}

- (void)laneUpAt:(NSTimeInterval)now {
    if (_phase == SZFriendsBoostPhaseHosting || _phase == SZFriendsBoostPhaseJoining) {
        _phase = SZFriendsBoostPhaseDirect;
        _laneAt = now;
    }
}

- (void)laneDownAt:(NSTimeInterval)now {
    if (_phase == SZFriendsBoostPhaseDirect) [self end:SZFriendsBoostReasonFailed tell:YES];
}

- (void)directRate:(double)direct bluetoothRate:(double)bluetooth now:(NSTimeInterval)now {
    BOOL measured = _laneAt >= 0 && now - _laneAt >= SZFriendsBoostMeasureFor;
    if (_phase == SZFriendsBoostPhaseDirect && measured && direct <= bluetooth) {
        [self end:SZFriendsBoostReasonSlower tell:YES];
    }
}

- (void)tick:(NSTimeInterval)now {
    BOOL late = _agreedAt >= 0 && now - _agreedAt >= SZFriendsBoostLinkWithin;
    if (late && (_phase == SZFriendsBoostPhaseAgreed || _phase == SZFriendsBoostPhaseHosting ||
                 _phase == SZFriendsBoostPhaseJoining)) {
        [self end:SZFriendsBoostReasonFailed tell:YES];
    }
}

- (void)transferEndedAt:(NSTimeInterval)now {
    [self end:SZFriendsBoostReasonTransferEnded tell:YES];
}

- (void)quittingAt:(NSTimeInterval)now {
    [self end:SZFriendsBoostReasonQuitting tell:YES];
}

- (void)sessionLostAt:(NSTimeInterval)now {
    [self end:SZFriendsBoostReasonFailed tell:NO];
}

- (void)end:(SZFriendsBoostReason)reason tell:(BOOL)tell {
    if (_phase == SZFriendsBoostPhaseEnded) return;
    id<SZFriendsBoostDriver> driver = _driver;
    if (_phase == SZFriendsBoostPhaseAsking) [driver boostAsk:NO];
    if (tell) {
        BOOL said = _sentReady || _phase == SZFriendsBoostPhaseProposed;
        [driver boostSend:said ? [SZFriendsBoostMessage end:reason] : [SZFriendsBoostMessage decline:reason]];
    }
    if (_hosting || _joining) [driver boostAllowDirectLane:NO];
    if (_hosting) [driver boostStopHosting];
    if (_joining) [driver boostLeaveJoined];
    _hosting = NO;
    _joining = NO;
    _phase = SZFriendsBoostPhaseEnded;
    _endReason = reason;
}

@end
