// Golden vectors exported from the Objective-C helper's own code, for the Rust core (portable/friends/core-rs) to
// reproduce byte for byte. Not part of the helper: build.sh links this program against the service sources and
// writes JSON into portable/friends/fixtures/vectors/. Every input is derived from a label (SZFDerive), so the
// output is the same on every run and every Mac, and a diff of the JSON is a diff of behaviour.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSString *SZFHexString(NSData *data);
// BLAKE2b of the UTF-8 label, `length` bytes (16 to 64): stable, distinct inputs without hand-written hex.
NSData *SZFDerive(NSString *label, NSUInteger length);
// An X25519 private key derived from `label`, clamped as the helper clamps the keys it generates.
NSData *SZFDeriveClampedKey(NSString *label);
NSData *SZFUTF8(NSString *string);
@class SZFriendsIdentity;
// The identity vectors call `name` ("alice", "bob", "carol"): keys derived from "<name> seed" and "<name> static".
SZFriendsIdentity *SZFVectorIdentity(NSString *name);

// Each returns one file's JSON object.
NSDictionary *SZFExportFrames(void);
NSDictionary *SZFExportNoise(void);
NSDictionary *SZFExportCPace(void);
NSDictionary *SZFExportEdgeCases(void);
NSDictionary *SZFExportBluetooth(void);
// `fixturePath`: the store area's committed v1 fixture (service/store/tests/fixtures/store-v1.sql).
NSDictionary *SZFExportStore(NSString *fixturePath);
// Device chains and joining (ADR 0012, 0013).
NSDictionary *SZFExportChain(void);
// Sync between own devices (ADR 0014).
NSDictionary *SZFExportSync(void);

NS_ASSUME_NONNULL_END
