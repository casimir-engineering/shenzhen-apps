#pragma once
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <LocalAuthentication/LocalAuthentication.h>
#include <mutex>

// LAContext covers data-protection items, but legacy login-Keychain ACLs can
// still display UI. Keep both policies; never relax an item's access control.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
inline void SPDFKeychainDisallowAuthenticationUI(NSMutableDictionary* query) {
    LAContext* context=[LAContext new]; context.interactionNotAllowed=YES;
    query[(__bridge id)kSecUseAuthenticationContext]=context;
    query[(__bridge id)kSecUseAuthenticationUI]=(__bridge id)kSecUseAuthenticationUIFail;
}

// The legacy switch is process-wide. One inline-function static mutex is shared
// across translation units so AI and Collection cannot restore UI under each
// other's operation. Construction does no Keychain work; failure is closed.
inline OSStatus SPDFKeychainWithInteractionPolicy(Boolean allowed, OSStatus (^operation)(void),
    OSStatus (*getAllowed)(Boolean*)=SecKeychainGetUserInteractionAllowed,
    OSStatus (*setAllowed)(Boolean)=SecKeychainSetUserInteractionAllowed) {
    static std::recursive_mutex mutex;
    std::lock_guard<std::recursive_mutex> lock(mutex);
    Boolean previous=false;
    OSStatus status=getAllowed(&previous);
    if(status!=errSecSuccess)return status;
    status=setAllowed(allowed);
    if(status!=errSecSuccess)return status;
    @try { status=operation(); }
    @finally {
        OSStatus restored=setAllowed(previous);
        if(status==errSecSuccess && restored!=errSecSuccess)status=restored;
    }
    return status;
}
// Existing background paths always use false. Only an explicit authorization
// button may opt into true; it shares the lock so concurrent readers cannot
// change the process-wide policy while the system authorization dialog is open.
inline OSStatus SPDFKeychainWithoutInteraction(OSStatus (^operation)(void),
    OSStatus (*getAllowed)(Boolean*)=SecKeychainGetUserInteractionAllowed,
    OSStatus (*setAllowed)(Boolean)=SecKeychainSetUserInteractionAllowed) {
    return SPDFKeychainWithInteractionPolicy(false,operation,getAllowed,setAllowed);
}
inline OSStatus SPDFKeychainForExplicitAuthorization(OSStatus (^operation)(void),
    OSStatus (*getAllowed)(Boolean*)=SecKeychainGetUserInteractionAllowed,
    OSStatus (*setAllowed)(Boolean)=SecKeychainSetUserInteractionAllowed) {
    return SPDFKeychainWithInteractionPolicy(true,operation,getAllowed,setAllowed);
}
inline void SPDFKeychainAllowAuthenticationUIForExplicitAction(NSMutableDictionary* query) {
    LAContext* context=[LAContext new];context.interactionNotAllowed=NO;
    query[(__bridge id)kSecUseAuthenticationContext]=context;
    query[(__bridge id)kSecUseAuthenticationUI]=(__bridge id)kSecUseAuthenticationUIAllow;
    query[(__bridge id)kSecUseOperationPrompt]=@"Authorize ShenzhenPDF to use your saved OpenRouter key.";
}
#pragma clang diagnostic pop
