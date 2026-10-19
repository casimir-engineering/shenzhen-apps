// Requests the helper must refuse, profiles --sandboxed-exec must refuse, Stop, and matplotlib in the installed
// environment. Included by SPDFPythonSandboxTests.m after the escape checks.
#pragma once
#import "SPDFPythonSandboxEscapeChecks.h"

// --sandboxed-exec run by hand with profiles that do not hold: the target (touch) must never run.
static void CheckRefusedProfiles(NSString* helper, NSString* scratch) {
    NSString* marker = [scratch stringByAppendingPathComponent:@"touched"];
    NSArray* cases = @[ @[ @"2", @"1024", @"(version 1)(allow default)" ],   // applies, but blocks nothing
                        @[ @"2", @"1024", @"(version 1)(this is not a profile" ], // does not apply
                        @[ @"99", @"1024", @"(version 1)(deny default)" ],     // a CPU limit above the ceiling
                        @[ @"2", @"0", @"(version 1)(deny default)" ] ];       // a file limit below 1
    for (NSArray* arguments in cases) {
        NSTask* task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:helper];
        task.arguments = [[@[ @"--sandboxed-exec" ] arrayByAddingObjectsFromArray:arguments]
            arrayByAddingObjectsFromArray:@[ @"/usr/bin/touch", marker ]];
        NSPipe* errors = [NSPipe pipe];
        task.standardError = errors;
        task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
        [task launchAndReturnError:nil];
        NSString* said = [[NSString alloc] initWithData:[errors.fileHandleForReading readDataToEndOfFile]
                                               encoding:NSUTF8StringEncoding];
        [task waitUntilExit];
        CHECK(task.terminationStatus == 126 && access(marker.fileSystemRepresentation, F_OK) != 0 && said.length,
              "a profile that does not apply, or applies but does not hold, refuses to run anything");
        unlink(marker.fileSystemRepresentation);
    }
}

static void CheckStop(SandboxSuite* suite) {
    NSTask* task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:suite.helper];
    NSPipe* input = [NSPipe pipe], *output = [NSPipe pipe];
    task.standardInput = input;
    task.standardOutput = output;
    [task launchAndReturnError:nil];
    NSDictionary* request = @{@"interpreter" : suite.python, @"code" : @"import time\ntime.sleep(20)\n",
                              @"work_parent" : suite.parent, @"limits" : @{@"wall_seconds" : @10}};
    [input.fileHandleForWriting writeData:[NSJSONSerialization dataWithJSONObject:request options:0 error:nil]];
    [input.fileHandleForWriting closeFile];
    SandboxSpin(0.5);
    NSDate* stopped = [NSDate date];
    kill(task.processIdentifier, SIGTERM);
    NSData* data = [output.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    NSDictionary* result = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    CHECK([result[@"status"] isEqual:@"stopped"] && -stopped.timeIntervalSinceNow < 3,
          "Stop (SIGTERM to the helper) ends the code at once and still reports");
    CHECK([[NSFileManager.defaultManager contentsOfDirectoryAtPath:suite.parent error:nil] count] == 0,
          "a stopped run's work directory is deleted too");
}

static void CheckRequests(SandboxSuite* suite) {
    NSDictionary* badName = SuiteRun(suite, @"print(1)", @{@"files" : @[ @{@"name" : @"../x", @"text" : @""} ]});
    CHECK([badName[@"error"] isEqual:@"bad_request"], "an input name that is a path is refused before anything runs");
    NSDictionary* noCode = SuiteRun(suite, @"", nil);
    CHECK([noCode[@"error"] isEqual:@"bad_request"], "a request without code is refused");
    NSDictionary* stub = SuiteRun(suite, @"print(1)", @{@"interpreter" : @"/usr/bin/python3"});
    CHECK([stub[@"error"] isEqual:@"interpreter_unavailable"], "the /usr/bin/python3 stub is refused");
    NSDictionary* missing = SuiteRun(suite, @"print(1)", @{@"interpreter" : @"/nonexistent/bin/python3"});
    CHECK([missing[@"error"] isEqual:@"interpreter_unavailable"], "a missing interpreter is reported as such");
    CheckStop(suite);
}

// Only with the assistant's own environment installed; a suite never installs it. SPDF_ASSISTANT_PYTHON may name
// another existing environment's interpreter with numpy, pandas and matplotlib, to check a Mac without the install.
static void CheckMatplotlib(SandboxSuite* suite) {
    NSString* environment = [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Application Support/ShenzhenPDF/assistant-python"];
    NSString* interpreter = [environment stringByAppendingPathComponent:@"bin/python3"];
    const char* chosen = getenv("SPDF_ASSISTANT_PYTHON");
    NSString* marker = [environment stringByAppendingPathComponent:@".shenzhenpdf-ready"];
    if (chosen && *chosen) {
        interpreter = @(chosen);
    } else if (access(marker.fileSystemRepresentation, F_OK) != 0) {
        printf("SPDFPythonSandboxTests: skipped the numpy, pandas and matplotlib check: the assistant's Python is not "
               "installed at %s (press Install on the card run_python shows, or set SPDF_ASSISTANT_PYTHON; a suite "
               "never installs it)\n", environment.fileSystemRepresentation);
        return;
    }
    // uname, cpu_count and the imports read system values: the profile names each one, so this is where a missing
    // name would show.
    NSString* code = @"import os, platform\nimport matplotlib\nimport matplotlib.pyplot as plt\nimport numpy, pandas\n"
                      "frame = pandas.DataFrame({'month': [1, 2, 3], 'deliveries': [4, 9, 6]})\n"
                      "frame['when'] = pandas.date_range('2026-01-01', periods=3, tz='Asia/Shanghai')\n"
                      "print('inverse', numpy.linalg.inv(numpy.eye(2) * 2)[0, 0])\n"
                      "plt.plot(frame.month, frame.deliveries)\nplt.title('Deliveries')\n"
                      "plt.savefig('chart.png', dpi=80)\nprint('backend', matplotlib.get_backend())\n"
                      "print('system', os.uname().sysname, os.cpu_count() > 0, platform.platform()[:5])\n";
    NSDictionary* result = SuiteRun(suite, code, @{@"interpreter" : interpreter, @"limits" : @{@"wall_seconds" : @25}});
    NSData* png = SuiteFile(result, @"chart.png");
    CHECK([result[@"status"] isEqual:@"completed"] && png.length > 1000 && memcmp(png.bytes, "\x89PNG", 4) == 0,
          "numpy, pandas and matplotlib import and draw a chart inside the sandbox");
    CHECK([[result[@"stdout"] lowercaseString] containsString:@"backend agg"], "with the Agg backend");
    CHECK([result[@"stdout"] containsString:@"inverse 0.5"] &&
          [result[@"stdout"] containsString:@"system Darwin True macOS"],
          "numpy computes, and uname, os.cpu_count and platform answer alongside them");
}
