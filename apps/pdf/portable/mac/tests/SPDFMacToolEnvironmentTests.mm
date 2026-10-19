// The environment ocrmypdf and Argos Translate are launched in.
//
// Both are Python programs, and both broke on machines set up with conda,
// pyenv, an activated virtualenv or a python.org framework build. The app was
// handing them its own environment, so PYTHONHOME or VIRTUAL_ENV pointed the
// tool's interpreter at another installation's standard library; and the
// installers ran under `bash -lc`, so the dotfiles chose which python3 did the
// installing. This suite pins the scrub list, the PATH order, and the property
// that the Argos installer never asks the shell which python to use.

#import <Cocoa/Cocoa.h>

#import "../SPDFMacToolEnvironment.h"

static int gFailures;

static void Expect(BOOL condition, NSString* what) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", what.UTF8String);
    ++gFailures;
}

static BOOL ShellParses(NSString* script) {
    NSString* path = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"spdf-env-%@.sh", NSUUID.UUID.UUIDString]];
    if (![script writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]) return NO;
    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    task.arguments = @[ @"-n", path ];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    [task launchAndReturnError:nil];
    [task waitUntilExit];
    BOOL ok = task.terminationStatus == 0;
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    return ok;
}

int main(void) {
    @autoreleasepool {
        // --- What must never reach a child -----------------------------------
        for (NSString* key in @[
                 @"PYTHONHOME", @"PYTHONPATH", @"PYTHONSTARTUP", @"PYTHONUSERBASE", @"PYTHONEXECUTABLE",
                 @"__PYVENV_LAUNCHER__", @"VIRTUAL_ENV", @"CONDA_PREFIX", @"CONDA_DEFAULT_ENV", @"PYENV_ROOT",
                 @"PYENV_VERSION", @"PIP_TARGET", @"PIP_PREFIX", @"POETRY_ACTIVE", @"UV_PYTHON",
                 @"DYLD_LIBRARY_PATH", @"DYLD_INSERT_LIBRARIES", @"LD_LIBRARY_PATH", @"LD_PRELOAD",
                 @"TESSDATA_PREFIX"
             ])
            Expect(spdf_mac_tool_environment_key_is_banned(key),
                   [NSString stringWithFormat:@"%@ redirects an interpreter or loader and is dropped", key]);

        // --- What must still get through --------------------------------------
        for (NSString* key in @[ @"HOME", @"USER", @"TMPDIR", @"LANG", @"SSL_CERT_FILE", @"HTTPS_PROXY",
                                 @"HOMEBREW_PREFIX", @"PATH" ])
            Expect(!spdf_mac_tool_environment_key_is_banned(key),
                   [NSString stringWithFormat:@"%@ is the user's own setting and is kept", key]);

        // --- A machine mid-conda, launched from a terminal ---------------------
        NSDictionary* hostile = @{
            @"HOME" : NSHomeDirectory(),
            @"PATH" : @"/opt/miniconda3/bin:/usr/bin:/bin",
            @"PYTHONHOME" : @"/opt/miniconda3",
            @"PYTHONPATH" : @"/opt/miniconda3/lib/python3.11/site-packages",
            @"VIRTUAL_ENV" : @"/Users/someone/.venvs/work",
            @"CONDA_PREFIX" : @"/opt/miniconda3",
            @"TESSDATA_PREFIX" : @"/somewhere/else/tessdata",
            @"LANG" : @"C",
            @"HTTPS_PROXY" : @"http://proxy.example:3128"
        };
        NSDictionary* env = spdf_mac_tool_environment(hostile, @[ @"/opt/homebrew/bin/ocrmypdf" ], nil);
        for (NSString* key in @[ @"PYTHONHOME", @"PYTHONPATH", @"VIRTUAL_ENV", @"CONDA_PREFIX", @"TESSDATA_PREFIX" ])
            Expect(env[key] == nil, [NSString stringWithFormat:@"%@ does not survive the scrub", key]);
        Expect([env[@"HOME"] isEqual:hostile[@"HOME"]], @"HOME survives");
        Expect([env[@"HTTPS_PROXY"] isEqual:hostile[@"HTTPS_PROXY"]], @"a proxy setting survives: downloads need it");
        Expect([env[@"PYTHONIOENCODING"] isEqualToString:@"utf-8"], @"pipes are read as UTF-8 whatever the locale");
        Expect([env[@"LANG"] isEqualToString:@"en_US.UTF-8"], @"a non-UTF-8 locale is replaced");
        Expect([spdf_mac_tool_environment(@{@"LANG" : @"fr_FR.UTF-8"}, @[], nil)[@"LANG"]
                   isEqualToString:@"fr_FR.UTF-8"],
               @"a UTF-8 locale the user chose is left alone");

        // --- The extras a caller owns are applied after the scrub --------------
        NSDictionary* withTessdata =
            spdf_mac_tool_environment(hostile, @[], @{@"TESSDATA_PREFIX" : @"/ours"});
        Expect([withTessdata[@"TESSDATA_PREFIX"] isEqualToString:@"/ours"],
               @"the OCR path sets its own TESSDATA_PREFIX, and that one wins");

        // --- PATH order --------------------------------------------------------
        NSArray<NSString*>* dirs =
            spdf_mac_tool_search_directories(@[ @"/opt/homebrew/bin/ocrmypdf" ], @"/opt/miniconda3/bin:/usr/bin");
        Expect([dirs.firstObject isEqualToString:spdf_mac_tool_venv_bin_path()],
               @"the app's own virtualenv comes first");
        Expect([dirs containsObject:@"/opt/homebrew/bin"], @"the directory the resolved tool lives in is on PATH");
        Expect([dirs indexOfObject:@"/usr/bin"] < [dirs indexOfObject:@"/opt/miniconda3/bin"],
               @"an inherited directory ranks below the known prefixes, never above");
        Expect([NSSet setWithArray:dirs].count == dirs.count, @"no directory appears twice");

        // --- Discovery ---------------------------------------------------------
        NSArray<NSString*>* candidates =
            spdf_mac_tool_candidate_paths(@"argos-translate", @[ @"/opt/homebrew/bin/argos-translate" ]);
        Expect([candidates.firstObject
                   isEqualToString:[spdf_mac_tool_venv_bin_path()
                                       stringByAppendingPathComponent:@"argos-translate"]],
               @"the virtualenv copy is preferred over anything on the machine");
        Expect([candidates containsObject:@"/opt/homebrew/bin/argos-translate"],
               @"an existing working install is still found, so nobody is broken by this");
        Expect([candidates.lastObject hasSuffix:@".local/bin/argos-translate"], @"the pip --user path stays last");

        // --- Nothing is ever installed globally ---------------------------------
        Expect(!spdf_mac_tool_venv_has_tool(@"SPDFDefinitelyNotATool"),
               @"a tool that is not in the environment is not in the environment");
        Expect(!spdf_mac_tool_venv_has_tool(@""), @"and no name is not a tool");
        // The gate that sends a machine to the installer, and the latch that
        // stops it asking again when the environment cannot be built at all.
        Expect(!spdf_mac_tool_install_attempted(), @"no attempt has been made yet");
        spdf_mac_tool_note_install_attempt();
        Expect(spdf_mac_tool_install_attempted(),
               @"after one attempt a machine with no Python is left alone rather than asked every run");

        // --- The same build as an installer step ---------------------------------
        // The install panel is the ONLY thing a machine with no OCR reaches: the
        // adoption needs a resolved tool path, and there is none until something
        // is installed. Leaving this out left every fresh install on Homebrew.
        NSString* step = spdf_mac_tool_environment_install_step(@[ @"ocrmypdf" ]);
        Expect([step containsString:@"-m venv"] && [step containsString:spdf_mac_tool_venv_path()],
               @"installing OCR builds the private environment too");
        Expect([step containsString:@"pip install --upgrade ocrmypdf"], @"and puts ocrmypdf in it");
        Expect([step rangeOfString:@"exit"].location == NSNotFound && [step hasSuffix:@"true\n"],
               @"guarded: it is spliced into a script under `set -e` and must not abort the install");
        Expect([step containsString:@"No Python 3 with venv support was found"],
               @"a machine that cannot have the environment is told, in the visible install log");
        Expect([step rangeOfString:@"'s "].location == NSNotFound,
               @"no apostrophe: this text sits inside single quotes in the generated shell");
        Expect(ShellParses(step), @"the installer step parses");
        Expect([spdf_mac_tool_environment_install_step(@[]) isEqualToString:@"true\n"],
               @"asking for no packages builds nothing");

        // --- The Argos installer ------------------------------------------------
        NSString* install = spdf_mac_tool_argos_install_script();
        Expect([install rangeOfString:@"command -v python3"].location == NSNotFound,
               @"it never asks the shell which python3: that answer is what differs between machines");
        Expect([install containsString:@"/usr/bin/python3"] && [install containsString:@"/opt/homebrew/bin/python3"],
               @"it probes fixed paths instead");
        Expect([install containsString:@"import venv"], @"and rejects a python that cannot build an environment");
        Expect([install containsString:@"-m venv"] && [install containsString:spdf_mac_tool_venv_path()],
               @"argostranslate goes into the app's own environment");
        Expect([install rangeOfString:@"pip install --user"].location == NSNotFound,
               @"never --user: that tree belongs to whichever python3 answered");
        Expect(ShellParses(install), @"the installer parses");

        if (gFailures == 0) puts("SPDFMacToolEnvironmentTests passed");
    }
    return gFailures == 0 ? 0 : 1;
}
