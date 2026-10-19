// The scripted Bluetooth radio and adapter delegate (SZFriendsBluetoothTestRadio.h).

#import "SZFriendsBluetoothTestRadio.h"

@implementation SZFTestRadio

@synthesize delegate = _delegate;

- (instancetype)init {
    if ((self = [super init])) {
        _publishRequests = [NSMutableArray array];
        _unpublished = [NSMutableArray array];
        _advertisedHistory = [NSMutableArray array];
        _advertisedPairs = [NSMutableArray array];
        _reads = [NSMutableArray array];
        _readsAskingPublic = [NSMutableArray array];
        _opens = [NSMutableArray array];
    }
    return self;
}

- (SZFriendsPermission)permissionWithoutPrompting {
    return self.permission;
}
- (void)powerUp {
    self.powerUps++;
}
- (void)powerDown {
    self.powerDowns++;
}
- (void)startScanning {
    self.scanStarts++;
    self.scanning = YES;
}
- (void)stopScanning {
    self.scanStops++;
    self.scanning = NO;
}
- (void)advertisePresenceValue:(NSData *)presenceValue publicValue:(NSData *)publicValue {
    self.advertisedPublic = publicValue != nil;
    self.advertisedValue = presenceValue;
    self.advertisedPublicValue = publicValue;
    [self.advertisedHistory addObject:presenceValue];
    [self.advertisedPairs addObject:@[ presenceValue, publicValue ?: [NSNull null] ]];
}
- (void)stopAdvertising {
    self.advertisingStops++;
    self.advertisedValue = nil;
    self.advertisedPublicValue = nil;
}
- (void)publishChannelForPublicEntry:(BOOL)publicEntry {
    [self.publishRequests addObject:@(publicEntry)];
}
- (void)unpublishChannelWithPSM:(uint16_t)psm {
    [self.unpublished addObject:@(psm)];
}
- (void)readPresenceFromPeripheral:(NSString *)peripheralID publicEntry:(BOOL)publicEntry {
    [self.reads addObject:peripheralID];
    [self.readsAskingPublic addObject:@(publicEntry)];
}
- (void)openChannelToPeripheral:(NSString *)peripheralID
                            psm:(uint16_t)psm
                     completion:(void (^)(id<SZFriendsByteStream>, NSError *))completion {
    [self.opens addObject:[NSString stringWithFormat:@"%@#%u", peripheralID, psm]];
    completion(self.openResult,
               self.openResult ? nil : SZFriendsDiscoveryMakeError(SZFriendsDiscoveryErrorTimedOut, @"x"));
}

@end

@implementation SZFTestAdapterDelegate

- (instancetype)init {
    if ((self = [super init])) {
        _sightings = [NSMutableArray array];
        _lost = [NSMutableArray array];
        _states = [NSMutableArray array];
        _acceptedPublic = [NSMutableArray array];
        _accepted = [NSMutableArray array];
    }
    return self;
}
- (void)adapter:(id<SZFriendsDiscoveryAdapter>)adapter didChangeState:(SZFriendsAdapterState)state {
    (void)adapter;
    [self.states addObject:@(state)];
}
- (void)adapter:(id<SZFriendsDiscoveryAdapter>)adapter didSight:(SZFriendsSighting *)sighting {
    (void)adapter;
    [self.sightings addObject:sighting];
}
- (void)adapter:(id<SZFriendsDiscoveryAdapter>)adapter didLoseEndpoint:(NSString *)endpointID {
    (void)adapter;
    [self.lost addObject:endpointID];
}
- (void)adapter:(id<SZFriendsDiscoveryAdapter>)adapter
    didAcceptStream:(id<SZFriendsByteStream>)stream
              route:(SZFriendsRouteMethod)route {
    [self adapter:adapter didAcceptStream:stream route:route publicEntry:NO];
}
- (void)adapter:(id<SZFriendsDiscoveryAdapter>)adapter
    didAcceptStream:(id<SZFriendsByteStream>)stream
              route:(SZFriendsRouteMethod)route
        publicEntry:(BOOL)publicEntry {
    (void)adapter;
    if (route != SZFriendsRouteMethodBluetooth) return;
    [self.acceptedPublic addObject:@(publicEntry)];
    [self.accepted addObject:stream];
}

@end

NSData *SZFTestPresence(NSString *tagHex, uint16_t hiddenPSM, uint16_t publicPSM, NSArray<NSData *> *callbacks) {
    return [[SZFriendsBluetoothPresence alloc] initWithPresenceTag:tagHex ? SZFTestData(tagHex) : nil
                                                       callbackTags:callbacks
                                                          hiddenPSM:hiddenPSM
                                                          publicPSM:publicPSM]
        .value;
}
