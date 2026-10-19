// SPDFMacAICapabilitiesSettingsIntegration.h. The work is in SPDFMacAICapabilitiesSettings.mm, where it can be
// tested without the reader; this file only passes it the Python row's source.

#import "SPDFMacAICapabilitiesSettingsIntegration.h"

@implementation ShenzhenMacDelegate (SPDFMacAICapabilitiesSettings)
- (NSDictionary*)aiCapabilitiesSettingsState:(SPDFMacAISettings*)settings {
    return SPDFMacAICapabilitiesState(settings, [self aiPythonSandboxSettings]);
}
- (BOOL)performAICapabilitiesSettingsAction:(NSString*)action controller:(SPDFMacUnifiedSettingsController*)controller {
    return SPDFMacAICapabilitiesPerformAction(action, controller, [self aiPythonSandboxSettings]);
}
@end
