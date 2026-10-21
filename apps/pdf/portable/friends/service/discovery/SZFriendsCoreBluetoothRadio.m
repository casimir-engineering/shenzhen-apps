// The production Bluetooth radio: CBCentralManager scans and reads presence (+Central), one CBPeripheralManager
// advertises and serves the presence characteristics, and one more per L2CAP channel publishes and accepts it
// (SZFriendsChannelHost). Never created in tests (it would ask the person for Bluetooth access); the two-Mac hardware
// matrix in hardware-matrix.md and scripts/friends/ble-hardware-check.sh with a phone exercise it.

#import "service/discovery/SZFriendsCoreBluetoothRadioInternal.h"

#include <stdatomic.h>

static atomic_uint gManagersCreated;

NSUInteger SZFriendsCoreBluetoothManagersCreated(void) {
    return atomic_load(&gManagersCreated);
}

static SZFriendsRadioPower PowerFromState(CBManagerState state) {
    switch (state) {
    case CBManagerStatePoweredOn:
        return SZFriendsRadioPowerOn;
    case CBManagerStatePoweredOff:
        return SZFriendsRadioPowerOff;
    case CBManagerStateUnauthorized:
        return SZFriendsRadioPowerUnauthorized;
    case CBManagerStateUnsupported:
        return SZFriendsRadioPowerUnsupported;
    default:
        return SZFriendsRadioPowerUnknown;
    }
}

@implementation SZFriendsPendingOpen
@end

@implementation SZFriendsPendingRead
@end

@implementation SZFriendsChannelHost
@end

@implementation SZFriendsCoreBluetoothRadio

@synthesize delegate = _delegate;

- (instancetype)initWithQueue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _queue = queue;
        _channelHosts = [NSMutableArray array];
        _published = [NSMutableDictionary dictionary];
        _peripherals = [NSMutableDictionary dictionary];
        _reads = [NSMutableDictionary dictionary];
        _opens = [NSMutableDictionary dictionary];
        _channels = [NSMutableDictionary dictionary];
    }
    return self;
}

- (SZFriendsPermission)permissionWithoutPrompting {
    return SZFriendsPermissionFromBluetoothAuthorization(CBManager.authorization);
}

#pragma mark - Power

- (void)powerUp {
    if (_central) return;
    // No power alert: Nearby shows "Bluetooth is off" itself, in words written for that spot.
    _central = [[CBCentralManager alloc] initWithDelegate:self
                                                    queue:_queue
                                                  options:@{CBCentralManagerOptionShowPowerAlertKey : @NO}];
    _peripheralManager =
        [[CBPeripheralManager alloc] initWithDelegate:self
                                                queue:_queue
                                              options:@{CBPeripheralManagerOptionShowPowerAlertKey : @NO}];
    atomic_fetch_add(&gManagersCreated, 2);
}

- (void)powerDown {
    if (!_central) return;
    [_central stopScan];
    for (CBPeripheral *peripheral in _peripherals.allValues) [_central cancelPeripheralConnection:peripheral];
    [_peripheralManager stopAdvertising];
    [self releaseChannelHosts];
    [_peripheralManager removeAllServices];
    _central.delegate = nil;
    _peripheralManager.delegate = nil;
    _central = nil;
    _peripheralManager = nil;
    _service = nil;
    _serviceAdded = _wantAdvertising = _wantScanning = NO;
    _reportedPower = SZFriendsRadioPowerUnknown;
    [_published removeAllObjects];
    for (NSString *peripheralID in _opens.allKeys) [self failOpensForPeripheral:peripheralID];
    [_reads removeAllObjects];
    [_peripherals removeAllObjects];
}

- (void)reportPower {
    SZFriendsRadioPower central = PowerFromState(_central.state);
    SZFriendsRadioPower peripheral = PowerFromState(_peripheralManager.state);
    SZFriendsRadioPower power = SZFriendsRadioPowerUnknown;
    if (central == SZFriendsRadioPowerUnauthorized || peripheral == SZFriendsRadioPowerUnauthorized) {
        power = SZFriendsRadioPowerUnauthorized;
    } else if (central == SZFriendsRadioPowerUnsupported || peripheral == SZFriendsRadioPowerUnsupported) {
        power = SZFriendsRadioPowerUnsupported;
    } else if (central == SZFriendsRadioPowerOff || peripheral == SZFriendsRadioPowerOff) {
        power = SZFriendsRadioPowerOff;
    } else if (central == SZFriendsRadioPowerOn && peripheral == SZFriendsRadioPowerOn) {
        power = SZFriendsRadioPowerOn;
    }
    if (power != SZFriendsRadioPowerOn) {
        _serviceAdded = NO; // services and channels do not survive the radio going away
        _service = nil;
        [self releaseChannelHosts];
        [_published removeAllObjects];
    }
    if (power == _reportedPower) return;
    _reportedPower = power;
    [self.delegate radioDidUpdatePower:power];
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    (void)central;
    [self reportPower];
}

- (void)peripheralManagerDidUpdateState:(CBPeripheralManager *)peripheral {
    if (peripheral != _peripheralManager) {
        [self channelHostDidUpdateState:peripheral];
        return;
    }
    if (peripheral.state == CBManagerStatePoweredOn && !_service) {
        NSMutableArray<CBMutableCharacteristic *> *characteristics = [NSMutableArray array];
        NSArray<NSString *> *uuids =
            @[ SZFriendsBluetoothPresenceCharacteristicUUID, SZFriendsBluetoothPublicCharacteristicUUID ];
        for (NSString *uuid in uuids) {
            // value nil: dynamic, answered from the current values on every read.
            [characteristics addObject:[[CBMutableCharacteristic alloc] initWithType:SZFriendsBluetoothUUID(uuid)
                                                                          properties:CBCharacteristicPropertyRead
                                                                               value:nil
                                                                         permissions:CBAttributePermissionsReadable]];
        }
        CBUUID *serviceUUID = SZFriendsBluetoothUUID(SZFriendsBluetoothServiceUUID);
        _service = [[CBMutableService alloc] initWithType:serviceUUID primary:YES];
        _service.characteristics = characteristics;
        [peripheral addService:_service];
    }
    [self reportPower];
}

#pragma mark - Central side

// The protocol's central-side methods, implemented in +Central: the compiler wants every protocol method on the class
// itself, so these hand over.
- (void)startScanning {
    [self centralStartScanning];
}

- (void)stopScanning {
    [self centralStopScanning];
}

- (void)readPresenceFromPeripheral:(NSString *)peripheralID publicEntry:(BOOL)publicEntry {
    [self centralReadPresenceFromPeripheral:peripheralID publicEntry:publicEntry];
}

- (void)openChannelToPeripheral:(NSString *)peripheralID
                            psm:(uint16_t)psm
                     completion:(void (^)(id<SZFriendsByteStream>, NSError *))completion {
    [self centralOpenChannelToPeripheral:peripheralID psm:psm completion:completion];
}

#pragma mark - Advertising

- (void)advertisePresenceValue:(NSData *)presenceValue publicValue:(NSData *)publicValue {
    _presenceValue = [presenceValue copy];
    _publicValue = [publicValue copy];
    BOOL publicEntry = publicValue != nil;
    BOOL changed = !_wantAdvertising || _advertisingPublic != publicEntry;
    _wantAdvertising = YES;
    _advertisingPublic = publicEntry;
    if (changed) [self restartAdvertising];
}

- (void)restartAdvertising {
    if (!_serviceAdded || _peripheralManager.state != CBManagerStatePoweredOn) return; // didAddService resumes
    [_peripheralManager stopAdvertising];
    if (!_wantAdvertising) return;
    NSMutableArray<CBUUID *> *uuids =
        [NSMutableArray arrayWithObject:SZFriendsBluetoothUUID(SZFriendsBluetoothServiceUUID)];
    if (_advertisingPublic) [uuids addObject:SZFriendsBluetoothUUID(SZFriendsBluetoothPublicUUID)];
    // No local name: whether macOS then adds the Mac's name on its own is a hardware-matrix check.
    [_peripheralManager startAdvertising:@{CBAdvertisementDataServiceUUIDsKey : uuids}];
}

- (void)stopAdvertising {
    _wantAdvertising = NO;
    [_peripheralManager stopAdvertising];
}

- (void)peripheralManager:(CBPeripheralManager *)peripheral didAddService:(CBService *)service error:(NSError *)error {
    (void)peripheral;
    (void)service;
    if (error) return; // logged by the system; advertising without the service would answer no reads
    _serviceAdded = YES;
    [self restartAdvertising];
}

- (void)peripheralManagerDidStartAdvertising:(CBPeripheralManager *)peripheral error:(NSError *)error {
    (void)peripheral;
    (void)error;
}

- (void)peripheralManager:(CBPeripheralManager *)peripheral didReceiveReadRequest:(CBATTRequest *)request {
    NSData *value = nil;
    CBUUID *asked = request.characteristic.UUID;
    if ([asked isEqual:SZFriendsBluetoothUUID(SZFriendsBluetoothPresenceCharacteristicUUID)]) {
        value = _presenceValue ?: [NSData data];
    } else if ([asked isEqual:SZFriendsBluetoothUUID(SZFriendsBluetoothPublicCharacteristicUUID)]) {
        value = _publicValue ?: [NSData data]; // empty while not visible: no public entry to describe
    } else {
        [peripheral respondToRequest:request withResult:CBATTErrorRequestNotSupported];
        return;
    }
    if (request.offset > value.length) {
        [peripheral respondToRequest:request withResult:CBATTErrorInvalidOffset];
        return;
    }
    request.value = [value subdataWithRange:NSMakeRange(request.offset, value.length - request.offset)];
    [peripheral respondToRequest:request withResult:CBATTErrorSuccess];
}

#pragma mark - Channels

- (SZFriendsChannelHost *)channelHostForManager:(CBPeripheralManager *)manager {
    for (SZFriendsChannelHost *host in _channelHosts) {
        if (host.manager == manager) return host;
    }
    return nil;
}

- (void)releaseChannelHost:(SZFriendsChannelHost *)host {
    if (host.psm && !host.unpublished && host.manager.state == CBManagerStatePoweredOn) {
        [host.manager unpublishL2CAPChannel:host.psm];
    }
    host.manager.delegate = nil;
    [_channelHosts removeObject:host];
}

// Every channel goes with the radio. A publish still waiting is answered as failed, later, so the adapter does not
// wait on it forever when the radio only resets (it forgets its channels itself only when the radio goes away).
- (void)releaseChannelHosts {
    for (SZFriendsChannelHost *host in [_channelHosts copy]) {
        if (host.psm == 0) {
            BOOL publicEntry = host.publicEntry;
            dispatch_async(_queue, ^{
                [self.delegate radioDidPublishChannelWithPSM:0 publicEntry:publicEntry];
            });
        }
        [self releaseChannelHost:host];
    }
}

// A withdrawn channel's manager goes once the channels it accepted have closed: releasing it ends its session, and
// with it, perhaps, a conversation still running on that channel.
- (void)pruneChannelHosts {
    for (SZFriendsChannelHost *host in [_channelHosts copy]) {
        if (host.unpublished && host.streams.allObjects.count == 0) [self releaseChannelHost:host];
    }
}

- (void)publishChannelForPublicEntry:(BOOL)publicEntry {
    if (_peripheralManager.state != CBManagerStatePoweredOn) {
        dispatch_async(_queue, ^{
            [self.delegate radioDidPublishChannelWithPSM:0 publicEntry:publicEntry];
        });
        return;
    }
    [self pruneChannelHosts];
    SZFriendsChannelHost *host = [SZFriendsChannelHost new];
    host.publicEntry = publicEntry;
    host.streams = [NSHashTable weakObjectsHashTable];
    [_channelHosts addObject:host];
    // Published once this manager reports it is powered on (channelHostDidUpdateState:). Bluetooth access belongs to
    // the process, so a further manager asks nobody.
    host.manager = [[CBPeripheralManager alloc] initWithDelegate:self
                                                           queue:_queue
                                                         options:@{CBPeripheralManagerOptionShowPowerAlertKey : @NO}];
    atomic_fetch_add(&gManagersCreated, 1);
}

- (void)channelHostDidUpdateState:(CBPeripheralManager *)peripheral {
    SZFriendsChannelHost *host = [self channelHostForManager:peripheral];
    if (!host) return;
    switch (peripheral.state) {
    case CBManagerStatePoweredOn:
        if (!host.publishAsked && !host.unpublished) {
            host.publishAsked = YES;
            // No link encryption: Noise encrypts, and encryption here would demand pairing dialogs (ADR 0004).
            [peripheral publishL2CAPChannelWithEncryption:NO];
        }
        break;
    case CBManagerStateUnknown:
    case CBManagerStateResetting:
        break;
    default: {
        // Off, denied or unsupported: the channel is gone, or never came. The main manager reports the same power
        // change, which withdraws every channel; a publish still waiting is answered here.
        BOOL waiting = host.psm == 0;
        BOOL publicEntry = host.publicEntry;
        if (host.psm && !host.unpublished) [_published removeObjectForKey:@(host.psm)];
        [self releaseChannelHost:host];
        if (waiting) [self.delegate radioDidPublishChannelWithPSM:0 publicEntry:publicEntry];
        break;
    }
    }
}

- (void)unpublishChannelWithPSM:(uint16_t)psm {
    [_published removeObjectForKey:@(psm)];
    for (SZFriendsChannelHost *host in _channelHosts) {
        if (host.psm != psm || host.unpublished) continue;
        if (host.manager.state == CBManagerStatePoweredOn) [host.manager unpublishL2CAPChannel:psm];
        host.unpublished = YES;
    }
    [self pruneChannelHosts];
}

- (void)peripheralManager:(CBPeripheralManager *)peripheral
    didPublishL2CAPChannel:(CBL2CAPPSM)PSM
                     error:(NSError *)error {
    SZFriendsChannelHost *host = [self channelHostForManager:peripheral];
    if (!host || host.psm) return; // released meanwhile (power cycle or stop), or a repeat
    BOOL publicEntry = host.publicEntry;
    if (error || PSM == 0) {
        [self releaseChannelHost:host];
        [self.delegate radioDidPublishChannelWithPSM:0 publicEntry:publicEntry];
        return;
    }
    host.psm = PSM;
    _published[@(PSM)] = @(publicEntry);
    [self.delegate radioDidPublishChannelWithPSM:PSM publicEntry:publicEntry];
}

- (void)peripheralManager:(CBPeripheralManager *)peripheral
       didOpenL2CAPChannel:(CBL2CAPChannel *)channel
                     error:(NSError *)error {
    if (error || !channel) return;
    SZFriendsChannelHost *host = [self channelHostForManager:peripheral];
    NSNumber *publicEntry = _published[@(channel.PSM)];
    // A channel we no longer offer (visibility ended, or its window's overlap ran out): dropping it closes it.
    if (!host || host.unpublished || host.psm != channel.PSM || !publicEntry) return;
    SZFriendsRunLoopByteStream *stream =
        [[SZFriendsRunLoopByteStream alloc] initWithInputStream:channel.inputStream
                                                   outputStream:channel.outputStream
                                                          owner:channel
                                             preferredWriteSize:SZFriendsL2CAPPreferredWriteSize];
    [host.streams addObject:stream];
    [self.delegate radioDidAcceptChannel:stream
                             publicEntry:publicEntry.boolValue
                                  peerID:channel.peer.identifier.UUIDString];
}

@end

id<SZFriendsBluetoothRadio> SZFriendsMakeCoreBluetoothRadio(dispatch_queue_t queue) {
    return [[SZFriendsCoreBluetoothRadio alloc] initWithQueue:queue];
}
