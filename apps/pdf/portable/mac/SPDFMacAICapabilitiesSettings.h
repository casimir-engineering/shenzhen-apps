#pragma once
// What the assistant may do, on the AI page of ShenzhenPDF's Settings window: document chat and automatic
// preparation (moved here from SPDFMacUnifiedSettings.mm), then the capabilities of ai-agent-capabilities.md: web
// search, helpers run in parallel (subagents) and the Python sandbox.
//
// Like the rest of the window the section only reads the state dictionary the host passes and reports changes
// through settingsChanged and actionHandler; it never reads files, the network or the Keychain. The switches use
// SPDFMacAISettings' own property names as state keys. The reader's side is SPDFMacAICapabilitiesSettingsIntegration.h.
#import "SPDFMacUnifiedSettings.h"

@class SPDFMacAISettings;

NS_ASSUME_NONNULL_BEGIN

// State keys, equal to SPDFMacAISettings' properties (web_search_enabled, python_enabled, subagents_enabled in
// ai-settings.yaml). Absent means on, the settings' default.
FOUNDATION_EXPORT NSString* const SPDFMacAIWebSearchEnabledKey;
FOUNDATION_EXPORT NSString* const SPDFMacAIPythonEnabledKey;
FOUNDATION_EXPORT NSString* const SPDFMacAISubagentsEnabledKey;

// The assistant's Python as Settings shows it. Status holds one of the four statuses below; without one the Python
// row is hidden, since there would be nothing to show or do. Location is the folder it is installed in; download is
// the sentence saying what installing fetches, from where and how much disk it keeps (the chat card's
// SPDFMacAIPythonInstallSummary when absent); detail is one whole sentence shown first under the status (why the
// last install stopped, the step an install is on, why Python cannot run here).
FOUNDATION_EXPORT NSString* const SPDFMacAIPythonStatusKey;
FOUNDATION_EXPORT NSString* const SPDFMacAIPythonLocationKey;
FOUNDATION_EXPORT NSString* const SPDFMacAIPythonDownloadKey;
FOUNDATION_EXPORT NSString* const SPDFMacAIPythonDetailKey;
FOUNDATION_EXPORT NSString* const SPDFMacAIPythonStatusNotInstalled;
FOUNDATION_EXPORT NSString* const SPDFMacAIPythonStatusInstalling;
FOUNDATION_EXPORT NSString* const SPDFMacAIPythonStatusReady;
FOUNDATION_EXPORT NSString* const SPDFMacAIPythonStatusUnavailable;
// actionHandler's action when the person presses Install…
FOUNDATION_EXPORT NSString* const SPDFMacAIPythonInstallAction;

// The Python side of Settings (ai-agent-capabilities.md § 4), implemented by SPDFMacAIPythonSettingsSource.h; the
// reader finds it as SPDFMacAICapabilitiesSettingsIntegration.h describes. Both methods run on the main thread.
@protocol SPDFMacAIPythonSandboxSettings <NSObject>
// What the Python row shows now, with the four keys above. Called every time Settings opens, so it may only look
// at files: never start Python, a download or a network request.
- (NSDictionary<NSString*, NSString*>*)pythonSandboxSettingsStatus;
// The person pressed Install…: ask for consent as the chat's first use does, install, and call update with the
// status after each change: installing, then ready, or not installed with a detail saying why it stopped.
- (void)installPythonSandboxForWindow:(NSWindow*)window
                               update:(void (^)(NSDictionary<NSString*, NSString*>* status))update;
@end

// The section's state for the host's Settings state: the switches from settings, then the Python status (every
// Python key, empty when unknown, so a later status replaces an earlier one's detail when the window merges it).
NSDictionary<NSString*, id>* SPDFMacAICapabilitiesState(SPDFMacAISettings* settings,
                                                       id<SPDFMacAIPythonSandboxSettings> _Nullable python);
// Copies the switches present in one settingsChanged dictionary onto settings, before the host saves them; other
// keys are left to the host. YES when it set one.
BOOL SPDFMacAICapabilitiesApply(SPDFMacAISettings* settings, NSDictionary* changes);
// YES when action is the section's (Install…): it is passed to python, whose updates reach controller.
BOOL SPDFMacAICapabilitiesPerformAction(NSString* action, SPDFMacUnifiedSettingsController* controller,
                                        id<SPDFMacAIPythonSandboxSettings> _Nullable python);
// Only what Settings can show from a Python status: every key above, a known status or "", strings or "".
NSDictionary<NSString*, NSString*>* SPDFMacAIPythonSettingsStatus(NSDictionary* _Nullable status);
// The Python row's words for a state, under the switch's explanation: the one-line status beside Install…
// ("Installed in ~/…" when ready), and the sentences beneath it.
NSString* SPDFMacAIPythonSettingsStatusLine(NSDictionary* state);
NSString* SPDFMacAIPythonSettingsDetail(NSDictionary* state);

// Called by SPDFMacUnifiedSettings.mm: -buildAI ends with the section (outside the setup wizard), and -updateState:
// passes every change so the switches and the Python row follow the host without rebuilding the page.
@interface SPDFMacUnifiedSettingsController (SPDFMacAICapabilities)
- (void)buildAICapabilities;
- (void)refreshAICapabilities:(NSDictionary*)changes;
@end

NS_ASSUME_NONNULL_END
