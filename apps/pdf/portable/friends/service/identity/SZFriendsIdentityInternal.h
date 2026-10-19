// Internals shared by the identity area's sources and tests. Not a public header: other areas use
// SZFriendsIdentity.h only.

#import "service/identity/SZFriendsIdentity.h"

NS_ASSUME_NONNULL_BEGIN

// An error in SZFriendsIdentityErrorDomain. `underlying` (an OSStatus or errno error) goes in NSUnderlyingErrorKey,
// so logs keep the system's reason. Descriptions name what failed, never key material.
NSError *SZFriendsIdentityMakeError(SZFriendsIdentityError code, NSString *description, NSError *_Nullable underlying);

// sodium_init() once per process; raises NSInternalInconsistencyException if libsodium cannot start (no secure
// randomness), because every later key operation would be unsafe.
void SZFriendsIdentityRequireSodium(void);

// Key-store item names: 1-64 of [A-Za-z0-9._-], not starting with '.', so a name can never be a path.
BOOL SZFriendsKeyStoreNameIsValid(NSString *name);

// The one key-store item holding both identity keys.
extern NSString *const SZFriendsIdentitySecretName;

// Secret item layout, version 1 (133 bytes):
//   "SZFI" | 0x01 | Ed25519 seed (32) | X25519 private key, clamped (32) | Ed25519 public key (32) |
//   X25519 public key (32)
// The public keys are stored as well as derivable, and the private key in its one clamped form, so any damaged byte
// fails as Corrupt instead of loading as a different identity, which friends would see as a key change.
enum { SZFriendsIdentitySecretLength = 133 };

@interface SZFriendsIdentity ()
// Corrupt for a wrong length, magic, version, or public keys that do not match the private ones.
+ (nullable instancetype)identityFromSecret:(NSData *)secret error:(NSError **)error;
+ (instancetype)generatedIdentity;
// The secret item for this identity; a fresh mutable buffer the caller zeroes after storing.
- (NSMutableData *)secretItem;
@end

NS_ASSUME_NONNULL_END
