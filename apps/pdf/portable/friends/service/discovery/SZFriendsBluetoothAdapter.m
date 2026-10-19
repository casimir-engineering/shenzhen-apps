// The CoreBluetooth adapter's logic (ADR 0004 § Decision): advertise the Friends service, scan for it, read each
// device's presence payload, report sightings, and open or accept L2CAP channels. Radio access goes through
// SZFriendsBluetoothRadio, so all of this runs against a scripted fake in tests.

#import "service/discovery/SZFriendsBluetoothRadio.h"

static NSString *const kEndpointPrefix = @"bluetooth:";
static NSString *const kPublicSuffix = @"/public";

@implementation SZFriendsBluetoothAdapterOptions

- (instancetype)init {
    if ((self = [super init])) {
        _scanRefreshInterval = 30;
        _presenceCacheLife = 300;
        _maximumConcurrentReads = 2;
        _channelOverlap = 30;
        _clock = ^NSDate * {
            return [NSDate date];
        };
    }
    return self;
}

@end

// What this adapter knows about one peripheral. Its identifier is a dialing handle, never identity.
@interface SZFriendsPeripheralRecord : NSObject
@property(nonatomic, nullable) SZFriendsBluetoothPresence *presence;
@property(nonatomic) uint16_t publicPSM; // from the public characteristic only
@property(nonatomic, nullable) NSDate *readAt;
@property(nonatomic) BOOL readPublicEntry; // what the advertisement said when the payload was read
@property(nonatomic) BOOL reading;
@property(nonatomic) BOOL publicSighted;
@property(nonatomic) NSDate *lastSeen;
@end

@implementation SZFriendsPeripheralRecord
@end

@interface SZFriendsBluetoothAdapter : NSObject <SZFriendsDiscoveryAdapter, SZFriendsBluetoothRadioDelegate>
- (instancetype)initWithQueue:(dispatch_queue_t)queue
                        radio:(id<SZFriendsBluetoothRadio>)radio
                      options:(SZFriendsBluetoothAdapterOptions *)options;
@end

@implementation SZFriendsBluetoothAdapter {
    dispatch_queue_t _queue;
    id<SZFriendsBluetoothRadio> _radio;
    SZFriendsBluetoothAdapterOptions *_options;
    BOOL _running;
    SZFriendsRadioPower _power;
    // Each channel and the window it was published for; a publish in flight and the window it was asked for.
    BOOL _hiddenPublishInFlight, _publicPublishInFlight;
    uint16_t _hiddenPSM, _publicPSM;
    id<NSCopying, NSObject> _hiddenChannelKey, _publicChannelKey, _hiddenRequestKey, _publicRequestKey;
    NSUInteger _radioGeneration; // bumps when the radio side is forgotten, so older overlap timers do nothing
    NSData *_tag;
    NSArray<NSData *> *_callbackTags;
    BOOL _publicEntry;
    // What reads return: one window's tag, callback slots and channels. Held back while a new window's channels are
    // being published, so nothing of the new window ever appears beside a channel of the old one.
    id<NSCopying, NSObject> _servedKey;
    NSData *_servedTag;
    NSArray<NSData *> *_servedCallbacks;
    uint16_t _servedHiddenPSM, _servedPublicPSM;
    NSMutableSet<NSNumber *> *_retiringPublicPSMs; // replaced public channels in their overlap
    SZFriendsCallbackSlots *_slots;
    SZFriendsAdmissionController *_admission;
    NSMutableDictionary<NSString *, SZFriendsPeripheralRecord *> *_peripherals;
    NSMutableArray<NSString *> *_readQueue;
    NSUInteger _readsInFlight;
    dispatch_source_t _scanTimer;
}

@synthesize delegate = _delegate;
@synthesize state = _state;

- (instancetype)initWithQueue:(dispatch_queue_t)queue
                        radio:(id<SZFriendsBluetoothRadio>)radio
                      options:(SZFriendsBluetoothAdapterOptions *)options {
    if ((self = [super init])) {
        _queue = queue;
        _radio = radio;
        _radio.delegate = self;
        _options = options;
        _callbackTags = @[];
        _servedCallbacks = @[];
        _retiringPublicPSMs = [NSMutableSet set];
        _slots = [SZFriendsCallbackSlots new];
        _admission = [[SZFriendsAdmissionController alloc] initWithClock:nil];
        _peripherals = [NSMutableDictionary dictionary];
        _readQueue = [NSMutableArray array];
    }
    return self;
}

- (void)setAdmissionLimits:(SZFriendsAdmissionLimits *)limits {
    _admission.limits = limits;
}

- (SZFriendsDiscoveryMethod)method {
    return SZFriendsDiscoveryMethodBluetooth;
}

- (SZFriendsPermission)permissionWithoutPrompting {
    return _radio.permissionWithoutPrompting;
}

- (void)setState:(SZFriendsAdapterState)state {
    if (state == _state) return;
    _state = state;
    [self.delegate adapter:self didChangeState:state];
}

#pragma mark - Lifecycle

- (void)start {
    if (_running) return;
    _running = YES;
    _power = SZFriendsRadioPowerUnknown;
    self.state = SZFriendsAdapterStateStarting;
    // Created even when access was denied: that does not prompt, and the manager is what tells us when access or
    // the radio comes back, so the method starts by itself (brief § Parallel discovery).
    [_radio powerUp];
}

- (void)stop {
    if (!_running) return;
    _running = NO;
    [self stopScanTimer];
    [_radio powerDown];
    [self forgetRadioSide];
    [_peripherals removeAllObjects];
    self.state = SZFriendsAdapterStateNotAsked;
}

- (void)forgetRadioSide {
    _hiddenPublishInFlight = _publicPublishInFlight = NO;
    _hiddenPSM = _publicPSM = _servedHiddenPSM = _servedPublicPSM = 0;
    _hiddenChannelKey = _publicChannelKey = _hiddenRequestKey = _publicRequestKey = nil;
    [_retiringPublicPSMs removeAllObjects];
    _radioGeneration++;
    _servedKey = nil;
    [_readQueue removeAllObjects];
    _readsInFlight = 0;
    for (SZFriendsPeripheralRecord *record in _peripherals.allValues) record.reading = NO;
}

- (void)radioDidUpdatePower:(SZFriendsRadioPower)power {
    if (!_running || power == _power) return;
    _power = power;
    switch (power) {
    case SZFriendsRadioPowerOn:
        [self publishChannels];
        [self advertise];
        [_radio startScanning];
        [self startScanTimer];
        self.state = SZFriendsAdapterStateWorking;
        break;
    case SZFriendsRadioPowerOff:
    case SZFriendsRadioPowerUnauthorized:
    case SZFriendsRadioPowerUnsupported:
        // Channels and advertisements do not survive the radio going away; they are set up again on power on.
        [self stopScanTimer];
        [self forgetRadioSide];
        self.state = power == SZFriendsRadioPowerOff          ? SZFriendsAdapterStateRadioOff
                     : power == SZFriendsRadioPowerUnauthorized ? SZFriendsAdapterStateDenied
                                                                : SZFriendsAdapterStateUnavailable;
        break;
    case SZFriendsRadioPowerUnknown:
        self.state = SZFriendsAdapterStateStarting;
        break;
    }
}

- (void)startScanTimer {
    [self stopScanTimer];
    _scanTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    uint64_t interval = (uint64_t)(_options.scanRefreshInterval * NSEC_PER_SEC);
    dispatch_source_set_timer(_scanTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval), interval, interval / 10);
    __weak SZFriendsBluetoothAdapter *weakSelf = self;
    dispatch_source_set_event_handler(_scanTimer, ^{
        [weakSelf refreshDiscovery];
    });
    dispatch_resume(_scanTimer);
}

- (void)stopScanTimer {
    if (_scanTimer) dispatch_source_cancel(_scanTimer);
    _scanTimer = nil;
}

- (void)refreshDiscovery {
    if (!_running || _power != SZFriendsRadioPowerOn) return;
    // With duplicates off a running scan reports each peripheral once; a fresh scan reports it again.
    [_radio stopScanning];
    [_radio startScanning];
}

#pragma mark - Advertising

- (void)advertisePresenceTag:(NSData *)tag
                callbackTags:(NSArray<NSData *> *)callbackTags
                 publicEntry:(BOOL)publicEntry {
    _tag = [tag copy];
    _callbackTags = [callbackTags copy];
    _publicEntry = publicEntry;
    if (!_running || _power != SZFriendsRadioPowerOn) return;
    [self publishChannels];
    [self advertise];
}

// The window the hidden entry stands for: its presence tag, or the window index when it has none.
- (id<NSCopying, NSObject>)rotationKey {
    return _tag ?: @(SZFriendsPresenceWindowIndex(_options.clock()));
}

// ADR 0004 promises strangers cannot link one window to the next, but a published channel keeps its PSM: anyone
// reading a characteristic would see the new tag beside the old PSM. So each window gets its own hidden channel, and
// while visible its own public channel too: a public PSM kept across the boundary tied one window's tag to the next.
- (void)publishChannels {
    id<NSCopying, NSObject> key = [self rotationKey];
    if ((_hiddenPSM == 0 || ![_hiddenChannelKey isEqual:key]) && !_hiddenPublishInFlight) {
        _hiddenPublishInFlight = YES;
        _hiddenRequestKey = [key copyWithZone:nil];
        [_radio publishChannelForPublicEntry:NO];
    }
    if (_publicEntry && (_publicPSM == 0 || ![_publicChannelKey isEqual:key]) && !_publicPublishInFlight) {
        _publicPublishInFlight = YES;
        _publicRequestKey = [key copyWithZone:nil];
        [_radio publishChannelForPublicEntry:YES];
    } else if (!_publicEntry) {
        // The deadline closes the public door at once: the channels go, not only the advertisement, and so does one
        // replaced at the last boundary that would otherwise linger for its overlap.
        if (_publicPSM) [_radio unpublishChannelWithPSM:_publicPSM];
        for (NSNumber *psm in _retiringPublicPSMs) [_radio unpublishChannelWithPSM:psm.unsignedShortValue];
        [_retiringPublicPSMs removeAllObjects];
        _publicPSM = 0;
        _publicChannelKey = nil;
    }
}

- (void)advertise {
    id<NSCopying, NSObject> key = [self rotationKey];
    BOOL newWindow = _servedKey == nil || ![key isEqual:_servedKey];
    // A new window whose channels are still being published: keep serving the old window whole until they are.
    BOOL publishing = _hiddenPublishInFlight || (_publicEntry && _publicPublishInFlight);
    BOOL holding = newWindow && _servedKey != nil && publishing;
    if (!holding) {
        if (newWindow) _servedKey = [key copyWithZone:nil];
        _servedTag = _tag;
        _servedCallbacks = [_slots slotsForTags:_callbackTags rotationKey:key];
        // Only channels published for this window: one that failed is served as none, never as the old one.
        _servedHiddenPSM = [_hiddenChannelKey isEqual:key] ? _hiddenPSM : 0;
        _servedPublicPSM = [_publicChannelKey isEqual:key] ? _publicPSM : 0;
    }
    if (!_publicEntry) _servedPublicPSM = 0;
    NSData *hidden = [[SZFriendsBluetoothPresence alloc] initWithPresenceTag:_servedTag
                                                                callbackTags:_servedCallbacks
                                                                   hiddenPSM:_servedHiddenPSM
                                                                   publicPSM:0]
                         .value;
    // The public UUID goes on the air only with a channel to dial: a reader that saw it without one would cache
    // that answer for minutes.
    NSData *publicValue = _servedPublicPSM ? [[SZFriendsBluetoothPresence alloc] initWithPresenceTag:nil
                                                                                         callbackTags:@[]
                                                                                            hiddenPSM:0
                                                                                            publicPSM:_servedPublicPSM]
                                                 .value
                                           : nil;
    // A new window also restarts advertising, so the advertising set is not carried across the boundary either.
    if (newWindow && !holding) [_radio stopAdvertising];
    [_radio advertisePresenceValue:hidden publicValue:publicValue];
}

// Stays published, unadvertised, for a short overlap: someone who read the old PSM may be opening it right now.
- (void)retireChannel:(uint16_t)psm publicEntry:(BOOL)publicEntry {
    NSUInteger generation = _radioGeneration;
    if (publicEntry) [_retiringPublicPSMs addObject:@(psm)];
    __weak SZFriendsBluetoothAdapter *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_options.channelOverlap * NSEC_PER_SEC)), _queue, ^{
        SZFriendsBluetoothAdapter *strongSelf = weakSelf;
        // After a power cycle or stop the radio withdrew every channel itself; the deadline, every public one.
        if (!strongSelf || strongSelf->_radioGeneration != generation || !strongSelf->_running) return;
        if (publicEntry && ![strongSelf->_retiringPublicPSMs containsObject:@(psm)]) return;
        [strongSelf->_retiringPublicPSMs removeObject:@(psm)];
        [strongSelf->_radio unpublishChannelWithPSM:psm];
    });
}

- (void)radioDidPublishChannelWithPSM:(uint16_t)psm publicEntry:(BOOL)publicEntry {
    if (!_running) return;
    if (publicEntry) {
        _publicPublishInFlight = NO;
        if (!_publicEntry) {
            // Visibility ended while the channel was being published.
            if (psm) [_radio unpublishChannelWithPSM:psm];
            return;
        }
        // The old window's public channel goes either way, as the hidden one does below.
        if (_publicPSM && _publicPSM != psm) [self retireChannel:_publicPSM publicEntry:YES];
        _publicPSM = psm;
        _publicChannelKey = _publicRequestKey;
    } else {
        _hiddenPublishInFlight = NO;
        // The old window's channel goes either way: replaced, or (when publishing failed) the new window is served
        // with no channel rather than beside the old PSM; the next advertisement tries again.
        if (_hiddenPSM && _hiddenPSM != psm) [self retireChannel:_hiddenPSM publicEntry:NO];
        _hiddenPSM = psm;
        _hiddenChannelKey = _hiddenRequestKey;
    }
    if (_power != SZFriendsRadioPowerOn) return;
    // A window may have turned while this was in flight; asking again catches up before anything is served.
    if (psm) [self publishChannels];
    [self advertise];
}

#pragma mark - Discovery

- (void)radioDidDiscoverPeripheral:(NSString *)peripheralID publicEntry:(BOOL)publicEntry {
    if (!_running) return;
    SZFriendsPeripheralRecord *record = _peripherals[peripheralID];
    if (!record) _peripherals[peripheralID] = record = [SZFriendsPeripheralRecord new];
    NSDate *now = _options.clock();
    record.lastSeen = now;
    // A cached payload stands for this window only (tags rotate), for a limited time (callback tags change), and
    // only while the advertisement's public flag agrees with it (visibility started or stopped since the read).
    BOOL fresh = record.presence && record.readAt &&
                 SZFriendsPresenceWindowIndex(record.readAt) == SZFriendsPresenceWindowIndex(now) &&
                 [now timeIntervalSinceDate:record.readAt] < _options.presenceCacheLife &&
                 record.readPublicEntry == publicEntry;
    if (fresh) {
        [self reportPeripheral:peripheralID record:record];
        return;
    }
    record.readPublicEntry = publicEntry;
    if (record.reading || [_readQueue containsObject:peripheralID]) return;
    [_readQueue addObject:peripheralID];
    [self pumpReads];
}

- (void)pumpReads {
    while (_readsInFlight < _options.maximumConcurrentReads && _readQueue.count) {
        NSString *peripheralID = _readQueue.firstObject;
        [_readQueue removeObjectAtIndex:0];
        _peripherals[peripheralID].reading = YES;
        _readsInFlight++;
        [_radio readPresenceFromPeripheral:peripheralID publicEntry:_peripherals[peripheralID].readPublicEntry];
    }
}

- (void)radioDidReadPresence:(NSData *)value publicValue:(NSData *)publicValue fromPeripheral:(NSString *)peripheralID {
    if (!_running) return;
    SZFriendsPeripheralRecord *record = _peripherals[peripheralID];
    if (record.reading) {
        record.reading = NO;
        if (_readsInFlight) _readsInFlight--;
    }
    SZFriendsBluetoothPresence *presence = value ? [SZFriendsBluetoothPresence presenceFromValue:value] : nil;
    if (record && presence) {
        record.presence = presence;
        // Each field from the characteristic that owns it: a public PSM in the hidden value is not one.
        record.publicPSM = publicValue ? [SZFriendsBluetoothPresence presenceFromValue:publicValue].publicPSM : 0;
        record.readAt = _options.clock();
        [self reportPeripheral:peripheralID record:record];
    }
    [self pumpReads];
}

- (void)reportPeripheral:(NSString *)peripheralID record:(SZFriendsPeripheralRecord *)record {
    SZFriendsBluetoothPresence *presence = record.presence;
    NSString *hiddenEndpoint = [kEndpointPrefix stringByAppendingString:peripheralID];
    NSString *publicEndpoint = [hiddenEndpoint stringByAppendingString:kPublicSuffix];
    [self.delegate adapter:self
                  didSight:[[SZFriendsSighting alloc] initWithMethod:SZFriendsDiscoveryMethodBluetooth
                                                               route:SZFriendsRouteMethodBluetooth
                                                          endpointID:hiddenEndpoint
                                                         presenceTag:presence.presenceTag
                                                        callbackTags:presence.callbackTags
                                                            isPublic:NO
                                                              seenAt:record.lastSeen]];
    if (record.publicPSM) {
        // The public entry is its own endpoint with no tag, as on Bonjour: who it is comes only from the
        // handshake's profile.
        record.publicSighted = YES;
        [self.delegate adapter:self
                      didSight:[[SZFriendsSighting alloc] initWithMethod:SZFriendsDiscoveryMethodBluetooth
                                                                   route:SZFriendsRouteMethodBluetooth
                                                              endpointID:publicEndpoint
                                                             presenceTag:nil
                                                            callbackTags:@[]
                                                                isPublic:YES
                                                                  seenAt:record.lastSeen]];
    } else if (record.publicSighted) {
        record.publicSighted = NO;
        [self.delegate adapter:self didLoseEndpoint:publicEndpoint];
    }
}

#pragma mark - Channels

- (void)openStreamToEndpoint:(NSString *)endpointID
                  completion:(void (^)(id<SZFriendsByteStream> _Nullable, NSError *_Nullable))completion {
    void (^done)(id<SZFriendsByteStream>, NSError *) = [completion copy];
    BOOL publicEntry = [endpointID hasSuffix:kPublicSuffix];
    NSString *peripheralID = nil;
    if ([endpointID hasPrefix:kEndpointPrefix]) {
        peripheralID = [endpointID substringFromIndex:kEndpointPrefix.length];
        if (publicEntry) peripheralID = [peripheralID substringToIndex:peripheralID.length - kPublicSuffix.length];
    }
    SZFriendsPeripheralRecord *record = peripheralID ? _peripherals[peripheralID] : nil;
    SZFriendsBluetoothPresence *presence = record.presence;
    uint16_t psm = publicEntry ? record.publicPSM : presence.hiddenPSM;
    NSError *error = nil;
    if (!_running || _power != SZFriendsRadioPowerOn) {
        error = SZFriendsDiscoveryMakeError(SZFriendsDiscoveryErrorNotRunning, @"Bluetooth not running");
    } else if (!presence) {
        error = SZFriendsDiscoveryMakeError(SZFriendsDiscoveryErrorUnknownEndpoint, endpointID);
    } else if (!psm) {
        error = SZFriendsDiscoveryMakeError(SZFriendsDiscoveryErrorNoChannel, endpointID);
    }
    if (error) {
        dispatch_async(_queue, ^{
            done(nil, error);
        });
        return;
    }
    [_radio openChannelToPeripheral:peripheralID
                                psm:psm
                         completion:^(id<SZFriendsByteStream> stream, NSError *failure) {
                             done(stream, stream ? nil : failure);
                         }];
}

- (void)radioDidAcceptChannel:(id<SZFriendsByteStream>)stream publicEntry:(BOOL)publicEntry peerID:(NSString *)peerID {
    if (!_running) {
        [stream close];
        return;
    }
    // Never refused: a full listener or central closes its oldest channel that has not authenticated instead.
    id<SZFriendsByteStream> admitted = [_admission admitStream:stream
                                                      listener:publicEntry ? @"public" : @"hidden"
                                                       address:peerID];
    id<SZFriendsDiscoveryAdapterDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(adapter:didAcceptStream:route:publicEntry:)]) {
        [delegate adapter:self didAcceptStream:admitted route:SZFriendsRouteMethodBluetooth publicEntry:publicEntry];
    } else {
        [delegate adapter:self didAcceptStream:admitted route:SZFriendsRouteMethodBluetooth];
    }
}

@end

id<SZFriendsDiscoveryAdapter> SZFriendsMakeBluetoothAdapterWithRadio(dispatch_queue_t queue,
                                                                      id<SZFriendsBluetoothRadio> radio,
                                                                      SZFriendsBluetoothAdapterOptions *options) {
    return [[SZFriendsBluetoothAdapter alloc] initWithQueue:queue radio:radio options:options];
}

id<SZFriendsDiscoveryAdapter> SZFriendsMakeBluetoothAdapter(dispatch_queue_t queue) {
    return SZFriendsMakeBluetoothAdapterWithRadio(queue, SZFriendsMakeCoreBluetoothRadio(queue),
                                                  [SZFriendsBluetoothAdapterOptions new]);
}
