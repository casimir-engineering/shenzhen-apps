// Internals of the device chain shared by its sources and tests (SZFriendsDeviceChain.h is the interface).

#import "service/identity/SZFriendsDeviceChain.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString *const SZFriendsChainLinkDomain;    // "SZFriends chain link v1": the signer's signature
extern NSString *const SZFriendsDeviceConsentDomain; // "SZFriends device consent v1": the subject's consent

NSError *SZFriendsChainError(SZFriendsDeviceChainError code, NSString *description);

@interface SZFriendsChainLink ()
// Parses one link and checks its own signature and consent against `rootKey` (for genesis, nil: the genesis signs
// for itself). Every check that needs no other link happens here: lengths, kind, field rules, signatures.
+ (nullable instancetype)linkWithData:(NSData *)data rootKey:(nullable NSData *)rootKey error:(NSError **)error;
// Builds and signs a link. `consent` for genesis and add. Raises nothing; nil with Refused for a name or system that
// is empty, or a field of the wrong length.
+ (nullable instancetype)signedLinkWithKind:(SZFriendsChainLinkKind)kind
                                    parents:(NSArray<NSData *> *)parents
                                     signer:(SZFriendsIdentity *)signer
                                    rootKey:(NSData *)rootKey
                                 subjectKey:(NSData *)subjectKey
                                  staticKey:(nullable NSData *)staticKey
                                    consent:(nullable NSData *)consent
                                       name:(nullable NSString *)name
                                     system:(nullable NSString *)system
                                       date:(NSDate *)date
                                      error:(NSError **)error;
@property(nonatomic, readonly, nullable) NSData *consent;
@property(nonatomic, readonly) uint64_t milliseconds;
@end

// The rules' outcome for a chain whose structure has been checked (SZFriendsDeviceChainRules.m): one entry per link in
// `links` order saying whether it counts, and the devices with their states.
@interface SZFriendsChainOutcome : NSObject
@property(nonatomic, copy) NSArray<SZFriendsChainDevice *> *devices;
@property(nonatomic, copy) NSIndexSet *effectiveLinks;
@end

// `links` in an order where parents come first; `ancestors[i]` holds the indexes of every ancestor of link i.
SZFriendsChainOutcome *SZFriendsChainApplyRules(NSArray<SZFriendsChainLink *> *links,
                                                NSArray<NSIndexSet *> *ancestors, NSData *rootKey);

@interface SZFriendsChainDevice ()
- (instancetype)initWithDeviceKey:(NSData *)deviceKey
                        staticKey:(NSData *)staticKey
                             name:(NSString *)name
                           system:(NSString *)system
                          addedAt:(NSDate *)addedAt
                        revokedAt:(nullable NSDate *)revokedAt
                            state:(SZFriendsChainDeviceState)state
                           isRoot:(BOOL)isRoot;
@end

// UTF-8 cut on a character boundary to at most `maxBytes`, after trimming whitespace and control characters.
NSString *SZFriendsChainLabel(NSString *text, NSUInteger maxBytes);

NS_ASSUME_NONNULL_END
