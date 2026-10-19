// Shared helpers for the session suite: checks, hex, waiting with a deadline, and the fakes every test file uses.
//
// Every wait is bounded (at most 10 s, usually far less), so a hang shows as a failure rather than a stuck build.

#import <Foundation/Foundation.h>

#import "service/identity/SZFriendsIdentity.h"
#import "service/session/SZFriendsSession.h"

NS_ASSUME_NONNULL_BEGIN

extern int SZFTestFailures;
void SZFTestFail(const char *file, int line, const char *expression, NSString *detail);
#define SZF_CHECK(condition, ...)                                                                                     \
    do {                                                                                                              \
        if (!(condition)) {                                                                                           \
            SZFTestFail(__FILE__, __LINE__, #condition, [NSString stringWithFormat:@"" __VA_ARGS__]);                 \
        }                                                                                                             \
    } while (0)

NSData *SZFHex(NSString *hex);
NSString *SZFHexString(NSData *data);
NSData *SZFBytes(uint8_t value, NSUInteger count);
NSData *SZFRandomBytes(NSUInteger count);

// Polls `condition` on `queue` until it holds or `timeout` (capped at 10 s) passes.
BOOL SZFWaitUntil(dispatch_queue_t queue, NSTimeInterval timeout, BOOL (^condition)(void));
// Waits until no memory-stream delivery is pending and the queue has run everything queued before.
void SZFDrain(dispatch_queue_t queue);
// Runs `block` on `queue` and waits for it.
void SZFOnQueue(dispatch_queue_t queue, void (^block)(void));

#pragma mark - In-memory byte streams with fault injection

@interface SZFMemoryStream : NSObject <SZFriendsByteStream>
// Two connected ends. Each end delivers on the queue its reader started with.
+ (NSArray<SZFMemoryStream *> *)pair;
@property(nonatomic) NSUInteger preferredWriteSize;
// Applied to every write from this end before delivery: return replacement bytes, or nil to drop the write.
// `offset` counts bytes this end wrote before this write.
@property(nonatomic, copy, nullable) NSData *_Nullable (^filter)(NSData *write, uint64_t offset);
// Deliver only this many bytes from this end, then sever the link both ways with an error (0: never).
@property(nonatomic) uint64_t severAfterBytes;
// Deliver this end's bytes one at a time, to prove reassembly.
@property(nonatomic) BOOL byteByByte;
// Deliver the write with this index (0-based) twice, to replay it inside the session (-1: never).
@property(nonatomic) NSInteger duplicateWriteIndex;
@property(nonatomic) NSTimeInterval delay;
@property(nonatomic, readonly) NSMutableData *transcript; // every byte this end wrote, before the filter
@property(nonatomic, readonly) NSUInteger writeCount;
@property(nonatomic, readonly) BOOL closed;
@property(nonatomic, readonly) BOOL closedByPeer;
@end

#pragma mark - Identities without a key store

@interface SZFriendsIdentity (SZFTest)
+ (instancetype)szf_newIdentity;
// Replaces the certificate this identity presents, to impersonate or to break the binding in tests.
- (void)szf_setCertificate:(NSData *)certificate;
// pk || Sig(sk, "SZFriends static v1" || staticPublicKey) made with this identity's signing key.
- (NSData *)szf_certificateForStaticKey:(NSData *)staticPublicKey;
@end

#pragma mark - Channel pairs

// Runs a channel's refusal deadline at once. Pairs and fixtures use it so tests about other things do not wait out
// SZFriendsRefusalDelay; SZFriendsChannelRefusalTests checks the deadline itself with a test clock.
void (^SZFImmediateScheduler(void))(NSTimeInterval delay, dispatch_block_t block);

// A connected initiator and responder over memory streams on one serial queue, recording what each side saw. The
// responder refuses with SZFImmediateScheduler and its own replay cache.
@interface SZFChannelPair : NSObject
@property(nonatomic, readonly) dispatch_queue_t queue;
@property(nonatomic, readonly) SZFMemoryStream *initiatorStream; // the initiator's end
@property(nonatomic, readonly) SZFMemoryStream *responderStream;
@property(nonatomic, readonly) SZFriendsSecureChannel *initiator;
@property(nonatomic, readonly) SZFriendsSecureChannel *responder;
@property(nonatomic, readonly) NSMutableArray<SZFriendsFrame *> *initiatorFrames;
@property(nonatomic, readonly) NSMutableArray<SZFriendsFrame *> *responderFrames;
@property(nonatomic) BOOL initiatorEstablished, responderEstablished, initiatorClosed, responderClosed;
@property(nonatomic, nullable) NSError *initiatorError, *responderError;
@property(nonatomic) NSUInteger policyCalls;
@property(nonatomic, nullable) NSData *policyIdentityKey, *policyToken;
+ (instancetype)pairWithOptions:(SZFriendsHandshakeOptions *)options
                 initiatorIdentity:(SZFriendsIdentity *)initiatorIdentity
                 responderIdentity:(SZFriendsIdentity *)responderIdentity
                     publicProfile:(nullable NSDictionary<NSNumber *, NSData *> *)publicProfile
                            policy:(nullable SZFriendsRemoteKeyPolicy)policy;
// Configure the streams or channels (fault injection, test clocks) before this.
- (void)start;
- (BOOL)waitUntilBothEstablished;
- (BOOL)waitUntilBothClosed;
@end

// Options for a pattern; IK dials `responder`'s static key and expects its identity key.
SZFriendsHandshakeOptions *SZFOptions(SZFriendsHandshakePattern pattern, SZFriendsIdentity *_Nullable responder);
SZFriendsFrame *SZFMessageFrame(NSString *text);

NS_ASSUME_NONNULL_END
