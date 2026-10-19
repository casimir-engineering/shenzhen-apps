#pragma once
// The Python row of Settings' AI page (SPDFMacAICapabilitiesSettings.h), backed by the assistant's own Python
// (SPDFMacAIPythonInstall.h): whether it is installed, being installed, ready or unavailable on this Mac, and
// Install… with the same consent and progress as the chat's install card. ShenzhenMacDelegate hands Settings the
// shared one (SPDFMacAIPythonIntegration.mm); the suite builds its own around a throwaway folder.
#import <Cocoa/Cocoa.h>

#import "SPDFMacAICapabilitiesSettings.h"
#import "SPDFMacAIPythonInstall.h"

NS_ASSUME_NONNULL_BEGIN

// Asks the person before anything is downloaded, then calls back on the main thread with their answer.
typedef void (^SPDFMacAIPythonInstallConfirmation)(NSWindow* _Nullable window, void (^answer)(BOOL install));

@interface SPDFMacAIPythonSettingsSource : NSObject <SPDFMacAIPythonSandboxSettings>
// The app's: the shared installer, and whether the sandbox helper is in this copy of ShenzhenPDF.
+ (instancetype)sharedSource;
- (instancetype)initWithEnvironment:(id<SPDFMacAIPythonEnvironment>)environment
                      helperPresent:(BOOL)helperPresent NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// A sheet on the Settings window with the chat card's title and body (SPDFMacAIPythonInstall.h), Install and Cancel;
// the suite answers for the person instead.
@property(nonatomic, copy) SPDFMacAIPythonInstallConfirmation confirmation;
@end

NS_ASSUME_NONNULL_END
