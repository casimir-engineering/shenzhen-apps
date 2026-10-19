// Shenzhen Friends device chain: one person, several computers (ADR 0012, friends-multi-device.md § Identity).
//
// Helper-only. A person is their root key: the Ed25519 identity key of their first device, which friends pin and
// comparison codes stay bound to. Every device has its own SZFriendsIdentity (an Ed25519 device key and an X25519
// Noise static key); on the first device the device key is the root key itself, so an existing profile keeps its keys
// and every friendship it has. The chain says which device keys speak for the root: an append-only set of signed
// links, each naming the links its signer had seen (its parents), so concurrent branches form a graph that merges by
// union and every device holding the same links computes the same devices.
//
//   genesis  the root key names the first device (itself) with its static key, name and system;
//   add      an authorized device adds a new one: its keys, name and system, and the new device's consent, its own
//            signature binding its static key to this root, so nobody can claim another person's device;
//   revoke   an authorized device removes a device (itself included);
//   rename   a device changes its own name or system.
//
// Rules (ADR 0012 § Rules gives the reasons and the known limits):
//   1. A link counts only when its signer was authorized by links it had seen: added there, and not revoked there.
//   2. A revoked device is never added again; a chain holding such an add is refused.
//   3. What a device signs without having been seen by a revocation of it is void, and so is everything that rested
//      on it: devices it added that way, and what they signed.
//   4. Revocation wins. Every revocation whose signer was authorized counts, so concurrent branches cannot keep a
//      device another branch revoked, and two devices revoking each other are both revoked. A revocation is void
//      only when a concurrent one removed its signer, and that one was not signed by the device it removes or by a
//      device added through it behind its back.
//
// A chain is a value. Decoding verifies every signature and consent, the structure, that every signer was added
// before what it signs, and rule 2, and refuses the whole chain on any failure; rules 1, 3 and 4 then decide which
// links count. Merging takes the union and checks it again. Nothing here touches a store or key store; the store
// keeps chains (SZFriendsStoreDevices.h) and the helper sends them in CHAIN frames.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class SZFriendsIdentity;

extern NSErrorDomain const SZFriendsDeviceChainErrorDomain;

typedef NS_ERROR_ENUM(SZFriendsDeviceChainErrorDomain, SZFriendsDeviceChainError) {
    SZFriendsDeviceChainErrorMalformed = 1,     // not a chain: lengths, version, a missing or later parent, a duplicate
    SZFriendsDeviceChainErrorForged = 2,        // a signature or a device's consent does not verify
    SZFriendsDeviceChainErrorUnauthorized = 3,  // signed by a key the chain had not added before that link
    SZFriendsDeviceChainErrorRevokedDevice = 4, // adds a device that was revoked before: never re-added
    SZFriendsDeviceChainErrorWrongRoot = 5,     // another root, or another genesis for the same root (a fork)
    SZFriendsDeviceChainErrorFull = 6,          // more than SZFriendsDeviceChainMaxLinks links
    SZFriendsDeviceChainErrorRefused = 7,       // a builder asked for what the rules forbid (renaming another device)
};

typedef NS_ENUM(uint8_t, SZFriendsChainLinkKind) {
    SZFriendsChainLinkGenesis = 0,
    SZFriendsChainLinkAdd = 1,
    SZFriendsChainLinkRevoke = 2,
    SZFriendsChainLinkRename = 3,
};

// The chain fits one CHAIN frame (SZFriendsFrameChainMax, 64,000 bytes): 128 links of at most 495 encoded bytes.
extern const NSUInteger SZFriendsDeviceChainMaxLinks;     // 128
// Renames stop here so adds and revocations always have room; a system update past it keeps the old label.
extern const NSUInteger SZFriendsDeviceChainRenameLimit;  // 112
extern const NSUInteger SZFriendsDeviceChainEncodedMax;   // 64,000 bytes
extern const NSUInteger SZFriendsDeviceChainParentsMax;   // 4 parents per link
extern const NSUInteger SZFriendsDeviceNameMax;           // 64 bytes of UTF-8, longer names are cut on a character
extern const NSUInteger SZFriendsDeviceSystemMax;         // 64 bytes of UTF-8

// One signed link. Immutable; built only by SZFriendsDeviceChain.
@interface SZFriendsChainLink : NSObject
@property(nonatomic, readonly) SZFriendsChainLinkKind kind;
@property(nonatomic, readonly) NSArray<NSData *> *parentHashes; // none for genesis, 1 to 4 otherwise
@property(nonatomic, readonly) NSData *signerKey;               // Ed25519 device key that signed
@property(nonatomic, readonly) NSData *subjectKey;              // the device the link is about
@property(nonatomic, readonly, nullable) NSData *subjectStaticKey; // genesis and add: its X25519 static key
@property(nonatomic, readonly, nullable) NSString *name;        // genesis, add, rename
@property(nonatomic, readonly, nullable) NSString *system;      // genesis, add, rename: "macOS 26.1"
@property(nonatomic, readonly) NSDate *date;                    // the signer's clock, in ms; never decides order
@property(nonatomic, readonly) NSData *linkHash;                // 32 bytes: what children name as a parent
@property(nonatomic, readonly) NSData *encodedData;
@end

// No state is 0, so asking a nil device for its state never reads as authorized.
typedef NS_ENUM(NSInteger, SZFriendsChainDeviceState) {
    SZFriendsChainDeviceAuthorized = 1, // speaks for the person: friends accept it, own devices sync with it
    SZFriendsChainDeviceRevoked = 2,    // removed for good
    SZFriendsChainDeviceVoid = 3,       // added only by links rule 3 voids: not authorized, may be added again
};

@interface SZFriendsChainDevice : NSObject
@property(nonatomic, readonly) NSData *deviceKey;
@property(nonatomic, readonly) NSData *staticKey;
@property(nonatomic, readonly) NSString *name;
@property(nonatomic, readonly) NSString *system;
@property(nonatomic, readonly) NSDate *addedAt;
@property(nonatomic, readonly, nullable) NSDate *revokedAt; // the earliest revocation that counts
@property(nonatomic, readonly) SZFriendsChainDeviceState state;
@property(nonatomic, readonly) BOOL isRoot; // the first device, whose device key is the root key
@end

@interface SZFriendsDeviceChain : NSObject

// Genesis for an existing or new profile: `root` is this device's identity, whose key becomes the root key and the
// first device's key. Nil only for a name or system that is empty after trimming.
+ (nullable instancetype)genesisChainWithIdentity:(SZFriendsIdentity *)root
                                             name:(NSString *)name
                                           system:(NSString *)system
                                             date:(NSDate *)date
                                            error:(NSError **)error;
// Decodes and verifies `data`. With `expectedRootKey`, a chain of another root fails WrongRoot (what friends do with
// the root they pinned); nil takes the root from the genesis (a device joining a profile learns it here).
+ (nullable instancetype)chainWithData:(NSData *)data
                       expectedRootKey:(nullable NSData *)expectedRootKey
                                 error:(NSError **)error;

@property(nonatomic, readonly) NSData *rootKey;
@property(nonatomic, readonly) NSData *genesisHash;
// Canonical order: parents first, ties by link hash. Two chains with the same links encode to the same bytes.
@property(nonatomic, readonly) NSArray<SZFriendsChainLink *> *links;
@property(nonatomic, readonly) NSArray<NSData *> *headHashes; // links no other link names: the next link's parents
@property(nonatomic, readonly) NSData *encodedData;
// Every device the chain ever added, earliest first, with its state under the rules above.
@property(nonatomic, readonly) NSArray<SZFriendsChainDevice *> *devices;
@property(nonatomic, readonly) NSArray<SZFriendsChainDevice *> *authorizedDevices;

- (nullable SZFriendsChainDevice *)deviceWithKey:(NSData *)deviceKey;
- (BOOL)authorizesDeviceKey:(NSData *)deviceKey;
- (BOOL)revokesDeviceKey:(NSData *)deviceKey;
// YES when every link of `other` is in this chain: merging it would change nothing.
- (BOOL)containsChain:(SZFriendsDeviceChain *)other;
- (BOOL)containsLinkHash:(NSData *)linkHash;

// The union with `other`, verified again. WrongRoot unless both have the same genesis; Full past the link limit.
- (nullable SZFriendsDeviceChain *)chainByMergingChain:(SZFriendsDeviceChain *)other error:(NSError **)error;

// New links on top of every head, signed by `signer`, which must be an authorized device of this chain (Unauthorized
// otherwise). Adding needs the new device's consent (SZFriendsDeviceConsent) and refuses a device already authorized
// or ever revoked (RevokedDevice). Renaming changes the signer's own name and system only, and stops at
// SZFriendsDeviceChainRenameLimit (Full).
- (nullable SZFriendsDeviceChain *)chainByAddingDeviceKey:(NSData *)deviceKey
                                                staticKey:(NSData *)staticKey
                                                  consent:(NSData *)consent
                                                     name:(NSString *)name
                                                   system:(NSString *)system
                                                 signedBy:(SZFriendsIdentity *)signer
                                                     date:(NSDate *)date
                                                    error:(NSError **)error;
- (nullable SZFriendsDeviceChain *)chainByRevokingDeviceKey:(NSData *)deviceKey
                                                   signedBy:(SZFriendsIdentity *)signer
                                                       date:(NSDate *)date
                                                      error:(NSError **)error;
- (nullable SZFriendsDeviceChain *)chainByRenamingTo:(NSString *)name
                                              system:(NSString *)system
                                            signedBy:(SZFriendsIdentity *)signer
                                                date:(NSDate *)date
                                               error:(NSError **)error;
@end

// The joining device's consent to be added under `rootKey`: its own signature, domain "SZFriends device consent v1",
// over rootKey (32) || its device key (32) || its static key (32). The join request carries it; the add link holds it.
NSData *SZFriendsDeviceConsent(SZFriendsIdentity *device, NSData *rootKey);
BOOL SZFriendsVerifyDeviceConsent(NSData *consent, NSData *deviceKey, NSData *staticKey, NSData *rootKey);

// What this Mac calls itself and its system, for the links it signs: the computer name from Sharing settings
// ("Mei's MacBook Air") and "macOS 26.1". Both cut to their limits; never empty.
NSString *SZFriendsLocalDeviceName(void);
NSString *SZFriendsLocalDeviceSystem(void);

NS_ASSUME_NONNULL_END
