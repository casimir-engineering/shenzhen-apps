#import "SPDFMacFriendsSigning.h"
#import <Security/Security.h>
#include <bsm/libbsm.h>

NSString* SPDFMacFriendsOwnTeamIdentifier(void) {
    SecCodeRef me = NULL;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &me) != errSecSuccess || !me) return nil;
    SecStaticCodeRef code = NULL;
    OSStatus status = SecCodeCopyStaticCode(me, kSecCSDefaultFlags, &code);
    CFRelease(me);
    if (status != errSecSuccess || !code) return nil;
    CFDictionaryRef info = NULL;
    status = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info);
    CFRelease(code);
    if (status != errSecSuccess || !info) return nil;
    NSDictionary* signing = CFBridgingRelease(info);
    id team = signing[(__bridge NSString*)kSecCodeInfoTeamIdentifier];
    // Ad-hoc and linker signatures carry no team; only a real Team ID turns the check on.
    return [team isKindOfClass:NSString.class] && [team length] ? team : nil;
}

bool SPDFMacFriendsVerifyPeer(void* context, const void* auditToken, size_t length, const char* requirement) {
    (void)context;
    if (!auditToken || length != sizeof(audit_token_t) || !requirement || !requirement[0]) return false;
    NSString* text = [NSString stringWithUTF8String:requirement];
    if (!text) return false;
    NSDictionary* attributes = @{(__bridge NSString*)kSecGuestAttributeAudit : [NSData dataWithBytes:auditToken
                                                                                              length:length]};
    SecCodeRef code = NULL;
    // The audit token, unlike a pid, names exactly the process that holds the socket, even if it has since exited.
    if (SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)attributes, kSecCSDefaultFlags, &code) !=
            errSecSuccess || !code)
        return false;
    SecRequirementRef required = NULL;
    OSStatus status = SecRequirementCreateWithString((__bridge CFStringRef)text, kSecCSDefaultFlags, &required);
    if (status != errSecSuccess || !required) {
        CFRelease(code);
        return false;
    }
    status = SecCodeCheckValidity(code, kSecCSDefaultFlags, required);
    CFRelease(required);
    CFRelease(code);
    return status == errSecSuccess;
}

BOOL SPDFMacFriendsApplySigningPolicy(NSString* (^teamIdentifier)(void), SPDFMacFriendsSetSigningPolicy setPolicy) {
    NSString* team = teamIdentifier ? teamIdentifier() : nil;
    if (!team.length || !setPolicy) return NO;
    // A malformed team makes the library refuse every helper rather than fall back to the uid check, so even a
    // failing status leaves a signed app's policy in force; there is nothing else to do with it here.
    (void)setPolicy(team.UTF8String, SPDFMacFriendsVerifyPeer);
    return YES;
}
