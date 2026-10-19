// A raw Noise endpoint for tests, built on the C state machine and the codec rather than SZFriendsSecureChannel,
// so it can do what an honest channel never does: skip HELLO, send unknown types, malformed fields or a reveal
// that breaks its commitment, and read the channel's traffic in clear (REKEY included).

#import "SZFriendsSessionTestSupport.h"

#import "service/session/szfriends_noise.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFScriptedPeer : NSObject
- (instancetype)initWithStream:(SZFMemoryStream *)stream
                         queue:(dispatch_queue_t)queue
                      identity:(nullable SZFriendsIdentity *)identity;
// `payloads` maps the handshake message index this side writes (0 and 2 for an initiator, 1 for a responder) to
// its payload; missing entries send an empty payload.
- (void)initiatePattern:(szfriends_noise_pattern)pattern
           remoteStatic:(nullable NSData *)remoteStatic
               payloads:(NSDictionary<NSNumber *, NSData *> *)payloads;
- (void)respondWithPayloads:(NSDictionary<NSNumber *, NSData *> *)payloads;

@property(nonatomic, readonly) BOOL handshakeDone;
@property(nonatomic, readonly) BOOL failed;  // a message did not decrypt
@property(nonatomic, readonly) BOOL closed;  // the stream closed
@property(nonatomic, readonly) NSMutableArray<NSData *> *plaintexts; // transport plaintexts received, in order
@property(nonatomic, readonly) NSMutableArray<NSData *> *handshakePayloads;
@property(nonatomic, readonly, nullable) NSData *handshakeHash;
@property(nonatomic) BOOL followRekeys; // default YES: Rekey() the receiving key after a REKEY plaintext
@property(nonatomic, copy, nullable) void (^onPlaintext)(NSData *plaintext);

- (void)sendPlaintext:(NSData *)plaintext;
// One length-prefixed transport message, encrypted but not sent, so tests can choose how the bytes are sliced.
- (nullable NSData *)sealPlaintext:(NSData *)plaintext;
- (void)sendFrame:(SZFriendsFrame *)frame;
- (void)sendRaw:(NSData *)bytes;
@end

// A handshake payload as the channel writes it: this build's minor range, plus whichever parts are given.
NSData *SZFPeerPayload(SZFriendsIdentity *_Nullable certificateOwner, NSInteger routeClass, NSData *_Nullable token);
// The frames an honest channel never lets a caller send, built by hand.
NSData *SZFPlaintext(uint8_t type, NSDictionary<NSNumber *, NSData *> *fields);

NS_ASSUME_NONNULL_END
