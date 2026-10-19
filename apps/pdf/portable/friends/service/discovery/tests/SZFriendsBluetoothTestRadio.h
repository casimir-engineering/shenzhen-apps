// The scripted Bluetooth radio and adapter delegate the Bluetooth adapter tests share. No CBCentralManager or
// CBPeripheralManager is ever created: that would ask the person for Bluetooth access.

#import "SZFriendsDiscoveryTestSupport.h"

#import "service/discovery/SZFriendsBluetoothRadio.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFTestRadio : NSObject <SZFriendsBluetoothRadio>
@property(nonatomic) SZFriendsPermission permission;
@property(nonatomic) NSUInteger powerUps, powerDowns, scanStarts, scanStops, advertisingStops;
@property(nonatomic) BOOL scanning, advertisedPublic;
@property(nonatomic, nullable) NSData *advertisedValue, *advertisedPublicValue;
@property(nonatomic) NSMutableArray<NSData *> *advertisedHistory; // every hidden value ever served
// Every advertisement as served together: @[hidden value, public value or NSNull].
@property(nonatomic) NSMutableArray<NSArray *> *advertisedPairs;
@property(nonatomic) NSMutableArray<NSNumber *> *publishRequests, *unpublished;
@property(nonatomic) NSMutableArray<NSString *> *reads, *opens;
@property(nonatomic) NSMutableArray<NSNumber *> *readsAskingPublic; // per read: was the public value asked for
@property(nonatomic, nullable) id<SZFriendsByteStream> openResult;
@end

@interface SZFTestAdapterDelegate : NSObject <SZFriendsDiscoveryAdapterDelegate>
@property(nonatomic) NSMutableArray<SZFriendsSighting *> *sightings;
@property(nonatomic) NSMutableArray<NSString *> *lost;
@property(nonatomic) NSMutableArray<NSNumber *> *states, *acceptedPublic;
@property(nonatomic) NSMutableArray<id<SZFriendsByteStream>> *accepted;
@end

// A presence characteristic value.
NSData *SZFTestPresence(NSString *_Nullable tagHex, uint16_t hiddenPSM, uint16_t publicPSM,
                        NSArray<NSData *> *callbacks);

void SZFriendsRunBluetoothVisibilityTests(void);

NS_ASSUME_NONNULL_END
