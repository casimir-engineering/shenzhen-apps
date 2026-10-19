// Shared helpers for the host adapter's headless tests.
//
// Expect() fails the process with a message instead of NSCAssert, because NSCAssert compiles away under NDEBUG
// and a release-flagged test run would then pass without checking anything.

#pragma once
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define Expect(condition, ...)                                                                              \
    do {                                                                                                    \
        if (!(condition)) {                                                                                 \
            fprintf(stderr, "%s:%d: expectation failed: %s\n  ", __FILE__, __LINE__, #condition);           \
            fprintf(stderr, "%s\n", [[NSString stringWithFormat:__VA_ARGS__] UTF8String]);                  \
            exit(1);                                                                                        \
        }                                                                                                   \
    } while (0)

// A fresh private directory under the per-user temp dir; tests point SZFRIENDS_STATE_DIR and SPDF_STATE_DIR here.
static inline NSString* SPDFMacFriendsTestTemporaryDirectory(NSString* name) {
    NSString* base = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"spdf-friends-%@-%d-%@", name, getpid(), NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:base withIntermediateDirectories:YES
                                             attributes:@{NSFilePosixPermissions : @0700} error:nil];
    return base;
}

// Points SPDF_STATE_DIR at `directory` before anything reads it: the tab drag key (SPDFMacTabDragSignature.h) and
// the reading copies live there, and a test must never create them in the real state directory.
static inline void SPDFMacFriendsTestUseReaderStateDirectory(NSString* directory) {
    setenv("SPDF_STATE_DIR", directory.fileSystemRepresentation, 1);
}

static inline NSString* SPDFMacFriendsTestWriteFile(NSString* directory, NSString* name, NSData* bytes) {
    NSString* path = [directory stringByAppendingPathComponent:name];
    [bytes writeToFile:path atomically:YES];
    return path;
}

// Runs the main run loop until `done` returns YES or `seconds` pass; returns done(). Every wait in these tests is
// bounded so a missing callback fails the suite instead of hanging it.
static inline BOOL SPDFMacFriendsTestRunUntil(NSTimeInterval seconds, BOOL (^done)(void)) {
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done() && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return done();
}
