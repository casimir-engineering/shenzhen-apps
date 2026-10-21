// The CoreBluetooth adapter's seam: the adapter's logic (states, presence reads, endpoints, channels) talks to a
// radio through this protocol. Production uses SZFriendsCoreBluetoothRadio over CBCentralManager and
// CBPeripheralManager; tests use a scripted fake, because a real manager would ask the person for Bluetooth access
// (and one Mac cannot discover itself). Internal to this directory.

#import <CoreBluetooth/CoreBluetooth.h>
#import <Foundation/Foundation.h>

#import "service/discovery/SZFriendsDiscoveryInternal.h"

NS_ASSUME_NONNULL_BEGIN

// Fixed for the life of the protocol: every Friends Mac must use the same values (ADR 0004 § Decision).
extern NSString *const SZFriendsBluetoothServiceUUID;        // the hidden Friends service, always advertised
extern NSString *const SZFriendsBluetoothPublicUUID;         // added during the person's 5 minutes
extern NSString *const SZFriendsBluetoothPresenceCharacteristicUUID; // read: the hidden entry's payload below
// Read while the public UUID is advertised: the same payload with only the public PSM set. WHY its own value: one
// value carrying the hidden tag, the hidden PSM and the public PSM together tied the public name and picture to the
// hidden tag on purpose-built reads, and the public PSM, kept across a window boundary, tied one window's tag to the
// next (review finding "presence linkability"). Both values still come from one device during the 5 minutes, so a
// reader then can tell they belong together; what they no longer do is outlast the window.
extern NSString *const SZFriendsBluetoothPublicCharacteristicUUID;

typedef NS_ENUM(NSInteger, SZFriendsRadioPower) {
    SZFriendsRadioPowerUnknown = 0, // unknown or resetting: wait for the next update
    SZFriendsRadioPowerOn = 1,
    SZFriendsRadioPowerOff = 2,
    SZFriendsRadioPowerUnauthorized = 3,
    SZFriendsRadioPowerUnsupported = 4,
};

SZFriendsPermission SZFriendsPermissionFromBluetoothAuthorization(CBManagerAuthorization authorization);

// What the presence characteristics return, version 1 (the spike decides whether the tag also fits the advertised
// local name, which would save the read):
//   [0] version 1   [1] flags, bit 0: a presence tag follows   [2..9] presence tag (zero without one)
//   [10..11] hidden channel PSM, u16be (0 until published)   [12..13] public channel PSM (0 when not visible)
//   [14] callback tag count n (at most 4)   [15..] n x 8-byte callback tags
// Longer values are accepted, so version 1 can grow fields at the end. The hidden characteristic fills everything but
// the public PSM, which is always 0 there; the public characteristic fills only the public PSM. A reader takes each
// field only from the characteristic that owns it.
@interface SZFriendsBluetoothPresence : NSObject
@property(nonatomic, readonly, nullable) NSData *presenceTag;
@property(nonatomic, readonly) NSArray<NSData *> *callbackTags;
@property(nonatomic, readonly) uint16_t hiddenPSM;
@property(nonatomic, readonly) uint16_t publicPSM;
- (instancetype)initWithPresenceTag:(nullable NSData *)presenceTag
                       callbackTags:(NSArray<NSData *> *)callbackTags
                          hiddenPSM:(uint16_t)hiddenPSM
                          publicPSM:(uint16_t)publicPSM NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (nullable instancetype)presenceFromValue:(NSData *)value; // nil for anything malformed or another version
- (NSData *)value;
@end

@protocol SZFriendsBluetoothRadioDelegate <NSObject>
- (void)radioDidUpdatePower:(SZFriendsRadioPower)power;
// A scan result for the Friends service; `publicEntry` when the public UUID was advertised too.
- (void)radioDidDiscoverPeripheral:(NSString *)peripheralID publicEntry:(BOOL)publicEntry;
// The presence characteristic's value, or nil when the read failed; and the public characteristic's when it was asked
// for and read.
- (void)radioDidReadPresence:(nullable NSData *)value
                 publicValue:(nullable NSData *)publicValue
              fromPeripheral:(NSString *)peripheralID;
// psm 0: publishing failed.
- (void)radioDidPublishChannelWithPSM:(uint16_t)psm publicEntry:(BOOL)publicEntry;
// `peerID`: the connecting central's identifier, what the per-address admission limit counts (nil when unknown).
- (void)radioDidAcceptChannel:(id<SZFriendsByteStream>)stream
                  publicEntry:(BOOL)publicEntry
                       peerID:(nullable NSString *)peerID;
@end

// Everything runs on the queue the radio was made with.
@protocol SZFriendsBluetoothRadio <NSObject>
@property(nonatomic, weak, nullable) id<SZFriendsBluetoothRadioDelegate> delegate;
// CBManager.authorization: a class property, so reading it creates no manager and never prompts.
@property(nonatomic, readonly) SZFriendsPermission permissionWithoutPrompting;
- (void)powerUp;   // creates the managers: the one call that may prompt
- (void)powerDown; // stops everything and releases the managers
- (void)startScanning;
- (void)stopScanning;
// Advertises the Friends service (and the public UUID when `publicValue` is given) and serves `presenceValue` and
// `publicValue` to reads of their characteristics.
- (void)advertisePresenceValue:(NSData *)presenceValue publicValue:(nullable NSData *)publicValue;
- (void)stopAdvertising;
- (void)publishChannelForPublicEntry:(BOOL)publicEntry;
- (void)unpublishChannelWithPSM:(uint16_t)psm;
// Reads the presence characteristic, and the public one too when `publicEntry` (the advertisement had the public
// UUID), in one connection.
- (void)readPresenceFromPeripheral:(NSString *)peripheralID publicEntry:(BOOL)publicEntry;
- (void)openChannelToPeripheral:(NSString *)peripheralID
                            psm:(uint16_t)psm
                     completion:
                         (void (^)(id<SZFriendsByteStream> _Nullable stream, NSError *_Nullable error))completion;
@end

@interface SZFriendsBluetoothAdapterOptions : NSObject
// Scanning restarts this often: with duplicates off, a scan reports each peripheral once, and a sighting not
// renewed within SZFriendsBluetoothSightingLife expires. Default 30 s (the spike tunes).
@property(nonatomic) NSTimeInterval scanRefreshInterval;
// A presence read is reused for re-sightings within its window for this long. Default 300 s.
@property(nonatomic) NSTimeInterval presenceCacheLife;
@property(nonatomic) NSUInteger maximumConcurrentReads; // default 2: each read is a short connection
// A hidden or public channel replaced at a new window stays published this long, unadvertised, for people already
// opening it; default 30 s.
@property(nonatomic) NSTimeInterval channelOverlap;
@property(nonatomic, copy) NSDate * (^clock)(void);     // default [NSDate date]
@end

id<SZFriendsDiscoveryAdapter> SZFriendsMakeBluetoothAdapterWithRadio(dispatch_queue_t queue,
                                                                      id<SZFriendsBluetoothRadio> radio,
                                                                      SZFriendsBluetoothAdapterOptions *options);
// The production radio. Creating it creates no manager; -powerUp does.
id<SZFriendsBluetoothRadio> SZFriendsMakeCoreBluetoothRadio(dispatch_queue_t queue);
// A test home's radio: the test air in `directory`, shared with the Rust helper's (its test_air.rs), on loopback
// only. `power` is SZFRIENDS_TEST_BLUETOOTH_POWER: "off", "denied", "unsupported" or "ask"; nil or anything else is
// on and allowed. Creates no manager.
id<SZFriendsBluetoothRadio> SZFriendsMakeTestAirRadio(dispatch_queue_t queue, NSString *directory,
                                                       NSString *_Nullable power);
// CBCentralManager and CBPeripheralManager instances this process has created (the launch tests prove creating
// an adapter creates none).
NSUInteger SZFriendsCoreBluetoothManagersCreated(void);

NS_ASSUME_NONNULL_END
