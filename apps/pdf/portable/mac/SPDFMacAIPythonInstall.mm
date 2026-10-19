#import "SPDFMacAIPythonInstall.h"

#import "SPDFMacToolEnvironment.h"

#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString* const kSPDFReadyMarker = @".shenzhenpdf-ready";

NSString* SPDFMacAIPythonDefaultDirectory(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Application Support/ShenzhenPDF/assistant-python"];
}

static NSString* SPDFShellQuote(NSString* text) {
    return [NSString stringWithFormat:@"'%@'", [text stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

NSString* SPDFMacAIPythonInstallScript(NSString* directory) {
    NSString* pip =
        @"\"$VENV/bin/python3\" -I -m pip install --disable-pip-version-check --no-input --only-binary=:all:";
    return [NSString stringWithFormat:
        @"set -u\n"
         "fail() { echo \"!! $1\"; exit 1; }\n"
         "VENV=%@\n"
         // The folder is removed before each install; never let a wrong path make that anything but ours.
         "case \"$VENV\" in /*/assistant-python) ;; *) fail 'The install folder is not the assistant one.' ;; esac\n"
         // Fixed paths, never `command -v python3`: that is whichever Python a shell profile put first. 3.9 is the
         // oldest the packages still ship wheels for; the Xcode tools' /usr/bin/python3 is 3.9.
         "PY=''\n"
         "for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do\n"
         "  if [ -x \"$candidate\" ] && \"$candidate\" -I -c 'import sys, venv, ensurepip; "
         "sys.exit(sys.version_info < (3, 9))' >/dev/null 2>&1; then PY=\"$candidate\"; break; fi\n"
         "done\n"
         "[ -n \"$PY\" ] || fail 'No Python 3.9 or later was found. Install Python 3 with Homebrew or the Xcode "
         "command line tools, then try again.'\n"
         "echo '## Creating the Python environment'\n"
         "rm -rf \"$VENV\"\n"
         "\"$PY\" -I -m venv \"$VENV\" || fail 'Could not create the Python environment.'\n"
         "echo '## Downloading numpy, pandas and matplotlib'\n"
         // A newer pip only helps; the one ensurepip bundled can install the wheels if this fails.
         "%@ --upgrade pip >/dev/null 2>&1 || true\n"
         "%@ numpy pandas matplotlib || fail 'Could not download numpy, pandas and matplotlib. Check the internet "
         "connection, then try again.'\n"
         "echo '## Checking the installation'\n"
         // Also builds matplotlib's font list, which the sandbox copies into each run rather than rebuilding it.
         "MPLBACKEND=Agg MPLCONFIGDIR=\"$VENV/.matplotlib\" \"$VENV/bin/python3\" -I -c "
         "'import numpy, pandas, matplotlib.pyplot' || fail 'The downloaded packages did not load. Try again.'\n"
         "touch \"$VENV/%@\" || fail 'Could not finish the installation.'\n"
         "echo '## Installed'\n",
        SPDFShellQuote(directory), pip, pip, kSPDFReadyMarker];
}

@implementation SPDFMacAIPythonInstaller {
    NSString* _script;
    NSTask* _task;
    int _lock;
}

+ (instancetype)sharedInstaller {
    static SPDFMacAIPythonInstaller* shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[self alloc] initWithDirectory:SPDFMacAIPythonDefaultDirectory() script:nil]; });
    return shared;
}

- (instancetype)initWithDirectory:(NSString*)directory script:(NSString*)script {
    if (!(self = [super init])) return nil;
    _directory = [directory copy];
    _script = [script copy];
    _lock = -1;
    return self;
}

- (NSString*)interpreterPath { return [_directory stringByAppendingPathComponent:@"bin/python3"]; }

- (BOOL)isInstalled {
    struct stat info;
    NSString* marker = [_directory stringByAppendingPathComponent:kSPDFReadyMarker];
    return lstat(marker.fileSystemRepresentation, &info) == 0 && S_ISREG(info.st_mode) &&
           access(self.interpreterPath.fileSystemRepresentation, X_OK) == 0;
}

- (BOOL)isInstalling { return _task != nil; }

- (void)forgetInstallation {
    if (!_task) unlink([_directory stringByAppendingPathComponent:kSPDFReadyMarker].fileSystemRepresentation);
}

// Held for the whole install. Another window is another process, and two installers removing and rebuilding one
// folder would each break the other's environment.
- (BOOL)takeLock {
    NSString* parent = _directory.stringByDeletingLastPathComponent;
    [NSFileManager.defaultManager createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil
                                                  error:nil];
    NSString* path = [_directory stringByAppendingString:@".lock"];
    _lock = open(path.fileSystemRepresentation, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (_lock >= 0 && flock(_lock, LOCK_EX | LOCK_NB) == 0) return YES;
    if (_lock >= 0) close(_lock);
    _lock = -1;
    return NO;
}

- (void)installWithProgress:(void (^)(NSString*))progress completion:(void (^)(NSString*))completion {
    if (_task) { completion(@"Python is already being installed."); return; }
    if (![self takeLock]) {
        completion(@"Python is being installed in another ShenzhenPDF window. Try again when it finishes.");
        return;
    }
    NSTask* task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
    task.arguments = @[ @"-c", _script ?: SPDFMacAIPythonInstallScript(_directory) ];
    // pip reads config files from the home folder and /Library unless told not to; the person's mirrors or
    // --user settings must not decide what this environment contains.
    task.environment = spdf_mac_tool_environment(NSProcessInfo.processInfo.environment, @[], @{
        @"PIP_CONFIG_FILE" : @"/dev/null", @"PIP_DISABLE_PIP_VERSION_CHECK" : @"1", @"PIP_NO_INPUT" : @"1"});
    NSPipe* output = [NSPipe pipe];
    task.standardOutput = output;
    task.standardError = output;
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    __block NSString* failure = nil;
    NSMutableString* pending = [NSMutableString string];
    void (^line)(NSString*) = ^(NSString* text) {
        if ([text hasPrefix:@"## "]) progress([text substringFromIndex:3]);
        else if ([text hasPrefix:@"!! "]) failure = [text substringFromIndex:3];
    };
    NSError* error = nil;
    if (![task launchAndReturnError:&error]) {
        close(_lock);
        _lock = -1;
        completion(@"The installer could not start.");
        return;
    }
    _task = task;
    // One reader, in order: every line reaches the main queue before the completion that follows the last one.
    NSFileHandle* reader = output.fileHandleForReading;
    __weak SPDFMacAIPythonInstaller* weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (NSData* data = reader.availableData; data.length; data = reader.availableData) {
            // Latin-1 when a chunk ends mid-character: the "## " and "!! " lines are ASCII either way.
            NSString* text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
            dispatch_async(dispatch_get_main_queue(), ^{
                [pending appendString:text];
                NSRange end;
                while ((end = [pending rangeOfString:@"\n"]).location != NSNotFound) {
                    line([pending substringToIndex:end.location]);
                    [pending deleteCharactersInRange:NSMakeRange(0, end.location + 1)];
                }
            });
        }
        [task waitUntilExit];
        int status = task.terminationStatus;
        dispatch_async(dispatch_get_main_queue(), ^{
            SPDFMacAIPythonInstaller* owner = weakSelf;
            if (pending.length) line(pending.copy);
            if (owner) {
                owner->_task = nil;
                if (owner->_lock >= 0) close(owner->_lock);
                owner->_lock = -1;
            }
            if (status == 0 && owner.installed) completion(nil);
            else completion(failure ?: @"The installation did not finish. Try again.");
        });
    });
}

@end
