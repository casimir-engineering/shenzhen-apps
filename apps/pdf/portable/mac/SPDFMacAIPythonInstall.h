#pragma once
// The assistant's own Python (portable/docs/plans/ai-agent-capabilities.md § 4): a virtual environment under
// Application Support with numpy, pandas and matplotlib. It is installed only when the person presses Install on the
// card run_python shows (SPDFMacAIPythonToolProvider.h), never globally, and the installer inherits none of the app's
// interpreter variables (spdf_mac_tool_environment, SPDFMacToolEnvironment.h). The code itself always runs through
// the sandbox helper (mac/python-sandbox/SPDFPythonSandbox.h), never from here.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol SPDFMacAIPythonEnvironment <NSObject>
// The interpreter the sandbox helper runs: <environment>/bin/python3.
@property(nonatomic, readonly, copy) NSString* interpreterPath;
// The installer finished and checked the packages import (it writes a marker last), and the interpreter is there.
@property(nonatomic, readonly, getter=isInstalled) BOOL installed;
@property(nonatomic, readonly, getter=isInstalling) BOOL installing;
// Main thread. `progress` receives short stage lines for the person ("Downloading numpy, pandas and matplotlib");
// `completion` runs once with nil on success or the reason it failed, written for the person.
- (void)installWithProgress:(void (^)(NSString* stage))progress
                 completion:(void (^)(NSString* _Nullable failure))completion;
// The interpreter could not start although the environment looked installed (Homebrew removed its Python, say):
// forget the installation so the next run offers Install again.
- (void)forgetInstallation;
@end

// What installing fetches, from where, and the disk it keeps, in the words the chat's install card and Settings
// both show: the person reads it just before pressing Install, in either place. Inline so Settings' own files can
// show it without linking the installer.
static inline NSString* SPDFMacAIPythonInstallSummary(void) {
    return @"Installing downloads about 40 MB from the Python Package Index (pypi.org) once and keeps it in "
           @"ShenzhenPDF’s folder, using about 200 MB of disk.";
}
// The consent itself, the chat's card and Settings' sheet alike: what it is for, what it fetches, what it can reach.
static inline NSString* SPDFMacAIPythonInstallTitle(void) { return @"Install Python for the assistant?"; }
static inline NSString* SPDFMacAIPythonInstallBody(void) {
    return [NSString stringWithFormat:@"To run code for you, the assistant needs its own copy of Python with numpy, "
                                      @"pandas and matplotlib. %@ Code the assistant runs can’t use the network or "
                                      @"open your files.", SPDFMacAIPythonInstallSummary()];
}

// ~/Library/Application Support/ShenzhenPDF/assistant-python: separate from the OCR tools' environment (python/), so
// installing or upgrading either cannot break the other.
NSString* SPDFMacAIPythonDefaultDirectory(void);

// The installer for `directory`, run by /bin/bash without a login shell (a login shell's dotfiles choose a
// different Python on every machine). A Python 3.9+ from a fixed path, a fresh venv, wheels only (no compiler ever
// runs), an import check, then the marker. Lines starting "## " are stages to show; "!! " is why it stopped.
NSString* SPDFMacAIPythonInstallScript(NSString* directory);

@interface SPDFMacAIPythonInstaller : NSObject <SPDFMacAIPythonEnvironment>
// The default directory, shared by every chat in this process; a lock file keeps two windows (two processes) from
// installing at once.
+ (instancetype)sharedInstaller;
// `script` nil runs SPDFMacAIPythonInstallScript(directory); tests pass a script that installs nothing.
- (instancetype)initWithDirectory:(NSString*)directory script:(nullable NSString*)script NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly, copy) NSString* directory;
@end

NS_ASSUME_NONNULL_END
