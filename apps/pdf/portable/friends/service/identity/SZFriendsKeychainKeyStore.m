// The Keychain key store: a generic password per name, created and read only by the helper, never with a prompt.
//
// Why the legacy (file-based) login keychain rather than the data-protection keychain: its access control list
// names the creating executable, which is the "only the helper reads it" property the brief asks for, and it works
// for a Developer ID helper without a provisioning profile. The item's access control names the helper by its
// designated requirement (identifier com.intuition.shenzhenfriends and the team), so every Developer ID helper of
// the team reads it, whichever app's copy made it and whatever build it was: the three apps' helpers must keep that
// identifier and team. A helper signed another way (ad hoc, another identifier or team) cannot read it, which the
// identity manager turns into "identity unavailable", never a new key; Reset Friends then removes it through its item
// reference, the one delete the file-based keychain allows across signatures (SZFriendsKeychainCalls.h).

#import "service/identity/SZFriendsKeychainCalls.h"
#import "service/identity/SZFriendsIdentityInternal.h"

#import <LocalAuthentication/LocalAuthentication.h>
#include <pthread.h>

NSString *const SZFriendsKeychainService = @"Shenzhen Friends";

// kSecUseAuthenticationUI(Fail) and the SecKeychain interaction switch are deprecated, but they are what still
// stops legacy-keychain ACL prompts; LAContext alone covers data-protection items only. The reader keeps all three
// for the same reason. Never relax an item's access control instead.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@implementation SZFriendsSystemKeychainCalls

- (OSStatus)copyMatching:(NSDictionary *)query result:(id _Nullable __autoreleasing *)result {
    CFTypeRef object = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &object);
    *result = CFBridgingRelease(object);
    return status;
}

- (OSStatus)add:(NSDictionary *)attributes {
    return SecItemAdd((__bridge CFDictionaryRef)attributes, NULL);
}

- (OSStatus)deleteItem:(id)item {
    return SecKeychainItemDelete((__bridge SecKeychainItemRef)item);
}

- (OSStatus)getUserInteractionAllowed:(Boolean *)allowed {
    return SecKeychainGetUserInteractionAllowed(allowed);
}

- (OSStatus)setUserInteractionAllowed:(Boolean)allowed {
    return SecKeychainSetUserInteractionAllowed(allowed);
}

@end

@implementation SZFriendsKeychainKeyStore {
    id<SZFriendsKeychainCalls> _calls;
}

- (instancetype)init {
    return [self initWithCalls:[[SZFriendsSystemKeychainCalls alloc] init]];
}

- (instancetype)initWithCalls:(id<SZFriendsKeychainCalls>)calls {
    if ((self = [super init])) _calls = calls;
    return self;
}

// The interaction switch is process-wide, so one lock serialises every Keychain operation in the helper: a second
// thread must not restore "allowed" while the first is mid-read. Fails closed: if the switch cannot be read or
// set, the operation does not run.
- (OSStatus)withoutInteraction:(OSStatus (^)(void))operation {
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&lock);
    Boolean previous = false;
    OSStatus status = [_calls getUserInteractionAllowed:&previous];
    if (status == errSecSuccess) status = [_calls setUserInteractionAllowed:false];
    if (status == errSecSuccess) {
        status = operation();
        OSStatus restored = [_calls setUserInteractionAllowed:previous];
        if (status == errSecSuccess && restored != errSecSuccess) status = restored;
    }
    pthread_mutex_unlock(&lock);
    return status;
}

- (NSMutableDictionary *)queryForName:(NSString *)name {
    LAContext *context = [[LAContext alloc] init];
    context.interactionNotAllowed = YES;
    return [@{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : SZFriendsKeychainService,
        (__bridge id)kSecAttrAccount : name,
        (__bridge id)kSecAttrSynchronizable : @NO,
        (__bridge id)kSecUseAuthenticationContext : context,
        (__bridge id)kSecUseAuthenticationUI : (__bridge id)kSecUseAuthenticationUIFail,
    } mutableCopy];
}

static NSError *SZFStatusError(OSStatus status) {
    return [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
}

- (nullable NSData *)secretNamed:(NSString *)name error:(NSError **)error {
    if (error) *error = nil;
    if (!SZFriendsKeyStoreNameIsValid(name)) {
        if (error) *error = SZFriendsIdentityMakeError(SZFriendsIdentityErrorUnavailable, @"Invalid key name.", nil);
        return nil;
    }
    NSMutableDictionary *query = [self queryForName:name];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    __block id result = nil;
    OSStatus status = [self withoutInteraction:^OSStatus {
        id found = nil;
        OSStatus copied = [self->_calls copyMatching:query result:&found];
        result = found;
        return copied;
    }];
    if (status == errSecItemNotFound) return nil;
    if (status == errSecSuccess && [result isKindOfClass:[NSData class]]) return result;
    // Everything else, including a refused ACL (errSecInteractionNotAllowed after a rebuild) and a locked keychain,
    // means the item may well exist: report it unavailable so nobody creates a replacement.
    if (error) *error = SZFriendsIdentityMakeError(SZFriendsIdentityErrorUnavailable,
        @"The Friends key exists in the keychain but cannot be read without asking.",
        SZFStatusError(status == errSecSuccess ? errSecDecode : status));
    return nil;
}

- (BOOL)storeSecret:(NSData *)secret named:(NSString *)name error:(NSError **)error {
    if (!SZFriendsKeyStoreNameIsValid(name)) {
        if (error) *error = SZFriendsIdentityMakeError(SZFriendsIdentityErrorStoreFailed, @"Invalid key name.", nil);
        return NO;
    }
    NSMutableDictionary *attributes = [self queryForName:name];
    attributes[(__bridge id)kSecValueData] = secret;
    // This device only, readable after the first unlock: a helper relaunched behind a locked screen (a crash
    // restore) still starts, and the key never travels in a backup to another Mac.
    attributes[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    // Add only, never SecItemUpdate: an existing item is someone's identity, and replacing it is Reset's job.
    OSStatus status = [self withoutInteraction:^OSStatus { return [self->_calls add:attributes]; }];
    if (status == errSecSuccess) return YES;
    NSString *why = status == errSecDuplicateItem
        ? @"A Friends key already exists in the keychain; it was not replaced."
        : @"The Friends key could not be saved in the keychain.";
    if (error) *error = SZFriendsIdentityMakeError(SZFriendsIdentityErrorStoreFailed, why, SZFStatusError(status));
    return NO;
}

- (BOOL)deleteSecretNamed:(NSString *)name error:(NSError **)error {
    if (!SZFriendsKeyStoreNameIsValid(name)) {
        if (error) *error = SZFriendsIdentityMakeError(SZFriendsIdentityErrorStoreFailed, @"Invalid key name.", nil);
        return NO;
    }
    // Every item of this name, by reference: finding one needs no access to its secret, and deleting it through
    // the reference works for an item a differently signed helper made (SZFriendsKeychainCalls.h).
    NSMutableDictionary *query = [self queryForName:name];
    query[(__bridge id)kSecReturnRef] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitAll;
    OSStatus status = [self withoutInteraction:^OSStatus {
        id found = nil;
        OSStatus copied = [self->_calls copyMatching:query result:&found];
        if (copied != errSecSuccess) return copied;
        NSArray *items = [found isKindOfClass:[NSArray class]] ? found : (found ? @[ found ] : @[]);
        for (id item in items) {
            OSStatus deleted = [self->_calls deleteItem:item];
            if (deleted != errSecSuccess && deleted != errSecItemNotFound) return deleted;
        }
        return errSecSuccess;
    }];
    if (status == errSecSuccess || status == errSecItemNotFound) return YES;
    if (error) *error = SZFriendsIdentityMakeError(SZFriendsIdentityErrorStoreFailed,
        @"The Friends key could not be removed from the keychain.", SZFStatusError(status));
    return NO;
}

@end

#pragma clang diagnostic pop
