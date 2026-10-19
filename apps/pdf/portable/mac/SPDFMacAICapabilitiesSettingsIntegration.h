#pragma once
// The reader's side of Settings' AI capabilities section (SPDFMacAICapabilitiesSettings.h), called by
// SPDFMacAISettingsIntegration.mm: the section's state, saving its switches, and Install… for the Python sandbox.
//
// The Python row's status and Install… come from aiPythonSandboxSettings, which SPDFMacAIPythonIntegration.mm
// implements with the assistant's own Python (SPDFMacAIPythonSettingsSource.h).
#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacAICapabilitiesSettings.h"

@class SPDFMacAISettings;

NS_ASSUME_NONNULL_BEGIN

@interface ShenzhenMacDelegate (SPDFMacAICapabilitiesSettings)
// Added to the Settings state each time it is read: the switches as saved, and the Python sandbox's status.
- (NSDictionary*)aiCapabilitiesSettingsState:(SPDFMacAISettings*)settings;
// YES when action was the section's own (Install…) and is handled.
- (BOOL)performAICapabilitiesSettingsAction:(NSString*)action controller:(SPDFMacUnifiedSettingsController*)controller;
@end

// Implemented in SPDFMacAIPythonIntegration.mm, as above.
@interface ShenzhenMacDelegate (SPDFMacAIPythonSandboxSettingsSource)
- (nullable id<SPDFMacAIPythonSandboxSettings>)aiPythonSandboxSettings;
@end

NS_ASSUME_NONNULL_END
