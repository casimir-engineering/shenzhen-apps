#import "SPDFMacAICredentials.h"
#import <objc/runtime.h>
@interface ShenzhenMacDelegate (WizardCredentialHost)
- (void)unifiedSettingsAction:(NSString*)action;
@end
@interface WizardCredentialProbe : ShenzhenMacDelegate @end
@implementation WizardCredentialProbe
- (void)configureAIAnalysis:(id)settings { (void)settings; }
- (void)applyUnifiedSettings:(NSDictionary*)changes { (void)changes; }
@end
static void CheckWizardCredentialPreservation(void) {
    // The acceptance main has already selected a temporary SPDF_STATE_DIR.
    Check([SPDFMacAISettings.defaultURL.path hasPrefix:NSTemporaryDirectory().stringByResolvingSymlinksInPath] ||
        [SPDFMacAISettings.defaultURL.path hasPrefix:NSTemporaryDirectory()],"wizard credential fixture is isolated");
    NSData* prior=[NSData dataWithContentsOfURL:SPDFMacAISettings.defaultURL];
    __block NSUInteger reads=0;__block NSString* key=nil;
    Method credential=class_getClassMethod(SPDFMacAICredentials.class,@selector(APIKeyWithError:));
    IMP originalCredential=method_getImplementation(credential);
    IMP injectedCredential=imp_implementationWithBlock(^NSString*(id receiver,NSError** error) {
        (void)receiver;reads++;
        if(error)*error=key ? nil : [NSError errorWithDomain:@"KeychainFixture" code:-25308 userInfo:nil];
        return key;
    });
    // Do not notify the user's running application from this headless fixture.
    Method broadcast=class_getInstanceMethod(NSDistributedNotificationCenter.class,
        @selector(postNotificationName:object:userInfo:deliverImmediately:));
    IMP originalBroadcast=method_getImplementation(broadcast);
    IMP suppressedBroadcast=imp_implementationWithBlock(^(id receiver,NSString* name,NSString* object,NSDictionary* info,BOOL now) {
        (void)receiver;(void)name;(void)object;(void)info;(void)now;
    });
    method_setImplementation(credential,injectedCredential);method_setImplementation(broadcast,suppressedBroadcast);
    @try {
        WizardCredentialProbe* reader=[WizardCredentialProbe new];
        for(NSUInteger scenario=0;scenario<3;scenario++) {
            SPDFMacAISettings* settings=[[SPDFMacAISettings alloc] initWithURL:SPDFMacAISettings.defaultURL];
            [settings load:nil];settings.connectionConfigured=scenario==0;settings.onboardingRevision=0;
            settings.automaticAnalysis=NO;Check([settings save:nil],"wizard fixture settings save");
            key=scenario==1 ? @"sk-or-v1-offline-wizard-fixture" : nil;reads=0;
            [reader unifiedSettingsAction:@"wizardDone"];
            SPDFMacAISettings* saved=[[SPDFMacAISettings alloc] initWithURL:SPDFMacAISettings.defaultURL];[saved load:nil];
            if(scenario==0)Check(saved.connectionConfigured && reads==0,
                "wizard Done preserves configured connection without a Keychain health check");
            else if(scenario==1)Check(saved.connectionConfigured && reads==1,
                "wizard Done adopts an available legacy credential only when unconfigured");
            else Check(!saved.connectionConfigured && reads==1,
                "wizard Done does not claim a connection when unconfigured credential access is denied");
            Check(saved.onboardingRevision==SPDFUnifiedSettingsExperienceVersion && saved.onboardingStep==0,
                "wizard completion still persists its setup revision");
        }
    } @finally {
        method_setImplementation(credential,originalCredential);method_setImplementation(broadcast,originalBroadcast);
        imp_removeBlock(injectedCredential);imp_removeBlock(suppressedBroadcast);
        if(prior)[prior writeToURL:SPDFMacAISettings.defaultURL atomically:YES];
        else [NSFileManager.defaultManager removeItemAtURL:SPDFMacAISettings.defaultURL error:nil];
    }
}
