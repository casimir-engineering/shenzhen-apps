// The production Bluetooth radio's central side: scanning for the Friends service, reading each device's presence
// characteristics, and opening L2CAP channels to others (SZFriendsCoreBluetoothRadioInternal.h).

#import "service/discovery/SZFriendsCoreBluetoothRadioInternal.h"

@implementation SZFriendsCoreBluetoothRadio (Central)

#pragma mark - Scanning and reading

- (void)centralStartScanning {
    _wantScanning = YES;
    if (_central.state != CBManagerStatePoweredOn) return;
    NSArray<CBUUID *> *services = @[
        SZFriendsBluetoothUUID(SZFriendsBluetoothServiceUUID), SZFriendsBluetoothUUID(SZFriendsBluetoothPublicUUID)
    ];
    [_central scanForPeripheralsWithServices:services options:@{CBCentralManagerScanOptionAllowDuplicatesKey : @NO}];
}

- (void)centralStopScanning {
    _wantScanning = NO;
    [_central stopScan];
}

- (void)centralManager:(CBCentralManager *)central
    didDiscoverPeripheral:(CBPeripheral *)peripheral
        advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                     RSSI:(NSNumber *)RSSI {
    (void)central;
    (void)RSSI;
    NSString *peripheralID = peripheral.identifier.UUIDString;
    _peripherals[peripheralID] = peripheral; // CoreBluetooth drops peripherals nobody retains
    NSMutableArray<CBUUID *> *uuids = [NSMutableArray array];
    [uuids addObjectsFromArray:advertisementData[CBAdvertisementDataServiceUUIDsKey] ?: @[]];
    [uuids addObjectsFromArray:advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] ?: @[]];
    BOOL publicEntry = [uuids containsObject:SZFriendsBluetoothUUID(SZFriendsBluetoothPublicUUID)];
    [self.delegate radioDidDiscoverPeripheral:peripheralID publicEntry:publicEntry];
}

- (void)centralReadPresenceFromPeripheral:(NSString *)peripheralID publicEntry:(BOOL)publicEntry {
    CBPeripheral *peripheral = _peripherals[peripheralID];
    if (!peripheral || _reads[peripheralID]) {
        if (!peripheral) {
            dispatch_async(_queue, ^{
                [self.delegate radioDidReadPresence:nil publicValue:nil fromPeripheral:peripheralID];
            });
        }
        return;
    }
    SZFriendsPendingRead *read = [SZFriendsPendingRead new];
    read.wantsPublic = publicEntry;
    _reads[peripheralID] = read;
    peripheral.delegate = self;
    if (peripheral.state == CBPeripheralStateConnected) {
        [peripheral discoverServices:@[ SZFriendsBluetoothUUID(SZFriendsBluetoothServiceUUID) ]];
    } else {
        [_central connectPeripheral:peripheral options:nil];
    }
    __weak SZFriendsCoreBluetoothRadio *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SZFriendsRadioTimeout * NSEC_PER_SEC)), _queue, ^{
        [weakSelf finishRead:peripheralID failed:YES];
    });
}

// Reports what came back (nothing when `failed`), at most once per read.
- (void)finishRead:(NSString *)peripheralID failed:(BOOL)failed {
    SZFriendsPendingRead *read = _reads[peripheralID];
    if (!read) return;
    [_reads removeObjectForKey:peripheralID];
    [self.delegate radioDidReadPresence:failed ? nil : read.value
                            publicValue:failed ? nil : read.publicValue
                         fromPeripheral:peripheralID];
    [self disconnectIfIdle:peripheralID];
}

- (void)disconnectIfIdle:(NSString *)peripheralID {
    // An open L2CAP channel rides on this connection; cancelling it would close the session.
    BOOL busy = _reads[peripheralID] != nil || _opens[peripheralID].count ||
                _channels[peripheralID].allObjects.count; // allObjects: count can include released entries
    CBPeripheral *peripheral = _peripherals[peripheralID];
    if (!busy && peripheral) [_central cancelPeripheralConnection:peripheral];
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    (void)central;
    NSString *peripheralID = peripheral.identifier.UUIDString;
    if (_reads[peripheralID]) [peripheral discoverServices:@[ SZFriendsBluetoothUUID(SZFriendsBluetoothServiceUUID) ]];
    for (SZFriendsPendingOpen *open in _opens[peripheralID]) [peripheral openL2CAPChannel:open.psm];
}

- (void)centralManager:(CBCentralManager *)central
    didFailToConnectPeripheral:(CBPeripheral *)peripheral
                         error:(NSError *)error {
    (void)central;
    (void)error;
    [self connectionEndedForPeripheral:peripheral.identifier.UUIDString];
}

- (void)centralManager:(CBCentralManager *)central
    didDisconnectPeripheral:(CBPeripheral *)peripheral
                      error:(NSError *)error {
    (void)central;
    (void)error;
    [self connectionEndedForPeripheral:peripheral.identifier.UUIDString];
}

- (void)connectionEndedForPeripheral:(NSString *)peripheralID {
    [self finishRead:peripheralID failed:YES];
    [self failOpensForPeripheral:peripheralID];
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    SZFriendsPendingRead *read = _reads[peripheral.identifier.UUIDString];
    for (CBService *service in error || !read ? @[] : peripheral.services) {
        if (![service.UUID isEqual:SZFriendsBluetoothUUID(SZFriendsBluetoothServiceUUID)]) continue;
        NSMutableArray<CBUUID *> *wanted =
            [NSMutableArray arrayWithObject:SZFriendsBluetoothUUID(SZFriendsBluetoothPresenceCharacteristicUUID)];
        if (read.wantsPublic) [wanted addObject:SZFriendsBluetoothUUID(SZFriendsBluetoothPublicCharacteristicUUID)];
        [peripheral discoverCharacteristics:wanted forService:service];
        return;
    }
    [self finishRead:peripheral.identifier.UUIDString failed:YES];
}

- (void)peripheral:(CBPeripheral *)peripheral
    didDiscoverCharacteristicsForService:(CBService *)service
                                   error:(NSError *)error {
    SZFriendsPendingRead *read = _reads[peripheral.identifier.UUIDString];
    if (!read || read.outstanding) return;
    CBUUID *hiddenUUID = SZFriendsBluetoothUUID(SZFriendsBluetoothPresenceCharacteristicUUID);
    CBUUID *publicUUID = SZFriendsBluetoothUUID(SZFriendsBluetoothPublicCharacteristicUUID);
    for (CBCharacteristic *characteristic in error ? @[] : service.characteristics) {
        BOOL wanted = [characteristic.UUID isEqual:hiddenUUID] ||
                      (read.wantsPublic && [characteristic.UUID isEqual:publicUUID]);
        if (!wanted) continue;
        read.outstanding++;
        [peripheral readValueForCharacteristic:characteristic];
    }
    if (!read.outstanding) [self finishRead:peripheral.identifier.UUIDString failed:YES];
}

- (void)peripheral:(CBPeripheral *)peripheral
    didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
                              error:(NSError *)error {
    SZFriendsPendingRead *read = _reads[peripheral.identifier.UUIDString];
    if (!read || !read.outstanding) return;
    if (!error && [characteristic.UUID isEqual:SZFriendsBluetoothUUID(SZFriendsBluetoothPublicCharacteristicUUID)]) {
        read.publicValue = characteristic.value;
    } else if (!error) {
        read.value = characteristic.value;
    }
    // A failed public read still reports the hidden value; a failed hidden read reports nothing (value stays nil).
    if (--read.outstanding == 0) [self finishRead:peripheral.identifier.UUIDString failed:NO];
}

#pragma mark - Opening channels

- (void)centralOpenChannelToPeripheral:(NSString *)peripheralID
                                   psm:(uint16_t)psm
                            completion:(void (^)(id<SZFriendsByteStream>, NSError *))completion {
    CBPeripheral *peripheral = _peripherals[peripheralID];
    SZFriendsPendingOpen *open = [SZFriendsPendingOpen new];
    open.psm = psm;
    open.completion = completion;
    if (!peripheral) {
        dispatch_async(_queue, ^{
            completion(nil, SZFriendsDiscoveryMakeError(SZFriendsDiscoveryErrorUnknownEndpoint, peripheralID));
        });
        return;
    }
    if (!_opens[peripheralID]) _opens[peripheralID] = [NSMutableArray array];
    [_opens[peripheralID] addObject:open];
    peripheral.delegate = self;
    if (peripheral.state == CBPeripheralStateConnected) [peripheral openL2CAPChannel:psm];
    else [_central connectPeripheral:peripheral options:nil];
    __weak SZFriendsCoreBluetoothRadio *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SZFriendsRadioTimeout * NSEC_PER_SEC)), _queue, ^{
        [weakSelf finishOpen:open peripheral:peripheralID stream:nil];
    });
}

- (void)finishOpen:(SZFriendsPendingOpen *)open
        peripheral:(NSString *)peripheralID
            stream:(id<SZFriendsByteStream>)stream {
    if (![_opens[peripheralID] containsObject:open]) return;
    [_opens[peripheralID] removeObject:open];
    NSError *error = stream ? nil : SZFriendsDiscoveryMakeError(SZFriendsDiscoveryErrorTimedOut, @"L2CAP open failed");
    open.completion(stream, error);
    if (!stream) [self disconnectIfIdle:peripheralID];
}

- (void)failOpensForPeripheral:(NSString *)peripheralID {
    for (SZFriendsPendingOpen *open in [_opens[peripheralID] copy]) {
        [self finishOpen:open peripheral:peripheralID stream:nil];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didOpenL2CAPChannel:(CBL2CAPChannel *)channel error:(NSError *)error {
    NSString *peripheralID = peripheral.identifier.UUIDString;
    SZFriendsPendingOpen *match = nil;
    for (SZFriendsPendingOpen *open in _opens[peripheralID]) {
        if (!channel || open.psm == channel.PSM) {
            match = open;
            break;
        }
    }
    if (!match) return;
    if (error || !channel) {
        [self finishOpen:match peripheral:peripheralID stream:nil];
        return;
    }
    SZFriendsRunLoopByteStream *stream =
        [[SZFriendsRunLoopByteStream alloc] initWithInputStream:channel.inputStream
                                                   outputStream:channel.outputStream
                                                          owner:channel
                                             preferredWriteSize:SZFriendsL2CAPPreferredWriteSize];
    if (!_channels[peripheralID]) _channels[peripheralID] = [NSHashTable weakObjectsHashTable];
    [_channels[peripheralID] addObject:stream];
    [self finishOpen:match peripheral:peripheralID stream:stream];
}

@end
