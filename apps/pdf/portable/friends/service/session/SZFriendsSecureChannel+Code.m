// Comparison codes: the pure derivation (SZFriendsSession.h § Comparison codes) and the channel's commit-then-reveal
// exchange (ADR 0001 § Comparison codes).
//
// Why commit-then-reveal: a code taken from h alone can be ground by a man in the middle running two handshakes
// until both six-digit codes match (about 2^20 X25519 operations). Here the responder commits to its nonce before
// seeing the initiator's, and the initiator reveals its own before seeing the responder's, so neither side, nor
// anyone between them, can steer the code: a forgery succeeds with probability 10^-6 and otherwise shows as codes
// that differ.

#import "service/session/SZFriendsSecureChannelInternal.h"

#import <sodium.h>

#import "service/session/SZFriendsFrameSchema.h"

static const char kCommitLabel[] = "SZFriends code commit v1";
static const char kCodeLabel[] = "SZFriends code v1";
enum { kCodeNonceBytes = 32 };
static NSString *const kNoIdentities = @"NN sessions have no identities to compare";

NSData *SZFriendsCodeCommitment(NSData *handshakeHash, NSData *responderNonce) {
    uint8_t digest[32];
    crypto_generichash_state state;
    crypto_generichash_init(&state, NULL, 0, sizeof digest);
    crypto_generichash_update(&state, (const uint8_t *)kCommitLabel, sizeof kCommitLabel - 1);
    crypto_generichash_update(&state, handshakeHash.bytes, handshakeHash.length);
    crypto_generichash_update(&state, responderNonce.bytes, responderNonce.length);
    crypto_generichash_final(&state, digest, sizeof digest);
    return [NSData dataWithBytes:digest length:sizeof digest];
}

NSString *SZFriendsComparisonCode(NSData *handshakeHash, NSData *initiatorNonce, NSData *responderNonce) {
    uint8_t digest[32];
    crypto_generichash_state state;
    crypto_generichash_init(&state, NULL, 0, sizeof digest);
    crypto_generichash_update(&state, (const uint8_t *)kCodeLabel, sizeof kCodeLabel - 1);
    crypto_generichash_update(&state, handshakeHash.bytes, handshakeHash.length);
    crypto_generichash_update(&state, initiatorNonce.bytes, initiatorNonce.length);
    crypto_generichash_update(&state, responderNonce.bytes, responderNonce.length);
    crypto_generichash_final(&state, digest, sizeof digest);
    uint64_t value = 0;
    for (int i = 0; i < 8; i++) {
        value = (value << 8) | digest[i];
    }
    // 2^64 mod 10^6 skews the lowest codes by about 5 x 10^-14: negligible next to the 10^-6 a forgery needs.
    return [NSString stringWithFormat:@"%06llu", (unsigned long long)(value % 1000000)];
}

@implementation SZFriendsSecureChannel (Code)

- (void)startCodeExchange:(void (^)(NSString *code, NSError *error))completion {
    NSString *refusal = nil;
    if (_codeRequested) {
        refusal = @"the comparison-code exchange runs once per session";
    } else if (_state == SZFriendsChannelStateClosed || _state == SZFriendsChannelStateClosing ||
               _state == SZFriendsChannelStateRefusing) {
        refusal = @"the channel is closed";
    } else if (self.pattern == SZFriendsHandshakeNN &&
               (self.isInitiator || _state >= SZFriendsChannelStateHandshaking)) {
        refusal = kNoIdentities;
    }
    if (refusal) {
        NSError *error = SZFriendsSessionMakeError(SZFriendsSessionErrorProtocol, refusal);
        // Asynchronous like every other completion, so callers never see it run inside their own call.
        dispatch_async(_queue, ^{
            completion(nil, error);
        });
        return;
    }
    _codeRequested = YES;
    _codeCompletion = [completion copy];
    uint8_t nonce[kCodeNonceBytes];
    randombytes_buf(nonce, sizeof nonce);
    _localCodeNonce = [NSData dataWithBytes:nonce length:sizeof nonce];
    [self advanceCodeExchange];
}

- (void)sendCodeFrame:(SZFriendsFrameType)type tag:(SZFriendsFieldTag)tag value:(NSData *)value {
    [self enqueueChannelFrame:[SZFriendsFrame frameWithType:type fields:@{@(tag) : value}]];
    [self pumpWrites];
}

- (void)advanceCodeExchange {
    if (_codeCompletion == nil || _state != SZFriendsChannelStateEstablished) {
        return;
    }
    if (self.pattern == SZFriendsHandshakeNN) {
        // A responder may ask before its preamble says the session is NN.
        [self finishCodeExchangeWithCode:nil error:SZFriendsSessionMakeError(SZFriendsSessionErrorProtocol,
                                                                            kNoIdentities)];
        return;
    }
    if (!self.isInitiator && !_sentCodeCommit) {
        _sentCodeCommit = YES;
        [self sendCodeFrame:SZFriendsFrameTypeCodeCommit
                        tag:SZFriendsFieldCommitment
                      value:SZFriendsCodeCommitment(self.handshakeHash, _localCodeNonce)];
    } else if (self.isInitiator && _receivedCodeCommit && !_sentCodeNonce) {
        _sentCodeNonce = YES;
        [self sendCodeFrame:SZFriendsFrameTypeCodeNonce tag:SZFriendsFieldNonce value:_localCodeNonce];
    }
}

- (void)handleCodeFrame:(SZFriendsFrame *)frame {
    BOOL initiator = self.isInitiator;
    if (self.pattern == SZFriendsHandshakeNN) {
        [self protocolFailure:SZFriendsSessionErrorProtocol reason:@"comparison codes in an NN session"];
        return;
    }
    switch (frame.type) {
    case SZFriendsFrameTypeCodeCommit:
        if (!initiator || _receivedCodeCommit) {
            break;
        }
        _receivedCodeCommit = YES;
        _peerCodeCommitment = [frame dataForTag:SZFriendsFieldCommitment];
        [self advanceCodeExchange];
        return;
    case SZFriendsFrameTypeCodeNonce: {
        if (initiator || !_sentCodeCommit || _receivedCodeNonce) {
            break;
        }
        _receivedCodeNonce = YES;
        NSData *initiatorNonce = [frame dataForTag:SZFriendsFieldNonce];
        NSData *responderNonce = _localCodeNonce;
        [self sendCodeFrame:SZFriendsFrameTypeCodeReveal tag:SZFriendsFieldNonce value:responderNonce];
        [self finishCodeExchangeWithCode:SZFriendsComparisonCode(self.handshakeHash, initiatorNonce, responderNonce)
                                   error:nil];
        return;
    }
    case SZFriendsFrameTypeCodeReveal: {
        if (!initiator || !_sentCodeNonce || _receivedCodeReveal) {
            break;
        }
        _receivedCodeReveal = YES;
        NSData *responderNonce = [frame dataForTag:SZFriendsFieldNonce];
        NSData *expected = SZFriendsCodeCommitment(self.handshakeHash, responderNonce);
        if (_peerCodeCommitment.length != expected.length ||
            sodium_memcmp(expected.bytes, _peerCodeCommitment.bytes, expected.length) != 0) {
            NSError *error = SZFriendsSessionMakeError(SZFriendsSessionErrorCodeMismatch,
                                                       @"responder nonce does not match its commitment");
            [self finishCodeExchangeWithCode:nil error:error];
            [self beginClosingWithReason:SZFriendsCloseReasonCodeMismatch error:error];
            return;
        }
        [self finishCodeExchangeWithCode:SZFriendsComparisonCode(self.handshakeHash, _localCodeNonce, responderNonce)
                                   error:nil];
        return;
    }
    default:
        break;
    }
    [self protocolFailure:SZFriendsSessionErrorProtocol reason:@"comparison-code frame out of order"];
}

- (void)finishCodeExchangeWithCode:(NSString *)code error:(NSError *)error {
    void (^completion)(NSString *, NSError *) = _codeCompletion;
    _codeCompletion = nil;
    _localCodeNonce = nil;
    _peerCodeCommitment = nil;
    if (completion) {
        completion(code, error);
    }
}

@end
