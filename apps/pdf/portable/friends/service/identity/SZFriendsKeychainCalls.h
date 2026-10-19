// The Security calls the Keychain key store makes, behind a protocol so tests substitute a fake and never touch
// the real Keychain (a test that did could prompt the owner or read their items). Identity area internal.

#import <Security/Security.h>

#import "service/identity/SZFriendsIdentity.h"

NS_ASSUME_NONNULL_BEGIN

@protocol SZFriendsKeychainCalls <NSObject>
- (OSStatus)copyMatching:(NSDictionary *)query result:(id _Nullable __autoreleasing *_Nonnull)result;
- (OSStatus)add:(NSDictionary *)attributes;
- (OSStatus)deleteMatching:(NSDictionary *)query;
// The legacy keychain's process-wide user-interaction switch (SecKeychainGet/SetUserInteractionAllowed).
- (OSStatus)getUserInteractionAllowed:(Boolean *)allowed;
- (OSStatus)setUserInteractionAllowed:(Boolean)allowed;
@end

// SecItemCopyMatching, SecItemAdd, SecItemDelete and the interaction switch, unchanged.
@interface SZFriendsSystemKeychainCalls : NSObject <SZFriendsKeychainCalls>
@end

extern NSString *const SZFriendsKeychainService; // "Shenzhen Friends"

@interface SZFriendsKeychainKeyStore ()
// -init uses SZFriendsSystemKeychainCalls.
- (instancetype)initWithCalls:(id<SZFriendsKeychainCalls>)calls NS_DESIGNATED_INITIALIZER;
@end

NS_ASSUME_NONNULL_END
