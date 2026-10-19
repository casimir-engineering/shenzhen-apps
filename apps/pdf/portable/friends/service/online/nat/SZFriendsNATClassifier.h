// The two-port NAT classifier (ADR 0011 § NAT class), outside the peer connection.
//
// One UDP socket sends a Binding request to the host's 3478 (coturn) and to its 3479 (the host's own responder,
// HOST-PROTOCOL-ONLINE.md § STUN and TURN addresses), both from the signed host list. The same socket seen with one
// mapped port by both means the NAT maps independently of the destination; two ports mean it maps each destination
// anew, and their difference gives prediction its step and direction. No answer from 3479, or answers that disagree
// on the address, leave the class unknown, and then only the plain checks run. Answers count only from the server
// asked, for a transaction this socket sent, and must parse strictly (SZFriendsNATStun.h).
//
// The class is kept per network (SZFriendsNATClassCache, keyed by SZFriendsNATRoute's networkKey) and measured again
// after a network change. Each side sends its class with its description through the authenticated signalling.

#import "service/online/nat/SZFriendsNAT.h"

NS_ASSUME_NONNULL_BEGIN

// The largest step that counts as a sequential NAT worth predicting (provisional, M0 matrix): the classifier's two
// requests leave together, so a sequential NAT's step between them is the NAT's increment (1 or 2 on the NATs the
// literature reports) plus whatever other flows took in between.
enum { SZFriendsNATPredictableStepMax = 16 };

@interface SZFriendsNATClassification : NSObject
@property(nonatomic, readonly) SZFriendsNATClass natClass;
// What 3478 and 3479 saw; either may be nil.
@property(nonatomic, readonly, nullable) SZFriendsNATEndpoint *mappedPrimary;
@property(nonatomic, readonly, nullable) SZFriendsNATEndpoint *mappedSecondary;
// For a per-destination NAT, secondary's port minus primary's (its sign is the direction); 0 otherwise.
@property(nonatomic, readonly) int32_t step;
// A per-destination NAT whose step is small enough to predict (|step| <= SZFriendsNATPredictableStepMax).
@property(nonatomic, readonly, getter=isPredictable) BOOL predictable;
+ (instancetype)classificationWithPrimary:(nullable SZFriendsNATEndpoint *)primary
                                secondary:(nullable SZFriendsNATEndpoint *)secondary;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface SZFriendsNATClassifier : NSObject
// `primary` and `secondary` are the host's two STUN ports (3478 and 3479), numeric, from the signed host list.
// `loopbackOnly` (tests) refuses any server that is not on loopback; otherwise a server must be a global address.
- (instancetype)initWithPrimary:(SZFriendsNATEndpoint *)primary
                      secondary:(SZFriendsNATEndpoint *)secondary
                   loopbackOnly:(BOOL)loopbackOnly NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Seconds after the first send at which both requests go again, and the whole budget (provisional: 0.25, 0.75,
// 1.5 and 2.5 s, RFC 8489's doubling cut short so a class is known well within the 5 s plain checks).
@property(nonatomic, copy) NSArray<NSNumber *> *retransmits;
@property(nonatomic) NSTimeInterval budget;

// Runs once; the completion runs once on `queue` (where -cancel is called too), with an error only when neither
// server answered (SZFriendsNATErrorTimedOut) or the servers or socket were refused.
- (void)classifyOnQueue:(dispatch_queue_t)queue
             completion:(void (^)(SZFriendsNATClassification *_Nullable classification,
                                  NSError *_Nullable error))completion;
- (void)cancel;
@end

// The class per network, in memory only. Entries expire after `maximumAge` (provisional 30 minutes: a router's
// behaviour can change under load) and all go at -networkDidChange.
@interface SZFriendsNATClassCache : NSObject
// `clock` counts seconds (nil: CLOCK_MONOTONIC); tests inject one.
- (instancetype)initWithMaximumAge:(NSTimeInterval)maximumAge
                             clock:(nullable NSTimeInterval (^)(void))clock NS_DESIGNATED_INITIALIZER;
- (instancetype)init; // 30 minutes, CLOCK_MONOTONIC
- (nullable SZFriendsNATClassification *)classificationForNetwork:(NSString *)networkKey;
- (void)setClassification:(SZFriendsNATClassification *)classification forNetwork:(NSString *)networkKey;
- (void)networkDidChange;
@end

NS_ASSUME_NONNULL_END
