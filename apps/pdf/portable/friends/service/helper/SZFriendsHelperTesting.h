// Seams the two-helper harness sets before the helper starts. Internal to the helper.
//
// The production executable (main.m) never touches these, so every value keeps its default there: no extra
// adapters, every ACK sent, no pacing, the real clock. The harness links the same helper objects with its own main
// (portable/friends/tests/e2e/), which sets them from its environment before calling SZFriendsHelperMain. WHY not
// environment variables read by the helper itself: a shipped helper must not change how it delivers because of
// its environment.

#import <Foundation/Foundation.h>

#import "service/discovery/SZFriendsDiscovery.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFriendsHelperTestHooks : NSObject
// Adapters added beside the ones SZFriendsHelperMakeAdapters picks (the harness's scripted slow Bluetooth).
@property(class, nonatomic, copy, nullable) NSArray<id<SZFriendsDiscoveryAdapter>> * (^extraAdapters)
    (dispatch_queue_t queue);
// Commit received messages and files but never acknowledge them: the sender keeps them in flight and resends
// after a reconnect, which is how the harness proves duplicates are suppressed.
@property(class, nonatomic) BOOL withholdAcknowledgements;
// Caps outgoing chunk bytes per second (0: no cap), so a transfer on loopback lasts long enough to be killed
// part-way through.
@property(class, nonatomic) double chunkBytesPerSecond;
// Added to the wall clock the outbox expiry reads, so "30 days later" needs no waiting.
@property(class, nonatomic) NSTimeInterval outboxClockOffset;
// Replaces SZFriendsStrangerIdleTimeout (60 s) when above 0, so the harness sees an idle stranger's session end
// within a scenario's budget.
@property(class, nonatomic) NSTimeInterval strangerIdleTimeout;
// Replaces SZFriendsStrangerSessionLife (3 minutes) when above 0, for the same reason.
@property(class, nonatomic) NSTimeInterval strangerSessionLife;
// The Friends ID a first start takes instead of a random draw, so two helpers can hold one unreserved ID (Add by ID
// with two holders, and a collision at the host).
@property(class, nonatomic, copy, nullable) NSString *initialFriendsID;
// The computer name and system this helper gives itself in place of the Mac's own (Sharing's computer name and the
// macOS version), so a test run never shows the real computer's.
@property(class, nonatomic, copy, nullable) NSString *deviceName;
@property(class, nonatomic, copy, nullable) NSString *deviceSystem;

// Replaces SZFriendsNearbyAdmissionLimits() when set. Every helper of a harness dials from 127.0.0.1, so per-address
// rates meant to tell computers apart count a whole scenario's computers as one.
@property(class, nonatomic, copy, nullable) SZFriendsAdmissionLimits *admissionLimits;
@end

// This computer's name and system as the helper reports them: SZFriendsLocalDeviceName() and
// SZFriendsLocalDeviceSystem(), unless SZFriendsHelperTestHooks replaces them.
NSString *SZFriendsHelperDeviceName(void);
NSString *SZFriendsHelperDeviceSystem(void);

// The adapters this helper runs. Production (no SZFRIENDS_STATE_DIR): Network.framework and CoreBluetooth. Under
// SZFRIENDS_STATE_DIR (tests, probes, the harness) never a real radio and never a non-loopback interface:
//   - the loopback network adapter for the Bonjour type in SZFRIENDS_TEST_SERVICE_TYPE when it is a valid test type
//     ("_" + 1 to 15 letters, digits or hyphens + "._tcp", never the production type); with
//     SZFRIENDS_TEST_NETWORK_HOLD (an absolute path) it does not start while that file exists, and starts within
//     100 ms of the file going (SZFriendsHelperHoldNetworkAdapter);
//   - the Bluetooth adapter over the test air in SZFRIENDS_TEST_BLUETOOTH (an absolute directory, shared with Rust
//     helpers; SZFRIENDS_TEST_BLUETOOTH_POWER as SZFriendsMakeTestAirRadio reads it);
// nothing otherwise; then whatever SZFriendsHelperTestHooks.extraAdapters adds. Creating adapters creates no
// browser, listener or manager.
NSArray<id<SZFriendsDiscoveryAdapter>> *SZFriendsHelperMakeAdapters(dispatch_queue_t queue,
                                                                    NSDictionary<NSString *, NSString *> *env);
// `adapter` held back while `file` exists, reporting its radio off; started once the file is gone, stopped again
// when it comes back.
id<SZFriendsDiscoveryAdapter> SZFriendsHelperHoldNetworkAdapter(dispatch_queue_t queue,
                                                                id<SZFriendsDiscoveryAdapter> adapter, NSString *file);
// Under SZFRIENDS_STATE_DIR only: while <state dir>/online-block-direct exists, online attempts send and apply no
// direct candidate, so only the relay connects (as the Rust helper's test homes do). Leaves a hook already set (the
// links e2e helper's main sets the same one) in place. Nothing in production.
void SZFriendsHelperSetOnlineTestHooks(NSDictionary<NSString *, NSString *> *env);
// The rule for SZFRIENDS_TEST_SERVICE_TYPE, exposed for the unit tests.
BOOL SZFriendsHelperTestServiceTypeIsValid(NSString *_Nullable serviceType);

NS_ASSUME_NONNULL_END
