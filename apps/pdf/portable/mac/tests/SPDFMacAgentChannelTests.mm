// The szpdf tool's protocol and JSON: request checks, the socket exchange, the command line, which reader an open
// goes to, and comments as data (SPDFMacAgentChannel.h, SPDFMacSzpdf.h, SPDFMacAgentComments.h). Headless: the only
// socket is one this test serves itself, in a directory of its own.
#import <Foundation/Foundation.h>

#import "SPDFMacAgentChannel.h"
#import "SPDFMacAgentComments.h"
#import "SPDFMacCommandLineTool.h"
#import "SPDFMacMarkdownComments.h"
#import "SPDFMacSzpdf.h"

#include <pthread.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

static int gFailures;

static void Expect(BOOL condition, NSString* message) {
    if (condition) return;
    ++gFailures;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
}

static NSDictionary* Check(id object) {
    NSData* data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    return SPDFMacAgentChannelValidateRequest(data, nil);
}

static void TestRequests(void) {
    Expect(Check(@{@"command" : @"state"}) != nil, @"state");
    Expect(Check(@{@"command" : @"open", @"path" : @"/a/b.md", @"page" : @3, @"front" : @NO, @"wait" : @YES}) != nil,
           @"open at a page");
    Expect(Check(@{@"command" : @"open", @"path" : @"/a/b.md", @"heading" : @"Setup"}) != nil, @"open at a heading");
    Expect(Check(@{@"command" : @"screenshot", @"windowId" : @42, @"output" : @"/tmp/w.PNG"}) != nil, @"screenshot");
    Expect(Check(@{@"command" : @"comments-changed", @"path" : @"/a/b.md"}) != nil, @"comments-changed");
    Expect(Check(@{@"command" : @"version", @"action" : @"new", @"path" : @"/a/b.md", @"carry" : @"all"}) != nil,
           @"version new");
    Expect(Check(@{@"command" : @"version", @"action" : @"compare", @"path" : @"/a/b.md", @"older" : @1, @"newer" : @2,
                   @"front" : @NO, @"wait" : @YES}) != nil,
           @"version compare");
    Expect(Check(@{@"command" : @"reload", @"path" : @"/a/b.md", @"timeout" : @30}) != nil, @"reload");
    Expect(Check(@{@"command" : @"close", @"windowId" : @7}) != nil && Check(@{@"command" : @"close", @"path" : @"/a.md"}),
           @"close a window or a document");
    Expect(Check(@{@"command" : @"watch-comments", @"path" : @"/a.md", @"since" : @"2026-11-03T05:40:28+08:00",
                   @"timeout" : @60}) != nil,
           @"watch-comments");
    Expect(Check(@{@"command" : @"open", @"path" : @"/a.md", @"reload" : @YES, @"timeout" : @5}) != nil, @"open --reload");
    NSArray* refused = @[
        @{@"command" : @"close"}, @{@"command" : @"close", @"path" : @"/a.md", @"windowId" : @7},
        @{@"command" : @"close", @"path" : @"a.md"}, @{@"command" : @"reload", @"path" : @"/a.md", @"timeout" : @0},
        @{@"command" : @"watch-comments", @"path" : @"/a.md", @"since" : @5},
        @{@"command" : @"open", @"path" : @"/a.md", @"reload" : @"yes"},
        @{@"command" : @"quit"}, @{@"command" : @"state", @"extra" : @1}, @{@"path" : @"/a.md"},
        @{@"command" : @"open", @"path" : @"b.md"}, @{@"command" : @"open"},
        @{@"command" : @"open", @"path" : @"/a.md", @"page" : @0},
        @{@"command" : @"open", @"path" : @"/a.md", @"page" : @1.5},
        @{@"command" : @"open", @"path" : @"/a.md", @"page" : @YES},
        @{@"command" : @"open", @"path" : @"/a.md", @"page" : @"2"},
        @{@"command" : @"open", @"path" : @"/a.md", @"heading" : @""},
        @{@"command" : @"open", @"path" : @"/a.md", @"page" : @2, @"heading" : @"Setup"},
        @{@"command" : @"open", @"path" : @"/a.md", @"front" : @1},
        @{@"command" : @"screenshot", @"windowId" : @"42", @"output" : @"/tmp/w.png"},
        @{@"command" : @"screenshot", @"windowId" : @42, @"output" : @"/tmp/w.jpg"},
        @{@"command" : @"screenshot", @"windowId" : @42, @"output" : @"w.png"},
        @{@"command" : @"version", @"action" : @"delete", @"path" : @"/a.md"},
        @{@"command" : @"version", @"action" : @"new", @"path" : @"/a.md", @"carry" : @"some"},
        @{@"command" : @"version", @"action" : @"compare", @"path" : @"/a.md", @"older" : @1},
        @{@"command" : @"version", @"action" : @"list", @"path" : @"a.md"},
    ];
    for (NSDictionary* request in refused)
        Expect(Check(request) == nil, [NSString stringWithFormat:@"refused: %@", request]);
    Expect(Check(@[ @1 ]) == nil, @"an array is refused");
    Expect(!SPDFMacAgentChannelValidateRequest([@"{not json" dataUsingEncoding:NSUTF8StringEncoding], nil),
           @"broken JSON is refused");
    Expect(!SPDFMacAgentChannelValidateRequest([NSMutableData dataWithLength:SPDFMacAgentChannelMaxLine + 1], nil),
           @"an oversized line is refused");
    NSError* error = nil;
    SPDFMacAgentChannelValidateRequest([@"{\"command\":\"nope\"}" dataUsingEncoding:NSUTF8StringEncoding], &error);
    Expect([error.localizedDescription isEqualToString:@"Unknown command."], @"the refusal says why");

    NSData* line = SPDFMacAgentChannelEncode(@{@"b" : @1, @"a" : @"x"});
    NSString* text = [[NSString alloc] initWithData:line encoding:NSUTF8StringEncoding];
    Expect([text isEqualToString:@"{\"a\":\"x\",\"b\":1}\n"], [NSString stringWithFormat:@"one sorted line: %@", text]);
}

static void TestPaths(void) {
    Expect([SPDFMacAgentChannelSocketPath(@"/s", 123) isEqualToString:@"/s/Agent/123.sock"], @"socket path");
    Expect(SPDFMacAgentChannelPIDFromName(@"123.sock") == 123, @"pid from name");
    for (NSString* name in @[ @"0123.sock", @"abc.sock", @"123.socket", @"-1.sock", @".sock", @"١٢.sock",
                              @"1234567890.sock" ])
        Expect(SPDFMacAgentChannelPIDFromName(name) == 0, [NSString stringWithFormat:@"not a pid: %@", name]);
    Expect(SPDFMacAgentChannelPathFits(@"/Users/someone/Library/Application Support/ShenzhenPDF/Agent/99999.sock"),
           @"the usual path fits");
    Expect(!SPDFMacAgentChannelPathFits([@"/" stringByPaddingToLength:120 withString:@"x" startingAtIndex:0]),
           @"a long path does not");
}

typedef struct {
    int fd;
    char answer[256];
} ServerArgs;

static void* ServeOnce(void* context) {
    ServerArgs* args = (ServerArgs*)context;
    int client = accept(args->fd, NULL, NULL);
    char buffer[1024];
    ssize_t n = read(client, buffer, sizeof(buffer));
    (void)n;
    write(client, args->answer, strlen(args->answer));
    close(client);
    return NULL;
}

static void TestExchange(void) {
    NSString* root = [NSString stringWithFormat:@"/tmp/szpdf-channel-test-%d", getpid()];
    NSString* directory = SPDFMacAgentChannelDirectory(root);
    Expect(SPDFMacAgentChannelPrepareDirectory(directory, nil), @"the directory is made");
    struct stat info;
    Expect(lstat(directory.fileSystemRepresentation, &info) == 0 && (info.st_mode & 0777) == 0700, @"and is 0700");
    chmod(directory.fileSystemRepresentation, 0755);
    Expect(!SPDFMacAgentChannelPrepareDirectory(directory, nil), @"a directory others can read is refused");
    chmod(directory.fileSystemRepresentation, 0700);

    NSString* path = SPDFMacAgentChannelSocketPath(root, getpid());
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un address = {};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, path.fileSystemRepresentation, sizeof(address.sun_path));
    Expect(bind(fd, (struct sockaddr*)&address, sizeof(address)) == 0 && listen(fd, 1) == 0, @"test server listens");
    ServerArgs args = {fd, "{\"opened\":true,\"windowId\":7}\n"};
    pthread_t thread;
    pthread_create(&thread, NULL, ServeOnce, &args);
    NSError* error = nil;
    NSDictionary* answer = SPDFMacAgentChannelExchange(path, @{@"command" : @"state"}, 5, &error);
    pthread_join(thread, NULL);
    Expect([answer[@"windowId"] isEqual:@7] && [answer[@"opened"] boolValue],
           [NSString stringWithFormat:@"answer read back: %@ %@", answer, error]);
    close(fd);
    unlink(path.fileSystemRepresentation);
    answer = SPDFMacAgentChannelExchange(path, @{@"command" : @"state"}, 1, &error);
    Expect(!answer && error, @"no reader there is an error, not a hang");
    rmdir(directory.fileSystemRepresentation);
    rmdir(root.fileSystemRepresentation);
}

static NSDictionary* Parse(NSArray* arguments) { return SPDFMacSzpdfParseArguments(arguments, @"/work", nil); }

static void TestArguments(void) {
    NSDictionary* open = Parse(@[ @"open", @"notes/a.md", @"--page", @"12", @"--wait" ]);
    Expect([open[@"path"] isEqualToString:@"/work/notes/a.md"] && [open[@"page"] isEqual:@12] &&
               [open[@"wait"] boolValue] && ![open[@"front"] boolValue] && [open[@"timeout"] isEqual:@30],
           [NSString stringWithFormat:@"open: %@", open]);
    open = Parse(@[ @"open", @"/x/a.md", @"--heading", @"Getting started", @"--front", @"--timeout", @"5" ]);
    Expect([open[@"heading"] isEqualToString:@"Getting started"] && [open[@"front"] boolValue] &&
               [open[@"timeout"] isEqual:@5],
           @"open at a heading, to the front");
    Expect([Parse(@[ @"open", @"a.md", @"--background" ])[@"front"] isEqual:@NO], @"--background is the default");
    Expect([Parse(@[ @"state" ])[@"command"] isEqualToString:@"state"], @"state");
    NSDictionary* shot = Parse(@[ @"screenshot", @"4242", @"out/w.png" ]);
    Expect([shot[@"windowId"] isEqual:@4242] && [shot[@"output"] isEqualToString:@"/work/out/w.png"], @"screenshot");
    Expect([Parse(@[ @"comments", @"a.pdf", @"--json" ])[@"json"] boolValue], @"comments --json");
    NSDictionary* reply = Parse(@[ @"comment", @"reply", @"a.md", @"m1234abcd", @"Done.", @"--author", @"Claude" ]);
    Expect([reply[@"command"] isEqualToString:@"comment-reply"] && [reply[@"text"] isEqualToString:@"Done."] &&
               [reply[@"author"] isEqualToString:@"Claude"] && [reply[@"id"] isEqualToString:@"m1234abcd"],
           @"comment reply");
    NSDictionary* reopen = Parse(@[ @"comment", @"resolve", @"a.md", @"m1", @"--reopen" ]);
    Expect([reopen[@"command"] isEqualToString:@"comment-resolve"] && ![reopen[@"resolved"] boolValue], @"reopen");
    Expect([Parse(@[ @"comment", @"resolve", @"a.md", @"m1" ])[@"resolved"] boolValue], @"resolve");
    NSDictionary* fresh = Parse(@[ @"version", @"new", @"r.md" ]);
    Expect([fresh[@"command"] isEqualToString:@"version-new"] && [fresh[@"carry"] isEqualToString:@"open"] &&
               [fresh[@"path"] isEqualToString:@"/work/r.md"],
           @"version new carries the open comments by default");
    Expect([Parse(@[ @"version", @"new", @"r.md", @"--carry", @"none" ])[@"carry"] isEqualToString:@"none"], @"--carry");
    Expect([Parse(@[ @"version", @"list", @"r.md" ])[@"command"] isEqualToString:@"version-list"], @"version list");
    NSDictionary* compare = Parse(@[ @"version", @"compare", @"r.md", @"1", @"2", @"--background" ]);
    Expect([compare[@"older"] isEqual:@1] && [compare[@"newer"] isEqual:@2] && ![compare[@"front"] boolValue] &&
               ![compare[@"wait"] boolValue],
           @"version compare, in the background");
    Expect([Parse(@[ @"version", @"compare", @"r.md", @"1", @"2", @"--wait" ])[@"wait"] boolValue], @"compare --wait");
    Expect([Parse(@[ @"comments", @"r.md", @"--version", @"1", @"--json" ])[@"version"] isEqual:@1],
           @"comments --version");
    NSArray* wrong = @[
        @[], @[ @"open" ], @[ @"open", @"a.md", @"--page", @"0" ], @[ @"open", @"a.md", @"--page", @"two" ],
        @[ @"open", @"a.md", @"--page", @"2", @"--heading", @"Setup" ], @[ @"open", @"a.md", @"--front", @"--background" ],
        @[ @"open", @"a.md", @"--page" ], @[ @"open", @"a.md", @"--timeout", @"0" ],
        @[ @"state", @"--wait" ], @[ @"screenshot", @"x", @"a.png" ], @[ @"screenshot", @"4", @"a.jpg" ],
        @[ @"comment", @"reply", @"a.md", @"m1" ], @[ @"comment", @"reply", @"a.md", @"m1", @"  " ],
        @[ @"comment", @"delete", @"a.md", @"m1" ], @[ @"comments", @"a.md", @"--author", @"x" ], @[ @"--version", @"x" ],
        @[ @"version", @"new", @"r.md", @"--carry", @"some" ], @[ @"version", @"list", @"r.md", @"--carry", @"all" ],
        @[ @"version", @"compare", @"r.md", @"2", @"2" ], @[ @"version", @"compare", @"r.md", @"1" ],
        @[ @"version", @"compare", @"r.md", @"1", @"2", @"--front", @"--background" ], @[ @"version", @"r.md" ],
        @[ @"comments", @"r.md", @"--version", @"0" ],
    ];
    for (NSArray* arguments in wrong)
        Expect(Parse(arguments) == nil, [NSString stringWithFormat:@"refused: %@", arguments]);
    NSError* error = nil;
    SPDFMacSzpdfParseArguments(@[ @"open", @"a.md", @"--nope" ], @"/", &error);
    Expect([error.localizedDescription isEqualToString:@"--nope does not apply to szpdf open."] &&
               [error.userInfo[SPDFMacSzpdfUsageCommandKey] isEqualToString:@"open open"] == NO &&
               [error.userInfo[SPDFMacSzpdfUsageCommandKey] isEqualToString:@"open"],
           @"the mistake names its command, for its usage");
    Expect([Parse(@[ @"open", @"a.md", @"--json" ])[@"command"] isEqualToString:@"open"], @"--json is accepted everywhere");
    Expect(SPDFMacIsSzpdfInvocation("/usr/local/bin/szpdf") && SPDFMacIsSzpdfInvocation("szpdf") &&
               !SPDFMacIsSzpdfInvocation("/Applications/ShenzhenPDF.app/Contents/MacOS/ShenzhenPDF") &&
               !SPDFMacIsSzpdfInvocation(NULL),
           @"run as szpdf");
}

static void TestChooseProcess(void) {
    NSDictionary* showing = @{@"windows" : @[ @{@"documents" : @[ @{@"path" : @"/a.md"} ]} ]};
    NSDictionary* active = @{@"active" : @YES, @"windows" : @[]};
    NSDictionary* plain = @{@"windows" : @[]};
    NSDictionary* quitting = @{@"quitting" : @YES, @"windows" : @[ @{@"documents" : @[ @{@"path" : @"/b.md"} ]} ]};
    Expect(SPDFMacSzpdfChooseProcess(@{@30 : plain, @20 : active, @40 : showing}, @"/a.md") == 40, @"the one showing it");
    Expect(SPDFMacSzpdfChooseProcess(@{@30 : plain, @20 : active, @40 : showing}, @"/c.md") == 20, @"else the active one");
    Expect(SPDFMacSzpdfChooseProcess(@{@30 : plain, @25 : plain}, @"/c.md") == 25, @"else the oldest");
    Expect(SPDFMacSzpdfChooseProcess(@{@10 : quitting, @30 : plain}, @"/b.md") == 30, @"never one that is quitting");
    Expect(SPDFMacSzpdfChooseProcess(@{@10 : quitting}, @"/b.md") == 0, @"none when all are quitting");
    Expect(SPDFMacSzpdfChooseProcess(@{}, @"/b.md") == 0, @"none when none runs");
}

static void TestCommentJSON(void) {
    SPDFMarkdownComment* comment = [SPDFMarkdownComment new];
    comment.author = @"Raph";
    comment.date = [NSDate dateWithTimeIntervalSince1970:1793517600];
    comment.quote = @"two pull-ups";
    comment.headingPath = @[ @"## Setup", @"### Wiring" ];
    comment.line = 12;
    comment.text = @"Check the value.";
    NSString* identifier = SPDFMacAgentMarkdownCommentID(comment);
    Expect(identifier.length == 9 && [identifier hasPrefix:@"m"], identifier);
    NSDictionary* json = SPDFMacAgentMarkdownCommentJSON(comment, identifier);
    Expect([json[@"headingPath"] isEqual:(@[ @"Setup", @"Wiring" ])] && [json[@"line"] isEqual:@12] &&
               [json[@"status"] isEqualToString:@"open"] && [[NSISO8601DateFormatter new] dateFromString:json[@"date"]].timeIntervalSince1970 == 1793517600 &&
               [json[@"date"] length] == 25 &&
               [json[@"replies"] isEqual:@[]],
           [NSString stringWithFormat:@"comment JSON: %@", json]);
    SPDFMarkdownCommentReply* reply = [SPDFMarkdownCommentReply new];
    reply.author = @"Claude";
    reply.text = @"4.7 kΩ.";
    comment.replies = @[ reply ];
    comment.resolved = YES;
    comment.text = @"Check the value, please.";
    comment.line = 14;
    Expect([SPDFMacAgentMarkdownCommentID(comment) isEqualToString:identifier],
           @"the id survives replies, resolving, edits to the text and moving lines");
    json = SPDFMacAgentMarkdownCommentJSON(comment, identifier);
    Expect([json[@"status"] isEqualToString:@"resolved"] && [json[@"replies"][0][@"author"] isEqualToString:@"Claude"],
           @"status and replies in the JSON");
    Expect([NSJSONSerialization isValidJSONObject:json], @"serializable");
    comment.quote = @"other words";
    Expect(![SPDFMacAgentMarkdownCommentID(comment) isEqualToString:identifier], @"another passage, another id");
}

// Settings' Install Command-Line Tool: a link in ~/.local/bin, made without asking for a password, replacing an older
// link but never a file someone else put there.
static void TestInstallLink(void) {
    NSString* home = [NSString stringWithFormat:@"/tmp/szpdf-install-test-%d", getpid()];
    NSString* link = SPDFMacCommandLineToolLinkPath(home);
    BOOL installed = NO;
    NSString* said = SPDFMacInstallCommandLineTool(@"/Applications/ShenzhenPDF.app", home, &installed);
    NSString* target = [NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:link error:nil];
    Expect(installed && [target isEqualToString:@"/Applications/ShenzhenPDF.app/Contents/MacOS/szpdf"] &&
               [said hasPrefix:@"Installed in ~/.local/bin."],
           [NSString stringWithFormat:@"installed: %@ -> %@", said, target]);
    Expect([SPDFMacCommandLineToolStatus(@"/Applications/ShenzhenPDF.app", home) hasPrefix:@"Installed"], @"status");
    Expect([SPDFMacCommandLineToolStatus(@"/Other/ShenzhenPDF.app", home) containsString:@"another copy"],
           @"a link to another copy is named as such");
    SPDFMacInstallCommandLineTool(@"/Other/ShenzhenPDF.app", home, &installed);
    target = [NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:link error:nil];
    Expect(installed && [target hasPrefix:@"/Other/"], @"an older link is replaced");
    unlink(link.fileSystemRepresentation);
    [@"#!/bin/sh\n" writeToFile:link atomically:NO encoding:NSUTF8StringEncoding error:nil];
    said = SPDFMacInstallCommandLineTool(@"/Applications/ShenzhenPDF.app", home, &installed);
    Expect(!installed && [said containsString:@"left alone"] &&
               [[NSString stringWithContentsOfFile:link encoding:NSUTF8StringEncoding error:nil] hasPrefix:@"#!"],
           @"someone else's file is left alone");
    unlink(link.fileSystemRepresentation);
    rmdir(link.stringByDeletingLastPathComponent.fileSystemRepresentation);
    rmdir([home stringByAppendingPathComponent:@".local"].fileSystemRepresentation);
    rmdir(home.fileSystemRepresentation);
}

int main(void) {
    @autoreleasepool {
        TestRequests();
        TestPaths();
        TestExchange();
        TestArguments();
        TestChooseProcess();
        TestCommentJSON();
        TestInstallLink();
    }
    if (gFailures) {
        fprintf(stderr, "SPDFMacAgentChannelTests failed: %d\n", gFailures);
        return 1;
    }
    printf("SPDFMacAgentChannelTests passed\n");
    return 0;
}
