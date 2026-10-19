#pragma once
#import <Cocoa/Cocoa.h>

// No storage, networking or Keychain work occurs during construction. The host owns
// persistence and credentials; secrets never enter the settings dictionary.
@interface SPDFMacUnifiedSettingsController : NSWindowController <NSWindowDelegate, NSTextFieldDelegate, NSSearchFieldDelegate>
@property(nonatomic, copy) void (^settingsChanged)(NSDictionary* changes);
@property(nonatomic, copy) void (^actionHandler)(NSString* action);
@property(nonatomic, copy) void (^credentialHandler)(NSString* secret);
- (instancetype)initWithState:(NSDictionary*)state;
- (void)updateState:(NSDictionary*)state;
- (void)selectSection:(NSString*)section;
- (void)showSetupWizard;
- (void)showSettings;
@property(nonatomic, readonly) NSInteger wizardStep;
- (void)showForWindow:(NSWindow*)parent;
@end

// Increment only when a release introduces an experience every reader must discover.
extern const NSInteger SPDFUnifiedSettingsExperienceVersion;
BOOL SPDFUnifiedSettingsShouldPresent(NSDictionary* settings, BOOL primaryLaunch, BOOL detached);
