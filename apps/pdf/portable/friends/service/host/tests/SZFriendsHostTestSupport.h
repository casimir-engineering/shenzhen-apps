// Test support for the host area: stand-ins for the identity area's objects, a scripted socket, list signing with
// throwaway keys, the shared vectors, and bounded waits. Nothing here touches the Keychain or any network beyond
// loopback.
//
// WHY stand-ins rather than the identity area's classes: that area is built in parallel and its header grows. The
// host client only sends -publicKey and -signatureForMessage:domain: to its identity and
// -randomIDWithWordCount:generator: to its codec, so these tests pass objects that answer exactly those messages,
// cast to the declared types. The client also checks every Friends ID a host returns against the bundled word
// list, so SZFriendsHostIdentityFakes.m implements SZFriendsWordList and SZFriendsIDCodec for that alone.

#import <Foundation/Foundation.h>

#import "service/host/SZFriendsHostInternal.h"
#import "service/identity/SZFriendsIdentity.h"

NS_ASSUME_NONNULL_BEGIN

extern int SZFHFailures;
void SZFHFail(const char *file, int line, NSString *format, ...) NS_FORMAT_FUNCTION(3, 4);
#define SZFHExpect(condition, ...)                                                                                    \
    do {                                                                                                              \
        if (!(condition)) SZFHFail(__FILE__, __LINE__, __VA_ARGS__);                                                  \
    } while (0)

// Polls `condition` every 10 ms for at most `timeout` seconds (never more than 10). The client under test runs on
// its own queue, so the calling thread may block.
BOOL SZFHWaitUntil(NSTimeInterval timeout, BOOL (^condition)(void));
// Lets everything already queued on `queue` run.
void SZFHDrain(dispatch_queue_t queue);

NSData *SZFHHex(NSString *hex);
NSString *SZFHHexString(NSData *data);
// A new directory under TMPDIR named SZFHTempDirPrefix() plus six random characters; SZFHRemoveTempDirs removes
// every one this run made.
NSString *SZFHTempDir(void);
NSString *SZFHTempDirPrefix(void);
void SZFHRemoveTempDirs(void);
NSDictionary *SZFHVectors(void);
NSString *SZFHEnv(NSString *name);

@interface SZFHTestIdentity : NSObject
+ (instancetype)identityWithSeed:(NSData *)seed;
+ (instancetype)randomIdentity;
// An identity whose signatures never verify, as a key the host does not know would produce.
+ (instancetype)brokenIdentity;
@property(nonatomic, readonly) NSData *publicKey;
- (NSData *)signatureForMessage:(NSData *)message domain:(NSString *)domain;
// The stand-in as the type the client's initializer declares.
- (SZFriendsIdentity *)asIdentity;
@end

// The stand-in word list: every ID in these tests is two or three of these words.
NSArray<NSString *> *SZFHTestWords(void);
// A distinct, valid ID for each draw number.
NSString *SZFHDrawID(NSUInteger draw);
// When NO, the stand-in +[SZFriendsWordList bundledList] returns nil, as a broken bundle would.
extern BOOL SZFHBundledWordListAvailable;

// Draws IDs from eight fixed words through the generator it is given.
@interface SZFHTestCodec : NSObject
- (NSString *)randomIDWithWordCount:(NSUInteger)wordCount generator:(uint32_t (^)(uint32_t bound))randomUniform;
- (SZFriendsIDCodec *)asCodec;
@end

// What the faked SZFriendsWordCountForNewID was last asked.
extern NSInteger SZFHLastListWords;
extern NSUInteger SZFHLastCollisions;

BOOL SZFHVerify(NSData *signature, NSData *message, NSString *domain, NSData *publicKey);

// An Ed25519 list-signing key, thrown away with the test.
@interface SZFHSigner : NSObject
+ (instancetype)randomSigner;
+ (instancetype)signerWithSeed:(NSData *)seed;
@property(nonatomic, readonly) NSData *publicKey;
@property(nonatomic, readonly) NSData *seed;
- (NSData *)envelopeForPayload:(NSDictionary *)payload;
- (NSData *)signatureOver:(NSData *)bytes;
@end

// A host-list payload: `hosts` are {id, url(s), priority, role?, key?}; `key` is the host's public key (NSData),
// random when absent.
NSDictionary *SZFHPayload(NSInteger version, NSArray<NSDictionary *> *hosts);

// `reply` with host_sig added: `host`'s signature over the challenge `nonce` (base64url) and the reply's body, for
// the request that named `requested` (HOST-PROTOCOL.md § Signatures).
NSDictionary *SZFHSigned(NSDictionary *reply, SZFHSigner *host, NSString *nonce, NSString *_Nullable requested);
// An Ed25519 private key in PKCS#8 PEM, which the Node host reads from FRIENDS_HOST_KEY_FILE.
NSString *SZFHPrivateKeyPEM(SZFHSigner *signer);

@interface SZFHFakeSocket : NSObject <SZFriendsHostSocket>
- (instancetype)initWithURL:(NSURL *)url;
@property(nonatomic, readonly) NSURL *url;
@property(nonatomic, readonly) BOOL opened;
@property(nonatomic, readonly) BOOL closed;
// Every message the client sent, decoded; thread-safe.
- (NSArray<NSDictionary *> *)sent;
- (void)deliver:(NSDictionary *)message;
- (void)hangUp;
// The host closes with a WebSocket close code (4002: this device was removed from its profile).
- (void)closeWithCode:(NSInteger)code;
@end

// Records delegate callbacks as strings ("state 2", "reserved maple-river", "renamed a b", "update",
// "attestation maple-river main-hk"); thread-safe.
@interface SZFHRecorder : NSObject <SZFriendsCheckInDelegate>
// How long the reserve and rename callbacks hold the client's queue after recording, so a test cannot depend on
// what the client does after them (it keeps the attestation next) arriving in time; 0 by default.
@property(atomic) NSTimeInterval reserveDelay;
- (NSArray<NSString *> *)events;
- (BOOL)saw:(NSString *)event;
@end

// Sends an HTTP request over the host's dashboard Unix socket; returns the status code, or 0.
NSInteger SZFHDashboardRequest(NSString *socketPath, NSString *method, NSString *path, NSString *user,
                               NSString *password, NSData *_Nullable body);

void SZFHRunCodecTests(void);
void SZFHRunListTests(void);
void SZFHRunCacheTests(void);
void SZFHRunClientTests(void);
void SZFHRunReplyTests(void);
void SZFHRunServerTests(void);
void SZFHRunDevicesTests(void);
void SZFHRunAttestationTests(void);

// A wire attestation signed by `host` (HOST-PROTOCOL.md § ID attestations), and today's UTC day as hosts date them.
NSDictionary *SZFHAttestation(SZFHSigner *host, NSString *hostID, NSString *friendsID, NSData *identityKey,
                              NSString *day);
NSString *SZFHUTCDay(NSDate *date);

NS_ASSUME_NONNULL_END
