#pragma once
#import "SPDFMacKeychainNoninteractive.h"
#include <atomic>
#include <unistd.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static BOOL NoninteractiveQuery(NSDictionary* query) {
    return [(LAContext*)query[(__bridge id)kSecUseAuthenticationContext] interactionNotAllowed] &&
        [query[(__bridge id)kSecUseAuthenticationUI] isEqual:(__bridge id)kSecUseAuthenticationUIFail];
}
static inline BOOL ExplicitAuthorizationQuery(NSDictionary* query) {
    return ![(LAContext*)query[(__bridge id)kSecUseAuthenticationContext] interactionNotAllowed] &&
        [query[(__bridge id)kSecUseAuthenticationUI] isEqual:(__bridge id)kSecUseAuthenticationUIAllow];
}
static BOOL SystemInteractionGuardWorks(void) {
    Boolean before=false,after=false;
    if(SecKeychainGetUserInteractionAllowed(&before)!=errSecSuccess)return NO;
    OSStatus status=SPDFKeychainWithoutInteraction(^OSStatus {
        Boolean during=true;OSStatus result=SecKeychainGetUserInteractionAllowed(&during);
        return result!=errSecSuccess ? result : during ? errSecInteractionNotAllowed : errSecSuccess;
    });
    return status==errSecSuccess && SecKeychainGetUserInteractionAllowed(&after)==errSecSuccess && before==after;
}
#pragma clang diagnostic pop

static Boolean testInteractionAllowed=true;
static OSStatus testGetFailure=errSecSuccess,testSetFailure=errSecSuccess;
static NSInteger testInteractionReads=0,testInteractionWrites=0;
static OSStatus TestGetInteraction(Boolean* allowed) {
    testInteractionReads++; if(testGetFailure)return testGetFailure;
    *allowed=testInteractionAllowed;return errSecSuccess;
}
static OSStatus TestSetInteraction(Boolean allowed) {
    testInteractionWrites++;if(testSetFailure)return testSetFailure;
    testInteractionAllowed=allowed;return errSecSuccess;
}
static void CheckNoninteractiveGuard(void (^check)(BOOL,NSString*)) {
    // Only this test process's interaction flag is touched; no credential is queried.
    check(SystemInteractionGuardWorks(),@"real legacy interaction guard disables and restores UI without accessing credentials");
    __block NSInteger operations=0;
    OSStatus (^operation)(void)=^OSStatus {operations++;return testInteractionAllowed ? errSecInternalComponent : errSecSuccess;};
    OSStatus status=SPDFKeychainWithoutInteraction(operation,TestGetInteraction,TestSetInteraction);
    check(status==errSecSuccess && operations==1 && testInteractionAllowed &&
        testInteractionReads==1 && testInteractionWrites==2,@"legacy guard disables UI only for its operation then restores it");
    testInteractionAllowed=false;
    status=SPDFKeychainWithoutInteraction(operation,TestGetInteraction,TestSetInteraction);
    check(status==errSecSuccess && !testInteractionAllowed,@"legacy guard preserves preexisting noninteractive mode");
    testInteractionAllowed=true;
    status=SPDFKeychainWithoutInteraction(^OSStatus { return errSecAuthFailed; },TestGetInteraction,TestSetInteraction);
    check(status==errSecAuthFailed && testInteractionAllowed,@"legacy denied access returns error without losing previous UI state");
    testGetFailure=errSecNotAvailable;NSInteger before=operations,writes=testInteractionWrites;
    status=SPDFKeychainWithoutInteraction(operation,TestGetInteraction,TestSetInteraction);
    check(status==errSecNotAvailable && operations==before && writes==testInteractionWrites,@"unknown legacy UI state fails closed");
    testGetFailure=errSecSuccess;testSetFailure=errSecInteractionNotAllowed;
    status=SPDFKeychainWithoutInteraction(operation,TestGetInteraction,TestSetInteraction);
    check(status==errSecInteractionNotAllowed && operations==before,@"failure to disable legacy UI never executes a credential operation");
    testSetFailure=errSecSuccess;
    @try {
        SPDFKeychainWithoutInteraction(^OSStatus { @throw [NSException exceptionWithName:@"fixture" reason:nil userInfo:nil]; },TestGetInteraction,TestSetInteraction);
    } @catch(NSException* exception) { (void)exception; }
    check(testInteractionAllowed,@"legacy guard restores prior UI state after an exception");
    status=SPDFKeychainWithoutInteraction(^OSStatus {
        return SPDFKeychainWithoutInteraction(operation,TestGetInteraction,TestSetInteraction);
    },TestGetInteraction,TestSetInteraction);
    check(status==errSecSuccess && testInteractionAllowed,@"nested credential operations remain noninteractive");
    testInteractionAllowed=false;
    status=SPDFKeychainForExplicitAuthorization(^OSStatus {
        if(!testInteractionAllowed)return errSecInternalComponent;
        OSStatus nested=SPDFKeychainWithoutInteraction(operation,TestGetInteraction,TestSetInteraction);
        return nested==errSecSuccess && testInteractionAllowed ? errSecSuccess : errSecInternalComponent;
    },TestGetInteraction,TestSetInteraction);
    check(status==errSecSuccess && !testInteractionAllowed,@"explicit authorization enables UI only during its call and restores the previous policy");
    testInteractionAllowed=true;
    std::atomic<int> active{0},overlap{0};auto activePtr=&active,overlapPtr=&overlap;
    dispatch_apply(24,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^(size_t index) {
        (void)index;
        SPDFKeychainWithoutInteraction(^OSStatus {
            if(activePtr->fetch_add(1)!=0 || testInteractionAllowed)overlapPtr->fetch_add(1);
            usleep(1000);activePtr->fetch_sub(1);return errSecSuccess;
        },TestGetInteraction,TestSetInteraction);
    });
    check(overlap.load()==0 && testInteractionAllowed,@"concurrent credential operations serialize the process-wide legacy UI switch");
    dispatch_apply(24,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^(size_t index) {
        BOOL interactive=index%2;
        OSStatus (^body)(void)=^OSStatus {
            if(activePtr->fetch_add(1)!=0 || testInteractionAllowed!=interactive)overlapPtr->fetch_add(1);
            usleep(1000);activePtr->fetch_sub(1);return errSecSuccess;
        };
        if(interactive)SPDFKeychainForExplicitAuthorization(body,TestGetInteraction,TestSetInteraction);
        else SPDFKeychainWithoutInteraction(body,TestGetInteraction,TestSetInteraction);
    });
    check(overlap.load()==0 && testInteractionAllowed,@"explicit authorization and background access share one serialized interaction policy");
}
