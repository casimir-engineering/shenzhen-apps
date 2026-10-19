#pragma once

#import <Foundation/Foundation.h>

static int SPDFMarkdownTestFailures = 0;

static void SPDFExpect(BOOL condition, NSString* message) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    ++SPDFMarkdownTestFailures;
}

static __attribute__((unused)) NSURL* SPDFFixtureURL(NSString* name) {
    NSString* source = @(__FILE__);
    NSString* directory = source.stringByDeletingLastPathComponent;
    return [NSURL fileURLWithPath:[[directory stringByAppendingPathComponent:@"fixtures"]
                                     stringByAppendingPathComponent:name]];
}

static int SPDFFinishTests(NSString* suite) {
    if (SPDFMarkdownTestFailures == 0) printf("%s passed\n", suite.UTF8String);
    return SPDFMarkdownTestFailures == 0 ? 0 : 1;
}
