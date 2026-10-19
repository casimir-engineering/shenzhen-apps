// Shared helpers for the discovery suites: checks, scripted adapters, fake streams, waiting with a deadline.

#import <Foundation/Foundation.h>

#import "service/discovery/SZFriendsDiscovery.h"
#import "service/discovery/SZFriendsDiscoveryInternal.h"

NS_ASSUME_NONNULL_BEGIN

extern int SZFTestFailures;

// Records a failure and carries on, so one run reports every broken expectation.
#define CHECK(condition, ...)                                                                                        \
    do {                                                                                                             \
        if (!(condition)) {                                                                                          \
            SZFTestFailures++;                                                                                       \
            fprintf(stderr, "%s:%d: CHECK failed: %s %s\n", __FILE__, __LINE__, #condition,                          \
                    [[NSString stringWithFormat:@"" __VA_ARGS__] UTF8String]);                                       \
        }                                                                                                            \
    } while (0)

NSData *SZFTestData(NSString *hex);
NSData *SZFTestSecret(uint8_t fill);
NSDate *SZFTestDate(NSTimeInterval secondsSince1970);
// Polls `condition` on `queue` every 10 ms until it holds or `timeout` passes; never call it on `queue`.
BOOL SZFTestWait(dispatch_queue_t queue, NSTimeInterval timeout, BOOL (^condition)(void));

SZFriendsSighting *SZFTestSighting(SZFriendsDiscoveryMethod method, SZFriendsRouteMethod route, NSString *endpointID,
                                   NSData *_Nullable tag, NSArray<NSData *> *callbackTags, BOOL isPublic,
                                   NSDate *seenAt);

// A stream that records what was written and whether it was closed.
@interface SZFTestStream : NSObject <SZFriendsByteStream>
@property(nonatomic, copy) NSString *name;
@property(nonatomic) BOOL closed;
@property(nonatomic, readonly) NSMutableData *written;
@end

// An adapter driven by the test: it reports exactly what the test tells it to.
@interface SZFTestAdapter : NSObject <SZFriendsDiscoveryAdapter>
- (instancetype)initWithMethod:(SZFriendsDiscoveryMethod)method;
@property(nonatomic) SZFriendsPermission permission;
@property(nonatomic) SZFriendsAdapterState stateOnStart; // reported from -start; default Working
@property(nonatomic, readonly) NSUInteger startCount, stopCount, refreshCount;
@property(nonatomic, readonly, nullable) NSData *advertisedTag;
@property(nonatomic, readonly) NSArray<NSData *> *advertisedCallbackTags;
@property(nonatomic, readonly) BOOL advertisedPublic;
@property(nonatomic, readonly) BOOL advertisedBeforeStart; // an advertisement arrived before the first -start
@property(nonatomic, readonly, nullable) SZFriendsAdmissionLimits *admissionLimits; // the last -setAdmissionLimits:
@property(nonatomic, readonly) NSMutableArray<NSString *> *openRequests;
// Per endpoint: what -openStreamToEndpoint: completes with, and after how long; unknown endpoints fail at once.
@property(nonatomic) NSMutableDictionary<NSString *, id<SZFriendsByteStream>> *openStreams;
@property(nonatomic) NSTimeInterval openDelay;
@property(nonatomic, nullable) dispatch_queue_t queue;
- (void)reportState:(SZFriendsAdapterState)state;
- (void)sight:(SZFriendsSighting *)sighting;
- (void)lose:(NSString *)endpointID;
- (void)acceptStream:(id<SZFriendsByteStream>)stream publicEntry:(BOOL)publicEntry;
@end

void SZFriendsRunPresenceTests(void);
void SZFriendsRunRacerTests(void);
void SZFriendsRunVisibilityTests(void);
void SZFriendsRunMergerTests(void);
void SZFriendsRunCoordinatorTests(void);
void SZFriendsRunBluetoothAdapterTests(void);
void SZFriendsRunStreamAndTXTTests(void);
void SZFriendsRunAdmissionTests(void);

NS_ASSUME_NONNULL_END
