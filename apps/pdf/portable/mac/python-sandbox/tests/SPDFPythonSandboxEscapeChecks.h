// Real runs through the helper: computation, every escape the plan names, the limits, planted files and malformed
// requests. Included by SPDFPythonSandboxTests.m.
#pragma once
#import "SPDFPythonSandboxTestSupport.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/un.h>

@interface SandboxSuite : NSObject
@property NSString *helper, *python, *parent, *outside, *secret, *token;
@property int tcp, udp, local, port;
@end
@implementation SandboxSuite
@end

static int SandboxListen(int type, int* port) {
    int fd = socket(AF_INET, type, 0);
    struct sockaddr_in address = {.sin_len = sizeof address, .sin_family = AF_INET,
                                  .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    bind(fd, (struct sockaddr*)&address, sizeof address);
    if (type == SOCK_STREAM) listen(fd, 4);
    socklen_t length = sizeof address;
    getsockname(fd, (struct sockaddr*)&address, &length);
    if (port) *port = ntohs(address.sin_port);
    fcntl(fd, F_SETFL, O_NONBLOCK);
    return fd;
}

static SandboxSuite* SandboxMakeSuite(NSString* helper, NSString* python, NSString* scratch) {
    SandboxSuite* suite = [SandboxSuite new];
    suite.helper = helper;
    suite.python = python;
    suite.parent = [scratch stringByAppendingPathComponent:@"work"];
    suite.outside = [scratch stringByAppendingPathComponent:@"outside"];
    [NSFileManager.defaultManager createDirectoryAtPath:suite.parent withIntermediateDirectories:YES attributes:nil
                                                  error:nil];
    [NSFileManager.defaultManager createDirectoryAtPath:suite.outside withIntermediateDirectories:YES attributes:nil
                                                  error:nil];
    suite.token = [NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];
    suite.secret = [suite.outside stringByAppendingPathComponent:@"secret.txt"];
    [suite.token writeToFile:suite.secret atomically:NO encoding:NSUTF8StringEncoding error:nil];
    int port = 0;
    suite.tcp = SandboxListen(SOCK_STREAM, &port);
    suite.port = port;
    suite.udp = SandboxListen(SOCK_DGRAM, NULL);
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    strlcpy(address.sun_path, [suite.outside stringByAppendingPathComponent:@"s.sock"].fileSystemRepresentation,
            sizeof address.sun_path);
    suite.local = socket(AF_UNIX, SOCK_STREAM, 0);
    bind(suite.local, (struct sockaddr*)&address, sizeof address);
    listen(suite.local, 4);
    fcntl(suite.local, F_SETFL, O_NONBLOCK);
    return suite;
}

static void SandboxFreeSuite(SandboxSuite* suite) {
    close(suite.tcp);
    close(suite.udp);
    close(suite.local);
}

static NSDictionary* SuiteRun(SandboxSuite* suite, NSString* code, NSDictionary* extra) {
    NSMutableDictionary* request = [@{@"interpreter" : suite.python, @"code" : code, @"work_parent" : suite.parent,
                                      @"limits" : @{@"wall_seconds" : @8}} mutableCopy];
    [request addEntriesFromDictionary:extra ?: @{}];
    NSDictionary* result = SandboxRunHelper(suite.helper, request, 20);
    NSArray* left = [NSFileManager.defaultManager contentsOfDirectoryAtPath:suite.parent error:nil];
    CHECK(result != nil && left.count == 0, "every run answers and leaves no work directory behind");
    return result ?: @{};
}

static NSData* SuiteFile(NSDictionary* result, NSString* name) {
    for (NSDictionary* file in result[@"files"])
        if ([file[@"name"] isEqual:name] && file[@"data"])
            return [[NSData alloc] initWithBase64EncodedString:file[@"data"] options:0];
    return nil;
}

static void CheckComputation(SandboxSuite* suite) {
    NSString* code = [kSandboxPNGWriter stringByAppendingString:
        @"import csv, math, statistics\n"
         "print('mean', round(statistics.mean(math.sqrt(i) for i in range(1, 101)), 4))\n"
         "with open('table.csv', 'w', newline='') as f:\n"
         "    writer = csv.writer(f, lineterminator='\\n')\n"
         "    writer.writerow(['n', 'square'])\n"
         "    for n in range(3): writer.writerow([n, n * n])\n"
         "write_png('chart.png', 4, 3)\n"
         "print(open('input.txt').read().strip())\n"];
    NSDictionary* result = SuiteRun(suite, code, @{@"files" : @[ @{@"name" : @"input.txt", @"text" : @"from input"} ]});
    CHECK([result[@"status"] isEqual:@"completed"] && [result[@"exit_code"] isEqual:@0], "normal code completes");
    CHECK([result[@"stdout"] containsString:@"mean 6.7146"] && [result[@"stdout"] containsString:@"from input"],
          "it computes and reads the files it was given");
    NSString* table = [[NSString alloc] initWithData:SuiteFile(result, @"table.csv") encoding:NSUTF8StringEncoding];
    CHECK([table isEqual:@"n,square\n0,0\n1,1\n2,4\n"], "files it writes come back");
    NSData* png = SuiteFile(result, @"chart.png");
    CHECK(png.length > 8 && memcmp(png.bytes, "\x89PNG", 4) == 0, "images come back");
    CHECK([[result[@"files"] valueForKey:@"name"] isEqual:(@[ @"chart.png", @"table.csv" ])],
          "the code and the inputs are not returned as results");
    NSDictionary* failed = SuiteRun(suite, @"x = 1\nraise ValueError('boom')\n", nil);
    CHECK([failed[@"status"] isEqual:@"failed"] && [failed[@"exit_code"] isEqual:@1] &&
          [failed[@"stderr"] containsString:@"File \"main.py\", line 2"] &&
          ![failed[@"stderr"] containsString:@"szpy-"], "a traceback names main.py, not the temporary folder");
}

static void CheckEscapes(SandboxSuite* suite) {
    NSString* home = NSHomeDirectory();
    NSString* code = [NSString stringWithFormat:
        @"import os, socket, subprocess\n"
         "def attempt(name, action):\n"
         "    try:\n"
         "        action()\n"
         "        print('ESCAPED', name)\n"
         "    except Exception as error:\n"
         "        print('BLOCKED', name, type(error).__name__)\n"
         "def tcp():\n    s = socket.socket(); s.settimeout(2); s.connect(('127.0.0.1', %d))\n"
         "def udp():\n    socket.socket(socket.AF_INET, socket.SOCK_DGRAM).sendto(b'x', ('127.0.0.1', %d))\n"
         "def local():\n    socket.socket(socket.AF_UNIX).connect('%@/s.sock')\n"
         "def fork():\n    pid = os.fork()\n    if pid == 0: os._exit(0)\n    os.waitpid(pid, 0)\n"
         "attempt('tcp', tcp)\nattempt('udp', udp)\nattempt('unix', local)\n"
         "attempt('secret', lambda: print(open('%@').read()))\n"
         "attempt('home', lambda: os.listdir('%@'))\n"
         "attempt('ssh', lambda: os.listdir('%@/.ssh'))\n"
         "attempt('data-volume', lambda: os.listdir('/System/Volumes/Data%@'))\n"
         "attempt('write-parent', lambda: open('%@/escaped.txt', 'w').write('x'))\n"
         "attempt('write-tmp', lambda: open('/private/tmp/spdf-escape-%@', 'w').write('x'))\n"
         "attempt('write-home', lambda: open('%@/spdf-escape-%@', 'w').write('x'))\n"
         "attempt('fork', fork)\n"
         "attempt('subprocess', lambda: subprocess.run(['/bin/echo', 'hi'], check=True))\n"
         "attempt('spawn', lambda: os.posix_spawn('/bin/echo', ['echo'], {}))\n"
         "print('CONTROL', sorted(os.listdir('.')))\n"
         "attempt('exec', lambda: os.execv('/bin/echo', ['echo', 'ESCAPED', 'exec']))\n",
        suite.port, suite.port, suite.outside, suite.secret, home, home, home, suite.parent, suite.token, home,
        suite.token];
    NSDictionary* result = SuiteRun(suite, code, nil);
    NSString* out = result[@"stdout"] ?: @"";
    for (NSString* name in @[ @"tcp", @"udp", @"unix", @"secret", @"home", @"ssh", @"data-volume", @"write-parent",
                              @"write-tmp", @"write-home", @"fork", @"subprocess", @"spawn", @"exec" ]) {
        BOOL blocked = [out containsString:[NSString stringWithFormat:@"BLOCKED %@ ", name]];
        if (!blocked) fprintf(stderr, "  escape attempt not blocked: %s\n", name.UTF8String);
        CHECK(blocked, "every escape attempt fails inside the sandbox");
    }
    CHECK(![out containsString:@"ESCAPED"] && [out containsString:@"CONTROL ['.matplotlib', '.tmp', 'main.py', 'out']"],
          "nothing escaped, and the script itself ran to the end");
    NSData* everything = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    CHECK(![[[NSString alloc] initWithData:everything encoding:NSUTF8StringEncoding] containsString:suite.token],
          "the secret beside the work directory never reaches the result");
    char byte;
    CHECK(accept(suite.tcp, NULL, NULL) < 0 && errno == EWOULDBLOCK, "the loopback listener saw no connection");
    CHECK(recv(suite.udp, &byte, 1, 0) < 0 && errno == EWOULDBLOCK, "no datagram arrived");
    CHECK(accept(suite.local, NULL, NULL) < 0 && errno == EWOULDBLOCK, "the Unix socket saw no connection");
    NSArray* written = @[ [suite.parent stringByAppendingPathComponent:@"escaped.txt"],
                          [@"/private/tmp/spdf-escape-" stringByAppendingString:suite.token],
                          [home stringByAppendingPathComponent:[@"spdf-escape-" stringByAppendingString:suite.token]] ];
    for (NSString* path in written) {
        CHECK(access(path.fileSystemRepresentation, F_OK) != 0, "nothing was written outside the work directory");
        unlink(path.fileSystemRepresentation);
    }
}

static NSString* const kSandboxAppleEventsProbe =
    @"import ctypes\n"
     "lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib')\n"
     "port = ctypes.c_uint(0)\n"
     "bootstrap = ctypes.c_uint.in_dll(lib, 'bootstrap_port')\n"
     "print('lookup', lib.bootstrap_look_up(bootstrap, b'com.apple.coreservices.appleevents', ctypes.byref(port)))\n";

static void CheckAppleEvents(SandboxSuite* suite) {
    // The same probe outside the sandbox first, so a failure inside means the sandbox, not a missing service.
    NSTask* outside = [NSTask new];
    outside.executableURL = [NSURL fileURLWithPath:suite.python];
    outside.arguments = @[ @"-I", @"-c", kSandboxAppleEventsProbe ];
    NSPipe* pipe = [NSPipe pipe];
    outside.standardOutput = pipe;
    [outside launchAndReturnError:nil];
    NSString* free = [[NSString alloc] initWithData:[pipe.fileHandleForReading readDataToEndOfFile]
                                           encoding:NSUTF8StringEncoding];
    [outside waitUntilExit];
    NSDictionary* inside = SuiteRun(suite, kSandboxAppleEventsProbe, nil);
    CHECK([free containsString:@"lookup 0"], "outside the sandbox the Apple events service answers");
    CHECK([inside[@"stdout"] hasPrefix:@"lookup "] && ![inside[@"stdout"] containsString:@"lookup 0"],
          "inside, the Apple events service cannot even be looked up");
}

static void CheckLimits(SandboxSuite* suite) {
    NSDictionary* spin = SuiteRun(suite, @"while True: pass\n", @{@"limits" : @{@"cpu_seconds" : @2}});
    CHECK([spin[@"limit"] isEqual:@"cpu"] && [spin[@"status"] isEqual:@"failed"] && [spin[@"seconds"] doubleValue] < 5,
          "an infinite loop is stopped at the CPU limit");
    NSDictionary* sleepy = SuiteRun(suite, @"import time\nprint('started')\nwhile True: time.sleep(0.2)\n",
                                    @{@"limits" : @{@"wall_seconds" : @2}});
    CHECK([sleepy[@"limit"] isEqual:@"time"] && [sleepy[@"stdout"] containsString:@"started"],
          "a run that idles is stopped at the wall-time limit, keeping what it printed");
    NSDictionary* bomb = SuiteRun(suite, @"chunks = []\nwhile True: chunks.append(b'x' * (16 << 20))\n",
                                  @{@"limits" : @{@"memory_mb" : @200}});
    CHECK([bomb[@"limit"] isEqual:@"memory"] && [bomb[@"seconds"] doubleValue] < 5, "a memory bomb is stopped");
    NSDictionary* chatty = SuiteRun(suite, @"while True: print('y' * 1000)\n", nil);
    CHECK([chatty[@"limit"] isEqual:@"output"] && [chatty[@"stdout"] length] == 65536 &&
          [chatty[@"stdout_truncated"] boolValue], "huge output is cut at 64 KB and the runaway is stopped");
    NSDictionary* disk = SuiteRun(suite, @"i = 0\nwhile True:\n    open(f'out{i}.bin', 'wb').write(b'z' * (4 << 20))\n"
                                          "    i += 1\n", nil);
    NSUInteger returned = 0;
    for (NSDictionary* file in disk[@"files"]) returned += [file[@"data"] length] * 3 / 4;
    CHECK([disk[@"limit"] isEqual:@"files"] && returned <= 10u << 20, "output files are capped at 10 MB");
    NSDictionary* big = SuiteRun(suite, @"open('big.bin', 'wb').write(b'z' * (11 << 20))\n", nil);
    CHECK([big[@"stderr"] containsString:@"File too large"], "one file beyond the cap fails inside the kernel");
    NSDictionary* raised = SuiteRun(suite, @"print(1)\n", @{@"limits" : @{@"cpu_seconds" : @1000,
                                    @"wall_seconds" : @1000, @"memory_mb" : @100000}});
    CHECK([raised[@"limits"] isEqual:(@{@"cpu_seconds" : @20, @"wall_seconds" : @30, @"memory_mb" : @512,
                                        @"stdout_bytes" : @65536, @"output_bytes" : @10485760})],
          "a request can lower the limits but never raise them");
}

static void CheckBoobyTraps(SandboxSuite* suite) {
    NSString* code = [NSString stringWithFormat:
        @"import os\n"
         "os.symlink('%@', 'leak.txt')\n"
         "try:\n    os.link('%@', 'hard.txt')\nexcept OSError: pass\n"
         "os.mkfifo('pipe.png')\n"
         "os.mkdir('locked'); open('locked/inner.txt', 'w').write('x'); os.chmod('locked', 0)\n"
         "open('immutable.txt', 'w').write('x'); os.chflags('immutable.txt', 2)\n"
         "path = 'deep'\n"
         "for _ in range(150): path += '/d'\n"
         "os.makedirs(path)\n"
         "print('planted')\n", suite.secret, suite.secret];
    NSDictionary* result = SuiteRun(suite, code, nil);
    NSData* everything = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    CHECK([result[@"stdout"] isEqual:@"planted\n"] &&
          ![[[NSString alloc] initWithData:everything encoding:NSUTF8StringEncoding] containsString:suite.token],
          "planted links, FIFOs, locks and deep trees neither leak nor stop the cleanup");
}
