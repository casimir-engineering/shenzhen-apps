// Host area internals shared by its sources and tests: encodings, the signed byte strings, and the check-in
// client's private state. Not a public header; other areas use SZFriendsHostConnection.h only.

#import "service/host/SZFriendsHostConnection.h"

NS_ASSUME_NONNULL_BEGIN

// Signature domains, byte for byte the ones in portable/server/friends/src/protocol.js. The identity signs
// UTF-8(domain) || message (SZFriendsIdentity -signatureForMessage:domain:).
extern NSString *const SZFriendsHostCheckinDomain; // "SZFriends checkin v1"
extern NSString *const SZFriendsHostReleaseDomain; // "SZFriends release v1"
extern NSString *const SZFriendsHostListDomain;    // "SZFriends host list v1\n"
extern NSString *const SZFriendsHostReplyDomain;   // "SZFriends host reply v1"
extern NSString *const SZFriendsHostAttestationDomain; // "SZFriends id attestation v1"

// ADR 0005: JSON text frames of at most 64 KiB, the largest a host sends (a signed list). A host accepts at most
// 8 KiB from a helper, far more than a check-in needs.
extern const NSUInteger SZFriendsHostMaxMessageBytes;
// ADR 0005 step 4: at most 20 fresh IDs per connection.
extern const NSUInteger SZFriendsHostMaxReservesPerConnection;
// At most 40 fresh IDs per launch, across every connection: a host that answers "taken" to everything and hangs up
// cannot make the helper draw without end.
extern const NSUInteger SZFriendsHostMaxDrawsPerLaunch;

// Strict base64url: the URL alphabet, no padding, canonical trailing bits, and `length` bytes when non-zero, so
// two different strings never name one key. Nil otherwise.
NSData *_Nullable SZFriendsHostBase64URLDecode(id _Nullable value, NSUInteger length);
NSString *SZFriendsHostBase64URLEncode(NSData *data);

// Fixed-order fields, each a u32 big-endian length then its bytes (NSString as UTF-8, or NSData).
NSData *SZFriendsHostLengthPrefixed(NSArray *fields);

// The messages check-in and release sign, after their domains (HOST-PROTOCOL.md § Signatures).
// From protocol 3 the check-in also signs the root key (32 bytes, empty without one) and the SHA-256 of the chain
// (32 bytes, empty without one); before it, `rootKey` and `chain` are ignored.
NSData *SZFriendsHostCheckinMessage(NSString *hostID, NSData *challenge, NSData *identityKey, NSString *friendsID,
                                    BOOL reserved, NSString *appVersion, NSInteger protocol, NSInteger listVersion,
                                    NSData *_Nullable rootKey, NSData *_Nullable chain);
// The protocol from which a device checks in for a person (HOST-PROTOCOL.md § Devices).
extern const NSInteger SZFriendsHostDevicesProtocol; // 3
// The protocol to check in with on a host that sent `challenge`: 3 where it says 3 or more, 2 on a host from before
// protocol 3, whose challenge says none (HOST-PROTOCOL.md § Versioning).
NSInteger SZFriendsHostProtocolForChallenge(NSDictionary<NSString *, id> *challenge);
// The close code after which a device stops: it was removed from its person's devices.
extern const NSInteger SZFriendsHostCloseDeviceRevoked; // 4002
NSData *SZFriendsHostReleaseMessage(NSString *hostID, NSData *challenge, NSData *identityKey, NSString *friendsID);

// What an ID attestation signs after its domain (HOST-PROTOCOL.md § Signatures).
NSData *SZFriendsHostAttestationMessage(NSString *hostID, NSString *friendsID, NSData *identityKey, NSString *day);

// The fields a host reply's signature covers (HOST-PROTOCOL.md § Signatures), built from the reply as received;
// `requested` is the ID the helper's message asked for, so one answer never verifies as another's.
NSArray *SZFriendsHostWelcomeBody(NSString *_Nullable requested, NSDictionary *message);
NSArray *SZFriendsHostReserveResultBody(NSString *_Nullable requested, NSDictionary *message);
NSArray *SZFriendsHostReleasedBody(NSDictionary *message);
// What a host reply signs after its domain: the challenge, then SHA-256 of the length-prefixed body.
NSData *SZFriendsHostReplyMessage(NSData *challenge, NSArray *body);
// Whether message.host_sig is `hostKey`'s signature over the challenge and `body`. NO for anything malformed.
BOOL SZFriendsHostReplyVerifies(NSDictionary *message, NSArray *body, NSData *_Nullable challenge,
                                NSData *_Nullable hostKey);
// `value` when the codec accepts it as a Friends ID in exactly this canonical form (two or three list words,
// lowercase, hyphenated); nil otherwise, and always nil without a codec.
NSString *_Nullable SZFriendsHostCanonicalID(id _Nullable value, SZFriendsIDCodec *_Nullable codec);

// One JSON text message with "type" and "v"; nil when it would exceed the size limit.
NSData *_Nullable SZFriendsHostEncodeMessage(NSString *type, NSDictionary<NSString *, id> *fields);
// A dictionary with a string "type", or nil.
NSDictionary<NSString *, id> *_Nullable SZFriendsHostDecodeMessage(NSData *data);

// wss:// to any host; ws:// only to 127.0.0.1, [::1] or localhost. No user, password or fragment.
BOOL SZFriendsHostURLAllowed(NSURL *url);

NSError *SZFriendsHostMakeError(SZFriendsHostError code, NSString *description);

// A JSON value that is an integer (JSON booleans are NSNumbers too, and are refused).
BOOL SZFriendsHostJSONInteger(id _Nullable value, long long minimum, long long maximum, long long *_Nullable out);

// For the area's tests: the reconnect attempt the next backoff uses, and the IDs drawn since the client started.
@interface SZFriendsCheckInClient (Testing)
- (NSUInteger)reconnectAttempt;
- (NSUInteger)drawsThisLaunch;
@end

@interface SZFriendsHostList (Internal)
// Version 0, no hosts: what the cache holds when nothing verifies.
+ (instancetype)emptyList;
// The signed payload bytes; equal versions are compared on these.
- (NSData *)payloadData;
@end

NS_ASSUME_NONNULL_END
