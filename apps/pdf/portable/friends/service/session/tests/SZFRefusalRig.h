// The refusal rig the session's refusal tests share: a responder on a test clock whose refusal deadline is recorded
// instead of scheduled, behind a stream that answers a listener's admission questions, and what an initiator writes
// first. Split from SZFriendsChannelRefusalTests.m so each test file stays under the size cap.

#import "SZFriendsSessionTestSupport.h"

NS_ASSUME_NONNULL_BEGIN

// A stream in front of a memory stream that answers what a listener's adapter would be asked.
@interface SZFAdmissionStream : NSObject <SZFriendsByteStream>
- (instancetype)initWithStream:(SZFMemoryStream *)stream;
@property(nonatomic) BOOL admit;
@property(nonatomic, readonly) NSMutableArray<NSNumber *> *askedPatterns;
@property(nonatomic) NSUInteger authenticated, firstMessages;
@property(nonatomic, copy, nullable) void (^onAsk)(void);
@end

@class SZFRefusalRig;
typedef BOOL (^SZFRigPolicy)(SZFRefusalRig *rig, SZFriendsHandshakePattern pattern);

// A responder on a test clock whose refusal deadline is recorded instead of scheduled, so the test decides when
// time passes and reads exactly when the link closed.
@interface SZFRefusalRig : NSObject
// A responder for `identity`, with a public entry when `profile` is set; the policy is asked as the key policy.
+ (instancetype)rigFor:(SZFriendsIdentity *)identity
               profile:(nullable NSDictionary *)profile
                 cache:(nullable SZFriendsReplayCache *)cache
                policy:(nullable SZFRigPolicy)policy;
- (void)deliver:(NSData *)bytes at:(NSTimeInterval)time; // the peer writes `bytes` at test time `time`
- (void)fireTimers;                                      // time reaches every recorded deadline
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) NSTimeInterval now;
@property(nonatomic) NSMutableArray<NSArray *> *timers; // @[fire time, block]
@property(nonatomic) SZFMemoryStream *peerEnd, *listenerEnd;
@property(nonatomic) SZFAdmissionStream *stream;
@property(nonatomic) SZFriendsSecureChannel *responder;
@property(nonatomic) BOOL closed;
@property(nonatomic, nullable) NSError *error;
@property(nonatomic) NSTimeInterval closedAt;
@property(nonatomic) NSUInteger policyCalls;
@end

typedef struct {
    const char *label;
    NSInteger code;
} SZFRefusalCase;

// What an initiator writes when it starts: the preamble and message 1, in one write.
NSData *SZFMessage1(SZFriendsHandshakeOptions *options, SZFriendsIdentity *initiator);
// Delivers `message` at `arrival` and checks the refusal waits for its deadline, then lets time reach it. Returns how
// long after `arrival` the link closed.
NSTimeInterval SZFExpectQuietRefusal(SZFRefusalRig *rig, NSData *message, NSTimeInterval arrival,
                                     SZFRefusalCase expected);

NS_ASSUME_NONNULL_END
