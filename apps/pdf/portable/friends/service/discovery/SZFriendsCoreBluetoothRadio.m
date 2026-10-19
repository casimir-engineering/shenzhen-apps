// The production Bluetooth radio: CBCentralManager scans and reads presence (+Central), CBPeripheralManager
// advertises and publishes L2CAP channels (here). Never created in tests (it would ask the person for Bluetooth
// access); the two-Mac hardware matrix in hardware-matrix.md exercises it.

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

@implementation SZFriendsCoreBluetoothRadio

@synthesize delegate = _delegate;

- (instancetype)initWithQueue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _queue = queue;
        _publishing = [NSMutableArray array];
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
    for (NSNumber *psm in _published) [_peripheralManager unpublishL2CAPChannel:psm.unsignedShortValue];
    [_peripheralManager removeAllServices];
    _central.delegate = nil;
    _peripheralManager.delegate = nil;
    _central = nil;
    _peripheralManager = nil;
    _service = nil;
    _serviceAdded = _wantAdvertising = _wantScanning = NO;
    _reportedPower = SZFriendsRadioPowerUnknown;
    [_publishing removeAllObjects];
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
        [_publishing removeAllObjects];
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

#pragma mark - Advertising and channels

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

- (void)publishChannelForPublicEntry:(BOOL)publicEntry {
    if (_peripheralManager.state != CBManagerStatePoweredOn) {
        dispatch_async(_queue, ^{
            [self.delegate radioDidPublishChannelWithPSM:0 publicEntry:publicEntry];
        });
        return;
    }
    [_publishing addObject:@(publicEntry)];
    // No link encryption: Noise encrypts, and encryption here would demand pairing dialogs (ADR 0004).
    [_peripheralManager publishL2CAPChannelWithEncryption:NO];
}

- (void)unpublishChannelWithPSM:(uint16_t)psm {
    [_published removeObjectForKey:@(psm)];
    [_peripheralManager unpublishL2CAPChannel:psm];
}

- (void)peripheralManager:(CBPeripheralManager *)peripheral
    didPublishL2CAPChannel:(CBL2CAPPSM)PSM
                     error:(NSError *)error {
    (void)peripheral;
    if (!_publishing.count) return;
    BOOL publicEntry = _publishing.firstObject.boolValue;
    [_publishing removeObjectAtIndex:0];
    if (!error) _published[@(PSM)] = @(publicEntry);
    [self.delegate radioDidPublishChannelWithPSM:error ? 0 : PSM publicEntry:publicEntry];
}

- (void)peripheralManager:(CBPeripheralManager *)peripheral
       didOpenL2CAPChannel:(CBL2CAPChannel *)channel
                     error:(NSError *)error {
    (void)peripheral;
    if (error || !channel) return;
    NSNumber *publicEntry = _published[@(channel.PSM)];
    if (!publicEntry) return; // a channel we no longer offer (visibility ended): dropping it closes it
    SZFriendsRunLoopByteStream *stream =
        [[SZFriendsRunLoopByteStream alloc] initWithInputStream:channel.inputStream
                                                   outputStream:channel.outputStream
                                                          owner:channel
                                             preferredWriteSize:SZFriendsL2CAPPreferredWriteSize];
    [self.delegate radioDidAcceptChannel:stream
                             publicEntry:publicEntry.boolValue
                                  peerID:channel.peer.identifier.UUIDString];
}

@end

id<SZFriendsBluetoothRadio> SZFriendsMakeCoreBluetoothRadio(dispatch_queue_t queue) {
    return [[SZFriendsCoreBluetoothRadio alloc] initWithQueue:queue];
}
