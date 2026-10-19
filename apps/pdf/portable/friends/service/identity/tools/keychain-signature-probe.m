// keychain-signature-probe <create|add|read|item-delete|ref-delete|destroy> <keychain>: the Keychain key store's
// calls (SZFriendsKeychainKeyStore.m), with interaction off as there, against a temporary keychain the script made.
// Never the login keychain: every query names the keychain file. keychain-signature-probe.sh runs the matrix.
#import <Foundation/Foundation.h>
#import <Security/Security.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static const char *const SZFProbePassword = "szfriends-probe";

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) return 2;
        NSString *mode = @(argv[1]);
        SecKeychainSetUserInteractionAllowed(false);
        SecKeychainRef keychain = NULL;
        OSStatus status;
        if ([mode isEqualToString:@"create"]) {
            status = SecKeychainCreate(argv[2], (UInt32)strlen(SZFProbePassword), SZFProbePassword, FALSE, NULL,
                                       &keychain);
        } else {
            status = SecKeychainOpen(argv[2], &keychain);
            if (status == errSecSuccess)
                status = SecKeychainUnlock(keychain, (UInt32)strlen(SZFProbePassword), SZFProbePassword, TRUE);
        }
        if (status != errSecSuccess || [mode isEqualToString:@"create"]) {
            printf("%s %d\n", argv[1], (int)status);
            return status == errSecSuccess ? 0 : 1;
        }
        NSMutableDictionary *query = [@{
            (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService : @"Shenzhen Friends probe",
            (__bridge id)kSecAttrAccount : @"identity",
            (__bridge id)kSecAttrSynchronizable : @NO,
            (__bridge id)kSecUseAuthenticationUI : (__bridge id)kSecUseAuthenticationUIFail,
        } mutableCopy];
        if ([mode isEqualToString:@"destroy"]) {
            status = SecKeychainDelete(keychain);
        } else if ([mode isEqualToString:@"add"]) {
            query[(__bridge id)kSecValueData] = [@"secret" dataUsingEncoding:NSUTF8StringEncoding];
            query[(__bridge id)kSecUseKeychain] = (__bridge id)keychain;
            status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
        } else {
            query[(__bridge id)kSecMatchSearchList] = @[ (__bridge id)keychain ];
            if ([mode isEqualToString:@"read"]) {
                query[(__bridge id)kSecReturnData] = @YES;
                CFTypeRef data = NULL;
                status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &data);
                if (data) CFRelease(data);
            } else if ([mode isEqualToString:@"item-delete"]) {
                status = SecItemDelete((__bridge CFDictionaryRef)query);
            } else if ([mode isEqualToString:@"ref-delete"]) {
                query[(__bridge id)kSecReturnRef] = @YES;
                CFTypeRef item = NULL;
                status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &item);
                if (status == errSecSuccess) status = SecKeychainItemDelete((SecKeychainItemRef)item);
                if (item) CFRelease(item);
            } else {
                return 2;
            }
        }
        printf("%s %d\n", argv[1], (int)status);
        return status == errSecSuccess ? 0 : 1;
    }
}
