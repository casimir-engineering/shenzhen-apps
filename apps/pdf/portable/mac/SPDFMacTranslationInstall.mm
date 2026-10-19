#import "SPDFMacTranslationInstall.h"

#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacToolEnvironment.h"

// Defined in ShenzhenPDFMac.mm.
@interface ShenzhenMacDelegate (SPDFMacTranslationInstallPrivate)
- (NSString*)argosInstallScript;
- (NSString*)argosToolPath;
- (void)updateTranslateCommandEnablement;
- (void)appendTranslationInstallLog:(NSString*)text;
- (void)runTranslationInstallTask:(NSTask*)task
                            title:(NSString*)title
                          heading:(NSString*)heading
                       initialLog:(NSString*)initialLog
                       completion:(void (^)(NSTask* finishedTask, NSString* output))completion;
- (void)runSelectionTranslationWithText:(NSString*)text
                         sourceLanguage:(NSString*)sourceLanguage
                         targetLanguage:(NSString*)targetLanguage
                       offeredInstaller:(BOOL)offeredInstaller;
@end

// Offering the Argos install when a selection cannot be translated yet, and
// resuming the translation when it finishes.
//
// The offer is made for two reasons now: Argos is not on the machine at all, or
// it is not in the app's own Python environment. Nothing is ever installed
// globally (see SPDFMacToolEnvironment.h), so the second is as much a reason as
// the first.

@implementation ShenzhenMacDelegate (SPDFMacTranslationInstall)

- (void)promptToInstallArgosAndContinueSelectionText:(NSString*)text
                                      sourceLanguage:(NSString*)sourceLanguage
                                      targetLanguage:(NSString*)targetLanguage {
    if (_translationInstallRunning) return;

    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Install Argos Translate?";
    alert.informativeText = @"Shenzhen PDF uses Argos Translate locally for offline selection translation. "
                            @"Install it, then continue translation.";
    [alert addButtonWithTitle:@"Install"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.alertStyle = NSAlertStyleInformational;
    if ([alert runModal] != NSAlertFirstButtonReturn) {
        _selectionTranslationStatusLabel.stringValue = @"Argos Translate is required for local translation.";
        return;
    }

    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
    // Not `-lc`: a login shell would source the dotfiles whose conda/pyenv hook
    // is exactly what made this install differ between machines.
    task.arguments = @[ @"-c", [self argosInstallScript] ];
    task.environment = [self taskEnvironmentWithToolPaths:@[]];
    spdf_mac_tool_note_install_attempt();

    __weak ShenzhenMacDelegate* weakSelf = self;
    [self runTranslationInstallTask:task
                              title:@"Installing Translation Support"
                            heading:@"Installing Argos Translate"
                         initialLog:@"Preparing Argos Translate installer...\n"
                         completion:^(NSTask* finishedTask, NSString* output) {
                           (void)output;
                           ShenzhenMacDelegate* strongSelf = weakSelf;
                           if (!strongSelf) return;
                           strongSelf->_translationInstallRunning = NO;
                           [strongSelf updateTranslateCommandEnablement];
                           if (finishedTask.terminationStatus == 0 && [strongSelf argosToolPath].length) {
                               [strongSelf appendTranslationInstallLog:@"\nArgos Translate installed.\n"];
                               [strongSelf->_translationInstallPanel orderOut:nil];
                               [strongSelf runSelectionTranslationWithText:text
                                                            sourceLanguage:sourceLanguage
                                                            targetLanguage:targetLanguage
                                                          offeredInstaller:NO];
                           } else {
                               [strongSelf appendTranslationInstallLog:
                                               @"\nArgos Translate installation failed. The log above can be selected "
                                               @"and copied.\n"];
                               strongSelf->_selectionTranslationStatusLabel.stringValue = @"Argos installation failed.";
                           }
                         }];
}


@end
