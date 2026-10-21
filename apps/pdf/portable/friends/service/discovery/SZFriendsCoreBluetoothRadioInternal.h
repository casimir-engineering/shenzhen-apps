// The production Bluetooth radio's shared state, split by side so each file stays reviewable: the radio file
// (managers, power, and the peripheral side: advertising, the presence characteristics, publishing and accepting
// L2CAP channels) and +Central (scanning, presence reads and opening channels to others). Internal to this directory.

#import "service/discovery/SZFriendsBluetoothRadio.h"

NS_ASSUME_NONNULL_BEGIN

// A read is connect, discover, read, disconnect; an open is connect and open. Either gives up after this, so a
// peripheral that walked away cannot hold a read slot.
static const NSTimeInterval SZFriendsRadioTimeout = 10;
// The session sizes Bluetooth chunks itself (4 KiB, ADR 0001); this only bounds one stream write.
static const NSUInteger SZFriendsL2CAPPreferredWriteSize = 4096;

static inline CBUUID *SZFriendsBluetoothUUID(NSString *string) {
    return [CBUUID UUIDWithString:string];
}

@interface SZFriendsPendingOpen : NSObject
@property(nonatomic) uint16_t psm;
@property(nonatomic, copy) void (^completion)(id<SZFriendsByteStream> _Nullable, NSError *_Nullable);
@end

// One presence read: the characteristics asked for, and the values that came back.
@interface SZFriendsPendingRead : NSObject
@property(nonatomic) BOOL wantsPublic;
@property(nonatomic) NSUInteger outstanding; // value reads asked for and not yet answered
@property(nonatomic, nullable) NSData *value, *publicValue;
@end

// One published L2CAP channel and the peripheral manager that publishes it, alone. WHY its own manager: bluetoothd
// routes an incoming connection only to the oldest channel a manager's session still has published, and refuses the
// rest ("Rejecting connection for PSM ... Could not find a session, endpoint or pipe"), so a second channel on the
// manager that carries the hidden one (a public channel, or the next window's) could never be dialled. Seen on the
// owner's Mac with a phone, 2026-10-20; the same bug on the central side is rdar://46227689.
@interface SZFriendsChannelHost : NSObject
@property(nonatomic) CBPeripheralManager *manager;
@property(nonatomic) BOOL publicEntry;
@property(nonatomic) BOOL publishAsked;
@property(nonatomic) uint16_t psm;                // 0 until published
@property(nonatomic) BOOL unpublished;            // withdrawn; kept only while a channel it accepted is open
@property(nonatomic) NSHashTable *streams;        // the channels it accepted, weakly held
@end

@interface SZFriendsCoreBluetoothRadio
    : NSObject <SZFriendsBluetoothRadio, CBCentralManagerDelegate, CBPeripheralManagerDelegate, CBPeripheralDelegate> {
  @package
    dispatch_queue_t _queue;
    CBCentralManager *_Nullable _central;
    CBPeripheralManager *_Nullable _peripheralManager;
    CBMutableService *_Nullable _service;
    BOOL _serviceAdded;
    NSData *_Nullable _presenceValue, *_Nullable _publicValue;
    BOOL _wantAdvertising, _advertisingPublic, _wantScanning;
    SZFriendsRadioPower _reportedPower;
    NSMutableArray<SZFriendsChannelHost *> *_channelHosts;      // one manager per published channel
    NSMutableDictionary<NSNumber *, NSNumber *> *_published;    // PSM -> public flag
    NSMutableDictionary<NSString *, CBPeripheral *> *_peripherals;
    NSMutableDictionary<NSString *, SZFriendsPendingRead *> *_reads;
    NSMutableDictionary<NSString *, NSMutableArray<SZFriendsPendingOpen *> *> *_opens;
    NSMutableDictionary<NSString *, NSHashTable *> *_channels;  // live streams per peripheral, weakly held
}
- (instancetype)initWithQueue:(dispatch_queue_t)queue;
@end

// What the class's SZFriendsBluetoothRadio methods of the same names hand over to.
@interface SZFriendsCoreBluetoothRadio (Central)
- (void)centralStartScanning;
- (void)centralStopScanning;
- (void)centralReadPresenceFromPeripheral:(NSString *)peripheralID publicEntry:(BOOL)publicEntry;
- (void)centralOpenChannelToPeripheral:(NSString *)peripheralID
                                   psm:(uint16_t)psm
                            completion:(void (^)(id<SZFriendsByteStream> _Nullable, NSError *_Nullable))completion;
// Every pending open for the peripheral fails (its connection ended, or the radio powered down).
- (void)failOpensForPeripheral:(NSString *)peripheralID;
@end

NS_ASSUME_NONNULL_END
