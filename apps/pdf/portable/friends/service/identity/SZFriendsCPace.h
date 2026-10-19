// CPace, the balanced PAKE of draft-irtf-cfrg-cpace-13, over ristretto255 with SHA-512 (its § 7.3), on libsodium.
//
// Helper-only. Joining a profile (SZFriendsJoin.h, PROTOCOL.md § Joining) runs it with the 8-digit code one of the
// person's computers shows: a plain hash of so short a code would fall to offline guessing, while CPace gives whoever
// does not know the code one guess per run, and the approving computer allows three. The functions below are the
// draft's own, named as it names them, so SZFriendsCPaceTests checks each against Appendix B.3's vectors.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern const NSUInteger SZFriendsCPaceShareLength;  // 32: an encoded ristretto255 element
extern const NSUInteger SZFriendsCPaceScalarLength; // 32: a little-endian scalar
extern const NSUInteger SZFriendsCPaceISKLength;    // 64: SHA-512

// prepend_len (Appendix A.1.1): `data` after its length in LEB128.
NSData *SZFriendsCPacePrependLength(NSData *data);
// lv_cat (Appendix A.1.3): every part with its length prepended, concatenated.
NSData *SZFriendsCPaceLVCat(NSArray<NSData *> *parts);
// generator_string (§ 7.1) with DSI "CPaceRistretto255" and SHA-512's 128-byte input block.
NSData *SZFriendsCPaceGeneratorString(NSData *prs, NSData *ci, NSData *sid);
// calculate_generator (§ 7.3): the element derived from SHA-512 of the generator string, encoded. Nil never happens
// for well-formed input; kept nullable because libsodium's call can fail.
NSData *_Nullable SZFriendsCPaceGenerator(NSData *prs, NSData *ci, NSData *sid);
// sample_scalar: a uniformly random scalar.
NSData *SZFriendsCPaceRandomScalar(void);
// scalar_mult: y * g for an encoded generator; nil for an invalid encoding.
NSData *_Nullable SZFriendsCPaceScalarMult(NSData *scalar, NSData *element);
// scalar_mult_vfy: y * Y, or nil where the draft returns the neutral element (Y invalid, or the identity), and the
// protocol aborts.
NSData *_Nullable SZFriendsCPaceScalarMultVfy(NSData *scalar, NSData *element);
// ISK (§ 6.2) with the initiator-responder transcript: SHA-512(lv_cat("CPaceRistretto255_ISK", sid, K) ||
// lv_cat(Ya, ADa) || lv_cat(Yb, ADb)).
NSData *SZFriendsCPaceISK(NSData *sid, NSData *secret, NSData *shareA, NSData *adA, NSData *shareB, NSData *adB);

// One side of one run. The initiator (A) sends its share first; the responder (B) answers with its own. Each side
// derives ISK from the other's share; a wrong code, an invalid share or a different sid gives the two sides different
// keys, which the caller's confirmation tags reveal.
@interface SZFriendsCPace : NSObject
// `password` is PRS, `channelIdentifier` CI and `sessionID` sid. `scalar` is for the vector tests; nil draws one.
- (nullable instancetype)initWithPassword:(NSData *)password
                        channelIdentifier:(NSData *)channelIdentifier
                                sessionID:(NSData *)sessionID
                                   scalar:(nullable NSData *)scalar NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) NSData *share; // Y, to send
// ISK, as initiator A (this side's share is Ya) or responder B; nil when the peer's share is invalid.
- (nullable NSData *)iskAsInitiatorWithAD:(NSData *)ownAD peerShare:(NSData *)peerShare peerAD:(NSData *)peerAD;
- (nullable NSData *)iskAsResponderWithAD:(NSData *)ownAD peerShare:(NSData *)peerShare peerAD:(NSData *)peerAD;
@end

NS_ASSUME_NONNULL_END
