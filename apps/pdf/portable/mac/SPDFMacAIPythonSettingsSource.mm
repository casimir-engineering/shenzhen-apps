#import "SPDFMacAIPythonSettingsSource.h"

#import "SPDFMacAIPythonRunner.h"
#import "SPDFMacAIPythonToolProvider.h"

// Settings' reason when the helper is not in the bundle: only a damaged or partial copy of the app lacks it.
static NSString* const kSPDFIncompleteApp =
    @"This copy of ShenzhenPDF is incomplete, so the assistant can’t run Python. Installing ShenzhenPDF again fixes "
    @"this.";

static void SPDFConfirmWithSheet(NSWindow* window, void (^answer)(BOOL install)) {
    NSAlert* alert = [NSAlert new];
    alert.messageText = SPDFMacAIPythonInstallTitle();
    alert.informativeText = SPDFMacAIPythonInstallBody();
    [alert addButtonWithTitle:@"Install"];
    [alert addButtonWithTitle:@"Cancel"];
    if (!window) { answer([alert runModal] == NSAlertFirstButtonReturn); return; }
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
        answer(response == NSAlertFirstButtonReturn);
    }];
}

@implementation SPDFMacAIPythonSettingsSource {
    id<SPDFMacAIPythonEnvironment> _environment;
    BOOL _helperPresent;
    NSString* _stage;   // the step an install started here is on, for the row while it runs
    NSString* _failure; // why the last install started here stopped, until the next one
}

+ (instancetype)sharedSource {
    static SPDFMacAIPythonSettingsSource* shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[self alloc] initWithEnvironment:SPDFMacAIPythonInstaller.sharedInstaller
                                     helperPresent:SPDFMacAIPythonHelperPath(NSBundle.mainBundle) != nil];
    });
    return shared;
}

- (instancetype)initWithEnvironment:(id<SPDFMacAIPythonEnvironment>)environment helperPresent:(BOOL)helperPresent {
    if (!(self = [super init])) return nil;
    _environment = environment;
    _helperPresent = helperPresent;
    return self;
}

// File checks only (the installer's marker and interpreter), since Settings asks every time it opens.
- (NSDictionary<NSString*, NSString*>*)pythonSandboxSettingsStatus {
    NSString* location = _environment.interpreterPath.stringByDeletingLastPathComponent
                             .stringByDeletingLastPathComponent; // <environment>/bin/python3
    if (!_helperPresent)
        return @{SPDFMacAIPythonStatusKey : SPDFMacAIPythonStatusUnavailable,
                 SPDFMacAIPythonDetailKey : kSPDFIncompleteApp};
    if (SPDFMacAIPythonSandboxRefused()) return @{SPDFMacAIPythonStatusKey : SPDFMacAIPythonStatusUnavailable};
    if (_environment.installing)
        return @{SPDFMacAIPythonStatusKey : SPDFMacAIPythonStatusInstalling, SPDFMacAIPythonLocationKey : location,
                 SPDFMacAIPythonDetailKey : _stage ?: @""};
    if (_environment.installed)
        return @{SPDFMacAIPythonStatusKey : SPDFMacAIPythonStatusReady, SPDFMacAIPythonLocationKey : location};
    return @{SPDFMacAIPythonStatusKey : SPDFMacAIPythonStatusNotInstalled, SPDFMacAIPythonLocationKey : location,
             SPDFMacAIPythonDownloadKey : SPDFMacAIPythonInstallSummary(), SPDFMacAIPythonDetailKey : _failure ?: @""};
}

- (void)installPythonSandboxForWindow:(NSWindow*)window update:(void (^)(NSDictionary<NSString*, NSString*>*))update {
    // Already there, or the chat's card is installing it: the row only needs to catch up.
    if (!_helperPresent || _environment.installing || _environment.installed) {
        update([self pythonSandboxSettingsStatus]);
        return;
    }
    __weak SPDFMacAIPythonSettingsSource* weakSelf = self;
    SPDFMacAIPythonInstallConfirmation confirm = self.confirmation ?: ^(NSWindow* sheetWindow, void (^reply)(BOOL)) {
        SPDFConfirmWithSheet(sheetWindow, reply);
    };
    confirm(window, ^(BOOL install) {
        SPDFMacAIPythonSettingsSource* owner = weakSelf;
        if (install) [owner installWithUpdate:update];
        else if (owner) update([owner pythonSandboxSettingsStatus]);
    });
}

- (void)installWithUpdate:(void (^)(NSDictionary<NSString*, NSString*>*))update {
    _stage = nil;
    _failure = nil;
    __weak SPDFMacAIPythonSettingsSource* weakSelf = self;
    [_environment installWithProgress:^(NSString* stage) {
        SPDFMacAIPythonSettingsSource* owner = weakSelf;
        // The last stage ("Installed") arrives just before the completion, which says Ready in its place.
        if (!owner || [stage isEqual:@"Installed"]) return;
        owner->_stage = [stage stringByAppendingString:@"…"];
        update([owner pythonSandboxSettingsStatus]);
    } completion:^(NSString* failure) {
        SPDFMacAIPythonSettingsSource* owner = weakSelf;
        if (!owner) return;
        owner->_stage = nil;
        owner->_failure = [failure copy];
        update([owner pythonSandboxSettingsStatus]);
    }];
    update([self pythonSandboxSettingsStatus]);
}

@end
