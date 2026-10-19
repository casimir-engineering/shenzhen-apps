// The Python sandbox helper (mac/python-sandbox/SPDFPythonSandbox.h), end to end: the real helper runs a real Python
// on this Mac in throwaway work directories. Every escape the plan names is attempted and must fail; computation and
// images must still work; the work directory must be gone after every run. Network attempts only ever target
// loopback listeners this suite opens, so even a broken sandbox would send nothing off the Mac.
//
// Usage: SPDFPythonSandboxTests <path to spdf-python-sandbox>
#import "SPDFPythonSandboxTestSupport.h"
#import "SPDFPythonSandboxUnitChecks.h"
#import "SPDFPythonSandboxRequestChecks.h"
#import "SPDFPythonSandboxSystemChecks.h"

int main(int argc, char** argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: %s <spdf-python-sandbox>\n", argv[0]); return 2; }
        NSString* helper = @(argv[1]);
        NSString* scratch = SandboxTemporaryDirectory(@"pysandbox");
        CheckInputNames();
        CheckHostileFiles(scratch);
        CheckMappedDisk(scratch);
        CheckSharedMemoryOwnership();
        CheckRefusedProfiles(helper, scratch);
        NSString* python = SandboxBasePython();
        if (!python) {
            puts("SPDFPythonSandboxTests: no Python 3 at /opt/homebrew, /usr/local or the Xcode tools, so the "
                 "sandboxed runs were skipped");
        } else {
            CheckProfile(python);
            SandboxSuite* suite = SandboxMakeSuite(helper, python, scratch);
            CheckComputation(suite);
            CheckEscapes(suite);
            CheckAppleEvents(suite);
            CheckProcessInformation(suite);
            CheckFileNames(suite);
            CheckSystemVolumes(suite);
            CheckSystemV(suite);
            CheckSharedMemoryCleanup(suite);
            CheckLimits(suite);
            CheckBoobyTraps(suite);
            CheckPreallocation(suite);
            CheckHiddenDisk(suite);
            CheckRequests(suite);
            CheckMatplotlib(suite);
            SandboxFreeSuite(suite);
        }
        [NSFileManager.defaultManager removeItemAtPath:scratch error:nil];
    }
    if (failures) { fprintf(stderr, "SPDFPythonSandboxTests: %d failures\n", failures); return 1; }
    puts("SPDFPythonSandboxTests passed");
    return 0;
}
