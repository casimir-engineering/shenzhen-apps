// run_python in the reader (mac/SPDFMacAIPythonToolProvider.h): offering, consent before installing, arguments,
// results in the chat, Friends-scoped requests and what their chat file keeps, failures, Stop, Settings' Python row;
// then the real runner and helper on this Mac with a throwaway work directory and no network. No Keychain, no
// provider, no app, and nothing is ever installed (the installer runs stand-in scripts in throwaway folders).
//
// Usage: SPDFMacAIPythonTests <path to spdf-python-sandbox>
#import <Cocoa/Cocoa.h>
#import "SPDFMacAIPythonProviderChecks.h"
#import "SPDFMacAIPythonRunChecks.h"
#import "SPDFMacAIPythonSettingsChecks.h"
#import "SPDFMacAIPythonStorageChecks.h"
#import "SPDFMacAIPythonDocumentChecks.h"

int main(int argc, char** argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: %s <spdf-python-sandbox>\n", argv[0]); return 2; }
        NSString* scratch = SandboxTemporaryDirectory(@"aipython");
        gImages = [scratch stringByAppendingPathComponent:@"images"];
        [NSFileManager.defaultManager createDirectoryAtPath:gImages withIntermediateDirectories:YES attributes:nil
                                                      error:nil];
        CheckOffering();
        CheckConsent();
        CheckArguments();
        CheckPresentation();
        CheckFriendsSavedChat();
        CheckSettingsSource(scratch);
        CheckCardAfterSettingsInstall();
        CheckSettingsHook();
        CheckFailures();
        CheckSettingsAfterRefusal(scratch);
        CheckInstaller(scratch);
        CheckHelperPathAndTables(scratch);
        CheckDocumentArguments();
        CheckGrantPaths(scratch);
        CheckSessionGrants(scratch);
        NSString* python = SandboxBasePython();
        if (python) CheckRealRunner(@(argv[1]), python);
        if (python) CheckDocumentRuns(@(argv[1]), python, scratch);
        else puts("SPDFMacAIPythonTests: no Python 3 at /opt/homebrew, /usr/local or the Xcode tools, so the real "
                  "runner check was skipped");
        [NSFileManager.defaultManager removeItemAtPath:scratch error:nil];
    }
    if (failures) { fprintf(stderr, "SPDFMacAIPythonTests: %d failures\n", failures); return 1; }
    puts("SPDFMacAIPythonTests passed");
    return 0;
}
