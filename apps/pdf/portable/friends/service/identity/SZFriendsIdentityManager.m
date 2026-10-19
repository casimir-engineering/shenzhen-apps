// Loading, first-start creation and the explicit reset of the identity. The rule everything here serves: a secret
// that exists but cannot be used is reported, never replaced (SZFriendsIdentity.h).

#import "service/identity/SZFriendsIdentityInternal.h"

#include <sodium.h>

@implementation SZFriendsIdentityManager {
    id<SZFriendsKeyStore> _keyStore;
}

- (instancetype)initWithKeyStore:(id<SZFriendsKeyStore>)keyStore {
    if ((self = [super init])) _keyStore = keyStore;
    return self;
}

static void SZFZero(NSData *data) {
    // Key stores hand back mutable buffers where they can; an immutable one (a CFData from Security) is left to
    // the allocator, since writing through it would be undefined.
    if ([data isKindOfClass:[NSMutableData class]]) sodium_memzero(((NSMutableData *)data).mutableBytes, data.length);
}

- (nullable SZFriendsIdentity *)loadOrCreateWithState:(SZFriendsIdentityState *_Nullable)state
                                                error:(NSError **)error {
    if (state) *state = SZFriendsIdentityStateUnavailable;
    NSError *readError = nil;
    NSData *secret = [_keyStore secretNamed:SZFriendsIdentitySecretName error:&readError];
    if (secret == nil && readError != nil) {
        if (error) *error = SZFriendsIdentityMakeError(SZFriendsIdentityErrorUnavailable,
            @"The Friends identity exists but cannot be read.", readError);
        return nil;
    }
    if (secret != nil) {
        SZFriendsIdentity *identity = [SZFriendsIdentity identityFromSecret:secret error:error];
        SZFZero(secret);
        if (identity != nil && state) *state = SZFriendsIdentityStateReady;
        return identity;
    }
    SZFriendsIdentity *identity = [self createWithError:error];
    if (identity != nil && state) *state = SZFriendsIdentityStateCreated;
    return identity;
}

- (nullable SZFriendsIdentity *)loadExistingWithError:(NSError **)error {
    NSError *readError = nil;
    NSData *secret = [_keyStore secretNamed:SZFriendsIdentitySecretName error:&readError];
    if (secret == nil) {
        if (error) *error = SZFriendsIdentityMakeError(SZFriendsIdentityErrorUnavailable,
            readError ? @"The Friends identity exists but cannot be read." : @"The Friends identity is missing.",
            readError);
        return nil;
    }
    SZFriendsIdentity *identity = [SZFriendsIdentity identityFromSecret:secret error:error];
    SZFZero(secret);
    return identity;
}

- (nullable SZFriendsIdentity *)resetIdentityWithError:(NSError **)error {
    if (![_keyStore deleteSecretNamed:SZFriendsIdentitySecretName error:error]) return nil;
    return [self createWithError:error];
}

- (nullable SZFriendsIdentity *)createWithError:(NSError **)error {
    SZFriendsIdentity *identity = [SZFriendsIdentity generatedIdentity];
    NSMutableData *item = [identity secretItem];
    NSError *storeError = nil;
    BOOL stored = [_keyStore storeSecret:item named:SZFriendsIdentitySecretName error:&storeError];
    // Read it back before anyone sees the new key: a store that accepts a write it cannot return (a keychain item
    // the next launch could not open) would otherwise become a key change at the next start.
    NSError *readError = nil;
    NSData *readBack = stored ? [_keyStore secretNamed:SZFriendsIdentitySecretName error:&readError] : nil;
    BOOL same = readBack.length == item.length && sodium_memcmp(readBack.bytes, item.bytes, item.length) == 0;
    SZFZero(readBack);
    sodium_memzero(item.mutableBytes, item.length);
    if (!stored) {
        if (error) *error = SZFriendsIdentityMakeError(SZFriendsIdentityErrorStoreFailed,
            @"A new Friends identity could not be saved.", storeError);
        return nil;
    }
    if (!same) {
        if (error) *error = SZFriendsIdentityMakeError(SZFriendsIdentityErrorStoreFailed,
            @"A new Friends identity was saved but could not be read back.", readError);
        return nil;
    }
    return identity;
}

@end
