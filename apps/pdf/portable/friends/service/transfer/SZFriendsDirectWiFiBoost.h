// The Wi-Fi Direct boost (ADR 0019) in the Mac helper: the same decisions, negotiation and way back as the Rust core's
// transfer::boost, which both helpers must agree with frame for frame (fixtures/vectors/transfer/frames.json, boost_*).
// A Mac can only join a link (CoreWLAN; it has no Wi-Fi Direct hosting), so here it is always the joining side, and
// two Macs (or a Mac and an iPhone) never boost: they have AWDL.
//
// Pure apart from SZFriendsDirectWiFiCoordinator, which runs boosts for the nearby service against an
// id<SZFriendsWiFiJoining> (CoreWLAN in the helper, a mock in tests: no test ever touches the Mac's real Wi-Fi) and
// keeps the record of the network to come back to in the state directory (direct-wifi.json).

#import <Foundation/Foundation.h>

#import "service/session/SZFriendsSession.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - When

extern const NSTimeInterval SZFriendsBoostBluetoothOnlyFor; // 10 s on Bluetooth alone, the device not on the network
extern const NSUInteger SZFriendsBoostNetworkTries;         // or 3 lane dials there failed
extern const double SZFriendsBoostSavesAtLeast;             // 20 s
extern const double SZFriendsBoostSetupSeconds;             // 15 s
extern const double SZFriendsBoostDirectBytesPerSecond;     // 8 MB/s, as the estimate counts it
extern const double SZFriendsBoostBluetoothBytesPerSecond;  // 150 kB/s until measured
extern const NSTimeInterval SZFriendsBoostMeasureFor;       // 6 s: then faster than Bluetooth, or it ends
extern const NSTimeInterval SZFriendsBoostLinkWithin;       // 45 s from both agreeing to the lane up

typedef struct {
    double bluetoothSeconds;
    double directSeconds; // setup included
} SZFriendsBoostEstimate;

SZFriendsBoostEstimate SZFriendsBoostEstimateFor(uint64_t remaining, double bluetoothRate);
// YES, with the estimate, when the boost saves at least SZFriendsBoostSavesAtLeast seconds.
BOOL SZFriendsBoostWorthIt(uint64_t remaining, double bluetoothRate, SZFriendsBoostEstimate *_Nullable estimate);
// Bluetooth alone, long enough, and the network had its chances.
BOOL SZFriendsBoostNotOnSameNetwork(BOOL bluetoothOnly, NSTimeInterval bluetoothOnlyFor, BOOL seenOnNetwork,
                                    NSUInteger networkFailures);

#pragma mark - Who hosts, who is asked

typedef NS_OPTIONS(uint8_t, SZFriendsBoostAbilities) {
    SZFriendsBoostCanHost = 1u << 0,
    SZFriendsBoostCanJoin = 1u << 1,
    SZFriendsBoostHostKeepsWiFi = 1u << 2,
    SZFriendsBoostJoinKeepsWiFi = 1u << 3,
};
typedef NS_ENUM(NSInteger, SZFriendsBoostRole) {
    SZFriendsBoostRoleNone = 0,
    SZFriendsBoostRoleHost,
    SZFriendsBoostRoleJoin,
};
// The same answer on both sides: fewer devices off their Wi-Fi, then the identity key that sorts first hosts.
SZFriendsBoostRole SZFriendsBoostRoleFor(SZFriendsBoostAbilities local, SZFriendsBoostAbilities peer,
                                         BOOL localSortsFirst);

typedef NS_ENUM(NSInteger, SZFriendsBoostCostKind) {
    SZFriendsBoostCostNothing = 0,
    SZFriendsBoostCostLeavesWiFi,     // stays online another way: no question, the note says so
    SZFriendsBoostCostLeavesInternet, // its only way online: the person is asked
};
@interface SZFriendsBoostConnectivity : NSObject
@property(nonatomic) BOOL onWiFi;
@property(nonatomic, copy, nullable) NSString *wifiName; // shown on this device only, never sent
@property(nonatomic) BOOL wired;
@property(nonatomic) BOOL mobile;
@end
@interface SZFriendsBoostCost : NSObject
+ (instancetype)costForRole:(SZFriendsBoostRole)role
                  abilities:(SZFriendsBoostAbilities)abilities
               connectivity:(SZFriendsBoostConnectivity *)connectivity;
@property(nonatomic, readonly) SZFriendsBoostCostKind kind;
@property(nonatomic, readonly, copy, nullable) NSString *network;
@property(nonatomic, readonly) BOOL overMobile; // LeavesWiFi only: online over mobile data, not a cable
@property(nonatomic, readonly) BOOL asks;
@end

#pragma mark - The link and the frames

// A link's name ("DIRECT-" and ten random letters and digits) and its passphrase (20 of them), random per boost.
@interface SZFriendsBoostLink : NSObject
+ (instancetype)random;
+ (instancetype)linkFromRandom:(NSData *)sixtyFourBytes; // the vectors' link
+ (nullable instancetype)linkWithNetwork:(NSString *)network passphrase:(NSString *)passphrase; // nil unless valid
@property(nonatomic, readonly, copy) NSString *network;
@property(nonatomic, readonly, copy) NSString *passphrase;
@end
// A private IPv4 address, or an IPv6 link-local or unique local one (4 or 16 bytes).
BOOL SZFriendsBoostAddressIsPrivate(NSData *address);

typedef NS_ENUM(uint8_t, SZFriendsBoostStep) {
    SZFriendsBoostStepPropose = 1,
    SZFriendsBoostStepReady = 2,
    SZFriendsBoostStepHost = 3,
    SZFriendsBoostStepEnd = 4,
    SZFriendsBoostStepDecline = 5,
};
typedef NS_ENUM(uint8_t, SZFriendsBoostReason) {
    SZFriendsBoostReasonDone = 0,
    SZFriendsBoostReasonNotNow = 1,
    SZFriendsBoostReasonUnsupported = 2,
    SZFriendsBoostReasonFailed = 3,
    SZFriendsBoostReasonSlower = 4,
    SZFriendsBoostReasonTransferEnded = 5,
    SZFriendsBoostReasonQuitting = 6,
};
@interface SZFriendsBoostMessage : NSObject
+ (instancetype)propose:(SZFriendsBoostAbilities)abilities;
+ (instancetype)ready:(SZFriendsBoostAbilities)abilities;
+ (instancetype)host:(SZFriendsBoostLink *)link address:(NSData *)address port:(uint16_t)port;
+ (instancetype)end:(SZFriendsBoostReason)reason;
+ (instancetype)decline:(SZFriendsBoostReason)reason;
// nil for a frame that is not BOOST, an unknown step, a missing field, or a HOST naming a link a joiner refuses.
+ (nullable instancetype)messageFromFrame:(SZFriendsFrame *)frame transfer:(NSData *_Nullable *_Nonnull)transfer;
- (SZFriendsFrame *)frameForTransfer:(NSData *)transfer;
@property(nonatomic, readonly) SZFriendsBoostStep step;
@property(nonatomic, readonly) SZFriendsBoostAbilities abilities;
@property(nonatomic, readonly) SZFriendsBoostReason reason;
@property(nonatomic, readonly, nullable) SZFriendsBoostLink *link;
@property(nonatomic, readonly, nullable) NSData *address;
@property(nonatomic, readonly) uint16_t port;
@end

#pragma mark - The negotiation

typedef NS_ENUM(NSInteger, SZFriendsBoostPhase) {
    SZFriendsBoostPhaseProposed,
    SZFriendsBoostPhaseAsking,
    SZFriendsBoostPhaseAgreed,
    SZFriendsBoostPhaseHosting,
    SZFriendsBoostPhaseJoining,
    SZFriendsBoostPhaseDirect,
    SZFriendsBoostPhaseEnded,
};

// What the boost asks of its driver, in order.
@protocol SZFriendsBoostDriver <NSObject>
- (void)boostSend:(SZFriendsBoostMessage *)message;
- (void)boostAsk:(BOOL)asking; // the question on the transfer's row comes (YES) or goes (NO)
- (void)boostHost:(SZFriendsBoostLink *)link;
- (void)boostJoin:(SZFriendsBoostLink *)link;
- (void)boostDialAddress:(NSData *)address port:(uint16_t)port;
- (void)boostAllowDirectLane:(BOOL)allowed;
- (void)boostStopHosting;
- (void)boostLeaveJoined;
@end

@interface SZFriendsBoost : NSObject
// This side saw a transfer crawl over Bluetooth and proposes.
+ (instancetype)proposeTransfer:(NSData *)transfer
                      abilities:(SZFriendsBoostAbilities)abilities
                   connectivity:(SZFriendsBoostConnectivity *)connectivity
                    sortsFirst:(BOOL)sortsFirst
                         driver:(id<SZFriendsBoostDriver>)driver;
// The peer proposed.
+ (instancetype)proposedTransfer:(NSData *)transfer
                       abilities:(SZFriendsBoostAbilities)abilities
                            peer:(SZFriendsBoostAbilities)peer
                    connectivity:(SZFriendsBoostConnectivity *)connectivity
                     sortsFirst:(BOOL)sortsFirst
                          driver:(id<SZFriendsBoostDriver>)driver
                             now:(NSTimeInterval)now;
@property(nonatomic, readonly) NSData *transfer;
@property(nonatomic, readonly) SZFriendsBoostPhase phase;
@property(nonatomic, readonly) SZFriendsBoostRole role;
@property(nonatomic, readonly) SZFriendsBoostCost *cost;
@property(nonatomic, readonly) SZFriendsBoostReason endReason; // once ended
@property(nonatomic, readonly) BOOL declinedByPerson;           // Not now on either side: never again for it
- (void)answer:(BOOL)goFaster now:(NSTimeInterval)now;
- (void)message:(SZFriendsBoostMessage *)message now:(NSTimeInterval)now;
- (void)hostedAt:(NSData *)address port:(uint16_t)port now:(NSTimeInterval)now;
- (void)joinedAt:(NSTimeInterval)now;
- (void)failedAt:(NSTimeInterval)now;
- (void)laneUpAt:(NSTimeInterval)now;
- (void)laneDownAt:(NSTimeInterval)now;
- (void)directRate:(double)direct bluetoothRate:(double)bluetooth now:(NSTimeInterval)now;
- (void)tick:(NSTimeInterval)now;
- (void)transferEndedAt:(NSTimeInterval)now;
- (void)quittingAt:(NSTimeInterval)now;
- (void)sessionLostAt:(NSTimeInterval)now;
@end

#pragma mark - Coming back

// What a device writes down before it leaves its network (direct-wifi.json, version 1), never sent anywhere.
@interface SZFriendsBoostSaved : NSObject
+ (instancetype)savedWithNetwork:(nullable NSString *)network
                     networkName:(nullable NSString *)networkName
                          joined:(NSString *)joined
                          leftAt:(NSTimeInterval)leftAt;
+ (nullable instancetype)savedFromJSON:(NSData *)json; // nil for anything else, a later version included
- (NSData *)JSON;
@property(nonatomic, readonly, copy, nullable) NSString *network;     // the platform's reference; nil: on none
@property(nonatomic, readonly, copy, nullable) NSString *networkName; // for "didn't get back on …"
@property(nonatomic, readonly, copy) NSString *joined;
@property(nonatomic, readonly) NSTimeInterval leftAt;
@end

extern const NSUInteger SZFriendsBoostRejoinTries;           // 3
extern const NSTimeInterval SZFriendsBoostRejoinAgainAfter; // 3 s
extern const NSTimeInterval SZFriendsBoostOnlineWithin;     // 20 s
extern const NSTimeInterval SZFriendsBoostCheckEvery;       // 2 s

@protocol SZFriendsBoostRejoinDriver <NSObject>
- (void)rejoinWrite:(SZFriendsBoostSaved *)saved;
- (void)rejoinNetwork:(nullable NSString *)network leaving:(NSString *)joined;
- (void)rejoinCheckOnline;
- (void)rejoinForget;
- (void)rejoinTellNetworkName:(nullable NSString *)networkName;
@end

@interface SZFriendsBoostRejoin : NSObject
- (instancetype)initWithDriver:(id<SZFriendsBoostRejoinDriver>)driver NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)launchedWithRecord:(nullable SZFriendsBoostSaved *)record now:(NSTimeInterval)now;
@property(nonatomic, readonly) BOOL away;
- (void)leaving:(SZFriendsBoostSaved *)saved;
- (void)comeBackAt:(NSTimeInterval)now;
- (void)rejoined:(BOOL)ok now:(NSTimeInterval)now;
- (void)online:(BOOL)online now:(NSTimeInterval)now;
- (void)tick:(NSTimeInterval)now;
@end

#pragma mark - The Mac's Wi-Fi, and the coordinator

// What joining a link takes on this Mac. Every call returns at once and answers once, on any queue.
@protocol SZFriendsWiFiJoining <NSObject>
- (SZFriendsBoostConnectivity *)connectivity;
// The network to come back to (its name), nil when on none.
- (nullable NSString *)currentNetwork;
- (void)joinNetwork:(NSString *)network passphrase:(NSString *)passphrase completion:(void (^)(BOOL joined))completion;
// Leaves `joined` if still on it, and gets back on `network` (nil: only leave).
- (void)rejoinNetwork:(nullable NSString *)network
              leaving:(NSString *)joined
           completion:(void (^)(BOOL ok))completion;
- (void)checkOnline:(void (^)(BOOL online))completion;
@end

// Where one transfer's row stands, for the snapshot.
typedef NS_ENUM(NSInteger, SZFriendsBoostStage) {
    SZFriendsBoostStageNone = 0,
    SZFriendsBoostStageAsking,
    SZFriendsBoostStageConnecting,
    SZFriendsBoostStageDirect,
    SZFriendsBoostStageRejoining,
    SZFriendsBoostStageRejoinFailed,
};
@interface SZFriendsBoostRow : NSObject
@property(nonatomic) SZFriendsBoostStage stage;
@property(nonatomic, copy, nullable) NSString *network;
@property(nonatomic) BOOL leavesWiFi;
@property(nonatomic) BOOL overEthernet;
@property(nonatomic) double bluetoothSeconds;
@property(nonatomic) double directSeconds;
@end

// The nearby service's side of a group's boost.
@protocol SZFriendsDirectWiFiGroup <NSObject>
- (BOOL)boostSendFrame:(SZFriendsFrame *)frame;
- (void)boostDialAddress:(NSData *)address port:(uint16_t)port;
- (void)boostCloseDirectLane;
@end

@interface SZFriendsDirectWiFiCoordinator : NSObject
- (instancetype)initWithWiFi:(id<SZFriendsWiFiJoining>)wifi
                  recordPath:(NSString *)recordPath
                       queue:(dispatch_queue_t)queue NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) SZFriendsBoostAbilities abilities; // a Mac: joins only
@property(nonatomic, copy, nullable) void (^onChanged)(void);     // a row's words changed
// At launch: a record left by a run that crashed brings the Mac back first.
- (void)launched;
// § 1, for a group sending `transfer` (hex) over Bluetooth alone; YES when it proposed.
- (BOOL)considerGroup:(id)key
             transfer:(NSString *)transfer
            remaining:(uint64_t)remaining
        bluetoothRate:(double)bluetoothRate
        bluetoothOnly:(BOOL)bluetoothOnly
     bluetoothOnlyFor:(NSTimeInterval)bluetoothOnlyFor
        seenOnNetwork:(BOOL)seenOnNetwork
      networkFailures:(NSUInteger)networkFailures
           sortsFirst:(BOOL)sortsFirst
                group:(id<SZFriendsDirectWiFiGroup>)group;
- (void)group:(id)key
     receivedFrame:(SZFriendsFrame *)frame
         remaining:(uint64_t)remaining
        sortsFirst:(BOOL)sortsFirst
             group:(id<SZFriendsDirectWiFiGroup>)group;
// boost_transfer and skip_boost: NO when the question is no longer there (stale).
- (BOOL)answerTransfer:(NSString *)transfer goFaster:(BOOL)goFaster;
- (void)group:(id)key directLaneUp:(BOOL)up;
- (void)group:(id)key directRate:(double)direct bluetoothRate:(double)bluetooth;
- (void)group:(id)key transferEnded:(NSString *)transfer;
- (void)groupEnded:(id)key;
- (void)quitting;
- (void)tick;
- (SZFriendsBoostRow *)rowForTransfer:(NSString *)transfer;
- (BOOL)hasBoostForGroup:(id)key;
- (nullable NSString *)transferOfGroup:(id)key;
@end

NS_ASSUME_NONNULL_END
