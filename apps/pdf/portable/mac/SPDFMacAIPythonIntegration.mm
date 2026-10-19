// The assistant's Python in the reader. run_python joins the AI chat's tool registry (SPDFMacAIToolProvider.h § 2):
// SPDFMacAIIntegration finds aiToolProviderPython by its aiToolProvider prefix when the chat is first used, never at
// launch. Settings' AI page asks aiPythonSandboxSettings for its Python row each time it opens
// (SPDFMacAICapabilitiesSettingsIntegration.h). Neither installs or runs Python: only a run or an Install does.
#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacAICapabilitiesSettingsIntegration.h"
#import "SPDFMacAIPythonSettingsSource.h"
#import "SPDFMacAIPythonToolProvider.h"

@implementation ShenzhenMacDelegate (SPDFMacAIPythonTools)

- (id<SPDFMacAIToolProvider>)aiToolProviderPython {
    NSString* helper = SPDFMacAIPythonHelperPath(NSBundle.mainBundle);
    if (!helper) return nil; // a build without the helper (the headless suites) has no Python tool
    return [[SPDFMacAIPythonToolProvider alloc] initWithRunner:[[SPDFMacAIPythonSandboxRunner alloc]
                                                                   initWithHelperPath:helper]
                                                   environment:SPDFMacAIPythonInstaller.sharedInstaller];
}

@end

@implementation ShenzhenMacDelegate (SPDFMacAIPythonSandboxSettingsSource)

// The shared installer's status, so Settings and the chat's install card always agree on what is installed.
- (id<SPDFMacAIPythonSandboxSettings>)aiPythonSandboxSettings {
    return SPDFMacAIPythonSettingsSource.sharedSource;
}

@end
