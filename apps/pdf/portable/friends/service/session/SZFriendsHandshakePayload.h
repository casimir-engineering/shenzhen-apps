// Handshake payloads (ADR 0001 § Wire format). Internal to service/session/.
//
// Payloads carry only the certificate, the minor-version range, capability bits, the initiator's route class,
// the IK callback's request token, and on a public entry's XX message 2 the public profile. They use the frame
// fields' tag-length-value encoding and tag namespace, without a type byte. Which message carries what:
//   NN  1 (initiator, plaintext): minor range, capabilities      2 (responder): minor range, capabilities
//   XX  1 (initiator, plaintext): nothing                         2 (responder): certificate, range, capabilities,
//       profile                                                   3 (initiator): certificate, range, capabilities,
//       route class
//   IK  1 (initiator): certificate, range, capabilities, route class, token when calling back after Add by ID
//       2 (responder): certificate, range, capabilities (the initiator checks it names the identity it dialed)
// Every payload that carries a certificate may also carry the sender's host-issued Friends ID attestation.

#import "service/session/SZFriendsSession.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFriendsHandshakePayload : NSObject
@property(nonatomic, copy, nullable) NSData *certificate;
@property(nonatomic, copy, nullable) NSData *requestToken;
@property(nonatomic, copy, nullable) NSData *attestation; // SZFriendsFieldAttestation, opaque here
@property(nonatomic) BOOL hasMinorRange;
@property(nonatomic) uint16_t minorMin;
@property(nonatomic) uint16_t minorMax;
@property(nonatomic) uint32_t capabilities;
@property(nonatomic) BOOL hasRouteClass;
@property(nonatomic) uint8_t routeClass;
// Profile fields only (Name, FriendsID, PictureSet, PictureIndex, Data); nil when the payload has none.
@property(nonatomic, copy, nullable) NSDictionary<NSNumber *, NSData *> *profile;

// This build's range (0...SZFriendsSessionMinor) and capabilities (none in M1).
+ (instancetype)localPayload;
- (nullable NSData *)encodedDataWithError:(NSError **)error;
// Unknown tags are ignored; duplicates and out-of-limit values fail.
+ (nullable instancetype)payloadWithData:(NSData *)data error:(NSError **)error;
@end

// The tags a public profile may carry, in XX message 2 and in PROFILE.
BOOL SZFriendsIsProfileTag(uint8_t tag);
// The minor version both sides speak (the lower maximum), or NO when the ranges do not overlap or one is inverted.
BOOL SZFriendsNegotiateMinor(uint16_t localMin, uint16_t localMax, uint16_t remoteMin, uint16_t remoteMax,
                             uint16_t *negotiated);

NS_ASSUME_NONNULL_END
