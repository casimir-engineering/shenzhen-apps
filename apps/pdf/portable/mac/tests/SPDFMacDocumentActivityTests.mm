// Last opened and last viewed (mac/SPDFMacDocumentActivity.h): the 2-second clock, the backfill, what the assistant
// reads, and the store across two processes' worth of instances, headless.
#import <Foundation/Foundation.h>
#import "SPDFMacDocumentActivity.h"
#include <math.h>

static int failures = 0;
#define EXPECT(condition)                                                                                         \
    do {                                                                                                          \
        if (!(condition)) {                                                                                       \
            NSLog(@"FAIL %s:%d: %s", __FILE__, __LINE__, #condition);                                            \
            failures++;                                                                                           \
        }                                                                                                         \
    } while (0)

static const NSTimeInterval kRef = 978307200;
static NSTimeZone* Shanghai(void) { return [NSTimeZone timeZoneWithName:@"Asia/Shanghai"]; }

static void TestClock(void) {
    SPDFMacDocumentViewClock* clock = [[SPDFMacDocumentViewClock alloc] initWithThreshold:2 heartbeat:60 idleLimit:60];
    // A tab in front for 1.9 s, then another: the first was never viewed.
    EXPECT([clock showPath:@"/a.pdf" at:100 idle:0].count == 0);
    EXPECT(clock.deadline == 102);
    EXPECT([clock tickAt:101.9 idle:0].count == 0);
    EXPECT([clock showPath:@"/b.pdf" at:101.9 idle:0].count == 0);
    // Two seconds in front: viewed, stamped then, and again when the view ends.
    NSArray* stamps = [clock tickAt:103.9 idle:0];
    EXPECT(stamps.count == 1 && [stamps[0][@"path"] isEqual:@"/b.pdf"] && [stamps[0][@"at"] doubleValue] == 103.9);
    EXPECT(clock.deadline == 163.9);
    stamps = [clock showPath:nil at:130 idle:0];
    EXPECT(stamps.count == 1 && [stamps[0][@"at"] doubleValue] == 130);
    EXPECT(clock.deadline == 0 && [clock tickAt:200 idle:0].count == 0);
    // The same tab again (a notification that changed nothing) does not restart the 2 seconds.
    [clock showPath:@"/c.pdf" at:300 idle:0];
    EXPECT([clock showPath:@"/c.pdf" at:301 idle:0].count == 0);
    EXPECT([clock tickAt:302 idle:0].count == 1);
    // Still reading a minute later: stamped. Then away from the Mac: stamped once at the last input, then nothing,
    // and switching tabs on return does not claim they looked at it meanwhile.
    EXPECT([[clock tickAt:362 idle:5][0][@"at"] doubleValue] == 362);
    stamps = [clock tickAt:422 idle:90];
    EXPECT(stamps.count == 1 && [stamps[0][@"at"] doubleValue] == 332);
    EXPECT([clock tickAt:482 idle:150].count == 0);
    EXPECT([clock showPath:@"/d.pdf" at:900 idle:0].count == 0);
    // An unattended relaunch: the tab in front is not viewed until someone is there.
    EXPECT([clock tickAt:902 idle:600].count == 0);
    EXPECT([clock tickAt:962 idle:1].count == 1);
    // Leaving after a view with nobody at the Mac (screens asleep): stamped when they last touched it.
    SPDFMacDocumentViewClock* other = [[SPDFMacDocumentViewClock alloc] initWithThreshold:2 heartbeat:60 idleLimit:60];
    [other showPath:@"/e.pdf" at:0 idle:0];
    [other tickAt:2 idle:0];
    EXPECT([[other showPath:nil at:50 idle:45][0][@"at"] doubleValue] == 50);
    [other showPath:@"/e.pdf" at:100 idle:0];
    [other tickAt:102 idle:0];
    EXPECT([[other showPath:nil at:200 idle:70][0][@"at"] doubleValue] == 130);
}

static void TestViewingState(void) {
    SPDFDocumentViewingState front = {.appActive = YES, .keyOrMain = YES, .visible = YES, .hasDocument = YES};
    EXPECT(SPDFDocumentViewingStateIsViewing(front));
    SPDFDocumentViewingState s = front; s.appActive = NO; EXPECT(!SPDFDocumentViewingStateIsViewing(s));
    s = front; s.keyOrMain = NO; EXPECT(!SPDFDocumentViewingStateIsViewing(s));
    s = front; s.visible = NO; EXPECT(!SPDFDocumentViewingStateIsViewing(s));
    s = front; s.miniaturized = YES; EXPECT(!SPDFDocumentViewingStateIsViewing(s));
    s = front; s.occluded = YES; EXPECT(!SPDFDocumentViewingStateIsViewing(s));
    s = front; s.screensAsleep = YES; EXPECT(!SPDFDocumentViewingStateIsViewing(s));
    s = front; s.sessionInactive = YES; EXPECT(!SPDFDocumentViewingStateIsViewing(s));
    s = front; s.hasDocument = NO; EXPECT(!SPDFDocumentViewingStateIsViewing(s));
}

static void TestMergeAndFields(void) {
    NSDictionary* real = @{@"opened" : @1000, @"viewed" : @2000};
    NSDictionary* guess = @{@"estimate" : @{@"opened" : @5000, @"viewed" : @6000}};
    NSDictionary* merged = SPDFDocumentActivityMerge(real, guess);
    EXPECT([merged[@"viewed"] isEqual:@2000] && [merged[@"estimate"][@"viewed"] isEqual:@6000]);
    EXPECT([SPDFDocumentActivityMerge(merged, @{@"viewed" : @1500})[@"viewed"] isEqual:@2000]);
    EXPECT([SPDFDocumentActivityMerge(merged, @{@"viewed" : @2500})[@"viewed"] isEqual:@2500]);
    // A real value is what the assistant reads, even beside a later estimate; an estimate alone says so.
    NSDictionary* fields = SPDFDocumentActivityFields(merged, Shanghai());
    EXPECT([fields[@"last_viewed"] isEqual:SPDFDocumentActivityISO(2000, Shanghai())] && !fields[@"last_viewed_estimated"]);
    fields = SPDFDocumentActivityFields(guess, Shanghai());
    EXPECT([fields[@"last_opened_estimated"] isEqual:@YES] && [fields[@"last_viewed_estimated"] isEqual:@YES]);
    fields = SPDFDocumentActivityFields(@{@"estimate" : @{@"notViewedSince" : @1791340740}}, Shanghai());
    EXPECT(fields[@"last_viewed"] == NSNull.null && [fields[@"not_viewed_since"] isEqual:@"2026-10-07T10:39:00+08:00"]);
    fields = SPDFDocumentActivityFields(nil, Shanghai());
    EXPECT(fields[@"last_opened"] == NSNull.null && fields[@"last_viewed"] == NSNull.null && fields.count == 2);
    EXPECT([SPDFDocumentActivityISO(1793000000, Shanghai()) isEqual:@"2026-10-26T15:33:20+08:00"]);
    NSDictionary* combined = SPDFDocumentActivityCombine(@[ @{@"viewed" : @10}, @{@"viewed" : @30, @"opened" : @5} ]);
    EXPECT([combined[@"viewed"] isEqual:@30] && [combined[@"opened"] isEqual:@5]);
}

static void TestParseAndNotViewedSince(void) {
    EXPECT(SPDFDocumentActivityParseTime(@"2026-10-19", Shanghai()) == 1792339200);
    EXPECT(SPDFDocumentActivityParseTime(@"2026-10-19T08:00:00+08:00", Shanghai()) == 1792368000);
    EXPECT(SPDFDocumentActivityParseTime(@"2026-10-19T00:00:00Z", Shanghai()) == 1792368000);
    EXPECT(isnan(SPDFDocumentActivityParseTime(@"last week", Shanghai())));
    double cutoff = 1000;
    EXPECT(SPDFDocumentActivityNotViewedSince(@{@"viewed" : @900}, cutoff, 0) == 1);
    EXPECT(SPDFDocumentActivityNotViewedSince(@{@"viewed" : @1100}, cutoff, 0) == 0);
    EXPECT(SPDFDocumentActivityNotViewedSince(@{@"estimate" : @{@"viewed" : @900}}, cutoff, 0) == 1);
    EXPECT(SPDFDocumentActivityNotViewedSince(@{@"estimate" : @{@"viewed" : @1100}}, cutoff, 0) == 0);
    EXPECT(SPDFDocumentActivityNotViewedSince(@{@"estimate" : @{@"notViewedSince" : @800}}, cutoff, 0) == 1);
    // "Not viewed after 1200" says nothing about 1000..1200.
    EXPECT(SPDFDocumentActivityNotViewedSince(@{@"estimate" : @{@"notViewedSince" : @1200}}, cutoff, 0) == -1);
    EXPECT(SPDFDocumentActivityNotViewedSince(@{@"estimate" : @{@"opened" : @1100}}, cutoff, 0) == -1);
    EXPECT(SPDFDocumentActivityNotViewedSince(nil, cutoff, 0) == -1);
    // Views recorded since before the cutoff: no real view since means not viewed, whatever the estimates say.
    EXPECT(SPDFDocumentActivityNotViewedSince(nil, cutoff, 900) == 1);
    EXPECT(SPDFDocumentActivityNotViewedSince(@{@"estimate" : @{@"viewed" : @1100}}, cutoff, 900) == 1);
    EXPECT(SPDFDocumentActivityNotViewedSince(@{@"viewed" : @1001}, cutoff, 900) == 0);
    // Recorded only since after the cutoff: a real view after it still says viewed.
    EXPECT(SPDFDocumentActivityNotViewedSince(@{@"viewed" : @1500}, cutoff, 1400) == 0);
}

static void TestBackfill(void) {
    NSDictionary* session = @{@"windows" : @[ @{@"focusedAt" : @(814690106), @"selectedTab" : @1, @"tabs" : @[
        @{@"path" : @"/docs/a.pdf", @"lastViewedAt" : @(814600000)},
        @{@"path" : @"/docs/b.pdf", @"lastViewedAt" : @(814500000)},
        @{@"path" : @"/docs/never.pdf", @"lastViewedAt" : @0},
        @{@"path" : @"/docs/c.pdf", @"lastViewedAt" : @(813033540)} ]} ]};
    NSArray* collection = @[ @{@"path" : @"/docs/kept.pdf", @"aliases" : @[ @"/old/kept.pdf" ], @"capturedAt" : @1790000000,
                               @"lastOpenedAt" : @1791000000,
                               @"versions" : @[ @{@"reason" : @"Opened", @"capturedAt" : @1791500000} ]},
                             @{@"path" : @"/docs/a.pdf", @"capturedAt" : @1700000000} ];
    NSMutableArray* asked = [NSMutableArray array];
    NSDictionary* guesses = SPDFDocumentActivityBackfill(session, collection, @[ @"/docs/recent.pdf", @"/docs/a.pdf" ],
        ^NSTimeInterval(NSString* path) {
            [asked addObject:path];
            return [path isEqual:@"/docs/recent.pdf"] ? 1792000000 : 1795000000;
        }, 0);
    // Tab activation times are reference-date seconds; everything lands under "estimate" in Unix seconds.
    EXPECT([guesses[@"/docs/a.pdf"][@"estimate"][@"viewed"] isEqual:@(814600000 + kRef)]);
    EXPECT(!guesses[@"/docs/a.pdf"][@"viewed"] && !guesses[@"/docs/a.pdf"][@"opened"]);
    // The selected tab was in front when its window was last focused.
    EXPECT([guesses[@"/docs/b.pdf"][@"estimate"][@"viewed"] isEqual:@(814690106 + kRef)]);
    EXPECT([guesses[@"/docs/b.pdf"][@"estimate"][@"opened"] isEqual:@(814500000 + kRef)]);
    // Never selected since activation times were recorded: not viewed since the earliest one.
    EXPECT([guesses[@"/docs/never.pdf"][@"estimate"][@"notViewedSince"] isEqual:@(813033540 + kRef)]);
    EXPECT(!guesses[@"/docs/never.pdf"][@"estimate"][@"viewed"]);
    // Collection: the latest open of a document, under its names; outside the session an open is the view.
    EXPECT([guesses[@"/docs/kept.pdf"][@"estimate"][@"opened"] isEqual:@1795000000]);
    EXPECT([guesses[@"/old/kept.pdf"][@"estimate"][@"opened"] isEqual:@1791500000]);
    EXPECT([guesses[@"/docs/kept.pdf"][@"estimate"][@"viewed"] isEqual:@1795000000]);
    EXPECT([guesses[@"/docs/recent.pdf"][@"estimate"][@"opened"] isEqual:@1792000000]);
    // Spotlight is not asked about documents the session knows (another app's open is not a view here).
    EXPECT(![asked containsObject:@"/docs/a.pdf"] && [asked containsObject:@"/docs/recent.pdf"]);
    EXPECT(SPDFDocumentActivityBackfill(nil, nil, nil, nil, 0).count == 0);
    // A brand-new profile: what happened once this build recorded real values is no estimate. A tab only selected
    // since (an activation time after `before`) gets no viewed guess, and Collection opens since are dropped.
    NSTimeInterval before = 814550000 + kRef;
    guesses = SPDFDocumentActivityBackfill(session, collection, nil, nil, before);
    EXPECT(!guesses[@"/docs/a.pdf"] || !guesses[@"/docs/a.pdf"][@"estimate"][@"viewed"]);
    EXPECT([guesses[@"/docs/b.pdf"][@"estimate"][@"viewed"] isEqual:@(814500000 + kRef)]);
    EXPECT([guesses[@"/docs/kept.pdf"][@"estimate"][@"opened"] isEqual:@1791500000]);
}

static NSString* TemporaryDirectory(void) {
    NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"spdf-activity-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    return path;
}

static void TestStore(void) {
    NSString* directory = TemporaryDirectory();
    NSString* file = [directory stringByAppendingPathComponent:SPDFDocumentActivityFileName];
    [@"windows:\n  - selectedTab: 0\n    focusedAt: 0\n    tabs:\n      - path: \"/docs/old.pdf\"\n        lastViewedAt: 800000000\n"
        writeToFile:[directory stringByAppendingPathComponent:@"session.yaml"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    SPDFMacDocumentActivityStore* store = [[SPDFMacDocumentActivityStore alloc] initWithDirectory:directory];
    store.lastUsedDate = ^NSTimeInterval(NSString* path) { (void)path; return 0; };
    store.flushDelay = 0.2;
    // Launch: recording stays in memory. No queue, no file, no timer until -start.
    [store recordOpenedPath:@"/docs/../docs/a.pdf" at:1000];
    [store recordViewedPath:@"/docs/a.pdf" at:1002];
    [NSThread sleepForTimeInterval:0.4];
    EXPECT(!store.hasQueue);
    EXPECT(![NSFileManager.defaultManager fileExistsAtPath:file]);
    [store start];
    EXPECT(store.hasQueue);
    [NSThread sleepForTimeInterval:0.6];
    NSString* text = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil];
    EXPECT([text containsString:@"/docs/a.pdf"] && [text containsString:@"backfilledAt"] &&
           [text hasPrefix:@"# ShenzhenPDF activity"]);
    // Another window's process, writing the same file: both keep their values; the backfill ran once.
    SPDFMacDocumentActivityStore* other = [[SPDFMacDocumentActivityStore alloc] initWithDirectory:directory];
    other.lastUsedDate = store.lastUsedDate;
    [other start];
    [other recordViewedPath:@"/docs/b.pdf" at:3000];
    [other recordViewedPath:@"/docs/a.pdf" at:1001];
    [other flushNow];
    NSDictionary* entries = [store entriesForPaths:@[ @"/docs/a.pdf", @"/docs/b.pdf", @"/docs/old.pdf", @"/docs/none.pdf" ]];
    EXPECT([entries[@"/docs/a.pdf"][@"viewed"] isEqual:@1002] && [entries[@"/docs/a.pdf"][@"opened"] isEqual:@1000]);
    EXPECT([entries[@"/docs/b.pdf"][@"viewed"] isEqual:@3000]);
    EXPECT([entries[@"/docs/old.pdf"][@"estimate"][@"viewed"] isEqual:@(800000000 + kRef)]);
    EXPECT([entries[@"/docs/none.pdf"] count] == 0);
    EXPECT(store.recordedSince == 1000);
    // Unsaved values are part of every answer.
    [store recordViewedPath:@"/docs/c.pdf" at:4000];
    EXPECT([[store entriesForPaths:@[ @"/docs/c.pdf" ]][@"/docs/c.pdf"][@"viewed"] isEqual:@4000]);
    // A real view of a backfilled document is kept beside its estimate, and is what the assistant reads.
    [store recordViewedPath:@"/docs/old.pdf" at:5000];
    [store flushNow];
    SPDFMacDocumentActivityStore* reopened = [[SPDFMacDocumentActivityStore alloc] initWithDirectory:directory];
    reopened.lastUsedDate = store.lastUsedDate;
    NSDictionary* old = [reopened entriesForPaths:@[ @"/docs/old.pdf" ]][@"/docs/old.pdf"];
    EXPECT([old[@"viewed"] isEqual:@5000] && old[@"estimate"]);
    EXPECT([SPDFDocumentActivityFields(old, Shanghai())[@"last_viewed"] isEqual:SPDFDocumentActivityISO(5000, Shanghai())]);
    NSString* written = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil];
    NSUInteger backfills = [written componentsSeparatedByString:@"backfilledAt"].count - 1;
    EXPECT(backfills == 1);
    [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
}

int main(void) {
    @autoreleasepool {
        TestClock();
        TestViewingState();
        TestMergeAndFields();
        TestParseAndNotViewedSince();
        TestBackfill();
        TestStore();
    }
    if (failures) { NSLog(@"SPDFMacDocumentActivityTests: %d failed", failures); return 1; }
    printf("SPDFMacDocumentActivityTests passed\n");
    return 0;
}
