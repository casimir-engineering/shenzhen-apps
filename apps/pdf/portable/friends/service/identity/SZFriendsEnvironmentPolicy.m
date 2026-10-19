// Which SZFRIENDS_* environment overrides this build honours, and the key store the helper picks from them.
//
// The overrides exist so tests, probes and the two-helper harness run against a temporary state directory and a file
// key store. A release signed with a team must not obey them: another process running as the person could set them
// for the next launch and move the identity into a plaintext file of its choosing (security review, low finding
// "environment overrides in production").

#import "service/identity/SZFriendsIdentityInternal.h"

#import <Security/Security.h>

NSString *_Nullable SZFriendsSigningTeamIdentifier(void) {
    static NSString *team;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SecCodeRef selfCode = NULL;
        if (SecCodeCopySelf(kSecCSDefaultFlags, &selfCode) != errSecSuccess || selfCode == NULL) return;
        SecStaticCodeRef staticCode = NULL;
        OSStatus status = SecCodeCopyStaticCode(selfCode, kSecCSDefaultFlags, &staticCode);
        CFRelease(selfCode);
        if (status != errSecSuccess || staticCode == NULL) return;
        CFDictionaryRef info = NULL;
        status = SecCodeCopySigningInformation(staticCode, kSecCSSigningInformation, &info);
        CFRelease(staticCode);
        if (status != errSecSuccess || info == NULL) return;
        NSDictionary *signing = CFBridgingRelease(info);
        id value = signing[(__bridge NSString *)kSecCodeInfoTeamIdentifier];
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) team = [value copy];
    });
    return team;
}

BOOL SZFriendsEnvironmentOverridesAllowedForTeam(NSString *_Nullable teamIdentifier) {
    // Fail closed: a team string of any shape means someone signed this build for release.
    return teamIdentifier.length == 0;
}

BOOL SZFriendsEnvironmentOverridesAllowed(void) {
    return SZFriendsEnvironmentOverridesAllowedForTeam(SZFriendsSigningTeamIdentifier());
}

id<SZFriendsKeyStore> SZFriendsKeyStoreForTeam(NSString *stateDirectory, NSDictionary<NSString *, NSString *> *env,
                                               NSString *_Nullable teamIdentifier) {
    if (!SZFriendsEnvironmentOverridesAllowedForTeam(teamIdentifier)) return [[SZFriendsKeychainKeyStore alloc] init];
    NSString *choice = [env[@"SZFRIENDS_KEY_STORE"] lowercaseString];
    BOOL stateOverridden = env[@"SZFRIENDS_STATE_DIR"] != nil;
    BOOL useFile = [choice isEqualToString:@"file"] || (stateOverridden && ![choice isEqualToString:@"keychain"]);
    if (useFile) {
        NSString *keys = [stateDirectory stringByAppendingPathComponent:@"keys"];
        return [[SZFriendsFileKeyStore alloc] initWithDirectory:keys];
    }
    return [[SZFriendsKeychainKeyStore alloc] init];
}

id<SZFriendsKeyStore> SZFriendsDefaultKeyStore(NSString *stateDirectory, NSDictionary<NSString *, NSString *> *env) {
    return SZFriendsKeyStoreForTeam(stateDirectory, env, SZFriendsSigningTeamIdentifier());
}
