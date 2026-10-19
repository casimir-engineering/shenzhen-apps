// Failures, Stop and concurrency with the scripted runner; then the real runner driving the real helper; the
// installer's script and plumbing (with a stand-in script: a suite never downloads anything); the helper's location
// and the table helpers. Included by SPDFMacAIPythonTests.mm.
#pragma once
#import "SPDFMacAIPythonFakes.h"
#import "SPDFMacAIPythonInstall.h"
#import "SPDFPythonSandbox.h"

#include <sys/stat.h>

static void CheckFailures(void) {
    FakeRunner* runner = [FakeRunner new];
    FakeEnvironment* environment = [FakeEnvironment new];
    environment.installed = YES;
    environment.interpreterPath = @"/fake/bin/python3";
    SPDFMacAIPythonToolProvider* provider = [[SPDFMacAIPythonToolProvider alloc] initWithRunner:runner
                                                                                    environment:environment];
    SPDFMacAIChatActivity* activity = FakeActivity();
    runner.reply = @{@"ok" : @NO, @"error" : @"interpreter_unavailable", @"message" : @"exec: No such file"};
    NSDictionary* broken = FakeCall(provider, @{@"code" : @"print(1)"}, FakeContext(activity, YES, nil));
    CHECK(environment.forgets == 1 && [broken[@"error"] containsString:@"reinstall"],
          "an interpreter that cannot start is forgotten, so the next call offers Install again");
    runner.reply = @{@"ok" : @NO, @"error" : @"sandbox_unavailable", @"message" : @"sandbox: rejected"};
    environment.installed = YES;
    NSDictionary* refused = FakeCall(provider, @{@"code" : @"print(1)"}, FakeContext(activity, YES, nil));
    NSDictionary* step = FakeEntries(activity, SPDFMacAIActivityKindStep).lastObject;
    CHECK([refused[@"error"] containsString:@"sandbox could not be applied"] &&
          [step[SPDFMacAIActivityStateKey] isEqual:SPDFMacAIActivityStateFailed] &&
          [step[SPDFMacAIActivityTitleKey] isEqual:@"Python run failed"] &&
          [step[SPDFMacAIActivityStatusKey] containsString:@"can’t isolate Python"],
          "a sandbox that cannot be applied is reported, and the step reads 'Python run failed'");
    CHECK([provider toolDefinitionsForContext:FakeContext(activity, YES, nil)].count == 0,
          "and the tool is not offered again: it never runs unsandboxed");
    NSUInteger before = runner.requests.count;
    FakeCall(provider, @{@"code" : @"print(1)"}, FakeContext(activity, YES, nil));
    CHECK(runner.requests.count == before, "a later call does not try again");

    FakeRunner* slow = [FakeRunner new];
    SPDFMacAIPythonToolProvider* busy = [[SPDFMacAIPythonToolProvider alloc] initWithRunner:slow
                                                                                environment:environment];
    SPDFMacAIRequestContext* context = FakeContext(activity, YES, nil);
    __block NSUInteger answered = 0;
    for (int i = 0; i < 3; i++)
        [busy performTool:@"run_python" arguments:@{@"code" : @"print(1)"} context:context
               completion:^(NSDictionary* result) { (void)result; answered++; }];
    CHECK(slow.requests.count == 2 && answered == 1, "at most two runs at once; a third is refused, not queued");
    [context.cancellation cancel];
    CHECK(slow.stops == 2, "Stop on the request stops its runs");
    [busy cancel];
    CHECK(slow.stops == 4, "the provider's cancel stops every run it holds");
    slow.pending[1](@{@"ok" : @NO, @"error" : @"stopped", @"message" : @"The run was stopped."});
    NSDictionary* stopped = FakeEntries(activity, SPDFMacAIActivityKindStep).lastObject;
    CHECK([stopped[SPDFMacAIActivityStateKey] isEqual:SPDFMacAIActivityStateStopped] &&
          [stopped[SPDFMacAIActivityTitleKey] isEqual:@"Python run stopped"] &&
          [stopped[SPDFMacAIActivityStatusKey] isEqual:@"Stopped"] && answered == 2,
          "a stopped run completes, and its step reads 'Python run stopped'");
    slow.pending[0](@{@"ok" : @NO, @"error" : @"stopped", @"message" : @"The run was stopped."});
    CHECK(answered == 3, "every run completes exactly once");
}

static void CheckRealRunner(NSString* helper, NSString* python) {
    FakeEnvironment* environment = [FakeEnvironment new];
    environment.installed = YES;
    environment.interpreterPath = python;
    SPDFMacAIPythonSandboxRunner* runner = [[SPDFMacAIPythonSandboxRunner alloc] initWithHelperPath:helper];
    SPDFMacAIPythonToolProvider* provider = [[SPDFMacAIPythonToolProvider alloc] initWithRunner:runner
                                                                                    environment:environment];
    SPDFMacAIChatActivity* activity = FakeActivity();
    NSString* code = [kSandboxPNGWriter stringByAppendingString:
        @"rows = [line.split(',') for line in open('sales.csv').read().split()]\n"
         "total = sum(int(r[1]) for r in rows[1:])\n"
         "print('total', total)\n"
         "write_png('chart.png', 8, 6)\n"
         "open('summary.csv', 'w').write('metric,value\\ntotal,%d\\n' % total)\n"];
    NSDate* start = [NSDate date];
    NSDictionary* result = FakeCall(provider, @{@"code" : code, @"files" : @[ @{@"name" : @"sales.csv",
                                                @"content" : @"month,sales\n1,4\n2,9\n"} ]},
                                    FakeContext(activity, YES, nil));
    CHECK([result[@"stdout"] isEqual:@"total 13\n"] && [result[@"status"] isEqual:@"completed"],
          "through the real helper: the code reads its input and prints");
    CHECK(FakeEntries(activity, SPDFMacAIActivityKindImage).count == 1 &&
          [[result[@"tables"] firstObject][@"rows"] isEqual:(@[ @[ @"metric", @"value" ], @[ @"total", @"13" ] ])],
          "its PNG is in the chat and its CSV is a table");
    CHECK(-start.timeIntervalSinceNow < 10, "a small run takes well under the limits");

    runner.stopGrace = 1;
    __block NSDictionary* stopped = nil;
    dispatch_block_t stop = [runner runRequest:@{@"interpreter" : python, @"code" : @"import time\ntime.sleep(20)\n"}
                                    completion:^(NSDictionary* answer) { stopped = answer; }];
    SandboxSpin(0.5);
    NSDate* stoppedAt = [NSDate date];
    stop();
    SandboxWait(^BOOL { return stopped != nil; });
    CHECK([stopped[@"status"] isEqual:@"stopped"] && -stoppedAt.timeIntervalSinceNow < 3,
          "Stop ends a running run within seconds, and the helper still reports");
    runner.timeout = 1;
    __block NSDictionary* late = nil;
    [runner runRequest:@{@"interpreter" : python, @"code" : @"import time\ntime.sleep(20)\n"}
            completion:^(NSDictionary* answer) { late = answer; }];
    SandboxWait(^BOOL { return late != nil; });
    CHECK([late[@"status"] isEqual:@"stopped"], "a run past the outer deadline is stopped from outside");
}

static void CheckInstaller(NSString* scratch) {
    NSString* script =
        SPDFMacAIPythonInstallScript(@"/Users/x/Library/Application Support/ShenzhenPDF/assistant-python");
    CHECK([script containsString:@"VENV='/Users/x/Library/Application Support/ShenzhenPDF/assistant-python'"] &&
          [script containsString:@"/opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3"] &&
          [script containsString:@"--only-binary=:all: numpy pandas matplotlib"],
          "a fixed-path Python builds a venv from wheels only");
    CHECK(![script containsString:@"command -v python"] && ![script containsString:@"--user"] &&
          ![script containsString:@"sudo"] && ![script containsString:@"bash -l"],
          "never the shell's python3, never --user or sudo, never a login shell");
    CHECK([script containsString:@"/*/assistant-python) ;;"] &&
          [script rangeOfString:@".shenzhenpdf-ready"].location > [script rangeOfString:@"import numpy"].location,
          "the folder it removes must be the assistant's, and the marker is written only after the import check");
    CHECK([SPDFMacAIPythonDefaultDirectory() hasSuffix:@"/ShenzhenPDF/assistant-python"] &&
          ![SPDFMacAIPythonDefaultDirectory() hasSuffix:@"/ShenzhenPDF/python"],
          "its own environment, apart from the OCR tools' one");

    NSString* directory = [scratch stringByAppendingPathComponent:@"assistant-python"];
    NSString* fake = [NSString stringWithFormat:@"echo '## Creating the Python environment'\nsleep 0.3\n"
                                                 "mkdir -p '%@/bin' && printf '#!/bin/sh\\n' > '%@/bin/python3' && "
                                                 "chmod +x '%@/bin/python3'\necho '## Installed'\n"
                                                 "touch '%@/.shenzhenpdf-ready'\n",
                                                directory, directory, directory, directory];
    SPDFMacAIPythonInstaller* installer = [[SPDFMacAIPythonInstaller alloc] initWithDirectory:directory script:fake];
    SPDFMacAIPythonInstaller* other = [[SPDFMacAIPythonInstaller alloc] initWithDirectory:directory script:fake];
    NSMutableArray* stages = [NSMutableArray array];
    __block NSString* outcome = @"pending", *otherOutcome = nil;
    CHECK(!installer.installed, "an empty folder is not an installation");
    [installer installWithProgress:^(NSString* stage) { [stages addObject:stage]; }
                        completion:^(NSString* failure) { outcome = failure ?: @"ok"; }];
    [other installWithProgress:^(NSString* stage) { (void)stage; }
                    completion:^(NSString* failure) { otherOutcome = failure; }];
    CHECK(installer.installing && [otherOutcome containsString:@"another ShenzhenPDF window"],
          "a second installer on the same folder (another window's process) waits its turn");
    SandboxWait(^BOOL { return ![outcome isEqual:@"pending"]; });
    CHECK([outcome isEqual:@"ok"] && installer.installed && !installer.installing &&
          [stages isEqual:(@[ @"Creating the Python environment", @"Installed" ])],
          "stages reach the card in order, then the environment counts as installed");
    CHECK([installer.interpreterPath isEqual:[directory stringByAppendingPathComponent:@"bin/python3"]],
          "the interpreter is the environment's own");
    [installer forgetInstallation];
    CHECK(!installer.installed, "a broken environment can be forgotten");
    SPDFMacAIPythonInstaller* failing = [[SPDFMacAIPythonInstaller alloc] initWithDirectory:directory
        script:@"echo '!! Could not download numpy, pandas and matplotlib.'\nexit 1\n"];
    __block NSString* failure = nil;
    [failing installWithProgress:^(NSString* stage) { (void)stage; }
                      completion:^(NSString* reason) { failure = reason ?: @"ok"; }];
    SandboxWait(^BOOL { return failure != nil; });
    CHECK([failure isEqual:@"Could not download numpy, pandas and matplotlib."], "a failure reaches the card as said");
    [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    [NSFileManager.defaultManager removeItemAtPath:[directory stringByAppendingString:@".lock"] error:nil];
}

static void CheckHelperPathAndTables(NSString* scratch) {
    NSString* bundle = [scratch stringByAppendingPathComponent:@"Reader.app"];
    NSString* helpers = [bundle stringByAppendingPathComponent:@"Contents/Helpers"];
    [NSFileManager.defaultManager createDirectoryAtPath:helpers withIntermediateDirectories:YES attributes:nil
                                                  error:nil];
    CHECK(SPDFMacAIPythonHelperPath([NSBundle bundleWithPath:bundle]) == nil, "no helper, no Python tool");
    NSString* helper = [helpers stringByAppendingPathComponent:@"spdf-python-sandbox"];
    [@"#!/bin/sh\n" writeToFile:helper atomically:NO encoding:NSUTF8StringEncoding error:nil];
    chmod(helper.fileSystemRepresentation, 0755);
    NSBundle* reader = [NSBundle bundleWithPath:bundle];
    CHECK([SPDFMacAIPythonHelperPath(reader).stringByResolvingSymlinksInPath
              isEqual:helper.stringByResolvingSymlinksInPath], "the helper is found in Contents/Helpers");
    [NSFileManager.defaultManager removeItemAtPath:bundle error:nil];

    NSUInteger total = 0;
    NSArray* rows = SPDFMacAIPythonParseTable(@"name,note\n\"Mei, Li\",\"said \"\"hi\"\"\nthen left\"\n\nZoe,ok\n",
                                              ',', 10, 10, &total);
    CHECK([rows isEqual:(@[ @[ @"name", @"note" ], @[ @"Mei, Li", @"said \"hi\"\nthen left" ], @[ @"Zoe", @"ok" ] ])]
          && total == 3, "CSV quoting, doubled quotes and line breaks inside quotes parse; blank lines do not count");
    NSUInteger shown = 0;
    NSString* table = SPDFMacAIPythonMarkdownTable(@[ @[ @"a|b", @"c" ], @[ @"1\n2", @"3" ], @[ @"4", @"5" ] ], 60,
                                                   &shown);
    CHECK([table isEqual:@"| a\\|b | c |\n| --- | --- |\n| 1 2 | 3 |\n| 4 | 5 |\n"] && shown == 2,
          "pipes and line breaks in cells cannot break the table");
    CHECK(SPDFMacAIPythonMarkdownTable(@[ @[ @"a" ], @[ @"1" ], @[ @"2" ] ], 22, &shown).length <= 22 && shown == 1,
          "rows that do not fit are dropped");
    CHECK([SPDFMacAIPythonClip(@"abc😀def", 5) isEqual:@"abc…"], "clipping never splits a character");
    NSDictionary* limits = @{@"wall_seconds" : @30, @"cpu_seconds" : @20, @"memory_mb" : @512};
    NSDictionary* lines = @{@"time" : @"Stopped: it ran for more than 30 s",
                            @"cpu" : @"Stopped: it computed for more than 20 s",
                            @"memory" : @"Stopped: it needed more than 512 MB of memory",
                            @"output" : @"Stopped: it printed far too much",
                            @"files" : @"Stopped: it wrote more than 10 MB of files"};
    for (NSString* limit in lines)
        CHECK([SPDFMacAIPythonStatusLine(@{@"status" : @"failed", @"limit" : limit, @"limits" : limits})
                  isEqual:lines[limit]], "each limit is said in the person's terms");
    CHECK([SPDFMacAIPythonStatusLine(@{@"status" : @"failed", @"exit_code" : @1}) isEqual:@"Ended with an error"] &&
          [SPDFMacAIPythonStatusLine(@{@"status" : @"stopped", @"limit" : @"stopped"}) isEqual:@"Stopped"],
          "an error and a Stop read as such");
    for (NSString* name in @[ @"data.csv", @"main.py", @".x", @"../x", @"a b.txt", @"x " ]) {
        FakeRunner* runner = [FakeRunner new];
        runner.reply = @{@"ok" : @YES, @"status" : @"completed"};
        FakeEnvironment* environment = [FakeEnvironment new];
        environment.installed = YES;
        environment.interpreterPath = @"/fake/bin/python3";
        SPDFMacAIPythonToolProvider* provider = [[SPDFMacAIPythonToolProvider alloc] initWithRunner:runner
                                                                                        environment:environment];
        FakeCall(provider, @{@"code" : @"1", @"files" : @[ @{@"name" : name, @"content" : @""} ]},
                 FakeContext(FakeActivity(), YES, nil));
        CHECK((runner.requests.count == 1) == SPDFPythonSandboxValidInputName(name),
              "the tool and the helper agree on which file names are allowed");
    }
}
