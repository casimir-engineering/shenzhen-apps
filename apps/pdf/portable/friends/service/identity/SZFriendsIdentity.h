// Shenzhen Friends identity: the immutable identity key, where its secret lives, and the two-word Friends ID.
//
// Helper-only. Friends are stored by identity key, never by name, Friends ID, address or hardware id, so an ID
// rename or a new name changes nothing about who is who (brief § Identity and keys, § Friends ID).
//
// The one rule that matters most: an identity secret that exists but cannot be read is UNAVAILABLE, never a
// reason to make a new key. Every friend would see a silent regeneration as a key change. Only an explicit
// reset (the user's Reset Friends) creates a new identity over an old one.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const SZFriendsIdentityErrorDomain;

typedef NS_ERROR_ENUM(SZFriendsIdentityErrorDomain, SZFriendsIdentityError) {
    SZFriendsIdentityErrorUnavailable = 1, // secret present but unreadable (ad-hoc rebuild, locked keychain)
    SZFriendsIdentityErrorCorrupt = 2,     // secret readable but not a valid key
    SZFriendsIdentityErrorStoreFailed = 3, // could not write a new secret (or delete one), or one already exists
    SZFriendsIdentityErrorInvalidWordList = 4, // a word list that breaks the format (ADR 0006)
};

#pragma mark - Key stores

// Where the identity secret lives. Reads are noninteractive: a store never shows a password or keychain
// prompt (the technique of the reader's noninteractive Keychain reads, reimplemented here because Friends
// may not include reader headers). Names are 1 to 64 characters of A-Z, a-z, 0-9, '.', '_' and '-', not starting
// with '.'; anything else fails with SZFriendsIdentityErrorStoreFailed (or Unavailable on read).
@protocol SZFriendsKeyStore <NSObject>
// Returns nil and NO error when no secret exists under `name`; nil and an error when one exists but cannot be
// read. The distinction is what keeps an unreadable key from being replaced.
- (nullable NSData *)secretNamed:(NSString *)name error:(NSError **)error;
// Creates the secret. Never replaces one: when `name` already exists it fails with StoreFailed, so not even a
// caller that misread "absent" can overwrite an identity. Replacing is delete, then store (Reset Friends).
- (BOOL)storeSecret:(NSData *)secret named:(NSString *)name error:(NSError **)error;
// Succeeds when the secret is gone afterwards, including when there was none.
- (BOOL)deleteSecretNamed:(NSString *)name error:(NSError **)error;
@end

// Keychain item created and read only by the helper, so its access control names the helper and apps never
// touch it. Generic password, service "Shenzhen Friends", account = the name, this-device-only, no iCloud sync.
// -init does no Keychain work; only the three methods do.
@interface SZFriendsKeychainKeyStore : NSObject <SZFriendsKeyStore>
@end

// A 0600 file per name in `directory` (0700, created on first store; SZFriendsDefaultKeyStore passes
// <state dir>/keys). For tests, probes and the two-helper harness, which must never touch the real Keychain.
// A file that is a symbolic link, not ours, or readable by group or others is reported unavailable, not used.
@interface SZFriendsFileKeyStore : NSObject <SZFriendsKeyStore>
- (instancetype)initWithDirectory:(NSString *)directory NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly, copy) NSString *directory;
@end

#pragma mark - Environment overrides

// The team identifier in this process's own code signature, or nil for ad-hoc, linker-signed and unsigned builds
// (every build `make` produces for tests). Read once, then cached; it does no Keychain work and never prompts.
NSString *_Nullable SZFriendsSigningTeamIdentifier(void);

// Whether a process signed with `teamIdentifier` (nil: no team) may honour the SZFRIENDS_* environment overrides:
// SZFRIENDS_STATE_DIR, SZFRIENDS_KEY_STORE and the test-only variables the helper reads under them. Only builds
// without a team may. WHY: any process running as the person can set variables for the next launch (launchctl
// setenv); a team-signed release that obeyed them would move its identity into a plaintext key file in a directory
// that process chose, which every friend would then see as a key change. Any non-empty team counts as signed.
BOOL SZFriendsEnvironmentOverridesAllowedForTeam(NSString *_Nullable teamIdentifier);
// The same for this process: SZFriendsEnvironmentOverridesAllowedForTeam(SZFriendsSigningTeamIdentifier()). The
// helper asks it before reading any SZFRIENDS_* variable.
BOOL SZFriendsEnvironmentOverridesAllowed(void);

// The store the helper uses. Where overrides are allowed: the file store when SZFRIENDS_STATE_DIR is set (unless
// SZFRIENDS_KEY_STORE is "keychain"), or when SZFRIENDS_KEY_STORE is "file"; the Keychain otherwise. Where they are
// not (a team-signed build), always the Keychain, whatever `env` says. WHY default to the file store under an
// overridden state directory: a test that forgets to ask for it must still not reach the Keychain.
// SZFRIENDS_STATE_DIR counts as set even when empty; SZFRIENDS_KEY_STORE is compared without regard to case.
id<SZFriendsKeyStore> SZFriendsDefaultKeyStore(NSString *stateDirectory, NSDictionary<NSString *, NSString *> *env);
// The same decision with the signing check injected: what a build signed with `teamIdentifier` would pick. Tests
// use it to stand in for a team-signed release; SZFriendsDefaultKeyStore passes SZFriendsSigningTeamIdentifier().
id<SZFriendsKeyStore> SZFriendsKeyStoreForTeam(NSString *stateDirectory, NSDictionary<NSString *, NSString *> *env,
                                               NSString *_Nullable teamIdentifier);

#pragma mark - Identity

// The local identity: two keys generated together, stored in one key-store item, both immutable (ADR 0001
// § Keys). The Ed25519 key is the identity: friends store it, the host check-in signs with it, the QR carries it.
// The X25519 key is the Noise static key. It is not derived from the Ed25519 key, because libsodium's
// documentation recommends distinct keys for signing and key exchange; a certificate links the two.
@interface SZFriendsIdentity : NSObject
@property(nonatomic, readonly) NSData *publicKey;         // Ed25519, 32 bytes: the stable identity of this person
@property(nonatomic, readonly) NSData *staticPublicKey;   // X25519, 32 bytes: the Noise static key
// 96 bytes, carried in every handshake payload that reveals the static key:
// publicKey (32) || Ed25519 signature (64) over "SZFriends static v1" || staticPublicKey.
@property(nonatomic, readonly) NSData *staticCertificate;
// 32 bytes, SZFriendsIdentityHash(publicKey): what statistics and (M2) rendezvous records key on instead of the
// key itself.
@property(nonatomic, readonly) NSData *identityHash;
// The first 8 hex digits of identityHash, for logs only. Never shown to users, never used as identity.
@property(nonatomic, readonly) NSString *logFingerprint;

// Builds an identity from given secrets instead of the key store: for golden vectors and tests only (production
// identities come from SZFriendsIdentityManager). `signingSeed` is the 32-byte Ed25519 seed, `staticPrivateKey`
// the 32-byte X25519 private key. Nil for wrong lengths.
+ (nullable instancetype)identityWithSigningSeed:(NSData *)signingSeed staticPrivateKey:(NSData *)staticPrivateKey;

// Signs UTF-8(domain) || message with the Ed25519 key. Every use has its own domain string, listed in
// SZFriendsSignatureDomains(), so a signature made for one purpose never verifies for another. Never signs data
// chosen wholly by a peer. An empty domain, or one that is a proper prefix of a listed domain (or has one as a
// proper prefix), is a programming error and raises NSInvalidArgumentException: with no separator between domain
// and message, "SZFriends static" || " v1" || key would be the bytes of a static certificate.
- (NSData *)signatureForMessage:(NSData *)message domain:(NSString *)domain;
// NO for a wrong-length key or signature, an empty or prefix-colliding domain, or a signature that does not verify.
+ (BOOL)verifySignature:(NSData *)signature
             forMessage:(NSData *)message
                 domain:(NSString *)domain
              publicKey:(NSData *)publicKey;

// The X25519 private key for the session layer's Noise handshakes. Kept inside the helper process; callers zero
// their copies (sodium_memzero) when done. Returns a fresh mutable copy, so zeroing its bytes is allowed.
- (NSData *)staticPrivateKey;
@end

// Every domain the identity key signs under, one per purpose, no one a prefix of another ("SZFriends static v1",
// "SZFriends request v1", "SZFriends checkin v1", "SZFriends release v1"). A new use adds its domain here, in the
// same change: signing refuses a domain that collides by prefix with one listed, and the identity suite checks the
// list stays prefix-free. The signature format has no separator before the message, so this is what keeps purposes
// apart until a later format frames the domain.
NSArray<NSString *> *SZFriendsSignatureDomains(void);

// Checks a peer's certificate against the static key its handshake used and returns the Ed25519 identity key it
// binds, or nil when the signature does not verify. The session layer calls it before trusting any static key.
NSData *_Nullable SZFriendsIdentityKeyFromCertificate(NSData *certificate, NSData *staticPublicKey);

// BLAKE2b-256 of UTF-8("SZFriends identity hash v1") || publicKey: a stable, domain-separated stand-in for an
// identity key where the key itself is not needed. Nil unless `publicKey` is 32 bytes.
NSData *_Nullable SZFriendsIdentityHash(NSData *publicKey);

typedef NS_ENUM(NSInteger, SZFriendsIdentityState) {
    SZFriendsIdentityStateReady = 0,       // loaded an existing identity
    SZFriendsIdentityStateCreated = 1,     // first start: a new identity was generated and stored
    SZFriendsIdentityStateUnavailable = 2, // a secret exists but cannot be used; Friends shows the reset path
};

@interface SZFriendsIdentityManager : NSObject
- (instancetype)initWithKeyStore:(id<SZFriendsKeyStore>)keyStore NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Loads the identity, creating one only when no secret exists at all. Returns nil with state Unavailable when
// a secret exists but cannot be read (error Unavailable) or parsed (Corrupt), and also when a new secret could not
// be stored and read back (StoreFailed): a key that will not survive a restart would be a key change tomorrow.
- (nullable SZFriendsIdentity *)loadOrCreateWithState:(SZFriendsIdentityState *_Nullable)state
                                                error:(NSError **)error;

// Reads the identity again after it was unavailable, and never creates one: an identity that is now missing is still
// unavailable, because the friends and history kept for the old one would otherwise meet a silent new key. Nil with
// the same errors as above while it still cannot be read (the keychain still locked, say).
- (nullable SZFriendsIdentity *)loadExistingWithError:(NSError **)error;

// The two halves of a reset, for a caller that has work between them: remove the stored secret (success when there is
// none), then make a new identity. Nothing is created by the first, and the second never removes anything.
- (BOOL)deleteIdentityWithError:(NSError **)error;
- (nullable SZFriendsIdentity *)createIdentityWithError:(NSError **)error;

// Explicit reset: deletes the old secret and creates a new identity. Only the user's Reset Friends calls it.
// When the delete fails nothing is created.
- (nullable SZFriendsIdentity *)resetIdentityWithError:(NSError **)error;
@end

#pragma mark - Friends ID

// A versioned list of 2,048 simple English words, excluding offensive, violent, technical and easily
// confused terms. Two words give 4,194,304 IDs. ADR 0006 is the decision: a selection from the EFF Large
// Wordlist (CC BY; the attribution travels in the file's header), curation rules 1 to 5 enforced by this area's
// test, the v1 word lines pinned by SHA-256. The list and how it was chosen: wordlist/WORDLIST.md.
@interface SZFriendsWordList : NSObject
// The list compiled into the helper from wordlist/friends-id-words-v1.txt, so the updater replacing the bundle
// while the helper runs cannot change it. Validated on first use: version 1, exactly 2,048 unique lowercase ASCII
// words of 3-8 letters, matching SZFriendsWordListV1Digest. Nil when it fails. Shared and immutable.
+ (nullable instancetype)bundledList;
// Any count from 1 to 65,536 of unique words of 3-8 letters a-z, in the given order. Error InvalidWordList.
+ (nullable instancetype)listWithWords:(NSArray<NSString *> *)words version:(NSInteger)version
                                 error:(NSError **)error;
// Parses the file format: '#' header lines first, one of them "# version: <n>", then one word per line, each
// ending in "\n"; no blank lines, no header lines after the first word, ASCII only. Does not check the pin.
+ (nullable instancetype)listWithFileData:(NSData *)data error:(NSError **)error;
@property(nonatomic, readonly) NSInteger version;
@property(nonatomic, readonly) NSUInteger count;
@property(nonatomic, readonly, copy) NSArray<NSString *> *words;
// Lowercase hex SHA-256 of every word followed by "\n", in list order: what a version's pin covers.
@property(nonatomic, readonly, copy) NSString *wordLinesDigest;
- (NSString *)wordAtIndex:(NSUInteger)index;
- (NSUInteger)indexOfWord:(NSString *)word; // NSNotFound when absent
@end

// The pinned wordLinesDigest of version 1. Changing any word changes it and fails friends-identity-check, so a
// new list is always a deliberate new version (ADR 0006 § Format and versioning).
extern NSString *const SZFriendsWordListV1Digest;

typedef NS_ENUM(NSInteger, SZFriendsIDState) {
    SZFriendsIDStateUnreserved = 0, // drawn offline; usable nearby; not yet confirmed by the main host
    SZFriendsIDStateReserved = 1,   // the main host granted it
    SZFriendsIDStateChanged = 2,    // the host refused it (taken) and a new one was reserved; tell the user once
};

// A uniform value below `bound` (bound >= 1). Production uses SZFriendsSystemRandomUniform; tests script draws.
typedef uint32_t (^SZFriendsRandomUniform)(uint32_t bound);
// libsodium's randombytes_uniform. Calls sodium_init() first, so it works before the helper's own init.
SZFriendsRandomUniform SZFriendsSystemRandomUniform(void);

@interface SZFriendsIDCodec : NSObject
- (instancetype)initWithWordList:(SZFriendsWordList *)wordList NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) SZFriendsWordList *wordList;

// Canonical form "word-word" (or "word-word-word" once three-word IDs are issued). Accepts what people type:
// surrounding whitespace, any case, and spaces, hyphens, dots or underscores between words (runs of them too, and
// the full-width and dash forms Chinese and macOS input methods produce). Nil when any word is not in the list,
// or for one word or four, so a typo is caught before a request is sent.
- (nullable NSString *)normalizedID:(NSString *)input;

// A uniformly random ID of `wordCount` (2 or 3) words. `randomUniform` returns a uniform value below its bound
// (libsodium's randombytes_uniform in production) so tests can script draws, including retries after collisions.
// Another word count, or a draw at or above the bound, raises NSInvalidArgumentException.
- (NSString *)randomIDWithWordCount:(NSUInteger)wordCount generator:(uint32_t (^)(uint32_t bound))randomUniform;
@end

// ADR 0006 § Three-word threshold: how many words the next drawn ID has. `listNewIDWords` is new_id_words from
// the signed host list (2 until the admin publishes 3); three collisions in a row mean three words whatever the
// list says, which covers a stale list.
NSUInteger SZFriendsWordCountForNewID(NSInteger listNewIDWords, NSUInteger collisionsInARow);

// The local Friends ID and where its reservation stands, as the store keeps it (friendsID, friendsIDState,
// previousFriendsID, idCollisionsInARow). Immutable: each event returns the next status for the helper to store.
//
//   first start            -> Unreserved (drawn offline, usable nearby at once)
//   host grants our ID      -> Reserved
//   host refuses, then grants a fresh draw -> Changed, previousID = the ID the person knew; the list shows the
//                              one-time notice until it is dismissed -> Reserved
//   host holds another ID for this key (a reinstall that kept its key) -> Reserved with that ID, no notice
//   main host unreachable   -> unchanged, still Unreserved
@interface SZFriendsIDStatus : NSObject <NSCopying>
- (instancetype)initWithFriendsID:(NSString *)friendsID
                            state:(SZFriendsIDState)state
                       previousID:(nullable NSString *)previousID
                 collisionsInARow:(NSUInteger)collisionsInARow NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// First start, and after Reset Friends: a fresh Unreserved ID of SZFriendsWordCountForNewID(listNewIDWords, 0)
// words.
+ (instancetype)initialStatusWithCodec:(SZFriendsIDCodec *)codec
                        listNewIDWords:(NSInteger)listNewIDWords
                             generator:(SZFriendsRandomUniform)generator;

@property(nonatomic, readonly, copy) NSString *friendsID;
@property(nonatomic, readonly) SZFriendsIDState state;
@property(nonatomic, readonly, copy, nullable) NSString *previousID; // set only while Changed
// "Taken" answers since the last successful reservation. At three it stays: three-word draws from then on.
@property(nonatomic, readonly) NSUInteger collisionsInARow;

// The host answered "taken" for the ID just claimed.
- (SZFriendsIDStatus *)statusAfterCollision;
// The ID to claim after that answer: a fresh draw of SZFriendsWordCountForNewID(listNewIDWords, collisionsInARow)
// words, never the current ID.
- (NSString *)replacementIDWithCodec:(SZFriendsIDCodec *)codec
                      listNewIDWords:(NSInteger)listNewIDWords
                           generator:(SZFriendsRandomUniform)generator;
// The host granted `reservedID` on the first claim (SZFriendsCheckInDelegate -checkInDidReserveID:).
- (SZFriendsIDStatus *)statusAfterReservationOf:(NSString *)reservedID;
// The host refused `oldID` and granted `newID` (-checkInDidRenameIDFrom:to:).
- (SZFriendsIDStatus *)statusAfterRenameFrom:(NSString *)oldID to:(NSString *)newID;
// The person dismissed the "Your ID changed" notice (dismiss_banner).
- (SZFriendsIDStatus *)statusAfterNoticeDismissed;
@end

NS_ASSUME_NONNULL_END
