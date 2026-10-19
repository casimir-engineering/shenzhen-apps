// SZFriendsSecureChannel's state, shared by its implementation files. Internal to service/session/.
//
// The channel is split by concern so each file stays reviewable on its own: SZFriendsSecureChannel.m (lifecycle,
// stream bytes, length framing, closing), +Handshake (preamble, Noise messages, payloads, the key policy),
// +Transport (send queues, encryption, rekey, session age, frame dispatch) and +Code (comparison codes).

#import "service/session/SZFriendsSession.h"

#import "service/session/szfriends_noise.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SZFriendsChannelState) {
    SZFriendsChannelStateIdle = 0,
    SZFriendsChannelStateAwaitingPreamble, // responder: nothing read yet
    SZFriendsChannelStateHandshaking,
    SZFriendsChannelStateAwaitingHello,    // responder: keys split, but nothing acts until the initiator's HELLO
    SZFriendsChannelStateEstablished,
    SZFriendsChannelStateClosing,          // CLOSE queued behind the control frames
    // Responder: refused before replying; reads nothing and closes at the refusal deadline (SZFriendsRefusalDelay).
    // After Closing so every "before Established" test leaves it alone.
    SZFriendsChannelStateRefusing,
    SZFriendsChannelStateClosed,
};

// "SZFriends session\0" (18 bytes), then the 4-byte preamble: the prologue both sides mix into h.
extern const char SZFriendsPrologueLabel[18];

@interface SZFriendsSecureChannel () {
  @package
    id<SZFriendsByteStream> _stream;
    SZFriendsIdentity *_identity;
    SZFriendsHandshakeOptions *_options; // initiator only
    NSDictionary<NSNumber *, NSData *> *_publicProfile;
    SZFriendsRemoteKeyPolicy _keyPolicy;
    dispatch_queue_t _queue;
    SZFriendsChannelState _state;

    szfriends_handshake_state _handshake;
    szfriends_cipher_state _sendCipher;
    szfriends_cipher_state _receiveCipher;
    BOOL _hasTransportKeys;

    NSMutableData *_inbound;
    NSUInteger _inboundOffset;

    NSMutableArray<NSData *> *_controlQueue; // encoded plaintexts, encrypted only when written
    NSMutableArray<NSData *> *_bulkQueue;    // CHUNK and DONE
    NSUInteger _inFlightBytes;
    BOOL _closeQueued;
    BOOL _closeWritten;
    NSError *_Nullable _closingError;

    NSTimeInterval _startedAt;
    NSTimeInterval _establishedAt;
    NSTimeInterval _lastSendRekeyAt;
    uint64_t _bytesSinceSendRekey;
    BOOL _receivedRequestByID;
    BOOL _receivedReceived;

    // Quiet refusals (SZFriendsSecureChannel.m). The deadline counts from when the deciding bytes arrived, read
    // before any work on them, so how long the work took never shows in when the link closes.
    NSTimeInterval _inputArrivedAt;
    BOOL _responderReplied; // the first handshake reply is written: refusals after it close at once
    NSError *_Nullable _refusalError;
    SZFriendsReplayCache *_Nullable _replayCache;
    BOOL _toldAuthenticated; // the stream heard -sessionDidAuthenticate

    // Refusal work equalisation (+Handshake): what processing IK message 1 at a responder cost, real and dummy.
    NSUInteger _message1DH, _message1DummyDH;
    NSUInteger _message1CertificateChecks, _message1DummyCertificateChecks;

    // Comparison codes (+Code).
    void (^_Nullable _codeCompletion)(NSString *_Nullable code, NSError *_Nullable error);
    BOOL _codeRequested;
    NSData *_Nullable _localCodeNonce;
    NSData *_Nullable _peerCodeCommitment;
    BOOL _sentCodeCommit, _receivedCodeCommit, _sentCodeNonce, _receivedCodeNonce, _receivedCodeReveal;

    // Configuration tests shorten; production uses the SZFriendsSession.h constants.
    uint64_t _rekeyAfterBytes;
    NSTimeInterval _rekeyAfterInterval;
    NSTimeInterval _maxAge;
    NSTimeInterval _handshakeTimeout;
    NSTimeInterval _refusalDelay;
    NSTimeInterval (^_clock)(void);
    void (^_scheduler)(NSTimeInterval delay, dispatch_block_t block); // runs `block` on _queue after `delay`
    NSUInteger _rekeysSent;
    NSUInteger _rekeysReceived;
}
@property(nonatomic, readwrite) BOOL isInitiator;
@property(nonatomic, readwrite) SZFriendsHandshakePattern pattern;
@property(nonatomic, readwrite) SZFriendsRouteMethod initiatorRoute;
@property(nonatomic, readwrite, nullable) NSData *remoteIdentityKey;
@property(nonatomic, readwrite, nullable) NSData *remoteCertificate;
@property(nonatomic, readwrite, nullable) NSData *remoteAttestation;
@property(nonatomic, readwrite, nullable) NSData *remoteStaticKey;
@property(nonatomic, readwrite, nullable) NSData *presentedRequestToken;
@property(nonatomic, readwrite, nullable) NSData *handshakeHash;
@property(nonatomic, readwrite) NSUInteger negotiatedMinor;

// SZFriendsSecureChannel.m
- (NSTimeInterval)now;
// Ends the channel at once: optionally one CLOSE (when keys exist), the stream closed, onClose(error).
- (void)terminateWithError:(nullable NSError *)error closeReason:(NSInteger)closeReason;
// Before a responder's first reply this refuses quietly (closing at the refusal deadline); otherwise it terminates.
- (void)failWithCode:(SZFriendsSessionError)code reason:(NSString *)logReason;
// Protocol violations after keys exist: CLOSE(ProtocolError), then terminate.
- (void)protocolFailure:(SZFriendsSessionError)code reason:(NSString *)logReason;
// Graceful: CLOSE after the queued control frames, then terminate with `error` once it is written.
- (void)beginClosingWithReason:(SZFriendsCloseReason)reason error:(nullable NSError *)error;
- (void)streamClosedWithError:(nullable NSError *)error;

@end

@interface SZFriendsSecureChannel (Handshake)
- (void)startInitiatorHandshake;
- (BOOL)consumePreambleFromBytes:(const uint8_t *)bytes length:(NSUInteger)length;
- (void)handleHandshakeMessage:(const uint8_t *)message length:(NSUInteger)length;
// Responder: tells the stream once that the initiator is known (SZFriendsByteStream -sessionDidAuthenticate).
- (void)reportAuthenticated;
@end

@interface SZFriendsSecureChannel (Transport)
- (BOOL)queueFrame:(SZFriendsFrame *)frame; // -sendFrame:
- (void)becomeEstablished;
- (void)handleTransportMessage:(const uint8_t *)message length:(NSUInteger)length;
- (void)enqueueChannelFrame:(SZFriendsFrame *)frame;
- (void)pumpWrites;
- (BOOL)checkSessionAge;
@end

@interface SZFriendsSecureChannel (Code)
- (void)startCodeExchange:(void (^)(NSString *_Nullable code, NSError *_Nullable error))completion;
- (void)advanceCodeExchange;
- (void)handleCodeFrame:(SZFriendsFrame *)frame;
- (void)finishCodeExchangeWithCode:(nullable NSString *)code error:(nullable NSError *)error;
@end

// What tests shorten or observe. Production never calls these.
@interface SZFriendsSecureChannel (Testing)
- (void)setRekeyAfterBytes:(uint64_t)bytes interval:(NSTimeInterval)interval;
- (void)setMaxAge:(NSTimeInterval)maxAge;
- (void)setHandshakeTimeout:(NSTimeInterval)timeout;
- (void)setRefusalDelay:(NSTimeInterval)delay;
- (void)setClock:(NSTimeInterval (^)(void))clock;
// Replaces dispatch_after for the refusal deadline, so a test with an injected clock decides when it fires.
- (void)setScheduler:(void (^)(NSTimeInterval delay, dispatch_block_t block))scheduler;
@property(nonatomic, readonly) NSUInteger rekeysSent;
@property(nonatomic, readonly) NSUInteger rekeysReceived;
// Responder, after IK message 1: the X25519 operations and certificate checks processing it ran, the dummy ones
// included, and how many of each were dummies.
@property(nonatomic, readonly) NSUInteger message1ScalarMultiplications, message1CertificateChecks;
@property(nonatomic, readonly) NSUInteger message1DummyScalarMultiplications, message1DummyCertificateChecks;
@end

NS_ASSUME_NONNULL_END
