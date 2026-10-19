#import <Foundation/Foundation.h>

#import "SPDFMacViewportCheckpoint.h"

static void RunFor(NSTimeInterval seconds) {
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

int main(void) {
    @autoreleasepool {
        __block NSInteger calls = 0;
        SPDFMacViewportCheckpoint* checkpoint = [[SPDFMacViewportCheckpoint alloc] initWithDelay:0.02];
        [checkpoint scheduleAction:^{ calls = 1; }];
        [checkpoint scheduleAction:^{ calls = 2; }];
        RunFor(0.08);
        NSCAssert(calls == 2 && !checkpoint.hasPendingAction,
                  @"rescheduling did not coalesce to the latest viewport");

        [checkpoint scheduleAction:^{ calls = 3; }];
        [checkpoint cancel];
        RunFor(0.08);
        NSCAssert(calls == 2 && !checkpoint.hasPendingAction,
                  @"cancelled stale session still persisted its viewport");
    }
    puts("SPDFMacViewportCheckpointTests passed");
    return 0;
}
